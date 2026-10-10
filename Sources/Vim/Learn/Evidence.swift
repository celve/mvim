public struct Evidence: Equatable, Sendable {
    public var question: Question
    public var outcome: Outcome
    public var why: Why
    public var seen: Seen

    public init(_ question: Question, _ outcome: Outcome, why: Why, seen: Seen = .snapshot) {
        self.question = question
        self.outcome = outcome
        self.why = why
        self.seen = seen
    }

    public static func offsets(_ outcome: Outcome, _ why: Why, seen: Seen = .snapshot) -> Evidence {
        Evidence(.offsets, outcome, why: why, seen: seen)
    }

    public enum Outcome: Equatable, Sendable {
        /// A write or key that did what it claims (nil), or an offsets answer the reads fit.
        case supports(OffsetsAnswer?)
        /// A blamed write or key, or reads no offsets answer fits.
        case refutes
        case neutral
    }

    public enum Seen: Equatable, Sendable {
        case snapshot
        /// The settle at this plan step.
        case settle(Int)
    }

    public enum Why: String, Equatable, Sendable {
        case settled
        case unanswered
        case length
        /// The selection read back somewhere else.
        case moved
        /// Offsets held, but not the paragraph side the markers had to confirm.
        case edge
        /// A text write that returned no error left the field as the passing settle before it read it.
        case unchanged
        case unmoved
        case leftSelection = "left-selection"
        case tooLong = "too-long"
        case offTarget = "off-target"
        case paragraphLines = "paragraph-lines"
        case emptyParagraph = "empty-paragraph"
        case webContent = "web-content"
        case plainIsTextContent = "plain=textContent"
        case plainIsValue = "plain=value"
        case selectedText = "selected-text"
        /// A settle's range held and its selected text did not.
        case textCheck = "text-check"
        case noBreaks = "no-breaks"
        /// The plain read is neither: Chromium's element-boundary snap.
        case boundarySnap = "boundary-snap"
        case textAgrees = "text-agrees"
        case unaligned
        case readsDisagree = "reads-disagree"
    }

    public var informative: Bool { outcome != .neutral }
}

// MARK: - Recorder

extension Evidence {
    var traceFields: String {
        "q=\(question.rawValue) \(outcome.traceName) why=\(why.rawValue) seen=\(seen.traceName)"
    }
}

extension Evidence.Outcome {
    var traceName: String {
        switch self {
        case .supports(let answer): return answer.map { "supports=\($0.rawValue)" } ?? "supports"
        case .refutes: return "refutes"
        case .neutral: return "neutral"
        }
    }
}

extension Evidence.Seen {
    var traceName: String {
        switch self {
        case .snapshot: return "snapshot"
        case .settle(let index): return "settle@\(index)"
        }
    }
}
