/// Assembles `RawCommand`s from one key token at a time.
///
/// The monitor is the keys-in-flight owner from the state design: a pure,
/// synchronous machine holding only the command buffer and the Insert-mode
/// typed log. The runtime tap translates hardware events into the notation
/// `RawCommand` speaks (`"a"`, `"<C-r>"`, `"<Esc>"`) and feeds them here;
/// keycodes, `SynthTag` bypass, and ⌘-chord filtering never reach this
/// layer.
///
/// Residency is passed in per key, not tracked — `VimState` stays the sole
/// source of truth, which obliges the runtime to process keys serially
/// (feed → plan → execute → commit) so each key is fed under the mode the
/// previous command produced.
///
/// No timers: the grammar has no complete-but-extensible command, so the
/// machine is purely event-driven. User mappings will break that property;
/// they arrive together with a flush entry point and a runtime timer.
public struct RawMonitor: Equatable, Sendable {
    /// The Normal/Visual command buffer, exposed for a showcmd-style HUD.
    public private(set) var pendingKeys: String = ""

    /// The most UTF-16 units `pendingKeys` holds.
    public static let pendingLimit = 256

    /// Keys passed through during the current Insert session; becomes the
    /// `insertPayload` handed over at Esc.
    private var insertLog: String = ""

    /// False once the session did something the log cannot express.
    private var insertLogIsLossless = true

    public init() {}

    /// Buffering-relevant residencies only — a local projection, because
    /// Raw sits below Execute and must not import `VimState.Mode` upward.
    /// Replace behaves as Insert here.
    public enum Mode: Equatable, Sendable {
        case normal
        case visual
        case insert
    }

    public enum Verdict: Equatable, Sendable {
        /// Consumed, and buffered where the buffer takes it; more keys are needed.
        case pending

        /// Consumed; a complete command to send through the planners.
        case command(Completed)

        /// Not vim's key — the app gets it.
        case passthrough

        /// Esc or backspace wiped a pending buffer; nothing to dispatch.
        case cancelled
    }

    public struct Completed: Equatable, Sendable {
        public let command: RawCommand

        /// Text typed in the session this command ends; nil when it ends none.
        public let insertPayload: String?

        /// False when the payload misses part of the session, so `.` must not replay it.
        public let insertPayloadIsLossless: Bool

        public init(command: RawCommand, insertPayload: String? = nil, insertPayloadIsLossless: Bool = true) {
            self.command = command
            self.insertPayload = insertPayload
            self.insertPayloadIsLossless = insertPayloadIsLossless
        }
    }

    public mutating func feed(_ token: String, mode: Mode) -> Verdict {
        switch mode {
        case .insert:
            return feedInsert(token)
        case .normal:
            return feedCommand(token, visual: false)
        case .visual:
            return feedCommand(token, visual: true)
        }
    }

    /// Focus moved: the runtime resets the monitor alongside `VimState.field`.
    public mutating func reset() {
        pendingKeys = ""
        insertLog = ""
        insertLogIsLossless = true
    }

    /// A key went to the app instead of vim: whatever command was half-typed
    /// is stale, because the app may have moved the caret out from under it.
    /// Only the command buffer is dropped — the Insert-mode typed log belongs
    /// to the session, not to any one command, and must survive.
    public mutating func cancelPending() {
        pendingKeys = ""
    }

    /// A chord or click changed the field behind the log's back mid-Insert.
    public mutating func markInsertLogLossy() {
        insertLogIsLossless = false
    }
}

// MARK: - Insert mode

private extension RawMonitor {
    mutating func feedInsert(_ token: String) -> Verdict {
        if isEscape(token) {
            let completed = Completed(
                command: RawCommand("<Esc>"),
                insertPayload: insertLog,
                insertPayloadIsLossless: insertLogIsLossless
            )
            insertLog = ""
            insertLogIsLossless = true
            return .command(completed)
        }
        if isBackspace(token) {
            // Past the typed text, it erased what the session never typed.
            if insertLog.isEmpty {
                insertLogIsLossless = false
            } else {
                insertLog.removeLast()
            }
        } else if let typed = typedText(of: token) {
            insertLog += typed
        } else {
            insertLogIsLossless = false
        }
        return .passthrough
    }

