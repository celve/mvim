/// Turns a run's settles into evidence: on the write just before each, on the native key it names, or on offsets.
public struct RunAttribution: Equatable, Sendable {
    public private(set) var evidence: [Evidence] = []
    private var pending: Question?
    /// The next step's plan index: the Executor and the Sim record every step, in order.
    private var index = 0

    public init() {}

    public mutating func record(
        _ step: PhysicalStep, passed: Bool = true,
        selection: Range<Int>? = nil, length: Int? = nil, selectedText: String? = nil
    ) {
        defer { index += 1 }
        switch step {
        case .setSelection:
            pending = .write(.writeSelection)
        case .replaceSelection:
            pending = .write(.insertText)
        case .settle(let expectation):
            let item = passed
                ? passing(expectation)
                : failing(expectation, selection: selection, length: length, selectedText: selectedText)
            if let item { evidence.append(item) }
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
        _ expectation: Expectation, selection: Range<Int>?, length: Int?, selectedText: String?
    ) -> Evidence? {
        if let expected = expectation.selectedText, expectation.rangeHeld(selection: selection, length: length) {
            // An unanswered text read contradicts nothing.
            guard let selectedText, !Expectation.sameText(expected, selectedText) else { return nil }
            return .offsets(.refutes, .textCheck, seen: .settle(index))
        }
        guard let blame = expectation.blame else {
            let why = expectation.miss(selection: selection, length: length)
            return pending.map { Evidence($0, .refutes, why: why, seen: .settle(index)) }
        }
        guard let selection else { return nil }
        if let why = expectation.strike(selection) {
            return Evidence(Question(blame.capability), .refutes, why: why, seen: .settle(index))
        }
        return expectation.exemption(selection).map { Evidence(Question(blame.capability), .neutral, why: $0, seen: .settle(index)) }
    }
}
