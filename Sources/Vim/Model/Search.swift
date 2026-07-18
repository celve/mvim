/// A search specification: a direction plus, once typed or resolved, a
/// pattern. `n`/`N` parse with a nil pattern; the logical planner fills it
/// from `VimState` memory.
public struct Search: Equatable, Hashable, Sendable {
    public let direction: Direction
    public let pattern: String?
    public let isSubmitted: Bool
    public let wordUnderCursor: WordMatch?

    public init(
        direction: Direction,
        pattern: String? = nil,
        isSubmitted: Bool = false,
        wordUnderCursor: WordMatch? = nil
    ) {
        self.direction = direction
        self.pattern = pattern
        self.isSubmitted = isSubmitted
        self.wordUnderCursor = wordUnderCursor
    }
}

/// `*`/`#` search whole words; `g*`/`g#` match inside words. The word itself
/// needs text, so it is extracted at the physical layer.
public enum WordMatch: String, Equatable, Hashable, Sendable {
    case wholeWord
    case partialWord
}
