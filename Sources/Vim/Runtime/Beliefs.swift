import Foundation

/// The user's overrides and the learned beliefs, in a JSON file the user may edit; mvim rereads it at every resolve.
final class Beliefs {
    static let shared = Beliefs(url: .applicationSupportDirectory.appending(path: "mvim/beliefs.json"), defaults: .standard)
    /// Where the menu kept overrides before the file.
    static let overridesKey = "capabilityOverrides"
    /// Where the beliefs lived before the file.
    static let beliefsKey = "fieldBeliefs"
    /// The old learner's schema 2 demotions.
    static let legacyKey = "learnedCapabilityPriors"
    /// The last version that read, applied while the file does not, across relaunches too.
    static let lastGoodKey = "beliefsLastGood"

    /// Overrides are rung → capability → `on` or `off`, as `CapabilityConfig` reads them.
    struct Contents: Codable, Equatable {
        var schema = BeliefStore.currentSchema
        var overrides: [String: [String: String]] = [:]
        var beliefs: [Belief] = []

        var store: BeliefStore {
            get { BeliefStore(beliefs: beliefs) }
            set { beliefs = newValue.beliefs }
        }

        /// An override retires the belief behind its row, so returning to Auto does not revive it.
        mutating func retire(_ capability: Capability, at rung: String) {
            store.forget(Question(capability), at: rung)
            if capability == .readCaret { store.forget(.offsets, at: rung) }
        }

        /// Leaves every choice as it is, so the field is tried afresh rather than pinned.
        mutating func forget(_ beliefs: [Belief]) {
            for belief in beliefs { store.forget(belief.question, at: belief.rung) }
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let url: URL
    let defaults: UserDefaults
    private lazy var lastGood: Contents? = defaults.string(forKey: Self.lastGoodKey).flatMap {
        try? JSONDecoder().decode(Contents.self, from: Data($0.utf8))
    }

    init(url: URL, defaults: UserDefaults) {
        self.url = url
        self.defaults = defaults
    }

    /// What mvim applies: the file, else the last version that read, with why the file itself is not used.
    func current() -> (contents: Contents, problem: Error?) {
        do {
            return (try load(), nil)
        } catch {
            return (lastGood ?? migrated(), error)
        }
    }

    /// With no file, writes one from what the defaults held, which stay until it is written.
    func load() throws -> Contents {
        if let contents = try read() { return contents }
        let contents = migrated()
        guard try write(contents, over: nil) else { return try read() ?? contents }
        return contents
    }

    /// Applies `change` again to a version saved meanwhile, so neither edit is lost.
    func update(_ change: (inout Contents) -> Void) throws {
        for _ in 0..<3 {
            let before = try load()
            var contents = before
            change(&contents)
            if contents == before { return }
            if try write(contents, over: before) { return }
        }
        throw Failure(description: "kept changing while mvim wrote it")
    }

    /// Nil when there is no file.
    func read() throws -> Contents? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        // Deleting the last entry leaves a trailing comma.
        decoder.allowsJSON5 = true
        let contents = try decoder.decode(Contents.self, from: Data(contentsOf: url))
        guard contents.schema == BeliefStore.currentSchema else {
            throw Failure(description: "schema \(contents.schema), not \(BeliefStore.currentSchema)")
        }
        // A name this build does not know is kept and ignored; a value no name takes is a typo.
        for belief in contents.beliefs where !belief.answerFits {
            throw Failure(description: "\(belief.question.rawValue) cannot be \(belief.answer) at \(belief.rung)")
        }
        for (rung, choices) in contents.overrides {
            // `CapabilityConfig.Override`, which LoomCore keeps out of this file's reach.
            for (capability, value) in choices where value != "on" && value != "off" {
                throw Failure(description: "\(capability) cannot be \(value) at \(rung)")
            }
        }
        remember(contents)
        return contents
    }

    static func provenance(tag: String) -> Provenance {
        Provenance(build: build, learnedAt: ISO8601DateFormatter().string(from: Date()), tag: tag)
    }

    static let build: String? = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let version = info["CFBundleShortVersionString"] as? String else { return nil }
        return (info["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
    }()

    /// False, writing nothing, once the file no longer holds `expected`; it never writes over one that does not read.
    private func write(_ contents: Contents, over expected: Contents?) throws -> Bool {
        guard try read() == expected else { return false }
        // Through a symlink, so a file kept elsewhere stays linked.
        let target = url.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(contents) + Data("\n".utf8)).write(to: target, options: .atomic)
        remember(contents)
        return true
    }

    /// Once a file reads, the defaults it replaced could only bring back what deleting it drops.
    private func remember(_ contents: Contents) {
        for key in [Self.overridesKey, Self.beliefsKey, Self.legacyKey] where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
        guard contents != lastGood, let json = try? JSONEncoder().encode(contents) else { return }
        lastGood = contents
        defaults.set(String(decoding: json, as: UTF8.self), forKey: Self.lastGoodKey)
    }

    private struct Legacy: Decodable {
        struct Record: Decodable {
            let rung: String
            let version: String
            let capability: String
        }

        let schema: Int
        let records: [Record]
    }

    private func migrated() -> Contents {
        let overrides = defaults.dictionary(forKey: Self.overridesKey) as? [String: [String: String]] ?? [:]
        return Contents(overrides: overrides, beliefs: migratedStore().beliefs)
    }

    private func migratedStore() -> BeliefStore {
        if let json = defaults.string(forKey: Self.beliefsKey) {
            guard let store = try? JSONDecoder().decode(BeliefStore.self, from: Data(json.utf8)),
                  store.schema == BeliefStore.currentSchema else { return BeliefStore() }
            return store
        }
        guard let json = defaults.string(forKey: Self.legacyKey),
              let legacy = try? JSONDecoder().decode(Legacy.self, from: Data(json.utf8)), legacy.schema == 2 else {
            return BeliefStore()
        }
        return BeliefStore(demotions: legacy.records.map { ($0.rung, $0.version, $0.capability) })
    }
}

private extension Belief {
    var answerFits: Bool {
        switch question {
        case .write, .key: return answer == Belief.broken
        case .offsets: return offsetsAnswer != nil
        case .unknown: return true
        }
    }
}
