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

public extension FieldReads {
    func evidence(current: OffsetsAnswer) -> Evidence? {
        let offsets = offsetsEvidence()
        let text = selectedTextEvidence(current: current)
        if text?.outcome == .refutes { return text }
        if case .supports(let answer)? = offsets?.outcome {
            if case .supports(let other)? = text?.outcome, other != answer { return .offsets(.refutes, .readsDisagree) }
            return offsets
        }
        if case .supports? = text?.outcome { return text }
        return offsets ?? text
    }

    func offsetsEvidence() -> Evidence? {
        guard let plain, let breaks = markers?.breaks, let value = markers?.value else { return nil }
        let field = breaks.fieldRange(value)
        if field == value { return .offsets(.neutral, .noBreaks) }
        if plain == field { return .offsets(.supports(.textContent), .plainIsTextContent) }
        if plain == value { return .offsets(.supports(.value), .plainIsValue) }
        return .offsets(.neutral, .boundarySnap)
    }

    func selectedTextEvidence(current: OffsetsAnswer) -> Evidence? {
        guard let plain, !plain.isEmpty, let selectedText, let text else { return nil }
        let model = TextModel(text)
        let observed = Expectation.withoutAttachments(selectedText)
        let valueFits = plain.upperBound <= model.length && Expectation.withoutAttachments(model.substring(plain)) == observed
        var textContentFits: Bool?
        if let breaks = markers?.breaks, let value = markers?.value, !value.isEmpty, value.upperBound <= model.length {
            textContentFits = Expectation.withoutAttachments(breaks.fieldText(model.substring(value), at: value)) == observed
        }
        switch (valueFits, textContentFits) {
        case (true, true?), (true, nil): return .offsets(.neutral, .textAgrees)
        case (true, false?): return .offsets(.supports(.value), .selectedText)
        case (false, true?): return .offsets(.supports(.textContent), .selectedText)
        case (false, false?): return .offsets(.refutes, .selectedText)
        case (false, nil): return current == .value ? .offsets(.refutes, .selectedText) : .offsets(.neutral, .unaligned)
        }
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

/// Under `value`, markers are read only where they could tell, until they do or `budget` reads say nothing.
public struct OffsetsSampling: Equatable, Sendable {
    public static let budget = 3

    public private(set) var remaining = OffsetsSampling.budget

    public init() {}

    /// Before the first `\n` both counts agree, so a marker read could tell nothing.
    public func samples(text: String?, plain: Range<Int>?) -> Bool {
        guard remaining > 0, let text, let plain else { return false }
        return text.utf16.prefix(plain.upperBound + 1).contains(10)
    }

    /// A silence counts only past a newline, where the markers had something to compare.
    public mutating func sampled(markers: Bool, evidence: Evidence?, text: String?, plain: Range<Int>?) {
        if !markers || evidence?.informative == true {
            remaining = 0
        } else if let text, let plain, text.utf16.prefix(plain.lowerBound).contains(10) {
            remaining = max(0, remaining - 1)
        }
    }
}
