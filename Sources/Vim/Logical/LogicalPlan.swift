/// A compiled Vim command: the sequence of semantic actions that realizes it.
///
/// `RawCommand` is syntax; a `LogicalPlan` is what that syntax means *right
/// now*, with every state dependency already resolved by `LogicalPlanner` —
/// `;` has its find target, `n` its pattern, `p` its register content. What
/// stays deliberately unresolved is the text itself: steps speak in motions,
/// objects, and modes, and the physical layer lowers them against the actual
/// field and its capabilities.
///
/// Steps execute in order; a step that cannot be realized aborts the rest of
/// the plan (the physical layer decides what "cannot" means for a field).
public struct LogicalPlan: Equatable, Sendable {
    public let steps: [LogicalStep]

    public init(steps: [LogicalStep]) {
        self.steps = steps
    }

    public init(_ steps: LogicalStep...) {
        self.steps = steps
    }

    /// The no-op plan: nothing to do, nothing to signal (prompts in
    /// progress, Insert-mode traffic, stray incompletes).
    public static let empty = LogicalPlan(steps: [])

    public static func bell(_ reason: LogicalStep.BellReason) -> LogicalPlan {
        LogicalPlan(.bell(reason))
    }

    public var isEmpty: Bool { steps.isEmpty }
}
