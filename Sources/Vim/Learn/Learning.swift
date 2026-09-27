/// The learner's rules, shared by the Controller and the Sim.
public enum Learning {
    public struct Observation: Equatable, Sendable {
        public var before: OffsetsAnswer
        public var source: OffsetsSource
        public var evidence: OffsetsEvidence?
        public var after: OffsetsAnswer

        public init(before: OffsetsAnswer, source: OffsetsSource, evidence: OffsetsEvidence? = nil, after: OffsetsAnswer? = nil) {
            self.before = before
            self.source = source
            self.evidence = evidence
            self.after = after ?? before
        }
    }

    /// A move toward safety takes effect on the snapshot that saw it.
    public static func observe(
        _ reads: FieldReads, before: OffsetsAnswer, source: OffsetsSource, newEngine: Bool
    ) -> Observation {
        guard source.observes, let evidence = reads.evidence(current: before) else {
            return Observation(before: before, source: source)
        }
        return Observation(before: before, source: source, evidence: evidence, after: before.next(evidence, newEngine: newEngine))
    }

    public struct Move: Equatable, Sendable {
        public let from: OffsetsAnswer
        public let to: OffsetsAnswer
        public let why: OffsetsEvidence.Why
    }

    public enum Skip: String, Equatable, Sendable {
        case userOverride = "user-override"
        case alreadyCommitted = "already-committed"
    }

    public struct Lesson: Equatable, Sendable {
        public var move: Move?
        /// The read model was written, by a move or an anchor.
        public var recorded = false
        public var committed: Capability?
        public var skip: Skip?
        public var neutral: Expectation.Verdict?
        public var republish = false
    }

    public static func learn(
        store: inout BeliefStore, rung: String, versions: Versions, model: ReadModel, observed snapshot: Observation,
        run: RunAttribution, overridden: (Capability) -> Bool, provenance: Provenance, tally: Tally
    ) -> Lesson {
        var lesson = Lesson(neutral: run.neutral)
        var answer = snapshot.after
        var why = snapshot.evidence?.why
        if snapshot.source.observes {
            if run.textMismatch {
                let next = answer.next(.misfit(.textCheck), newEngine: model.newEngine)
                if next != answer { (answer, why) = (next, .textCheck) }
            }
            let moved = answer != snapshot.before
            if moved {
                lesson.recorded = store.record(offsets: answer, at: rung, versions: versions, provenance: provenance, tally: tally)
            } else if snapshot.source == .start, answer != .value, snapshot.evidence?.informative == true {
                // An anchor dates the engine, so a later engine can restore `value`.
                lesson.recorded = store.record(
                    offsets: answer, at: rung, anchor: true, versions: versions, provenance: provenance, tally: tally
                )
            }
            if moved, let why { lesson.move = Move(from: snapshot.before, to: answer, why: why) }
        }
        lesson.republish = answer != model.answer || lesson.recorded
        if let failed = run.failed {
            if overridden(failed) {
                lesson.skip = .userOverride
            } else if store.commit(broken: failed, at: rung, judgedUnder: snapshot.after, versions: versions, provenance: provenance) {
                lesson.committed = failed
                lesson.republish = true
            } else {
                lesson.skip = .alreadyCommitted
            }
        }
        return lesson
    }
}

// MARK: - Recorder

extension Expectation.Verdict {
    var traceFields: String {
        switch self {
        case .blamed(let key): return "blamed q=\(key.traceName)"
        case .neutral(let key, let reason): return "neutral q=\(key.traceName) why=\(reason.rawValue)"
        }
    }
}

extension Learning.Lesson {
    func traceLines(rung: String, versions: Versions, failed: Capability?) -> [String] {
        var lines: [String] = []
        if let move {
            lines.append("offsets \(move.from.rawValue)→\(move.to.rawValue) why=\(move.why.rawValue) rung=\(rung) engine=\(versions.engineKey)")
        } else if recorded {
            lines.append("offsets anchored rung=\(rung) engine=\(versions.engineKey)")
        }
        if let committed {
            lines.append("commit q=\(committed.traceName) rung=\(rung) ver=\(versions.app ?? "nil")")
        } else if let skip {
            lines.append("skip=\(skip.rawValue) fail=\(failed?.traceName ?? "nil")")
        }
        if republish {
            if lines.isEmpty { lines.append("offsets changed rung=\(rung)") }
            lines[lines.count - 1] += " → republish"
        }
        return lines
    }
}
