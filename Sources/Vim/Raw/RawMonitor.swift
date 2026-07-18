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

    /// Keys passed through during the current Insert session; becomes the
    /// `insertPayload` handed over at Esc.
    private var insertLog: String = ""

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
        /// Consumed and buffered; more keys are needed.
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

        /// Text typed during the Insert session this command ends, delivered
        /// exactly once, at exit. The runtime folds it into `lastInsert` and
        /// the dot body.
        public let insertPayload: String?

        public init(command: RawCommand, insertPayload: String? = nil) {
            self.command = command
            self.insertPayload = insertPayload
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
    }
}

// MARK: - Insert mode

private extension RawMonitor {
    mutating func feedInsert(_ token: String) -> Verdict {
        if isEscape(token) {
            let payload = insertLog
            insertLog = ""
            return .command(Completed(
                command: RawCommand("<Esc>"),
                insertPayload: payload.isEmpty ? nil : payload
            ))
        }
        if let typed = typedText(of: token) {
            insertLog += typed
        }
        return .passthrough
    }

    /// What a token contributes to the typed log: plain characters and
    /// whitespace. Notation tokens (arrows, chords) pass through without
    /// logging — vim would split the insert session there; v1 just skips
    /// them.
    func typedText(of token: String) -> String? {
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
        // Esc on a non-empty buffer cancels the pending command (and, for
        // free, an open prompt). On an empty buffer it dispatches: Normal
        // no-ops, Visual exits.
        if isEscape(token), !pendingKeys.isEmpty {
            pendingKeys = ""
            return .cancelled
        }

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
        pendingKeys = candidate
        return .pending
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

    var isPromptBuffer: Bool {
        switch RawCommand(pendingKeys).intent {
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
