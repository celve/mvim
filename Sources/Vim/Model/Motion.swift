/// Shared Vim vocabulary: directions and motions.
///
/// Model types are the domain vocabulary more than one layer embeds in its
/// own data structures. They carry no editor state, no key spellings (the
/// Raw layer owns spelling), and no execution knowledge (the Physical layer
/// owns lowering).
public enum Direction: String, Equatable, Hashable, Sendable {
    case left
    case right
    case up
    case down
    case forward
    case backward
}

/// A cursor motion. State-dependent motions (`;`, `n`, `'a`) appear here in
/// unresolved form as parsed; the logical planner substitutes `VimState`
/// memory before a motion reaches a plan.
public enum Motion: Equatable, Hashable, Sendable {
    case character(Direction)
    case displayLine(Direction)
    case line(Direction, firstNonBlank: Bool)
    case word(Direction, end: Bool, bigWord: Bool)
    case lineStart(firstNonBlank: Bool)
    case lineEnd
    case lastNonBlank
    case column
    case fileStart
    case fileEnd
    case screenLine(ScreenLine)
    case sentence(Direction)
    case paragraph(Direction)
    case section(Direction, SectionBoundary)
    case matchingItem
    case find(character: Character, direction: Direction, beforeCharacter: Bool)
    case repeatFind(oppositeDirection: Bool)
    case mark(name: Character, lineWise: Bool)
    case search(Search)
    case page(Direction, halfPage: Bool)
    case scrollLine(Direction)
    case custom(keys: String)
}

public enum ScreenLine: String, Equatable, Hashable, Sendable {
    case top
    case middle
    case bottom
}

public enum SectionBoundary: String, Equatable, Hashable, Sendable {
    case section
    case openBrace
    case closeBrace
    case methodStart
    case methodEnd
}
