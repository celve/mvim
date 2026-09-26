/// The learner's two rules for one command, shared by the controller and the Sim.
public enum Learning {
    /// The snapshot's evidence, and the answer it is read under: a move toward safety takes effect at once.
    public static func observe(
        _ reads: FieldReads, current: OffsetsAnswer, model: ReadModel
    ) -> (evidence: OffsetsEvidence?, answer: OffsetsAnswer) {
        // A user override pins the answer and retires the belief.
        guard model.source != .user, let evidence = reads.evidence(current: current) else { return (nil, current) }
        return (evidence, current.next(evidence, newEngine: model.newEngine))
    }

    /// The answer a snapshot starts from: a learned one, or the engine rule's for this snapshot.
    public static func current(_ model: ReadModel, starting: OffsetsAnswer) -> OffsetsAnswer {
        model.source == .learned ? model.answer : starting
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

    /// What one command taught; `republish` asks for the binding to be resolved again.
    public struct Lesson: Equatable, Sendable {
        public var move: Move?
        /// The read model was written, moved or first confirmed at this engine.
        public var recorded = false
        public var committed: Capability?
        public var skip: Skip?
        public var neutral: Expectation.Verdict?
        public var republish = false
    }

    /// The trial rule for writes and keys, and the observation rule for offsets, applied to `store`.
    ///
    /// `snapshot` is the answer the snapshot started from and the one the command ran under.
    public static func learn(
        store: inout BeliefStore, rung: String, versions: Versions, model: ReadModel,
        snapshot: (before: OffsetsAnswer, evidence: OffsetsEvidence?, after: OffsetsAnswer),
        run: RunAttribution, overridden: (Capability) -> Bool, provenance: Provenance, tally: Tally
    ) -> Lesson {
        var lesson = Lesson(neutral: run.neutral)
        var answer = snapshot.after
        var why = snapshot.evidence?.why
        if model.source != .user {
            if run.textMismatch {
                let next = answer.next(.misfit(.textCheck), newEngine: model.newEngine)
                if next != answer { (answer, why) = (next, .textCheck) }
            }
            let moved = answer != snapshot.before
            if moved {
                lesson.recorded = store.record(offsets: answer, at: rung, versions: versions, provenance: provenance, tally: tally)
            } else if model.source != .learned, answer != .value, snapshot.evidence?.informative == true {
                // Dates the engine a starting answer was confirmed under, so a later engine can restore `value`.
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
    /// `neutral q=lineStartKey why=paragraph-lines`.
    var traceFields: String {
        switch self {
        case .blamed(let key): return "blamed q=\(key.traceName)"
        case .neutral(let key, let reason): return "neutral q=\(key.traceName) why=\(reason.rawValue)"
        }
    }
}

extension Learning.Lesson {
    /// One `learn` line per thing learned; a republish rides the last.
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
