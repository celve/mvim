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
    /// Whether aligning needs the marker text, which only a line in `value` makes worth reading.
    static func takesText(_ value: String?) -> Bool {
        guard let value, !value.utf16.contains(0xFFFC) else { return false }
        return value.contains("\n")
    }

    /// `text` is the raw marker text where `takesText` read it, returned for the restore.
    static func aligning(
        value: String?, range: Range<Int>, text: String?, sides: [ParagraphBreaks.End: ParagraphBreaks.Side?]
    ) -> FieldSnapshot.Step<(reads: MarkerReads, text: String?)> {
        // A U+FFFC in `AXValue` is the page's own text, which the plain marker offsets drop as a placeholder.
        guard let value, !value.utf16.contains(0xFFFC) else { return .done((MarkerReads(breaks: nil, value: nil), nil)) }
        var breaks = ParagraphBreaks()
        var raw: String?
        if takesText(value) {
            guard let text, let aligned = ParagraphBreaks(value: value, fieldText: FieldReads.withoutAttachments(text)) else {
                return .done((MarkerReads(breaks: nil, value: nil), nil))
            }
            breaks = aligned
            raw = text
        }
        switch FieldSnapshot.valueRange(range, in: breaks, sides: sides) {
        case .needs(let need):
            return .needs(need)
        case .done(let resolved):
            return .done((MarkerReads(breaks: breaks, value: resolved, textlessLeaves: raw?.utf16.contains(0xFFFC) ?? false), raw))
        }
    }
}
