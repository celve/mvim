/// What one observation says about the offsets question.
public enum OffsetsEvidence: Equatable, Sendable {
    case supports(OffsetsAnswer, Why)
    /// No answer fits what the field read.
    case misfit(Why)
    /// Says nothing either way.
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

/// One snapshot's reads, before a read model interprets them.
public struct FieldReads: Equatable, Sendable {
    public var text: String?
    /// P: `AXSelectedTextRange`.
    public var plain: Range<Int>?
    /// S: `AXSelectedText`.
    public var selectedText: String?
    /// Nil where the markers were not read, or the field has none.
    public var markers: MarkerReads?

    public init(text: String? = nil, plain: Range<Int>? = nil, selectedText: String? = nil, markers: MarkerReads? = nil) {
        self.text = text
        self.plain = plain
        self.selectedText = selectedText
        self.markers = markers
    }
}

/// The text markers' view of the selection.
public struct MarkerReads: Equatable, Sendable {
    /// Nil when the marker text did not line up with `AXValue`.
    public var breaks: ParagraphBreaks?
    /// V: the marker selection in `AXValue` offsets; nil when unaligned or a boundary's side was unreadable.
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
    /// What the snapshot says, against the answer it was read under; nil when it read nothing comparable.
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

    /// P against V and F, where F is V without the generated breaks.
    func offsetsEvidence() -> OffsetsEvidence? {
        guard let plain, let breaks = markers?.breaks, let value = markers?.value else { return nil }
        let field = breaks.fieldRange(value)
        if field == value { return .neutral(.noBreaks) }
        if plain == field { return .supports(.textContent, .plainIsTextContent) }
        if plain == value { return .supports(.value, .plainIsValue) }
        return .neutral(.boundarySnap)
    }

    /// S against what each answer predicts from `AXValue`, for a non-empty selection.
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

    /// The selection and paragraph facts a snapshot takes under `answer`.
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

/// Under `value` the markers are read only on a binding's first snapshots, until one is informative.
public struct OffsetsSampling: Equatable, Sendable {
    public static let budget = 3

    public private(set) var remaining = OffsetsSampling.budget

    public init() {}

    public func readsMarkers(under answer: OffsetsAnswer) -> Bool {
        answer != .value || remaining > 0
    }

    public mutating func sampled(under answer: OffsetsAnswer, markers: Bool, evidence: OffsetsEvidence?) {
        guard answer == .value, remaining > 0 else { return }
        remaining = !markers || evidence?.informative == true ? 0 : remaining - 1
    }
}

// MARK: - Recorder

extension OffsetsEvidence {
    /// `supports=textContent why=plain=textContent`, `misfit why=selected-text`, `neutral why=no-breaks`.
    var traceFields: String {
        switch self {
        case .supports(let answer, let why): return "supports=\(answer.rawValue) why=\(why.rawValue)"
        case .misfit(let why): return "misfit why=\(why.rawValue)"
        case .neutral(let why): return "neutral why=\(why.rawValue)"
        }
    }
}
