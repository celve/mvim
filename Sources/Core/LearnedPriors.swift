import Foundation

/// The lazy write probe's conclusions: capabilities a field *claimed* and then
/// demonstrably failed to deliver.
///
/// Reads are probeable harmlessly, so the prober trial-reads them fresh at every
/// bind. Writes cannot be probed without performing them — so the probe runs
/// lazily as real commands, and a settle verdict is one reading of it. Turning
/// those noisy readings into a conclusion is `StrikeLedger`'s job; this store
/// holds only what it concluded.
///
/// **Commits only.** Pending strike counts live in memory and die with the
/// process, deliberately: a structural lie fails every command and commits in
/// seconds, while a merely flaky field interleaves successes, never commits, and
/// is forgotten at exit. Persisting the counts would let an occasional hiccup
/// accumulate across restarts into a demotion it never earned.
///
/// Keyed by `(surface rung, app version, capability)`:
/// - the **rung** is a `Surface` rung, so a demotion learned in a browser's web
///   content cannot leak to the app's own native chrome. Writes land at the role
///   rung; reads walk the ladder.
/// - the **version** is the TTL made physical — an app update re-opens the trial,
///   so a fixed `AXSelectedText` silently earns the exact lane back.
/// - only **negative** results are stored: positives re-confirm for free on every
///   successful command, whereas a cached negative stops the capability being
///   exercised and so needs an expiry.
///
/// Disposable cache, never config — decode failure or schema drift degrades to an
/// empty store, i.e. claims trusted as before. That is why it is a separate store
/// from `CapabilityConfig`: the user's decisions must never ride on the
/// disposability of a machine's guess. `defaults delete com.loom.Norm
/// learnedCapabilityPriors` is the flush. LoomCore cannot see the engine's
/// `Capability` type, so the store speaks its raw strings; the runtime converts.
public enum LearnedPriors {
    static let storeKey = "learnedCapabilityPriors"

    /// Curated known liars, folded into the same lookup (the seed pattern).
    /// Version-agnostic: a shipped entry is a standing claim, not an observation.
    static let seeds: [String: Set<String>] = [:]

    struct Record: Codable, Equatable {
        var rung: String
        var version: String      // "" when unresolvable
        var capability: String   // Capability.rawValue
    }

    struct Store: Codable {
        var schema = 2
        var records: [Record] = []
    }

    /// Every committed demotion that applies to a surface, seeds included.
    ///
    /// Reads walk the whole ladder even though writes only ever land at the role
    /// rung, so a curated seed at a wider rung (a whole app, a site in any
    /// browser) still reaches a narrower field.
    public static func demoted(rungs: [String], version: String?) -> Set<String> {
        var demoted: Set<String> = []
        for rung in rungs {
            if let seeded = seeds[rung] { demoted.formUnion(seeded) }
        }
        let version = version ?? ""
        let rungs = Set(rungs)
        for record in load().records
        where record.version == version && rungs.contains(record.rung) {
            demoted.insert(record.capability)
        }
        return demoted
    }

    /// Persist one conclusion. Idempotent — `StrikeLedger` only reports the
    /// committing transition, but a restart re-earns strikes against a rung that
    /// may already be recorded.
    public static func commit(rung: String, version: String?, capability: String) {
        var store = load()
        let version = version ?? ""
        // Version expiry made physical: an update re-opens every trial for this
        // rung, so a fixed capability is not pinned to the blind lane forever.
        let before = store.records.count
        store.records.removeAll { $0.rung == rung && $0.version != version }
        let record = Record(rung: rung, version: version, capability: capability)
        guard !store.records.contains(record) else {
            if store.records.count != before { save(store) }
            return
        }
        store.records.append(record)
        save(store)
    }

    /// Drop a conclusion — the user promoted it to a durable `CapabilityConfig`
    /// decision, so this copy is redundant, or vetoed it outright.
    public static func forget(rung: String, capability: String) {
        var store = load()
        let before = store.records.count
        store.records.removeAll { $0.rung == rung && $0.capability == capability }
        guard store.records.count != before else { return }
        save(store)
    }

    // MARK: - Persistence (a JSON string, so `defaults read` stays legible)

    private static func load() -> Store {
        guard let json = UserDefaults.standard.string(forKey: storeKey),
              let data = json.data(using: .utf8),
              let store = try? JSONDecoder().decode(Store.self, from: data),
              store.schema == 2 else { return Store() }
        return store
    }

    private static func save(_ store: Store) {
        guard store.records.isEmpty == false else {
            UserDefaults.standard.removeObject(forKey: storeKey)
            return
        }
        guard let data = try? JSONEncoder().encode(store),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: storeKey)
    }
}
