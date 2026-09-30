/// What a belief answers, stored as a capability's name or `offsets`.
public enum Question: RawRepresentable, Codable, Hashable, Sendable {
    case write(Capability)
    case key(Capability)
    case offsets
    /// A name another build wrote, kept and ignored so the store reads back as written.
    case unknown(String)

    /// Stores only ever held writes and keys, so any capability but a native key reads as a write.
    public init(_ capability: Capability) {
        self = Capability.nativeKeys.contains(capability) ? .key(capability) : .write(capability)
    }

    public init(rawValue: String) {
        if rawValue == "offsets" {
            self = .offsets
        } else if let capability = Capability(rawValue: rawValue) {
            self.init(capability)
        } else {
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .write(let capability), .key(let capability): return capability.rawValue
        case .offsets: return "offsets"
        case .unknown(let name): return name
        }
    }

    public var capability: Capability? {
        switch self {
        case .write(let capability), .key(let capability): return capability
        case .offsets, .unknown: return nil
        }
    }
}

/// A rung's learned answer: `broken` for a write or key, or the `offsets` read model.
public struct Belief: Codable, Equatable, Sendable {
    public static let broken = "broken"

    public var rung: String
    public var question: Question
    public var answer: String
    /// The verdict holds only while the read model gives this answer.
    public var judgedUnder: OffsetsAnswer?
    public var appVersion: String
    public var engineVersion: String?
    public var provenance: Provenance
    public var tally: Tally?
    /// Confirmed, not moved: dates the engine but leaves each field its starting answer.
    public var anchor: Bool?

    public init(
        rung: String, question: Question, answer: String, judgedUnder: OffsetsAnswer? = nil,
        versions: Versions, provenance: Provenance = Provenance(), tally: Tally? = nil, anchor: Bool? = nil
    ) {
        self.rung = rung
        self.question = question
        self.answer = answer
        self.judgedUnder = judgedUnder
        self.appVersion = versions.app ?? ""
        self.engineVersion = versions.engine
        self.provenance = provenance
        self.tally = tally
        self.anchor = anchor
    }

    public var capability: Capability? { question.capability }

    public var offsetsAnswer: OffsetsAnswer? {
        question == .offsets ? OffsetsAnswer(rawValue: answer) : nil
    }

    /// The read model expires on this: Electron's framework version, else the app's.
    var engineKey: String { engineVersion ?? appVersion }
}

public struct Provenance: Codable, Equatable, Sendable {
    public var build: String?
    public var learnedAt: String?
    /// The deciding command's recorder tag, `e12.c47`.
    public var tag: String?

    public init(build: String? = nil, learnedAt: String? = nil, tag: String? = nil) {
        self.build = build
        self.learnedAt = learnedAt
        self.tag = tag
    }
}

/// Offsets evidence counted since the process started.
public struct Tally: Codable, Equatable, Sendable {
    public var value = 0
    public var textContent = 0
    public var misfit = 0
    public var neutral = 0

    public init() {}

    public mutating func count(_ evidence: Evidence) {
        guard evidence.question == .offsets else { return }
        switch evidence.outcome {
        case .supports(.value?): value += 1
        case .supports(.textContent?): textContent += 1
        case .supports, .refutes: misfit += 1
        case .neutral: neutral += 1
        }
    }
}

public struct Versions: Equatable, Sendable {
    public var app: String?
    public var engine: String?

    public init(app: String? = nil, engine: String? = nil) {
        self.app = app
        self.engine = engine
    }

    var engineKey: String { engine ?? app ?? "" }
}

public extension OffsetsAnswer {
    func next(_ outcome: Evidence.Outcome, newEngine: Bool) -> OffsetsAnswer {
        switch outcome {
        case .neutral, .supports(nil):
            return self
        case .refutes:
            return .untrusted
        case .supports(let answer?):
            guard answer != self else { return self }
            switch answer {
            case .value: return newEngine ? .value : .untrusted
            case .textContent, .untrusted: return answer
            }
        }
    }
}