    /// A token's text in the log: Return is `"\n"`, other notation is nil.
    func typedText(of token: String) -> String? {
        if token == "<CR>" || token == "\r" { return "\n" }
        guard !isNotation(token) else { return nil }
        guard let scalar = token.unicodeScalars.first else { return nil }
        if scalar.value < 0x20, token != "\n", token != "\r", token != "\t" {
            return nil
        }
        return token
    }
}

// MARK: - Normal and Visual modes

private extension RawMonitor {
    mutating func feedCommand(_ token: String, visual: Bool) -> Verdict {
        // Esc cancels a pending command or an open prompt.
        if isEscape(token), !pendingKeys.isEmpty {
            pendingKeys = ""
            return .cancelled
        }

        // Idle, physical Esc in Normal is the app's, so a second Esc reaches its cancel; ⌃[ still dispatches.
        if token == "<Esc>", !visual { return .passthrough }

        // Backspace edits an open prompt; on an emptied prompt it cancels.
        // Outside prompts it stays a motion token (`d<BS>` is delete-left).
        if isBackspace(token), isPromptBuffer {
            pendingKeys.removeLast()
            return pendingKeys.isEmpty ? .cancelled : .pending
        }

        let candidate = pendingKeys + token
        let parsed = RawCommand(candidate)
        if isDispatchable(parsed, visual: visual) {
            pendingKeys = ""
            return .command(Completed(command: parsed))
        }
        // A key that completes nothing and cannot be held is taken and dropped, so a held key stops growing the buffer.
        if extendsFullCount(token, prompt: isPrompt(parsed.intent)) || candidate.utf16.count > Self.pendingLimit {
            return .pending
        }
        pendingKeys = candidate
        return .pending
    }

    /// A run of this many digits holds a count at its ceiling, even where the first of them names a register.
    static let fullCountDigits = String(Count.max).count + 2

    /// Whether `token` is a digit after a count already at Vim's ceiling, which it cannot change; a prompt's digits are text.
    func extendsFullCount(_ token: String, prompt: Bool) -> Bool {
        guard !prompt, token.count == 1, token.first.map(isDigit) ?? false else { return false }
        return pendingKeys.reversed().prefix(while: isDigit).count >= Self.fullCountDigits
    }

    func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// The completeness rules. `RawCommand.isComplete` alone is wrong in
    /// three mode-dependent ways, all decided here and nowhere else.
    func isDispatchable(_ command: RawCommand, visual: Bool) -> Bool {
        switch command.intent {
        case .incomplete(.operatorTarget):
            // A bare operator acts on the selection in Visual mode.
            return visual
        case .incomplete:
            return false
        case .search(let search):
            // `/nee` parses as a complete intent but is still assembling.
            return search.isSubmitted
        case .commandLine(let line):
            return line.isSubmitted
        case .modeChange(.insert(let position)):
            // In Visual, `i`/`a` begin a text object — wait for the object
            // key; the next key reparses as `.custom("iw")`.
            if visual, position == .beforeCursor || position == .afterCursor {
                return false
            }
            return true
        default:
            return true
        }
    }

    var isPromptBuffer: Bool { isPrompt(RawCommand(pendingKeys).intent) }

    func isPrompt(_ intent: RawCommand.Intent) -> Bool {
        switch intent {
        case .search(let search):
            return !search.isSubmitted
        case .commandLine(let line):
            return !line.isSubmitted
        case .incomplete(.search), .incomplete(.commandLine):
            return true
        default:
            return false
        }
    }
}

// MARK: - Token classification

private extension RawMonitor {
    func isNotation(_ token: String) -> Bool {
        token.count > 1 && token.hasPrefix("<") && token.hasSuffix(">")
    }

    func isEscape(_ token: String) -> Bool {
        token == "<Esc>" || token == "<C-[>" || token == "\u{1B}"
    }

    func isBackspace(_ token: String) -> Bool {
        token == "<BS>" || token == "\u{7F}" || token == "\u{08}"
    }
}
