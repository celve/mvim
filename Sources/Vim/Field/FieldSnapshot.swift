/// The field as the physical planner sees it, in UTF-16 offsets; it gates reads on presence, writes on `capabilities`.
public struct FieldSnapshot: Equatable, Sendable {
    public let capabilities: CapabilityProfile

    public let text: String?

    public let selection: Range<Int>?

    public let length: Int?

    /// The Visual anchor, from `VimState`: the one input the field itself cannot answer.
    public let anchor: Int?

    /// The drawn block cursor, only while it is still the selection; otherwise the selection is the user's.
    public let cursor: Range<Int>?

    /// Web content, where a native key that seems to do nothing may have had nowhere to go (LIN-1559).
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

    public var caret: Int? {
        selection.flatMap { $0.isEmpty ? $0.lowerBound : nil }
    }
}

public extension FieldSnapshot {
    /// One snapshot's reads: the runtime's over AX, the Sim's from its fake field.
    struct Reads: Equatable, Sendable {
        public var field: FieldReads
        /// `AXNumberOfCharacters`.
        public var length: Int?
        public var webContent: Bool
        /// The child count, which the memo is keyed on.
        public var blocks: Int?
        /// The marker selection, in plain marker offsets.
        public var marked: Range<Int>?
        /// The raw marker text, U+FFFCs included; nil where `AXValue` has no line.
        public var markerText: String?
        public var inEmptyParagraph: Bool?
        /// A missing end is unread; a nil side is a failed read.
        public var sides: [ParagraphBreaks.End: ParagraphBreaks.Side?]

        public init(
            field: FieldReads, length: Int? = nil, webContent: Bool = false, blocks: Int? = nil, marked: Range<Int>? = nil,
            markerText: String? = nil, inEmptyParagraph: Bool? = nil, sides: [ParagraphBreaks.End: ParagraphBreaks.Side?] = [:]
        ) {
            self.field = field
            self.length = length
            self.webContent = webContent
            self.blocks = blocks
            self.marked = marked
            self.markerText = markerText
            self.inEmptyParagraph = inEmptyParagraph
            self.sides = sides
        }
    }

    /// A read costly enough that a step asks for it instead of getting it up front.
    enum Need: Equatable, Sendable {
        case side(ParagraphBreaks.End)
        case emptyParagraph
        /// Discovery over `markers`, answered by passing its memo for `value`.
        case emptyParagraphs(value: String, markers: String)
    }

    /// A step's result, or the read it needs first.
    enum Step<Value> {
        case done(Value)
        case needs(Need)

        public static func run(taking take: (Need) -> Void, _ step: () -> Step) -> Value {
            while true {
                switch step() {
                case .done(let value): return value
                case .needs(let need): take(need)
                }
            }
        }
    }

    /// Everything after the learner; `memo` is the last discovery, returned current.
    static func build(
        _ reads: Reads, capabilities: CapabilityProfile, answer: OffsetsAnswer, anchor: Int?, cursor: Range<Int>?,
        memo known: EmptyParagraphs.Memo?
    ) -> Step<(snapshot: FieldSnapshot, memo: EmptyParagraphs.Memo?)> {
        var field = reads.field
        if answer == .textContent, reads.marked != nil, field.markers?.breaks != nil {
            guard let inEmptyParagraph = reads.inEmptyParagraph else { return .needs(.emptyParagraph) }
            field.markers?.emptyParagraph = inEmptyParagraph
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
        if answer == .textContent, let value = text, let aligned = breaks, let marked = reads.marked, let raw = reads.markerText,
           case let plainMarkers = FieldReads.withoutAttachments(raw), plainMarkers.utf16.contains(10) {
            guard let known, known.holds(value: value, markers: raw, blocks: reads.blocks) else {
                return .needs(.emptyParagraphs(value: value, markers: raw))
            }
            memo = known
            if let found = known.found,
               let restored = EmptyParagraphs.restore(value: value, fieldText: plainMarkers, aligned: aligned, found: found) {
                switch valueRange(marked, in: restored.breaks, sides: reads.sides) {
                case .needs(let need):
                    return .needs(need)
                case .done(let resolved?) where resolved.upperBound <= restored.text.utf16.count:
                    text = restored.text
                    breaks = restored.breaks
                    selection = resolved
                    gap = restored.gap
                    holdsEmptyParagraphs = !found.isEmpty
                    let model = TextModel(restored.text)
                    // A caret on an empty line is in a paragraph the model already holds.
                    let onEmptyLine = resolved.isEmpty
                        && model.lineStart(of: resolved.lowerBound) == model.lineEnd(of: resolved.lowerBound)
                    emptyParagraph = emptyParagraph && !onEmptyLine
                case .done:
                    break
                }
            }
        }
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
        return .done((snapshot, memo))
    }

    /// `breaks.valueRange` over the sides read so far, or the side it needs next.
    static func valueRange(
        _ field: Range<Int>, in breaks: ParagraphBreaks, sides: [ParagraphBreaks.End: ParagraphBreaks.Side?]
    ) -> Step<Range<Int>?> {
        var missing: ParagraphBreaks.End?
        let range = breaks.valueRange(field) { end in
            guard let side = sides[end] else {
                missing = missing ?? end
                return nil
            }
            return side
        }
        return missing.map { .needs(.side($0)) } ?? .done(range)
    }
}
