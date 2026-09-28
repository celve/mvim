import Foundation

/// The store as a JSON file the user may edit; mvim rereads it at every resolve.
struct Beliefs {
    static let shared = Beliefs(url: .applicationSupportDirectory.appending(path: "mvim/beliefs.json"), defaults: .standard)
    /// Where the store lived before the file, migrated once.
    static let defaultsKey = "fieldBeliefs"
    /// The old learner's schema 2 demotions, migrated once.
    static let legacyKey = "learnedCapabilityPriors"

    struct UnknownSchema: Error {
        let schema: Int
    }

    let url: URL
    let defaults: UserDefaults

    /// Creates the file on first use, from the store the defaults held.
    func load() throws -> BeliefStore {
        if let store = try read() { return store }
        let store = migrated()
        if (try? save(store)) != nil {
            defaults.removeObject(forKey: Self.defaultsKey)
            defaults.removeObject(forKey: Self.legacyKey)
        }
        return store
    }

    /// Never writes over a file that does not read, so a broken edit waits for the user.
    func save(_ store: BeliefStore) throws {
        _ = try read()
        // Through a symlink, so a file kept elsewhere stays linked.
        let target = url.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(store) + Data("\n".utf8)).write(to: target, options: .atomic)
    }

    func forget(_ question: Question, at rung: String) throws {
        var store = try load()
        guard store.forget(question, at: rung) else { return }
        try save(store)
    }

    /// Nil when there is no file.
    func read() throws -> BeliefStore? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        // Deleting the last entry leaves a trailing comma.
        decoder.allowsJSON5 = true
        let store = try decoder.decode(BeliefStore.self, from: Data(contentsOf: url))
        guard store.schema == BeliefStore.currentSchema else { throw UnknownSchema(schema: store.schema) }
        return store
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

    private func migrated() -> BeliefStore {
        if let json = defaults.string(forKey: Self.defaultsKey) {
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
