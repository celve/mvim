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

    /// The keys that produced a command — the literal source only when it is
    /// provably free of anything the user supplied, and a shape plus a length
    /// otherwise (`d/needle<CR>` → `op(delete,search)…(12)`).
    ///
    /// Three conditions, and the third is a different **kind** of check on
    /// purpose. `register` and `carriesOperand` interrogate the parse, which
    /// works because that walk is exhaustive over closed enums. But **the parse
    /// is lossy**, so it can never certify `source`: `parseOperator` consumes a
    /// target count and then discards it into `.incomplete(.operatorTarget)`,
    /// leaving `d4111111111111111` with no count anywhere in the model and
    /// every digit still in the string. A count is always digits, so scanning
    /// the string actually being emitted closes that whole class — including
    /// the next place the parser decides to drop one.
    ///
    /// It costs `0` and `g0`, which redact to `motion(lineStart)…(1)`. No
    /// length threshold is offered: "short counts are harmless" is the taste
    /// judgement that produced this leak twice.
    static func keys(_ command: RawCommand) -> String {
        guard command.register == nil,
              !command.source.contains(where: \.isNumber),
              !carriesOperand(command.intent) else {
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

    /// What a redacted command was, without its operand or its digits. Display
    /// only, so it may `default:` freely — the safety property is the
    /// `carriesOperand` family above.
    ///
    /// Detailed on purpose: every counted command now routes through here, so
    /// this is the whole readout for `3dd` and `12j`.
    static func shape(_ intent: RawCommand.Intent) -> String {
        switch intent {
        case .search: return "search"
        case .commandLine: return "cmdline"
        case .custom: return "custom"
        case .window: return "window"
        case .mark: return "mark"
        case .macro: return "macro"
        case .history: return "history"
        case .repeat: return "repeat"
        case .modeChange: return "modeChange"
        case .incomplete: return "incomplete"
        case .view: return "view"
        case .fold: return "fold"
        case .motion(let motion): return "motion(\(shape(motion)))"
        case .edit(let edit): return "edit(\(shape(edit)))"
        case .operatorCommand(let command):
            return "op(\(command.kind.rawValue),\(shape(command.target)))"
        }
    }

    static func shape(_ target: RawCommand.OperatorTarget) -> String {
        switch target {
        case .pending: return "pending"
        case .line: return "line"
        case .motion(let motion): return shape(motion)
        case .textObject: return "textObject"
        case .custom: return "custom"
        }
    }

    static func shape(_ edit: RawCommand.Edit) -> String {
        switch edit {
        case .deleteCharacter: return "deleteCharacter"
        case .substituteCharacter: return "substituteCharacter"
        case .substituteLine: return "substituteLine"
        case .changeToLineEnd: return "changeToLineEnd"
        case .deleteToLineEnd: return "deleteToLineEnd"
        case .yankLine: return "yankLine"
        case .replaceCharacter: return "replaceCharacter"
        case .joinLines: return "joinLines"
        case .put: return "put"
        case .toggleCase: return "toggleCase"
        case .increment: return "increment"
        case .decrement: return "decrement"
        }
    }

    static func shape(_ motion: Motion) -> String {
        switch motion {
        case .character: return "character"
        case .displayLine: return "displayLine"
        case .line: return "line"
        case .word: return "word"
        case .lineStart: return "lineStart"
        case .lineEnd: return "lineEnd"
        case .lastNonBlank: return "lastNonBlank"
        case .column: return "column"
        case .fileStart: return "fileStart"
        case .fileEnd: return "fileEnd"
        case .screenLine: return "screenLine"
        case .sentence: return "sentence"
        case .paragraph: return "paragraph"
        case .section: return "section"
        case .matchingItem: return "matchingItem"
        case .find: return "find"
        case .repeatFind: return "repeatFind"
        case .mark: return "mark"
        case .search: return "search"
        case .page: return "page"
        case .scrollLine: return "scrollLine"
        case .custom: return "custom"
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
