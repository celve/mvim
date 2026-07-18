/// Undo-history navigation. `undo`/`redo` delegate to the host's undo
/// stack; the text-state variants (`g-`/`g+`) exist in the vocabulary but
/// have no realization over AX — there is no undo tree to walk.
public enum HistoryAction: String, Equatable, Hashable, Sendable {
    case undo
    case redo
    case olderTextState
    case newerTextState
}
