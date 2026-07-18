/// What the runtime could read from the focused field at command time. The
/// optionals mirror the capability profile: absent reads are simply nil,
/// and the planner's lane choice follows from what is present.
///
/// Offsets are UTF-16 code units, AX's currency.
public struct FieldSnapshot: Equatable, Sendable {
    public let text: String?

    /// The selected range; an empty range is the caret.
    public let selection: Range<Int>?

    public let length: Int?

    /// The Visual anchor, copied out of `VimState` by the runtime — the one
    /// piece of execution context the field itself cannot answer.
    public let anchor: Int?

    public init(
        text: String? = nil,
        selection: Range<Int>? = nil,
        length: Int? = nil,
        anchor: Int? = nil
    ) {
        self.text = text
        self.selection = selection
        self.length = length ?? text.map { $0.utf16.count }
        self.anchor = anchor
    }

    /// The caret, when the selection is collapsed.
    public var caret: Int? {
        selection.flatMap { $0.isEmpty ? $0.lowerBound : nil }
    }
}
