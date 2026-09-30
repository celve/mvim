/// One semantic action of a compiled Vim command.
///
/// Steps are the instruction set of the logical machine. They speak caret,
/// selection, text, and mode — never keys, and never AX. The caret/selection
/// is the machine's implicit register: `select` establishes what subsequent
/// mutating steps act on, so `ciw` compiles to
/// `[select(inner word), deleteSelection, setMode(.insert)]`.
///
/// Payloads reuse the Model vocabulary. State-dependent commands (`;`, `n`,
/// `'a`, `p`, `.`) never reach a plan unresolved — the planner substitutes
/// `VimState` memory into the payload or emits `bell`.
///
/// The caret is a *gap* between characters, as in AX, not an on-character
/// block as vim draws it. That convention is load-bearing: `lineEnd` means
/// the gap after the last character, which is exactly what lets `A` compile
/// to `moveCaret(lineEnd) + setMode(.insert)` with no special "append"
/// destination.
public enum LogicalStep: Equatable, Sendable {
    /// Move the caret to a destination, clearing any selection.
    case moveCaret(Destination)

    /// Set the selection to a symbolic target, anchored at the caret where
    /// the target is caret-relative.
    case select(SelectionTarget)

    /// Visual mode: move the selection's head, keeping its anchor.
    case extendSelection(Destination)

    /// Reduce the selection to a caret at one of its edges.
    case collapseSelection(SelectionEdge)

    /// Visual `o`: the anchor becomes the head and vice versa.
    case swapSelectionEnds

    /// Delete the selection. `nil` register means default routing; routing
    /// itself (unnamed mirror, delete ring, append) is the reducer's lore.
    case deleteSelection(into: Register?)

    /// Copy the selection without changing the text.
    case yankSelection(into: Register?)

    /// Replace the selection with literal text (`r`).
    case replaceSelection(String)

    /// Rewrite the selection in place (case, shift).
    case transformSelection(SelectionTransform)

    /// Type literal text at the caret; the caret ends after the text.
    case insertText(String)

    /// Put register content. Content is resolved at plan time for stored
    /// registers; `.pasteboard` defers to execution because `+`/`*` live in
    /// macOS, not in `VimState`.
    case put(PutSource, PutAction, count: Int)

    /// Join the caret's line with the following ones (`J`, `gJ`). Stays
    /// atomic because the whitespace rules need text — the physical layer
    /// decomposes it.
    case joinLines(count: Int, keepWhitespace: Bool)

    case setMode(Mode)

    /// Capture the caret as a mark. The `MarkPoint` payload (offset plus
    /// staleness witness) is captured at execution time.
    case setMark(Character)

    /// Undo/redo, delegated to the host's undo stack.
    case history(HistoryAction)

    /// Commit a state effect. Logical plans carry the memory commits only
    /// raw intent can decide (`fx` writes the find memory, `;` must not);
    /// the physical planner passes them through 1:1 and adds its own
    /// offset- and capture-dependent commits.
    case commit(VimEffect)

    /// Render Normal mode's on-character cursor — vim's block cursor as
    /// mode semantics. The planner appends it to every plan that ends
    /// resident in Normal; lowering is best-effort (a one-character
    /// selection where the field allows, a bare caret elsewhere) and never
    /// rejects the plan.
    case renderCursor

    /// The command is invalid or unsupported here: signal, change nothing.
    case bell(BellReason)
}

// MARK: - Destinations and targets

public extension LogicalStep {
    /// Where a caret move or selection extension lands.
    enum Destination: Equatable, Sendable {
        case motion(Motion, count: Int)

        /// A resolved mark. `lineWise` distinguishes `'a` (first non-blank
        /// of the mark's line) from `` `a `` (the exact offset).
        case mark(MarkPoint, lineWise: Bool)

        /// An absolute offset already known to the planner (`gi`).
        case offset(Int)
    }

