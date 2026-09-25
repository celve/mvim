/// Everything known about the focused field, in one value: the durable half
/// (`capabilities` — what it *can* do, probed on focus or served from the
/// per-app cache) and the volatile half (what it *holds right now*, read
/// fresh per command). Two refresh rates, one consumer — the physical
/// planner takes this and nothing else about the field.
///
/// The optionals mirror the capabilities by construction, but the planner
/// deliberately trusts *presence* for read-gating (evidence: what we
/// actually got) and `capabilities` for write- and settle-gating (promises
/// about actions not yet taken).
///
/// Offsets are UTF-16 code units, AX's currency.
public struct FieldSnapshot: Equatable, Sendable {
    public let capabilities: CapabilityProfile

    public let text: String?

    /// The selected range; an empty range is the caret.
    public let selection: Range<Int>?

    public let length: Int?

    /// The Visual anchor, copied out of `VimState` by the runtime — the one
    /// piece of execution context the field itself cannot answer.
    public let anchor: Int?

    /// The drawn block cursor, stamped by the runtime **only when it still
    /// equals the live selection** — a mismatch (mouse click, app
    /// interference) means the selection is the user's, not ours.
    public let cursor: Range<Int>?

    /// The field is web content, where a native key that seems to do nothing may have had nowhere to go (LIN-1559).
    public let webContent: Bool

    /// Non-nil when the field selects in text content; `selection` is already converted.
    public let breaks: ParagraphBreaks?

    public init(
        capabilities: CapabilityProfile = CapabilityProfile(),
        text: String? = nil,
        selection: Range<Int>? = nil,
        length: Int? = nil,
        anchor: Int? = nil,
        cursor: Range<Int>? = nil,
        webContent: Bool = false,
        breaks: ParagraphBreaks? = nil
    ) {
        self.capabilities = capabilities
        self.text = text
        self.selection = selection
        self.length = length ?? text.map { $0.utf16.count }
        self.anchor = anchor
        self.cursor = cursor
        self.webContent = webContent
        self.breaks = breaks
    }

    /// The caret, when the selection is collapsed.
    public var caret: Int? {
        selection.flatMap { $0.isEmpty ? $0.lowerBound : nil }
    }
}
