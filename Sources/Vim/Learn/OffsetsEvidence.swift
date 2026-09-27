public enum OffsetsEvidence: Equatable, Sendable {
    case supports(OffsetsAnswer, Why)
    /// No answer fits what the field read.
    case misfit(Why)
    case neutral(Why)

    public enum Why: String, Equatable, Sendable {
        case plainIsTextContent = "plain=textContent"
        case plainIsValue = "plain=value"
        case selectedText = "selected-text"
        /// A settle's range held and its selected text did not.
        case textCheck = "text-check"
        case noBreaks = "no-breaks"
        /// The plain read is neither: Chromium's element-boundary snap.
        case boundarySnap = "boundary-snap"
        case textAgrees = "text-agrees"
        case unaligned = "unaligned"
        case readsDisagree = "reads-disagree"
    }

    public var informative: Bool {
        if case .neutral = self { return false }
        return true
    }

    public var why: Why {
        switch self {
        case .supports(_, let why), .misfit(let why), .neutral(let why): return why
        }
    }
}

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
    func evidence(current: OffsetsAnswer) -> OffsetsEvidence? {
        let offsets = offsetsEvidence()
        let text = selectedTextEvidence(current: current)
        if case .misfit? = text { return text }
        if case .supports(let answer, _)? = offsets {
            if case .supports(let other, _)? = text, other != answer { return .misfit(.readsDisagree) }
            return offsets
        }
        if case .supports? = text { return text }
        return offsets ?? text
    }

    func offsetsEvidence() -> OffsetsEvidence? {
        guard let plain, let breaks = markers?.breaks, let value = markers?.value else { return nil }
        let field = breaks.fieldRange(value)
        if field == value { return .neutral(.noBreaks) }
        if plain == field { return .supports(.textContent, .plainIsTextContent) }
        if plain == value { return .supports(.value, .plainIsValue) }
        return .neutral(.boundarySnap)
    }

    func selectedTextEvidence(current: OffsetsAnswer) -> OffsetsEvidence? {
        guard let plain, !plain.isEmpty, let selectedText, let text else { return nil }
        let model = TextModel(text)
        let observed = Self.withoutAttachments(selectedText)
        let valueFits = plain.upperBound <= model.length && Self.withoutAttachments(model.substring(plain)) == observed
        var textContentFits: Bool?
        if let breaks = markers?.breaks, let value = markers?.value, !value.isEmpty, value.upperBound <= model.length {
            textContentFits = Self.withoutAttachments(breaks.fieldText(model.substring(value), at: value)) == observed
        }
        switch (valueFits, textContentFits) {
        case (true, true?), (true, nil): return .neutral(.textAgrees)
        case (true, false?): return .supports(.value, .selectedText)
        case (false, true?): return .supports(.textContent, .selectedText)
        case (false, false?): return .misfit(.selectedText)
        case (false, nil): return current == .value ? .misfit(.selectedText) : .neutral(.unaligned)
        }
    }

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
    public mutating func sampled(markers: Bool, evidence: OffsetsEvidence?, text: String?, plain: Range<Int>?) {
        if !markers || evidence?.informative == true {
            remaining = 0
        } else if let text, let plain, text.utf16.prefix(plain.lowerBound).contains(10) {
            remaining = max(0, remaining - 1)
        }
    }
}

// MARK: - Recorder

extension OffsetsEvidence {
    var traceFields: String {
        switch self {
        case .supports(let answer, let why): return "supports=\(answer.rawValue) why=\(why.rawValue)"
        case .misfit(let why): return "misfit why=\(why.rawValue)"
        case .neutral(let why): return "neutral why=\(why.rawValue)"
        }
    }
}
