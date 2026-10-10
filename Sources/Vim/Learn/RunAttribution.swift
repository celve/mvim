/// Turns a run's settles into evidence: on the write just before each, on the native key it names, or on offsets.
public struct RunAttribution: Equatable, Sendable {
    public private(set) var evidence: [Evidence] = []
    /// The optional route whose settle failed, which is no evidence on any key.
    public private(set) var missedRoute: Route?
    private var pending: Question?
    /// The field as the previous step read it, when that step was a settle that passed.
    private var settled: Read?
    /// `settled` as it stood at the text write just recorded.
    private var beforeWrite: Read?
    /// The next step's plan index: the Executor and the Sim record every step, in order.
    private var index = 0

    /// The selection and length a settle read, where its expectation asked for both: the Sim answers either way.
    private struct Read: Equatable, Sendable {
        let selection: Range<Int>
        let length: Int

        init?(_ expectation: Expectation, selection: Range<Int>?, length: Int?) {
            guard expectation.landing != nil, expectation.length != nil, let selection, let length else { return nil }
            self.selection = selection
            self.length = length
        }
    }

    public init() {}

    /// `writeError` is what the write before a failed settle returned, as `Executor.SettleFailure` keeps it.
    public mutating func record(
        _ step: PhysicalStep, passed: Bool = true,
        selection: Range<Int>? = nil, length: Int? = nil, selectedText: String? = nil, writeError: Int32? = nil
    ) {
        defer { index += 1 }
        let previous = settled
        let written = beforeWrite
        settled = nil
        beforeWrite = nil
        switch step {
        case .setSelection:
            pending = .write(.writeSelection)
        case .replaceSelection:
            pending = .write(.insertText)
            beforeWrite = previous
        case .settle(let expectation):
            let read = Read(expectation, selection: selection, length: length)
            let unchanged = written != nil && read == written && writeError == nil
            let item = passed
                ? passing(expectation)
                : failing(expectation, selection: selection, length: length, selectedText: selectedText, unchanged: unchanged)
            if let item { evidence.append(item) }
            // A read that went dark fails any plan alike.
            if !passed, selection != nil, let route = expectation.route { missedRoute = route }
            if passed { settled = read }
            pending = nil
        default:
            pending = nil
        }
    }

    private func passing(_ expectation: Expectation) -> Evidence? {
        guard let question = expectation.checkedKey.map(Question.init) ?? pending else { return nil }
        return Evidence(question, .supports(nil), why: .settled, seen: .settle(index))
    }

    private func failing(
        _ expectation: Expectation, selection: Range<Int>?, length: Int?, selectedText: String?, unchanged: Bool
    ) -> Evidence? {
        if let expected = expectation.selectedText, expectation.rangeHeld(selection: selection, length: length) {
            // An unanswered text read contradicts nothing.
            guard let selectedText, !Expectation.sameText(expected, selectedText) else { return nil }
            return .offsets(.refutes, .textCheck, seen: .settle(index))
        }
        guard let blame = expectation.blame else {
            let why = unchanged ? .unchanged : expectation.miss(selection: selection, length: length)
            return pending.map { Evidence($0, .refutes, why: why, seen: .settle(index)) }
        }
        guard let selection else { return nil }
        if let why = expectation.strike(selection) {
            return Evidence(Question(blame.capability), .refutes, why: why, seen: .settle(index))
        }
        return expectation.exemption(selection).map { Evidence(Question(blame.capability), .neutral, why: $0, seen: .settle(index)) }
    }
}

// MARK: - Verdicts

extension Expectation {
    /// The key a non-converged settle blames, given the last selection it read.
    public func blamed(observed: Range<Int>?) -> Capability? {
        guard let observed, strike(observed) != nil else { return nil }
        return blame?.capability
    }

    /// The rule a failed settle's read broke, which strikes its key; nil when exempt.
    public func strike(_ observed: Range<Int>) -> Evidence.Why? {
        guard let blame, !blame.exempt else { return nil }
        return broken(blame, observed)
    }

    /// The exemption that leaves a failed settle's key unblamed.
    public func exemption(_ observed: Range<Int>) -> Evidence.Why? {
        guard let blame, strike(observed) == nil else { return nil }
        return blame.exemptions.first { exemption in
            exemption.all ? broken(blame, observed) != nil
                : exemption.offTarget && landing?.matches(observed) == false || exemption.unmoved.contains(observed)
        }.map { Evidence.Why($0.reason) }
    }

    /// Why a failed settle after a write missed, when its selected text is not the reason.
    public func miss(selection observed: Range<Int>?, length observedLength: Int?) -> Evidence.Why {
        if landing != nil && observed == nil || length != nil && observedLength == nil { return .unanswered }
        if let length, observedLength != length { return .length }
        if let landing, let observed, !landing.matches(observed) { return .moved }
        if let longest, let observed, observed.count > longest { return .tooLong }
        return .edge
    }

    public var checkedKey: Capability? {
        blame.flatMap { $0.exempt ? nil : $0.capability }
    }

    private func broken(_ blame: Blame, _ observed: Range<Int>) -> Evidence.Why? {
        if blame.unmoved.contains(observed) { return .unmoved }
        if blame.leavesCaret && !observed.isEmpty { return .leftSelection }
        if let longest, observed.count > longest { return .tooLong }
        if blame.offTarget && landing?.matches(observed) == false { return .offTarget }
        return nil
    }
}

private extension Expectation.Blame {
    var exempt: Bool { exemptions.contains(where: \.all) }
}

extension Evidence.Why {
    init(_ reason: Expectation.Exemption.Reason) {
        switch reason {
        case .paragraphLines: self = .paragraphLines
        case .emptyParagraph: self = .emptyParagraph
        case .webContent: self = .webContent
        }
    }
}
