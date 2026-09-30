public struct FieldReads: Equatable, Sendable {
    public var text: String?
    /// `AXSelectedTextRange`.
    public var plain: Range<Int>?
    public var selectedText: String?
    public var markers: MarkerReads?

    public init(text: String? = nil, plain: Range<Int>? = nil, selectedText: String? = nil, markers: MarkerReads? = nil) {
        self.text = text
        self.plain = plain
        self.selectedText = selectedText
        self.markers = markers
    }
}

public struct MarkerReads: Equatable, Sendable {
    /// Nil when the marker text did not line up with `AXValue`.
    public var breaks: ParagraphBreaks?
    /// The marker selection in `AXValue` offsets; nil when unaligned or a side was unreadable.
    public var value: Range<Int>?
    public var emptyParagraph: Bool
    public var textlessLeaves: Bool

    public init(breaks: ParagraphBreaks?, value: Range<Int>?, emptyParagraph: Bool = false, textlessLeaves: Bool = false) {
        self.breaks = breaks
        self.value = value
        self.emptyParagraph = emptyParagraph
        self.textlessLeaves = textlessLeaves
    }
}

/// How a field counts caret and selection offsets.
public enum OffsetsAnswer: String, Codable, CaseIterable, Equatable, Sendable {
    case value
    /// Chromium's count, without the paragraph breaks it generates in `AXValue`.
    case textContent
    /// No count fits: the caret is withheld and commands go blind.
    case untrusted
}

public extension FieldReads {
    /// Chromium writes a U+FFFC into its text for each element with no text; `AXValue` has none.
    static func withoutAttachments(_ text: String) -> String {
        String(decoding: text.utf16.filter { $0 != 0xFFFC }, as: UTF16.self)
    }

    func interpreted(under answer: OffsetsAnswer) -> (selection: Range<Int>?, breaks: ParagraphBreaks?, emptyParagraph: Bool, textlessLeaves: Bool) {
        switch answer {
        case .value:
            return (plain, nil, false, false)
        case .textContent:
            guard let markers, let breaks = markers.breaks else { return (nil, ParagraphBreaks(), false, false) }
            return (markers.value, breaks, markers.emptyParagraph, markers.textlessLeaves)
        case .untrusted:
            return (nil, nil, false, false)
        }
    }
}

public extension MarkerReads {
    /// `text` reads the marker text, only where `value` breaks a line, and comes back raw for putting empty paragraphs back.
    static func aligning(
        value: String?, range: Range<Int>, side: (ParagraphBreaks.End) -> ParagraphBreaks.Side?, text: () -> String?
    ) -> (reads: MarkerReads, text: String?) {
        // A U+FFFC in `AXValue` is the page's own text, which the plain marker offsets drop as a placeholder.
        guard let value, !value.utf16.contains(0xFFFC) else { return (MarkerReads(breaks: nil, value: nil), nil) }
        var breaks = ParagraphBreaks()
        var textlessLeaves = false
        var raw: String?
        if value.contains("\n") {
            guard let markers = text(),
                  let aligned = ParagraphBreaks(value: value, fieldText: FieldReads.withoutAttachments(markers)) else {
                return (MarkerReads(breaks: nil, value: nil), nil)
            }
            breaks = aligned
            textlessLeaves = markers.utf16.contains(0xFFFC)
            raw = markers
        }
        return (MarkerReads(breaks: breaks, value: breaks.valueRange(range, side: side), textlessLeaves: textlessLeaves), raw)
    }
}
