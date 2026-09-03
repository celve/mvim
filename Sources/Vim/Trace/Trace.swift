/// Engine values as short strings, for the recorder's log lines.
///
/// Pure and `Foundation`-free so `make test` pins every renderer — this is the
/// highest-churn code in the feature and the only place the redaction rule can
/// be enforced by a machine rather than by discipline.
///
/// **The redaction rule.** No renderer here ever emits a `String` or
/// `Character` payload carried by a step, an effect or a register. Field text,
/// typed text, search patterns and Ex command lines all reach the engine as
/// those payloads, and none of them is diagnostic — lengths and case names
/// are. `Diag` may log more when the user has opted in; `Trace` never does.
///
/// **The plan alphabet** (`shape`), one character per step, in order:
///
///     W setSelection   R replaceSelection   P press      T typeText
///     X clipboardCut   Y clipboardCopy      V clipboardInsert
///     G captureSelectedText                 ! settle     ? softSettle
///     . commit         B bell
///
/// A `press` posting more than once carries its count (`P3`), so `P3` and `PP`
/// stay distinguishable. Order is the diagnostic: a `!` directly after a `P` is
/// a hard settle verifying a blind actuation, which can never attribute its
/// failure to a capability (`Executor`'s positional attribution clears on
/// `press`), so it teaches the learner nothing and rings forever.
enum Trace {
    // MARK: - Capabilities

    /// One binding's whole capability resolution: `RT+p RL+p WS-l …`, in
    /// `Capability.allCases` order so the columns line up between lines.
    /// Status is `+ - ?`, source is `p s u l`; `??` is an atom the report
    /// does not mention at all.
    static func caps(_ report: CapabilityReport) -> String {
        var out = ""
        for capability in Capability.allCases {
            if !out.isEmpty { out += " " }
            out += initials(capability)
            guard let entry = report.entries[capability] else {
                out += "??"
                continue
            }
            out += mark(entry.status) + mark(entry.source)
        }
        return out
    }

    static func name(_ capability: Capability) -> String { capability.rawValue }

    /// `[writeSelection insertText]`, in declaration order — a `Set` has none.
    static func names(_ capabilities: Set<Capability>) -> String {
        "[" + Capability.allCases.filter(capabilities.contains).map(name).joined(separator: " ") + "]"
    }

    static func initials(_ capability: Capability) -> String {
        switch capability {
        case .readText: return "RT"
        case .readLength: return "RL"
        case .readCaret: return "RC"
        case .readSelectedText: return "RS"
        case .writeSelection: return "WS"
        case .insertText: return "IT"
        case .drawCursor: return "DC"
        case .wholeDocument: return "WD"
        case .fieldIsSession: return "FS"
        }
    }

    static func mark(_ status: CapabilityStatus) -> String {
        switch status {
        case .available: return "+"
        case .unavailable: return "-"
        case .unknown: return "?"
        }
    }

    static func mark(_ source: CapabilityReport.Source) -> String {
        switch source {
        case .probed: return "p"
        case .seeded: return "s"
        case .user: return "u"
        case .learned: return "l"
        }
    }

    // MARK: - Plans

    /// The physical plan as an ordered string of opcodes. See the type's doc
    /// comment for the alphabet.
    static func shape(_ plan: PhysicalPlan) -> String {
        plan.steps.map(opcode).joined()
    }

    static func opcode(_ step: PhysicalStep) -> String {
        switch step {
        case .setSelection: return "W"
        case .replaceSelection: return "R"
        case .press(_, let count): return count > 1 ? "P\(count)" : "P"
        case .typeText: return "T"
        case .clipboardCut: return "X"
        case .clipboardCopy: return "Y"
        case .clipboardInsert: return "V"
        case .captureSelectedText: return "G"
        case .settle: return "!"
        case .softSettle: return "?"
        case .commit: return "."
        case .bell: return "B"
        }
    }

    /// A logical step by case name, with only non-textual payloads. The step
    /// type is what identifies a rejection: it narrows the planner's 26
    /// `return nil` sites to one or two.
    static func name(_ step: LogicalStep) -> String {
        switch step {
        case .moveCaret: return "moveCaret"
        case .select: return "select"
        case .extendSelection: return "extendSelection"
        case .collapseSelection: return "collapseSelection"
        case .swapSelectionEnds: return "swapSelectionEnds"
        case .deleteSelection: return "deleteSelection"
        case .yankSelection: return "yankSelection"
        case .replaceSelection(let text): return "replaceSelection(\(text.utf16.count))"
        case .transformSelection: return "transformSelection"
        case .insertText(let text): return "insertText(\(text.utf16.count))"
        case .put: return "put"
        case .joinLines(let count, _): return "joinLines(\(count))"
        case .setMode(let mode): return "setMode(\(name(mode)))"
        case .setMark: return "setMark"
        case .history: return "history"
        case .commit: return "commit"
        case .renderCursor: return "renderCursor"
        case .bell(let reason): return "bell(\(name(reason)))"
        }
    }

    /// Why a plan rang — the reason `LogicalStep.BellReason` has carried for
    /// the recorder since before one existed. Register and mark names are
    /// dropped: `keys` already shows the command that named them.
    static func name(_ reason: LogicalStep.BellReason) -> String {
        switch reason {
        case .unsupported: return "unsupported"
        case .emptyRegister: return "emptyRegister"
        case .unsetMark: return "unsetMark"
        case .noPriorFind: return "noPriorFind"
        case .noPriorSearch: return "noPriorSearch"
        case .noPriorChange: return "noPriorChange"
        case .noPriorVisual: return "noPriorVisual"
        }
    }

    static func name(_ mode: LogicalStep.Mode) -> String {
        switch mode {
        case .normal: return "normal"
        case .insert: return "insert"
        case .replace: return "replace"
        case .visual: return "visual"
        }
    }

    static func name(_ transition: FocusTransition) -> String {
        switch transition {
        case .sameElement: return "sameElement"
        case .sameDocument: return "sameDocument"
        case .newSession: return "newSession"
        }
    }

    static func name(_ mode: VimState.Mode?) -> String {
        switch mode {
        case .none: return "unbound"
        case .normal: return "normal"
        case .insert: return "insert"
        case .replace: return "replace"
        case .visual: return "visual"
        }
    }

    // MARK: - Commands

    /// The keys that produced a command. Vim syntax is not content, with two
    /// exceptions: a search pattern and an Ex command line are typed by the
    /// user and are dropped for their length.
    static func keys(_ command: RawCommand) -> String {
        switch command.intent {
        case .search: return "search…(\(command.source.utf16.count))"
        case .commandLine: return "cmdline…(\(command.source.utf16.count))"
        default: return command.source
        }
    }

    // MARK: - Ranges

    static func range(_ range: Range<Int>?) -> String {
        guard let range else { return "nil" }
        return "\(range.lowerBound)..\(range.upperBound)"
    }

    static func optional(_ value: Int?) -> String {
        guard let value else { return "nil" }
        return "\(value)"
    }
}
