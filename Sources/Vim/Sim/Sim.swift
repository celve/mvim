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
/// It executes lane-A/B AX and clipboard steps exactly. It does **not**
/// emulate Cocoa key semantics: `press` steps (blind lanes, undo) count as
/// `unsupportedSteps`, because the Sim can only prove we emit the plans we
/// designed, never that a blind plan works in a real app.
public struct Sim {
    public private(set) var text: String
    public private(set) var selection: Range<Int>
    public private(set) var state: VimState
    public private(set) var pasteboard: String?
    public var profile: CapabilityProfile

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
        let snapshot = FieldSnapshot(text: text, selection: selection, anchor: anchor)
        let physical = PhysicalPlanner.plan(logical, snapshot: snapshot, profile: profile)

        captures = [:]
        execute(physical)

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
    mutating func execute(_ plan: PhysicalPlan) {
        for step in plan.steps {
            switch step {
            case .setSelection(let range):
                let model = TextModel(text)
                selection = model.clamp(range.lowerBound)..<model.clamp(range.upperBound)

            case .replaceSelection(let replacement):
                applyReplace(replacement)

            case .typeText(let typed):
                applyReplace(typed)

            case .press:
                unsupportedSteps += 1

            case .clipboardCapture(let slot, let cutting):
                captures[slot] = TextModel(text).substring(selection)
                if cutting { applyReplace("") }

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
                    return   // abort the remainder, like the real executor
                }

            case .commit(let effect):
                state = VimReducer.reduce(state, effect, captures: captures)

            case .bell:
                bells += 1
            }
        }
    }

    mutating func applyReplace(_ replacement: String) {
        text = TextModel(text).replacing(selection, with: replacement)
        let caretAfter = selection.lowerBound + replacement.utf16.count
        selection = caretAfter..<caretAfter
    }
}
