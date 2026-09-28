import Foundation

/// The user's overrides and the learned beliefs, in a JSON file the user may edit; mvim rereads it at every resolve.
struct Beliefs {
    static let shared = Beliefs(url: .applicationSupportDirectory.appending(path: "mvim/beliefs.json"), defaults: .standard)
    /// Where the menu kept overrides before the file.
    static let overridesKey = "capabilityOverrides"
    /// Where the beliefs lived before the file.
    static let beliefsKey = "fieldBeliefs"
    /// The old learner's schema 2 demotions.
    static let legacyKey = "learnedCapabilityPriors"

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
    }

    struct Unusable: Error, CustomStringConvertible {
        let description: String
    }

    let url: URL
    let defaults: UserDefaults

    /// With no file, writes one from what the defaults held, which stay until it is written.
    func load() throws -> Contents {
        if let contents = try read() { return contents }
        let contents = migrated()
        try save(contents)
        for key in [Self.overridesKey, Self.beliefsKey, Self.legacyKey] { defaults.removeObject(forKey: key) }
        return contents
    }

    /// Never writes over a file that does not read, so a broken edit waits for the user.
    func save(_ contents: Contents) throws {
        _ = try read()
        // Through a symlink, so a file kept elsewhere stays linked.
        let target = url.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(contents) + Data("\n".utf8)).write(to: target, options: .atomic)
    }

    func update(_ change: (inout Contents) -> Void) throws {
        var contents = try load()
        let before = contents
        change(&contents)
        if contents != before { try save(contents) }
    }

    /// Nil when there is no file.
    func read() throws -> Contents? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        // Deleting the last entry leaves a trailing comma.
        decoder.allowsJSON5 = true
        let contents = try decoder.decode(Contents.self, from: Data(contentsOf: url))
        guard contents.schema == BeliefStore.currentSchema else {
            throw Unusable(description: "schema \(contents.schema), not \(BeliefStore.currentSchema)")
        }
        // A name this build does not know is kept and ignored; a value no name takes is a typo.
        for belief in contents.beliefs where !belief.answerFits {
            throw Unusable(description: "\(belief.question.rawValue) cannot be \(belief.answer) at \(belief.rung)")
        }
        for (rung, choices) in contents.overrides {
            // `CapabilityConfig.Override`, which LoomCore keeps out of this file's reach.
            for (capability, value) in choices where value != "on" && value != "off" {
                throw Unusable(description: "\(capability) cannot be \(value) at \(rung)")
            }
        }
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
