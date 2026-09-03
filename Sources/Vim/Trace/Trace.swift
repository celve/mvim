/// Engine values as short strings. Pure, so `make test` pins the rule that none holds user text.
enum Trace {
    // MARK: - Capabilities

    /// `RT+p RL+p WS-l …` in `allCases` order; status `+ - ?`, source `p s u l`, `??` absent.
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

    /// Declaration order — a `Set` has none.
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

    /// One character per step, in order; `P3` is one press posting three times.
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

    /// The step type is what identifies a rejection among the planner's 26 `return nil` sites.
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

    /// The reason `BellReason` has carried for a recorder that did not exist yet.
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

    /// The digit test reads `source`, not the parse, which discards a count when incomplete.
    static func keys(_ command: RawCommand) -> String {
        guard command.register == nil,
              !command.source.contains(where: \.isNumber),
              !carriesOperand(command.intent) else {
            return "\(shape(command.intent))…(\(command.source.utf16.count))"
        }
        return command.source
    }

    /// Recurses because the payloads nest; no `default:` below, so a new case cannot leak.
    static func carriesOperand(_ intent: RawCommand.Intent) -> Bool {
        switch intent {
        case .modeChange, .history, .repeat:
            return false
        case .mark, .macro:
            return true
        // Kept as raw keys by design, so nothing has parsed them.
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
        // `ci"`, `ci(`: the delimiter names the object, but the user still typed it.
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
        // What is held is the prefix Norm recognised, not the operand still to come.
        case .command, .register, .operatorTarget, .characterArgument, .macroRegister,
             .markName, .namespace:
            return false
        case .search, .commandLine:
            return true
        }
    }

    /// Display only — the whole readout for a redacted command, so it names every case.
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
