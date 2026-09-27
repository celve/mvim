/// Attributes a settle to the write just before it, or to the native key it names.
public struct RunAttribution: Equatable, Sendable {
    public private(set) var failed: Capability?
    public private(set) var settled: Set<Capability> = []
    /// A failure the key's lane exempts from blame.
    public private(set) var neutral: Expectation.Verdict?
    /// The range held but the selected text differed: the offsets belief's fault, not a write's.
    public private(set) var textMismatch = false
    private var pending: Capability?

    public init() {}

    public mutating func record(
        _ step: PhysicalStep, passed: Bool = true,
        selection: Range<Int>? = nil, length: Int? = nil, selectedText: String? = nil
    ) {
        switch step {
        case .setSelection:
            pending = .writeSelection
        case .replaceSelection:
            pending = .insertText
        case .settle(let expectation):
            if passed {
                if let attributed = expectation.checkedKey ?? pending { settled.insert(attributed) }
            } else if let expected = expectation.selectedText, expectation.rangeHeld(selection: selection, length: length) {
                // An unanswered text read contradicts nothing.
                if let selectedText, !Expectation.sameText(expected, selectedText) { textMismatch = true }
            } else if expectation.blame == nil {
                failed = pending
            } else {
                switch expectation.verdict(observed: selection) {
                case .blamed(let key)?: failed = key
                case let exempt?: neutral = exempt
                case nil: break
                }
            }
            pending = nil
        default:
            pending = nil
        }
    }
}
