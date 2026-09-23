/// The granularity of a selection or of register content: vim's character-,
/// line-, and block-wise trichotomy, without vim's syntactic `.previous`
/// (`gv` resolves through remembered state instead).
public enum VisualKind: String, Equatable, Hashable, Sendable {
    case character
    case line
    case block
}

/// A remembered Visual selection (`gv`): its kind and text range.
public struct VisualMemory: Equatable, Hashable, Sendable {
    public let kind: VisualKind
    public let range: Range<Int>

    public init(kind: VisualKind, range: Range<Int>) {
        self.kind = kind
        self.range = range
    }
}

/// A remembered position in text mvim does not own. The host can rewrite
/// the field at any time, so a mark carries a cheap witness of the text it
/// was set in; a failed witness means "mark invalid" — an error, never a
/// jump to a wrong offset.
public struct MarkPoint: Equatable, Hashable, Sendable {
    public let offset: Int

    /// Length of the field text when the mark was set.
    public let textLength: Int

    /// A short slice around `offset` captured at set time, for validation
    /// and possible re-anchoring.
    public let context: String

    public init(offset: Int, textLength: Int, context: String) {
        self.offset = offset
        self.textLength = textLength
        self.context = context
    }
}
