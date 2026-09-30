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

    /// The caret is in an empty paragraph `text` has no line for, so its read is a neighbour's.
    public let caretInEmptyParagraph: Bool

    /// `AXValue` leaves out some of the field's elements, such as an icon, a widget or an `<hr>`.
    public let textlessLeaves: Bool

    /// How much longer `text` is than `AXValue`, for the empty paragraphs put back as lines (LIN-1612).
    public let valueGap: Int

    /// `text` holds empty paragraphs discovery found, whose lines `AXValue` shows by Chromium's own rule.
    public let holdsEmptyParagraphs: Bool

    public init(
        capabilities: CapabilityProfile = CapabilityProfile(),
        text: String? = nil,
        selection: Range<Int>? = nil,
        length: Int? = nil,
        anchor: Int? = nil,
        cursor: Range<Int>? = nil,
        webContent: Bool = false,
        breaks: ParagraphBreaks? = nil,
        caretInEmptyParagraph: Bool = false,
        textlessLeaves: Bool = false,
        valueGap: Int = 0,
        holdsEmptyParagraphs: Bool = false
    ) {
        self.capabilities = capabilities
        self.text = text
        self.selection = selection
        self.length = length ?? text.map { $0.utf16.count }
        self.anchor = anchor
        self.cursor = cursor
        self.webContent = webContent
        self.breaks = breaks
        self.caretInEmptyParagraph = caretInEmptyParagraph
        self.textlessLeaves = textlessLeaves
        self.valueGap = valueGap
        self.holdsEmptyParagraphs = holdsEmptyParagraphs
    }

    /// The caret, when the selection is collapsed.
    public var caret: Int? {
        selection.flatMap { $0.isEmpty ? $0.lowerBound : nil }
    }
}

public extension FieldSnapshot {
    /// One snapshot's reads, which the runtime takes over AX and the Sim from its fake field.
    struct Reads {
        /// As the learner observed them.
        public var field: FieldReads
        /// `AXNumberOfCharacters`.
        public var length: Int?
        public var webContent: Bool
        /// The child count, which the empty paragraphs found are kept against.
        public var blocks: Int?
        public var marked: MarkerSelection?

        public init(field: FieldReads, length: Int?, webContent: Bool, blocks: Int?, marked: MarkerSelection?) {
            self.field = field
            self.length = length
            self.webContent = webContent
            self.blocks = blocks
            self.marked = marked
        }
    }

    /// What putting empty paragraphs back needs of the marker selection, read only when the snapshot gets that far.
    struct MarkerSelection {
        /// In plain marker offsets.
        public var range: Range<Int>
        /// The raw marker text `field.markers` aligned with; nil where `AXValue` breaks no line.
        public var text: String?
        public var side: (ParagraphBreaks.End) -> ParagraphBreaks.Side?
        public var inEmptyParagraph: () -> Bool
        /// Discovery over the raw marker text: the plain offsets of the empty paragraphs' `<br>`s, nil if it failed.
        public var emptyParagraphs: (String) -> [Int]?

        public init(
            range: Range<Int>, text: String?, side: @escaping (ParagraphBreaks.End) -> ParagraphBreaks.Side?,
            inEmptyParagraph: @escaping () -> Bool, emptyParagraphs: @escaping (String) -> [Int]?
        ) {
            self.range = range
            self.text = text
            self.side = side
            self.inEmptyParagraph = inEmptyParagraph
            self.emptyParagraphs = emptyParagraphs
        }
    }

    /// Everything after the learner, for the runtime and the Sim alike; `memo` is the last discovery, handed back current.
    static func build(
        _ reads: Reads, capabilities: CapabilityProfile, answer: OffsetsAnswer, anchor: Int?, cursor: Range<Int>?,
        memo known: EmptyParagraphs.Memo?
    ) -> (snapshot: FieldSnapshot, memo: EmptyParagraphs.Memo?) {
        var field = reads.field
        // Only the snapshot reads the empty paragraph, which costs four more round trips.
        if answer == .textContent, let marked = reads.marked, field.markers?.breaks != nil {
            field.markers?.emptyParagraph = marked.inEmptyParagraph()
        }
        var interpreted = field.interpreted(under: answer)
        if !capabilities.has(.readCaret) {
            interpreted = (nil, answer == .textContent ? ParagraphBreaks() : nil, false, false)
        }
        var text = capabilities.has(.readText) ? field.text : nil
        var selection = interpreted.selection
        var breaks = interpreted.breaks
        var emptyParagraph = interpreted.emptyParagraph
        var gap = 0
        var holdsEmptyParagraphs = false
        var memo: EmptyParagraphs.Memo?
        // After the learner, which judges the reads as the field gave them.
        if answer == .textContent, let value = text, let aligned = breaks, let marked = reads.marked, let raw = marked.text,
           case let plainMarkers = FieldReads.withoutAttachments(raw), plainMarkers.utf16.contains(10) {
            memo = known.flatMap { $0.holds(value: value, markers: raw, blocks: reads.blocks) ? $0 : nil }
                ?? EmptyParagraphs.Memo(value: value, markers: raw, blocks: reads.blocks, found: marked.emptyParagraphs(raw))
            if let found = memo?.found,
               let restored = EmptyParagraphs.restore(value: value, fieldText: plainMarkers, aligned: aligned, found: found),
               let resolved = restored.breaks.valueRange(marked.range, side: marked.side),
               resolved.upperBound <= restored.text.utf16.count {
                text = restored.text
                breaks = restored.breaks
                selection = resolved
                gap = restored.gap
                holdsEmptyParagraphs = !found.isEmpty
                let model = TextModel(restored.text)
                // A caret on an empty line is in a paragraph the model already holds.
                let onEmptyLine = resolved.isEmpty && model.lineStart(of: resolved.lowerBound) == model.lineEnd(of: resolved.lowerBound)
                emptyParagraph = emptyParagraph && !onEmptyLine
            }
        }
        // The drawn cursor counts only while it still IS the selection; otherwise the selection is the user's.
        let stampedCursor = (cursor != nil && !cursor!.isEmpty && cursor == selection) ? cursor : nil
        let snapshot = FieldSnapshot(
            capabilities: capabilities,
            text: text,
            selection: selection,
            length: capabilities.has(.readLength) ? reads.length : nil,
            anchor: anchor,
            cursor: stampedCursor,
            webContent: reads.webContent,
            breaks: breaks,
            caretInEmptyParagraph: emptyParagraph,
            textlessLeaves: interpreted.textlessLeaves,
            valueGap: gap,
            holdsEmptyParagraphs: holdsEmptyParagraphs
        )
        return (snapshot, memo)
    }
}