    /// What a `select` step covers. Caret-relative targets are resolved
    /// against the field by the physical layer.
    enum SelectionTarget: Equatable, Sendable {
        /// Characterwise span from the caret to a destination. `inclusive`
        /// is vim's motion lore (`e`, `f`, `$`, `%` cover their endpoint;
        /// `w`, `b`, `}` do not), decided at planning so the physical layer
        /// only does arithmetic.
        case span(to: Destination, inclusive: Bool)

        /// Linewise span: whole lines from the caret's line through the
        /// destination's line (`dj`, `dG`, `d'a`). `interior` excludes the
        /// final line terminator — change keeps the line it empties.
        case lineSpan(to: Destination, interior: Bool)

        /// Whole lines starting at the caret's line (`dd`, `yy`, `3cc`).
        case lines(count: Int, interior: Bool)

        case textObject(TextObject, count: Int)

        /// Caret to end of line (`D`, `C`).
        case toLineEnd

        /// The selection already on screen (Visual-mode operators).
        case current

        /// A remembered selection (`gv`).
        case remembered(VisualMemory)

        /// The wise-ness the selection will have, when it is knowable
        /// without the field: `.current` depends on the live Visual kind.
        public var wise: VisualKind? {
            switch self {
            case .span, .toLineEnd:
                return .character
            case .lineSpan, .lines:
                return .line
            case .textObject(let object, _):
                if case .paragraph = object.kind { return .line }
                return .character
            case .current:
                return nil
            case .remembered(let memory):
                return memory.kind
            }
        }
    }

    enum SelectionEdge: String, Equatable, Sendable {
        case start
        case end

        /// The moving end — the one that is not the Visual anchor.
        case head
    }

    enum SelectionTransform: String, Equatable, Sendable {
        case toggleCase
        case lowercase
        case uppercase
        case shiftRight
        case shiftLeft
    }

    enum PutSource: Equatable, Sendable {
        case content(RegisterContent)

        /// Paste the pasteboard as-is (one synthesized ⌘V — never an engine
        /// read, which would race the app's async processing of the ⌘X that
        /// filled it). `wise` is the marker's memory of how the blind
        /// capture was made; `+`/`*` carry `.character` (macOS keeps no
        /// wise, and the lowering for unknown and characterwise coincide).
        case pasteboard(wise: Wise)
    }

    /// The mode a plan enters. Distinct from `VimState.Mode` because the
    /// Visual anchor is runtime data — entering Visual captures the caret
    /// (or the just-made selection) as the anchor at execution time.
    enum Mode: Equatable, Sendable {
        case normal
        case insert
        case replace
        case visual(VisualKind)
    }

    /// Why a plan rings instead of acting. Carried for the flight recorder;
    /// execution treats every reason identically.
    enum BellReason: Equatable, Sendable {
        case unsupported(String)
        case emptyRegister(Character)
        case unsetMark(Character)
        case noPriorFind
        case noPriorSearch
        case noPriorChange
        case noPriorVisual
    }
}

// MARK: - Recorder

extension LogicalStep {
    /// The step type is what identifies a rejection, which carries no reason of its own.
    var traceName: String {
        switch self {
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
        case .setMode(let mode): return "setMode(\(mode.traceName))"
        case .setMark: return "setMark"
        case .history: return "history"
        case .commit: return "commit"
        case .renderCursor: return "renderCursor"
        case .bell(let reason): return "bell(\(reason.traceName))"
        }
    }
}

extension LogicalStep.BellReason {
    /// The reason this type has carried for a recorder that did not exist yet.
    var traceName: String {
        switch self {
        case .unsupported: return "unsupported"
        case .emptyRegister: return "emptyRegister"
        case .unsetMark: return "unsetMark"
        case .noPriorFind: return "noPriorFind"
        case .noPriorSearch: return "noPriorSearch"
        case .noPriorChange: return "noPriorChange"
        case .noPriorVisual: return "noPriorVisual"
        }
    }
}

extension LogicalStep.Mode {
    var traceName: String {
        switch self {
        case .normal: return "normal"
        case .insert: return "insert"
        case .replace: return "replace"
        case .visual: return "visual"
        }
    }
}
