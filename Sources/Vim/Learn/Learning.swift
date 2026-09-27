/// The learner's rules, shared by the Controller and the Sim.
public enum Learning {
    public struct Observation: Equatable, Sendable {
        public var before: OffsetsAnswer
        public var source: OffsetsSource
        public var evidence: Evidence?
        public var after: OffsetsAnswer

        public init(before: OffsetsAnswer, source: OffsetsSource, evidence: Evidence? = nil, after: OffsetsAnswer? = nil) {
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
        return Observation(
            before: before, source: source, evidence: evidence, after: before.next(evidence.outcome, newEngine: newEngine)
        )
    }

    public struct Move: Equatable, Sendable {
        public let from: OffsetsAnswer
        public let to: OffsetsAnswer
        public let why: Evidence.Why
    }

    public enum Skip: String, Equatable, Sendable {
        case userOverride = "user-override"
        case alreadyCommitted = "already-committed"
    }

    public struct Lesson: Equatable, Sendable {
        public var move: Move?
        /// The read model was written, by a move or an anchor.
        public var recorded = false
        /// The write or key the run refuted, committed broken unless `skip` says why not.
        public var refuted: Evidence?
        public var skip: Skip?
        public var republish = false

        public var committed: Capability? { skip == nil ? refuted?.question.capability : nil }
    }

    /// Whether its question's rule can act on it: a write or key only when refuted.
    public static func teaches(_ evidence: Evidence) -> Bool {
        evidence.question == .offsets ? evidence.informative : evidence.outcome == .refutes
    }

    /// The snapshot's offsets evidence already moved its answer, so `run` holds the command's settles alone.
    public static func learn(
        store: inout BeliefStore, rung: String, versions: Versions, model: ReadModel, observed snapshot: Observation,
        run: [Evidence], overridden: (Capability) -> Bool, provenance: Provenance, tally: Tally
    ) -> Lesson {
        var lesson = Lesson()
        var answer = snapshot.after
        var why = snapshot.evidence?.why
        if snapshot.source.observes {
            for item in run where item.question == .offsets {
                let next = answer.next(item.outcome, newEngine: model.newEngine)
                if next != answer { (answer, why) = (next, item.why) }
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
        // A run ends at its first failed settle, so it refutes one write or key at most.
        if let refuted = run.first(where: { $0.outcome == .refutes && $0.question.capability != nil }),
           let capability = refuted.question.capability {
            lesson.refuted = refuted
            if overridden(capability) {
                lesson.skip = .userOverride
            } else if store.commit(broken: capability, at: rung, judgedUnder: snapshot.after, versions: versions, provenance: provenance) {
                lesson.republish = true
            } else {
                lesson.skip = .alreadyCommitted
            }
        }
        return lesson
    }
}

// MARK: - Recorder

extension Learning.Lesson {
    func traceLines(rung: String, versions: Versions) -> [String] {
        var lines: [String] = []
        if let move {
            lines.append("offsets \(move.from.rawValue)→\(move.to.rawValue) why=\(move.why.rawValue) rung=\(rung) engine=\(versions.engineKey)")
        } else if recorded {
            lines.append("offsets anchored rung=\(rung) engine=\(versions.engineKey)")
        }
        if let refuted {
            let fields = "q=\(refuted.question.rawValue) why=\(refuted.why.rawValue)"
            lines.append(skip.map { "skip=\($0.rawValue) \(fields)" } ?? "commit \(fields) rung=\(rung) ver=\(versions.app ?? "nil")")
        }
        if republish {
            if lines.isEmpty { lines.append("offsets changed rung=\(rung)") }
            lines[lines.count - 1] += " → republish"
        }
        return lines
    }
}