// MARK: - The store

/// One belief per rung and question; a user's edit is learned state too, never config.
public struct BeliefStore: Codable, Equatable, Sendable {
    public static let currentSchema = 3

    public var schema = BeliefStore.currentSchema
    public var beliefs: [Belief] = []

    public init(beliefs: [Belief] = []) {
        self.beliefs = beliefs
    }
}

public enum OffsetsSource: String, Equatable, Sendable {
    case start
    case learned
    /// A `readCaret` override retired the belief.
    case user
    /// No AX children, so no generated breaks: both counts agree, whatever the rung learned.
    case plain

    /// Whether the field's reads teach its rung's read model.
    public var observes: Bool { self == .start || self == .learned }
}

public struct ReadModel: Equatable, Sendable {
    /// At bind; each snapshot takes its own through `reading`.
    public var answer: OffsetsAnswer
    public var source: OffsetsSource
    /// Nil unless the rung's learned answer is in force at this engine.
    public var learned: OffsetsAnswer?
    public var pinned: Bool
    /// The stored belief, in force or not.
    public var belief: Belief?
    public var newEngine: Bool

    public init(
        answer: OffsetsAnswer, source: OffsetsSource = .start, learned: OffsetsAnswer? = nil, pinned: Bool = false,
        belief: Belief? = nil, newEngine: Bool = false
    ) {
        self.answer = answer
        self.source = source
        self.learned = learned
        self.pinned = pinned
        self.belief = belief
        self.newEngine = newEngine
    }

    /// One snapshot's answer, since a field gains children as it fills.
    public func reading(chromium: Bool, children: Bool) -> (answer: OffsetsAnswer, source: OffsetsSource) {
        guard children else { return (.value, .plain) }
        if let learned { return (learned, .learned) }
        return (chromium ? .textContent : .value, pinned ? .user : .start)
    }
}

public struct ResolvedBeliefs: Equatable, Sendable {
    public var readModel: ReadModel
    public var broken: Set<Capability>
    public var inForce: [Belief]
    /// Verdicts judged under another offsets answer.
    public var reopened: [Belief]
}

public extension BeliefStore {
    /// Verdicts apply across the ladder, as curation does; the read model only at `rung`.
    func resolve(
        rungs: [String], rung: String?, versions: Versions, chromium: Bool, children: Bool, userPinsOffsets: Bool
    ) -> ResolvedBeliefs {
        let stored = rung.flatMap { offsetsBelief(at: $0) }
        let newEngine = stored.map { $0.engineKey != versions.engineKey } ?? false
        var model = ReadModel(answer: .value, pinned: userPinsOffsets, belief: stored, newEngine: newEngine)
        if !userPinsOffsets, !newEngine, stored?.anchor != true { model.learned = stored?.offsetsAnswer }
        (model.answer, model.source) = model.reading(chromium: chromium, children: children)
        let app = versions.app ?? ""
        var broken: Set<Capability> = []
        var inForce: [Belief] = []
        var reopened: [Belief] = []
        for belief in beliefs where rungs.contains(belief.rung) && belief.answer == Belief.broken && belief.appVersion == app {
            guard let capability = belief.capability else { continue }
            if (belief.judgedUnder ?? .value) == model.answer {
                broken.insert(capability)
                inForce.append(belief)
            } else {
                reopened.append(belief)
            }
        }
        return ResolvedBeliefs(readModel: model, broken: broken, inForce: inForce, reopened: reopened)
    }

    func offsetsBelief(at rung: String) -> Belief? {
        beliefs.first { $0.rung == rung && $0.question == .offsets }
    }

