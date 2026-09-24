/// A simulated host: an in-memory text field plus the full engine loop.
///
/// The Sim plays the runtime's role against a fake field — it feeds tokens
/// through the monitor, plans against its own text/selection, interprets
/// the physical steps by string surgery, verifies settles against itself,
/// and hands commits to the reducer. That closes the loop entirely in pure
/// code: end-to-end goldens of the form
/// `(text, caret, keystrokes) → (text′, caret′, state′)` run under
/// `make test`, and later the flight recorder can replay through the same
/// machine.
///
/// It executes lane-A/B AX and clipboard steps exactly — including the
/// modeled pasteboard, written by `clipboardCut`/`clipboardCopy` and read
/// by `clipboardInsert(nil)`, which makes the clipboard=unnamed contract
/// pure-testable. Of Cocoa's keys it emulates, through `KeyModel`, the
/// ones lane B counts with, and every one the model knows under
/// `emulatesKeys`; any other `press` (the blind lane's chords, undo) counts
/// as `unsupportedSteps`, because the Sim can only prove we emit the plans
/// we designed, never that a blind plan works in a real app.
///
/// Its faults are the only way a golden reaches the abort path at all.
public struct Sim {
    public private(set) var text: String
    public private(set) var selection: Range<Int>
    public private(set) var state: VimState
    /// The modeled system pasteboard — the blind lanes' register.
    public private(set) var pasteboard: String?
    public var profile: CapabilityProfile

    /// Accepts `AXSelectedText` and does nothing — the Chromium contenteditable.
    public var swallowsReplace = false

    /// The same lie about `AXSelectedTextRange` — what a `writeSelection` demotion leaves.
    public var swallowsSelect = false

    /// Answers no `AXSelectedTextRange` at all — the recorder's `answered=0`.
    public var unreadableSelection = false

    /// Makes the field a Chromium contenteditable: `AXSelectedTextRange` starts at `reads` of the selection's
    /// start and is as long as `AXSelectedText`, the true selected text less its paragraph breaks (LIN-1533).
    public var reads: ((_ offset: Int, _ text: String) -> Int)?

    public var readSelection: Range<Int> {
        guard let reads else { return selection }
        let start = reads(selection.lowerBound, text)
        return start..<start + readSelectedText.utf16.count
    }

    public var readSelectedText: String {
        let selected = TextModel(text).substring(selection)
        return reads == nil ? selected : selected.filter { $0 != "\n" }
    }

    /// Where the last command's run ended early, if it did.
    public private(set) var abortedStep: PhysicalStep?

    /// Every key `KeyModel` knows runs, not only the ones lane B counts with.
    public var emulatesKeys = false

    /// Graphemes per visual row for ↓ ↑ ⌘← ⌘→; nil puts each line on one row.
    public var wrapWidth: Int?

    /// Keys this field ignores, as an app that rebinds them would.
    public var ignoredChords: Set<Chord> = []

    /// Keys this field treats as others, as an app that rebinds ⌃A to select-all would.
    public var reboundChords: [Chord: Chord] = [:]

    /// Keys the failed settles blamed, in order.
    public private(set) var blamed: [Capability] = []

    /// The lowest world the last run's settles matched, when it was not `AXValue`'s own.
    public private(set) var world: Int?

    public private(set) var bells = 0
    public private(set) var settleFailures = 0
    /// Runs stopped at a branch that more than one reading of the field still fit.
    public private(set) var ambiguities = 0
    public private(set) var unsupportedSteps = 0

    private var monitor = RawMonitor()
    private var captures: [CaptureSlot: String] = [:]

    /// The focus is the selection's lower bound.
    private var backward = false

    /// The command that opened the current Insert session, recorded at its Esc.
    private var openChange: (source: String, count: Int?, register: Register?, mutated: Bool)?

    public init(
        text: String,
        caret: Int = 0,
        state: VimState = .initial,
        profile: CapabilityProfile
    ) {
        self.text = text
        let clamped = TextModel(text).clamp(caret)
        self.selection = clamped..<clamped
        self.state = state
        self.profile = profile
    }

    public var caret: Int { selection.lowerBound }

    /// Feed each character of `keys` as one token.
    public mutating func type(_ keys: String) {
        for character in keys {
            feed(String(character))
        }
    }

    public mutating func feed(_ token: String) {
        let mode: RawMonitor.Mode
        switch state.field.mode {
        case .normal: mode = .normal
        case .visual: mode = .visual
        case .insert, .replace: mode = .insert
        }
        switch monitor.feed(token, mode: mode) {
        case .pending, .cancelled:
            break
        case .passthrough:
            applyTyping(token)
        case .command(let completed):
            run(completed)
        }
    }

    /// Step-level entry for goldens that exercise the interpreter directly —
    /// blind-lane plans never survive the keystroke loop (`.press` counts as
    /// unsupported), but their clipboard steps still deserve pure coverage.
    @discardableResult
    public mutating func perform(_ steps: [PhysicalStep]) -> Bool {
        captures = [:]
        return execute(PhysicalPlan(steps: steps)) == nil
    }

