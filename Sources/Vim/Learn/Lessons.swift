/// What the menu lists as learned in a field, and the stored answers its Try Again forgets.
public extension ResolvedBeliefs {
    struct Lesson: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            case inForce
            /// Judged under another offsets answer, so the field tries the atom again.
            case reopened
        }

        public let capability: Capability
        public let state: State
        /// Each at the rung it was stored at; the first dates the lesson.
        public let beliefs: [Belief]
    }

    /// A learned read model that turned nothing off is no lesson: forgetting `value` restarts Chromium at `textContent`.
    func lessons(report: CapabilityReport, overridden: Set<Capability>) -> [Lesson] {
        Capability.allCases.compactMap { capability -> Lesson? in
            guard capability.species == .mechanism, let entry = report.entries[capability] else { return nil }
            let onTrial = reopened.filter { $0.capability == capability }
            switch (entry.status, entry.source) {
            case (.unavailable, .learned):
                let model = capability == .readCaret && readModel.answer == .untrusted ? readModel.belief : nil
                let beliefs = [model].compactMap { $0 } + inForce.filter { $0.capability == capability } + onTrial
                return beliefs.isEmpty ? nil : Lesson(capability: capability, state: .inForce, beliefs: beliefs)
            case (.available, .probed) where !overridden.contains(capability) && !onTrial.isEmpty:
                return Lesson(capability: capability, state: .reopened, beliefs: onTrial)
            default:
                return nil
            }
        }
    }
}
