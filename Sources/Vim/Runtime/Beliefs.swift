import Foundation

/// A JSON string so `defaults read` stays legible; an unreadable store reads as empty.
enum Beliefs {
    static let storeKey = "fieldBeliefs"
    /// The old learner's schema 2 demotions, migrated once.
    static let legacyKey = "learnedCapabilityPriors"

    static func load() -> BeliefStore {
        let defaults = UserDefaults.standard
        if let json = defaults.string(forKey: storeKey) {
            guard let data = json.data(using: .utf8),
                  let store = try? JSONDecoder().decode(BeliefStore.self, from: data),
                  store.schema == BeliefStore.currentSchema else { return BeliefStore() }
            return store
        }
        guard let migrated = migrated() else { return BeliefStore() }
        save(migrated)
        defaults.removeObject(forKey: legacyKey)
        return migrated
    }

    static func save(_ store: BeliefStore) {
        guard !store.beliefs.isEmpty else {
            UserDefaults.standard.removeObject(forKey: storeKey)
            return
        }
        guard let data = try? JSONEncoder().encode(store), let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: storeKey)
    }

    static func forget(_ question: String, at rung: String) {
        var store = load()
        guard store.forget(question, at: rung) else { return }
        save(store)
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

    private static func migrated() -> BeliefStore? {
        guard let json = UserDefaults.standard.string(forKey: legacyKey), let data = json.data(using: .utf8),
              let legacy = try? JSONDecoder().decode(Legacy.self, from: data), legacy.schema == 2 else { return nil }
        return BeliefStore(demotions: legacy.records.map { ($0.rung, $0.version, $0.capability) })
    }
}
