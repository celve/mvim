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