    /// `Controller.rebind`'s pure twin: focus moved, and the transition says
    /// how much of the session survives. Lives here rather than in an
    /// extension because `monitor` and `openChange` are private — and they
    /// are exactly what the paired-halves invariant is about.
    ///
    /// Pass `text` to model a `sameDocument` swap literally: the next block
    /// is different text whose offsets restart at zero, which is precisely
    /// what makes the departing field's offsets fiction.
    public mutating func refocus(_ transition: FocusTransition, text: String? = nil, caret: Int = 0) {
        if let text {
            self.text = text
            let clamped = TextModel(text).clamp(caret)
            selection = clamped..<clamped
        }
        state.field = state.field.carried(across: transition)
        if transition.clearsChangeInFlight {
            monitor.reset()
            openChange = nil
        }
    }
}

// MARK: - The runtime loop

private extension Sim {
    mutating func run(_ completed: RawMonitor.Completed) {
        let command = completed.command
        let logical = LogicalPlanner.plan(command, state: state)
        var anchor: Int?
        if case .visual(let context) = state.field.mode {
            anchor = context.anchor
        }
        // Same cursor match-stamp as the runtime's Snapshotter.
        var cursor: Range<Int>?
        if let drawn = state.field.cursor, !drawn.isEmpty, drawn == readSelection {
            cursor = drawn
        }
        let snapshot = FieldSnapshot(
            capabilities: profile,
            text: text,
            selection: readSelection,
            anchor: anchor,
            cursor: cursor
        )
        let planned = PhysicalPlanner.planning(logical, snapshot: snapshot)
        let physical = planned.plan
        let before = state.field.mode

        captures = [:]
        abortedStep = execute(physical)
        guard abortedStep == nil else {
            // Abort hygiene, mirroring the Controller down to the stand-down.
            if abortedStep?.checksSelectedText == true {
                if !unreadableSelection, !readSelection.isEmpty { _ = press(.left) }
                if state.field.mode.isInserting {
                    state = VimReducer.reduce(state, .setMode(before.nonVisual))
                }
            } else if !repairStrandedSelection(operand: planned.operand), state.field.mode.isInserting {
                state = VimReducer.reduce(state, .setMode(before.nonVisual))
            }
            // The monitor drained the payload it will never offer again.
            if let payload = completed.insertPayload, !state.field.mode.isInserting {
                closeInsertSession(payload, lossless: completed.insertPayloadIsLossless)
            }
            recordChange(for: command, from: before, mutated: physical.mutatesText, aborted: true)
            return
        }

        if let payload = completed.insertPayload {
            closeInsertSession(payload, lossless: completed.insertPayloadIsLossless)
        }

        recordChange(for: command, from: before, mutated: physical.mutatesText)
    }

    /// The Controller's twin, and it must obey the host the same way.
    mutating func repairStrandedSelection(operand: Range<Int>?) -> Bool {
        guard !unreadableSelection else { return false }   // unknown is not empty
        guard !readSelection.isEmpty else { return true }
        if state.field.mode.isInserting, readSelection == operand { return true }
        guard profile.has(.writeSelection), !swallowsSelect else { return false }
        selection = selection.lowerBound..<selection.lowerBound
        return true
    }

    /// Fold a just-ended Insert session into the dot memories.
    mutating func closeInsertSession(_ payload: String, lossless: Bool) {
        if !payload.isEmpty {
            state = VimReducer.reduce(state, .setLastInsert(payload))
        }
        guard let change = openChange else { return }
        openChange = nil
        guard lossless else {
            state = VimReducer.reduce(state, .setLastChange(.unreplayable))
            return
        }
        // An empty session is still a change if its entry mutated (`ciw`, `o`).
        guard change.mutated || !payload.isEmpty else { return }
        state = VimReducer.reduce(state, .setLastChange(VimState.ChangeMemory(
            body: change.source,
            count: change.count,
            register: change.register,
            insert: payload
        )))
    }

    /// Records a mutating command as `lastChange`, or opens a body if it entered Insert.
    mutating func recordChange(
        for command: RawCommand, from before: VimState.Mode, mutated: Bool, aborted: Bool = false
    ) {
        if case .repeat = command.intent { return }   // `.` must not overwrite what it replays
        // An aborted plan mutated nothing, whatever its steps intended.
        let changed = mutated && !aborted
        if case .visual = before {
            // Visual keys name a selection `.` cannot rebuild.
            if changed || state.field.mode.isInserting {
                state = VimReducer.reduce(state, .setLastChange(.unreplayable))
            }
            return
        }
        if state.field.mode.isInserting {
            if openChange == nil {
                openChange = (command.source, command.count, command.register, changed)
            }
            return
        }
        guard changed else { return }
        state = VimReducer.reduce(state, .setLastChange(VimState.ChangeMemory(
            body: command.source,
            count: command.count,
            register: command.register
        )))
    }

