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
/// pure-testable. It does **not** emulate Cocoa key semantics: `press`
/// steps (blind lanes, undo) count as `unsupportedSteps`, because the Sim
/// can only prove we emit the plans we designed, never that a blind plan
/// works in a real app.
public struct Sim {
    public private(set) var text: String
    public private(set) var selection: Range<Int>
    public private(set) var state: VimState
    /// The modeled system pasteboard — the blind lanes' register.
    public private(set) var pasteboard: String?
    public var profile: CapabilityProfile

    /// A host that accepts an AX write and does nothing — the Chromium
    /// contenteditable a hard settle exists to catch.
    public var swallowsWrites = false

    public private(set) var bells = 0
    public private(set) var settleFailures = 0
    public private(set) var unsupportedSteps = 0

    private var monitor = RawMonitor()
    private var captures: [CaptureSlot: String] = [:]

    /// A mutating command that entered Insert leaves its dot body open until
    /// the session's Esc delivers the typed payload.
    private var openChange: (source: String, count: Int?, register: Register?)?

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
        return execute(PhysicalPlan(steps: steps))
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
        if let drawn = state.field.cursor, !drawn.isEmpty, drawn == selection {
            cursor = drawn
        }
        let snapshot = FieldSnapshot(
            capabilities: profile,
            text: text,
            selection: selection,
            anchor: anchor,
            cursor: cursor
        )
        let planned = PhysicalPlanner.planning(logical, snapshot: snapshot)
        let physical = planned.plan

        captures = [:]
        let executed = execute(physical)
        guard executed else {
            // Abort hygiene, mirroring the Controller: collapse the stranded
            // selection unless it is the operand the app is about to type over,
            // and record no memories.
            if !selection.isEmpty, !(state.field.mode.isInserting && selection == planned.operand) {
                selection = selection.lowerBound..<selection.lowerBound
            }
            return
        }

        if let payload = completed.insertPayload {
            state = VimReducer.reduce(state, .setLastInsert(payload))
            if let change = openChange {
                state = VimReducer.reduce(state, .setLastChange(VimState.ChangeMemory(
                    body: change.source + payload + "<Esc>",
                    count: change.count,
                    register: change.register
                )))
                openChange = nil
            }
        }

        recordChange(for: command, mutated: physical.mutatesText)
    }

    /// Dot-worthiness, the runtime lore: a mutating command becomes
    /// `lastChange` — unless it *entered* Insert, in which case the body
    /// stays open until Esc appends the typed payload. Plain insert entries
    /// (`i`, `A`) open a body too: their mutation is the typing itself.
    mutating func recordChange(for command: RawCommand, mutated: Bool) {
        if case .repeat = command.intent { return }   // `.` must not overwrite what it replays
        let enteredInsert: Bool
        switch state.field.mode {
        case .insert, .replace: enteredInsert = true
        default: enteredInsert = false
        }
        if enteredInsert {
            if openChange == nil {
                openChange = (command.source, command.count, command.register)
            }
            return
        }
        guard mutated else { return }
        state = VimReducer.reduce(state, .setLastChange(VimState.ChangeMemory(
            body: command.source,
            count: command.count,
            register: command.register
        )))
    }

    /// Insert-mode passthrough typing lands in the fake field the way the
    /// real app would apply it.
    mutating func applyTyping(_ token: String) {
        guard token.count == 1, let scalar = token.unicodeScalars.first else { return }
        if scalar.value < 0x20, token != "\n", token != "\r", token != "\t" { return }
        applyReplace(token == "\r" ? "\n" : token)
    }
}

// MARK: - Physical step interpreter

private extension Sim {
    mutating func execute(_ plan: PhysicalPlan) -> Bool {
        for (index, step) in plan.steps.enumerated() {
            switch step {
            case .setSelection(let range):
                let model = TextModel(text)
                selection = model.clamp(range.lowerBound)..<model.clamp(range.upperBound)

            case .replaceSelection(let replacement):
                if !swallowsWrites { applyReplace(replacement) }

            case .typeText(let typed):
                applyReplace(typed)

            case .press:
                unsupportedSteps += 1

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
                var converged = true
                if let expected = expectation.selection {
                    converged = converged && expected == selection
                }
                if let expectedLength = expectation.length {
                    converged = converged && expectedLength == text.utf16.count
                }
                if !converged {
                    settleFailures += 1
                    drainResidency(of: plan, after: index)
                    return false   // the rest dies, like the real executor
                }

            case .softSettle:
                // Best-effort barrier: never aborts. In this synchronous host
                // there is nothing async to wait for, and the blind step it
                // follows is an unsupported no-op, so the field won't match the
                // prediction — which is exactly why a soft settle must proceed.
                break

            case .commit(let effect):
                state = VimReducer.reduce(state, effect, captures: captures)

            case .bell:
                bells += 1
            }
        }
        return true
    }

    /// Acting is over, but residency was never the field's to veto — the twin
    /// of the real executor's surviving-commit scan.
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
