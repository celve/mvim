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
/// pure-testable. Of Cocoa's keys it emulates only the ones lane B counts
/// with, on unwrapped text; every other `press` (the blind lane's chords,
/// undo) counts as `unsupportedSteps`, because the Sim can only prove we
/// emit the plans we designed, never that a blind plan works in a real app.
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

    /// What `AXSelectedTextRange` answers for a true offset; `AXSelectedText` stays true. Chromium's
    /// contenteditables drop the paragraph breaks before it, or read it as its block's start (LIN-1533).
    public var reads: (_ offset: Int, _ text: String) -> Int = { offset, _ in offset }

    public var readSelection: Range<Int> {
        let lower = reads(selection.lowerBound, text)
        return lower..<max(lower, reads(selection.upperBound, text))
    }

    public private(set) var bells = 0
    public private(set) var settleFailures = 0
    public private(set) var unsupportedSteps = 0

    private var monitor = RawMonitor()
    private var captures: [CaptureSlot: String] = [:]

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
        let abortedAt = execute(physical)
        guard abortedAt == nil else {
            // Abort hygiene, mirroring the Controller down to the stand-down.
            if !repairStrandedSelection(operand: planned.operand(abortedAt: abortedAt)),
               state.field.mode.isInserting {
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
    /// The index of the step that ended the run, nil when every step ran.
    mutating func execute(_ plan: PhysicalPlan) -> Int? {
        for (index, step) in plan.steps.enumerated() {
            switch step {
            case .setSelection(let range):
                guard !swallowsSelect else { break }
                let model = TextModel(text)
                selection = model.clamp(range.lowerBound)..<model.clamp(range.upperBound)

            case .replaceSelection(let replacement):
                if !swallowsReplace { applyReplace(replacement) }

            case .typeText(let typed):
                applyReplace(typed)

            case .press(let chord, let count):
                for _ in 0..<count {
                    guard press(chord) else {
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
                captures[slot] = TextModel(text).substring(selection)

            case .settle(let expectation):
                // A non-answer satisfies nothing, exactly as `Expectation.matches` has it.
                let converged = expectation.matches(
                    selection: unreadableSelection ? nil : readSelection,
                    length: text.utf16.count,
                    selectedText: TextModel(text).substring(selection)
                )
                if !converged {
                    settleFailures += 1
                    drainResidency(of: plan, after: index)
                    return index   // the rest dies, like the real executor
                }

            case .softSettle:
                // Best-effort barrier: never aborts. In this synchronous host
                // there is nothing async to wait for, and the blind step it
                // follows may be an unsupported no-op, so the field need not match
                // the prediction — which is exactly why a soft settle must proceed.
                break

            case .commit(let effect):
                state = VimReducer.reduce(state, effect, captures: captures)

            case .bell:
                bells += 1
            }
        }
        return nil
    }

    /// Lane B's keys as LIN-1533 measured them — an arrow collapses a selection to its own side, ↓ moving
    /// from its end; false for any other chord.
    mutating func press(_ chord: Chord) -> Bool {
        let model = TextModel(text)
        let caret: Int
        switch chord {
        case .left:
            caret = selection.isEmpty ? model.advance(selection.lowerBound, byGraphemes: -1) : selection.lowerBound
        case .right:
            caret = selection.isEmpty ? model.advance(selection.upperBound, byGraphemes: 1) : selection.upperBound
        case .up:
            caret = model.verticalMove(from: selection.lowerBound, by: -1, firstNonBlank: false)
        case .down:
            caret = model.verticalMove(from: selection.upperBound, by: 1, firstNonBlank: false)
        case .lineStart:
            caret = model.lineStart(of: selection.lowerBound)
        case .selectRight:
            selection = selection.lowerBound..<model.advance(selection.upperBound, byGraphemes: 1)
            return true
        case .deleteBack:
            if selection.isEmpty {
                selection = model.advance(selection.lowerBound, byGraphemes: -1)..<selection.upperBound
            }
            applyReplace("")
            return true
        default:
            return false
        }
        selection = caret..<caret
        return true
    }

    /// The twin of the real executor's surviving-commit scan.
    mutating func drainResidency(of plan: PhysicalPlan, after index: Int) {
        for survivor in plan.steps[(index + 1)...] {
            if case .commit(let effect) = survivor, effect.survivesAbort {
                state = VimReducer.reduce(state, effect, captures: captures)
            }
        }
    }

    mutating func applyReplace(_ replacement: String) {
        text = TextModel(text).replacing(selection, with: replacement)
        let caretAfter = selection.lowerBound + replacement.utf16.count
        selection = caretAfter..<caretAfter
    }
}
