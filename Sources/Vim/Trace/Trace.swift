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
///     C commit         B bell
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
        case .commit: return "C"
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

    /// The keys that produced a command — the literal source **only when the
    /// parse proves the user supplied no operand character**, and a shape plus
    /// a length otherwise.
    ///
    /// The discriminator cannot be the top-level intent: the payloads nest.
    /// `d/hunter2<CR>` is an `.operatorCommand` whose target is a search, and
    /// `rS` and `dfS` are an `.edit` and an `.operatorCommand` carrying a
    /// character of the document.
    ///
    /// And an operand is never *merely* syntax here, because of the bug this
    /// recorder exists to find: when Norm's mode tracking is wrong the user
    /// believes they are typing and every keystroke parses as a Normal-mode
    /// command, so `ma`, `"a`, `rS` and `.custom` are **letters of their
    /// prose**. That is why the register prefix redacts too, and why `.custom`
    /// — the unrecognized sequence a stranded session produces most — redacts
    /// rather than being waved through as "just keys".
    ///
    /// `ciw`, `3dd`, `w`, `dd`, `x`, `p`, `gg` and the rest of the ordinary
    /// vocabulary carry no operand and survive intact, which is the whole
    /// readability of the log.
    static func keys(_ command: RawCommand) -> String {
        guard command.register == nil, !carriesOperand(command.intent) else {
            return "\(shape(command.intent))…(\(command.source.utf16.count))"
        }
        return command.source
    }

    /// Did the user supply a character this command carries? **Exhaustive on
    /// purpose — no `default:` anywhere below**, so a new case cannot be added
    /// without deciding, and the decision is a compile error rather than a
    /// silent leak. That is the whole safety property; `shape` beneath it is
    /// only display and may default freely.
    static func carriesOperand(_ intent: RawCommand.Intent) -> Bool {
        switch intent {
        case .modeChange, .history, .repeat:
            return false
        // A mark or macro register is a name the user typed — see above.
        case .mark, .macro:
            return true
        // Kept as raw keys by their own design, so nothing has parsed them.
        case .window, .custom:
            return true
        case .search, .commandLine:
            return true
        case .motion(let motion):
            return carriesOperand(motion)
        case .operatorCommand(let command):
            return carriesOperand(command.target)
        case .edit(let edit):
            return carriesOperand(edit)
        case .view(let view):
            return carriesOperand(view)
        case .fold(let fold):
            return carriesOperand(fold)
        case .incomplete(let incomplete):
            return carriesOperand(incomplete)
        }
    }

    static func carriesOperand(_ motion: Motion) -> Bool {
        switch motion {
        case .find, .mark, .search, .custom:
            return true
        case .character, .displayLine, .line, .word, .lineStart, .lineEnd, .lastNonBlank,
             .column, .fileStart, .fileEnd, .screenLine, .sentence, .paragraph, .section,
             .matchingItem, .repeatFind, .page, .scrollLine:
            return false
        }
    }

    static func carriesOperand(_ target: RawCommand.OperatorTarget) -> Bool {
        switch target {
        case .pending, .line:
            return false
        case .motion(let motion):
            return carriesOperand(motion)
        case .textObject(let object):
            return carriesOperand(object.kind)
        case .custom:
            return true
        }
    }

    static func carriesOperand(_ kind: TextObjectKind) -> Bool {
        switch kind {
        // `ci"`, `ci(`, `cit` — the delimiter is the object's name, but the
        // user still typed it, and under a stale mode it is their text.
        case .block, .quote, .custom:
            return true
        case .word, .sentence, .paragraph, .tag:
            return false
        }
    }

    static func carriesOperand(_ edit: RawCommand.Edit) -> Bool {
        switch edit {
        case .replaceCharacter:
            return true
        case .deleteCharacter, .substituteCharacter, .substituteLine, .changeToLineEnd,
             .deleteToLineEnd, .yankLine, .joinLines, .put, .toggleCase, .increment, .decrement:
            return false
        }
    }

    static func carriesOperand(_ view: RawCommand.ViewAction) -> Bool {
        switch view {
        case .custom:
            return true
        case .cursorAtTop, .cursorAtCenter, .cursorAtBottom, .horizontal:
            return false
        }
    }

    static func carriesOperand(_ fold: RawCommand.FoldAction) -> Bool {
        switch fold {
        case .custom:
            return true
        case .open, .close, .toggle, .delete, .openAll, .closeAll, .enable, .disable,
             .toggleEnabled:
            return false
        }
    }

    static func carriesOperand(_ incomplete: RawCommand.IncompleteCommand) -> Bool {
        switch incomplete {
        // The half-typed operand has not arrived; what is held is the prefix
        // Norm recognized (`f`, `r`, `g`), which is its own syntax.
        case .command, .register, .operatorTarget, .characterArgument, .macroRegister,
             .markName, .namespace:
            return false
        case .search, .commandLine:
            return true
        }
    }

    /// What a redacted command was, without its operand. Display only.
    static func shape(_ intent: RawCommand.Intent) -> String {
        switch intent {
        case .search: return "search"
        case .commandLine: return "cmdline"
        case .custom: return "custom"
        case .window: return "window"
        case .mark: return "mark"
        case .macro: return "macro"
        case .incomplete: return "incomplete"
        case .motion(let motion): return "motion(\(shape(motion)))"
        case .operatorCommand(let command): return "op(\(command.kind.rawValue))"
        case .edit: return "edit"
        case .view: return "view"
        case .fold: return "fold"
        default: return "cmd"
        }
    }

    static func shape(_ motion: Motion) -> String {
        switch motion {
        case .find: return "find"
        case .mark: return "mark"
        case .search: return "search"
        case .custom: return "custom"
        default: return "motion"
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
