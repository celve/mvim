/// What one run tells the learner, step by step; the executor and the Sim share it.
///
/// A write is attributed positionally: the most recent `.setSelection` or `.replaceSelection` before a settle,
/// which the settle consumes. A settle that names a native key attributes to the key instead.
public struct RunAttribution: Equatable, Sendable {
    public private(set) var failed: Capability?
    public private(set) var settled: Set<Capability> = []
    /// A failure the key's lane exempts from blame.
    public private(set) var neutral: Expectation.Verdict?
    /// A settle whose range held and whose selected text did not, which is the offsets belief's to answer for.
    public private(set) var textMismatch = false
    private var pending: Capability?

    public init() {}

    /// After each step runs; a settle passes what it last read.
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
                // The range held, so no write is at fault; only a text read back, and different, contradicts the offsets.
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
