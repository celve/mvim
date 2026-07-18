/// A text object (`iw`, `ap`, `i(` …): a region defined by what surrounds
/// the caret rather than by a motion from it.
public struct TextObject: Equatable, Hashable, Sendable {
    public let scope: TextObjectScope
    public let kind: TextObjectKind

    public init(scope: TextObjectScope, kind: TextObjectKind) {
        self.scope = scope
        self.kind = kind
    }
}

public enum TextObjectScope: String, Equatable, Hashable, Sendable {
    case inner
    case around
}

public enum TextObjectKind: Equatable, Hashable, Sendable {
    case word(bigWord: Bool)
    case sentence
    case paragraph
    case block(delimiter: Character)
    case quote(Character)
    case tag
    case custom(Character)
}