    /// Insert-mode passthrough typing lands in the fake field the way the
    /// real app would apply it.
    mutating func applyTyping(_ token: String) {
        if token == "<BS>" {
            if selection.isEmpty {
                selection = TextModel(text).advance(selection.lowerBound, byGraphemes: -1)..<selection.upperBound
            }
            applyReplace("")
            return
        }
        if token == "<CR>" {
            applyReplace("\n")
            return
        }
        guard token.count == 1, let scalar = token.unicodeScalars.first else { return }
        if scalar.value < 0x20, token != "\n", token != "\r", token != "\t" { return }
        applyReplace(token == "\r" ? "\n" : token)
    }
}

// MARK: - Physical step interpreter

private extension Sim {
    /// The step that ended the run, nil when every step ran.
    mutating func execute(_ plan: PhysicalPlan) -> PhysicalStep? {
        var queue = plan.steps
        // The worlds every settle so far has matched; nil is all of them.
        var consistent: Set<Int>?
        defer { world = consistent.flatMap { $0.contains(0) ? nil : $0.min() } }
        var index = 0
        while index < queue.count {
            switch queue[index] {
            case .branch(let branches):
                guard let chosen = Branch.chosen(from: branches, consistent: consistent) else {
                    ambiguities += 1
                    drainResidency(of: queue[index...], consistent: consistent)
                    return queue[index]
                }
                queue.replaceSubrange(index...index, with: chosen.steps)
                continue

            case .setSelection(let range):
                guard !swallowsSelect else { break }
                let model = TextModel(text)
                selection = model.clamp(range.lowerBound)..<model.clamp(range.upperBound)
                backward = false

            case .replaceSelection(let replacement):
                if !swallowsReplace { applyReplace(replacement) }

            case .typeText(let typed):
                applyReplace(typed)

            case .press(let chord, let count):
                for _ in 0..<count where !ignoredChords.contains(chord) {
                    guard emulatesKeys || Self.countedKeys.contains(chord), press(reboundChords[chord] ?? chord) else {
                        unsupportedSteps += 1
                        break
                    }
                }

            case .clipboardCut:
                pasteboard = TextModel(text).substring(selection)
                applyReplace("")

            case .clipboardCopy:
                pasteboard = TextModel(text).substring(selection)

            case .clipboardInsert(let content):
                applyReplace(content ?? pasteboard ?? "")

            case .captureSelectedText(let slot):
                captures[slot] = readSelectedText

            case .settle(let expectation):
                // A non-answer satisfies nothing, exactly as `Expectation.matches` has it.
                let observed = unreadableSelection ? nil : readSelection
                let matched = expectation.worlds(
                    matching: observed, length: text.utf16.count, selectedText: readSelectedText
                )
                let live = consistent.map(matched.intersection) ?? matched
                if live.isEmpty {
                    settleFailures += 1
                    if let key = expectation.blamed(observed: observed) { blamed.append(key) }
                    drainResidency(of: queue[(index + 1)...], consistent: consistent)
                    return queue[index]   // the rest dies, like the real executor
                }
                consistent = live

            case .softSettle(let expectation):
                // Best-effort barrier: never aborts, and narrows the worlds only when one matched.
                let observed = unreadableSelection ? nil : readSelection
                let matched = expectation.worlds(
                    matching: observed, length: text.utf16.count, selectedText: readSelectedText
                )
                let live = consistent.map(matched.intersection) ?? matched
                if !live.isEmpty { consistent = live }

            case .commit(let effect):
                state = VimReducer.reduce(state, effect, captures: captures)

            case .bell:
                bells += 1
            }
            index += 1
        }
        return nil
    }

    /// The keys lane B counts with, which run whether or not `emulatesKeys` is on.
    static let countedKeys: Set<Chord> = [.left, .right, .up, .down, .lineStart, .selectRight, .deleteBack]

    /// One key as `KeyModel` has Cocoa's bindings do it, which is how LIN-1533 measured Chromium's arrows; false for
    /// a key the model does not know.
    mutating func press(_ chord: Chord) -> Bool {
        var keys = KeyModel(
            text: text,
            anchor: backward ? selection.upperBound : selection.lowerBound,
            focus: backward ? selection.lowerBound : selection.upperBound,
            wrap: wrapWidth
        )
        guard keys.press(chord) else { return false }
        text = keys.text
        selection = keys.selection
        backward = keys.focus < keys.anchor
        return true
    }

    /// The twin of the real executor's surviving-commit scan.
    mutating func drainResidency(of steps: ArraySlice<PhysicalStep>, consistent: Set<Int>?) {
        for survivor in steps {
            switch survivor {
            case .commit(let effect) where effect.survivesAbort:
                state = VimReducer.reduce(state, effect, captures: captures)
            case .branch(let branches):
                let chosen = Branch.chosen(from: branches, consistent: consistent) ?? branches.first
                drainResidency(of: ArraySlice(chosen?.steps ?? []), consistent: consistent)
            default:
                break
            }
        }
    }

    mutating func applyReplace(_ replacement: String) {
        text = TextModel(text).replacing(selection, with: replacement)
        let caretAfter = selection.lowerBound + replacement.utf16.count
        selection = caretAfter..<caretAfter
        backward = false
    }
}