    /// False when that verdict already stood.
    mutating func commit(
        broken capability: Capability, at rung: String, judgedUnder offsets: OffsetsAnswer,
        versions: Versions, provenance: Provenance
    ) -> Bool {
        let app = versions.app ?? ""
        // An app update reopens every trial at the rung.
        beliefs.removeAll { $0.rung == rung && $0.question != .offsets && $0.appVersion != app }
        let verdict = Belief(
            rung: rung, question: Question(capability), answer: Belief.broken, judgedUnder: offsets,
            versions: versions, provenance: provenance
        )
        guard let index = beliefs.firstIndex(where: { $0.rung == rung && $0.question == verdict.question }) else {
            beliefs.append(verdict)
            return true
        }
        let old = beliefs[index]
        guard old.answer != verdict.answer || old.judgedUnder != verdict.judgedUnder else { return false }
        beliefs[index] = verdict
        return true
    }

    /// False, writing nothing, when it already stood at this engine.
    mutating func record(
        offsets answer: OffsetsAnswer, at rung: String, anchor: Bool = false, versions: Versions, provenance: Provenance,
        tally: Tally
    ) -> Bool {
        let belief = Belief(
            rung: rung, question: .offsets, answer: answer.rawValue,
            versions: versions, provenance: provenance, tally: tally, anchor: anchor ? true : nil
        )
        guard let index = beliefs.firstIndex(where: { $0.rung == rung && $0.question == .offsets }) else {
            beliefs.append(belief)
            return true
        }
        let old = beliefs[index]
        guard old.answer != belief.answer || old.engineKey != belief.engineKey || old.anchor != belief.anchor else { return false }
        beliefs[index] = belief
        return true
    }

    /// The old learner read plain `AXValue` offsets, so its demotions were judged under `value`.
    init(demotions: [(rung: String, version: String, capability: String)]) {
        self.init(beliefs: demotions.compactMap { demotion in
            guard let capability = Capability(rawValue: demotion.capability) else { return nil }
            return Belief(
                rung: demotion.rung, question: Question(capability), answer: Belief.broken, judgedUnder: .value,
                versions: Versions(app: demotion.version), provenance: Provenance(tag: "migrated")
            )
        })
    }

    @discardableResult
    mutating func forget(_ question: Question, at rung: String) -> Bool {
        let before = beliefs.count
        beliefs.removeAll { $0.rung == rung && $0.question == question }
        return beliefs.count != before
    }
}

// MARK: - Recorder

extension ReadModel {
    var traceName: String {
        "\(answer.rawValue)/\(source.rawValue)" + (newEngine ? " new-engine" : "")
    }
}

extension Belief {
    var traceFields: String {
        var fields = "q=\(question.rawValue) a=\(answer)"
        if let judgedUnder { fields += " judged=\(judgedUnder.rawValue)" }
        fields += " ver=\(appVersion.isEmpty ? "nil" : appVersion)"
        if let engineVersion { fields += " engine=\(engineVersion)" }
        if let build = provenance.build { fields += " build=\(build.filter { $0 != " " })" }
        if let learnedAt = provenance.learnedAt { fields += " at=\(learnedAt)" }
        if let tag = provenance.tag { fields += " tag=\(tag)" }
        if let tally { fields += " tally=\(tally.traceName)" }
        if anchor == true { fields += " anchor" }
        return fields
    }
}

extension Tally {
    var traceName: String { "v\(value),tc\(textContent),misfit\(misfit),neutral\(neutral)" }
}

extension ResolvedBeliefs {
    var traceLines: [String] {
        var lines = inForce.map { "belief \($0.traceFields) in-force" }
        lines += reopened.map { "belief \($0.traceFields) reopened offsets=\(readModel.answer.rawValue)" }
        if let belief = readModel.belief {
            let state = readModel.newEngine ? "stale" : readModel.pinned ? "retired" : belief.anchor == true ? "dates-engine"
                : readModel.source == .plain ? "not-this-field" : "in-force"
            lines.append("belief \(belief.traceFields) \(state)")
        }
        return lines
    }
}
