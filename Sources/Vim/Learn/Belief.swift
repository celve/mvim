/// How a field counts caret and selection offsets: the offsets question's answers.
public enum OffsetsAnswer: String, Codable, CaseIterable, Equatable, Sendable {
    /// `AXValue`'s own offsets.
    case value
    /// Chromium's count without the paragraph breaks it generates in `AXValue` (#11, #13).
    case textContent
    /// No answer fits: caret reads are withheld and commands take the blind lane.
    case untrusted
}

/// One learned answer to one question about the fields at a rung.
///
/// A trial belief's question is a write or key capability, and its only stored answer is
/// `broken`, since a pass changes nothing. The read model's question is `offsets`.
public struct Belief: Codable, Equatable, Sendable {
    public static let offsets = "offsets"
    public static let broken = "broken"

    public var rung: String
    public var question: String
    public var answer: String
    /// The offsets answer a trial verdict was judged under; the verdict holds only while it does.
    public var judgedUnder: OffsetsAnswer?
    /// "" when unresolvable, as the old store had it.
    public var appVersion: String
    public var engineVersion: String?
    public var provenance: Provenance
    public var tally: Tally?
    /// A read model evidence confirmed rather than moved: it dates the engine and leaves each field its own start.
    public var anchor: Bool?

    public init(
        rung: String, question: String, answer: String, judgedUnder: OffsetsAnswer? = nil,
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

    public var capability: Capability? { Capability(rawValue: question) }

    public var offsetsAnswer: OffsetsAnswer? {
        question == Self.offsets ? OffsetsAnswer(rawValue: answer) : nil
    }

    /// What the read model expires on: Electron's framework where readable, else the app itself.
    var engineKey: String { engineVersion ?? appVersion }
}

/// Where a belief came from, for the recorder.
public struct Provenance: Codable, Equatable, Sendable {
    /// The mvim build that decided it.
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

/// The offsets evidence a read-model belief has seen since the process started.
public struct Tally: Codable, Equatable, Sendable {
    public var value = 0
    public var textContent = 0
    public var misfit = 0
    public var neutral = 0

    public init() {}

    public mutating func count(_ evidence: OffsetsEvidence) {
        switch evidence {
        case .supports(.value, _): value += 1
        case .supports(.textContent, _): textContent += 1
        case .supports(.untrusted, _), .misfit: misfit += 1
        case .neutral: neutral += 1
        }
    }
}

/// The host app's version and, where readable, its web engine's.
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
    /// Toward a safer answer on one observation; back to `value` only on another engine.
    func next(_ evidence: OffsetsEvidence, newEngine: Bool) -> OffsetsAnswer {
        switch evidence {
        case .neutral:
            return self
        case .misfit:
            return .untrusted
        case .supports(let answer, _):
            guard answer != self else { return self }
            switch answer {
            case .value: return newEngine ? .value : .untrusted
            case .textContent, .untrusted: return answer
            }
        }
    }
}

// MARK: - The store

/// The learner's memory: one belief per rung and question. A disposable cache, never config.
public struct BeliefStore: Codable, Equatable, Sendable {
    public static let currentSchema = 3

    public var schema = BeliefStore.currentSchema
    public var beliefs: [Belief] = []

    public init(beliefs: [Belief] = []) {
        self.beliefs = beliefs
    }
}

/// Where a read model came from.
public enum OffsetsSource: String, Equatable, Sendable {
    /// The engine rule: a Chromium field with AX children counts text content, any other `AXValue`.
    case start
    case learned
    /// A `readCaret` override retired the belief.
    case user
    /// The field has no AX children, so no generated breaks: both counts are `AXValue`'s, whatever its rung learned.
    case plain

    /// Whether the field's reads teach its rung's read model.
    public var observes: Bool { self == .start || self == .learned }
}

/// How a binding reads offsets, and what the movement rule needs to move it.
public struct ReadModel: Equatable, Sendable {
    /// At bind, where the profile was resolved.
    public var answer: OffsetsAnswer
    public var source: OffsetsSource
    /// The rung's learned answer, in force at this engine.
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

/// The beliefs that apply to one field.
public struct ResolvedBeliefs: Equatable, Sendable {
    public var readModel: ReadModel
    /// Trial verdicts in force.
    public var broken: Set<Capability>
    public var inForce: [Belief]
    /// Trial verdicts judged under another offsets answer, reopened.
    public var reopened: [Belief]
}

public extension BeliefStore {
    /// Trial verdicts hold across the whole ladder, as curation's do; the read model lives at `rung` alone.
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
        beliefs.first { $0.rung == rung && $0.question == Belief.offsets }
    }

    /// One failure blamed on `capability` sets it broken; false when that verdict already stood.
    mutating func commit(
        broken capability: Capability, at rung: String, judgedUnder offsets: OffsetsAnswer,
        versions: Versions, provenance: Provenance
    ) -> Bool {
        let app = versions.app ?? ""
        // An app update reopens every trial at the rung.
        beliefs.removeAll { $0.rung == rung && $0.question != Belief.offsets && $0.appVersion != app }
        let verdict = Belief(
            rung: rung, question: capability.rawValue, answer: Belief.broken, judgedUnder: offsets,
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

    /// Writes the read model; false, and nothing written, when it already stood at this engine.
    mutating func record(
        offsets answer: OffsetsAnswer, at rung: String, anchor: Bool = false, versions: Versions, provenance: Provenance,
        tally: Tally
    ) -> Bool {
        let belief = Belief(
            rung: rung, question: Belief.offsets, answer: answer.rawValue,
            versions: versions, provenance: provenance, tally: tally, anchor: anchor ? true : nil
        )
        guard let index = beliefs.firstIndex(where: { $0.rung == rung && $0.question == Belief.offsets }) else {
            beliefs.append(belief)
            return true
        }
        let old = beliefs[index]
        guard old.answer != belief.answer || old.engineKey != belief.engineKey || old.anchor != belief.anchor else { return false }
        beliefs[index] = belief
        return true
    }

    /// The learner before beliefs had one read model, plain `AXValue` offsets, so its demotions were judged under it.
    init(demotions: [(rung: String, version: String, capability: String)]) {
        self.init(beliefs: demotions.compactMap { demotion in
            guard Capability(rawValue: demotion.capability) != nil else { return nil }
            return Belief(
                rung: demotion.rung, question: demotion.capability, answer: Belief.broken, judgedUnder: .value,
                versions: Versions(app: demotion.version), provenance: Provenance(tag: "migrated")
            )
        })
    }

    /// A user override retires the belief.
    @discardableResult
    mutating func forget(_ question: String, at rung: String) -> Bool {
        let before = beliefs.count
        beliefs.removeAll { $0.rung == rung && $0.question == question }
        return beliefs.count != before
    }
}

// MARK: - Recorder

extension ReadModel {
    /// `textContent/start`; a stored belief from another engine adds `new-engine`.
    var traceName: String {
        "\(answer.rawValue)/\(source.rawValue)" + (newEngine ? " new-engine" : "")
    }
}

extension Belief {
    /// `q=writeSelection a=broken judged=value ver=1.49.1 build=1.0.0(812) at=… tag=e3.c7`; unknowns left out.
    var traceFields: String {
        var fields = "q=\(question) a=\(answer)"
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
    /// One `belief` line per stored answer that touched this field, with why it does or does not apply.
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
