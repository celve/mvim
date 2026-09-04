/// A compiled-to-the-metal Vim command: the concrete step sequence that
/// realizes a `LogicalPlan` in one particular field, under one capability
/// profile. Anything derivable — fidelity, rejection reasons — is
/// recomputable from the recorded planner inputs; the plan stores only the
/// program.
public struct PhysicalPlan: Equatable, Sendable {
    public let steps: [PhysicalStep]

    public init(steps: [PhysicalStep]) {
        self.steps = steps
    }

    public init(_ steps: PhysicalStep...) {
        self.steps = steps
    }

    public static let empty = PhysicalPlan(steps: [])

    /// Planning failure *is* this plan.
    public static let rejected = PhysicalPlan(.bell)

    /// Whether execution changes the field's text. Sole consumer:
    /// dot-worthiness — the runtime records a change body only when true.
    public var mutatesText: Bool {
        steps.contains { $0.mutatesText }
    }
}

// MARK: - Recorder

extension PhysicalPlan {
    /// One character per step, in order — the order is the diagnostic.
    var traceShape: String { steps.map(\.traceCode).joined() }
}
