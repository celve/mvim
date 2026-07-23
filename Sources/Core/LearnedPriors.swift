import Foundation

/// The lazy write probe's result cache.
///
/// Reads are probeable harmlessly, so the prober trial-reads them fresh at
/// every bind. Writes can only be probed destructively — so the probe runs
/// lazily as real commands, the settle verdict is the probe result, and
/// this store caches it per (bundleID, appVersion, role). The caching
/// ceremony is what a noisy, expensive probe requires: two consecutive
/// strikes commit a demotion; an attributed success clears pending strikes
/// (honest apps settle constantly, so a false lesson needs back-to-back
/// failures with nothing in between); version keying is the TTL — an app
/// update re-opens the trial; seeds are pre-warmed entries for known
/// liars; `defaults delete com.loom.Norm learnedCapabilityPriors` is the
/// flush. Only negative results are stored: positives re-confirm for free
/// on every successful command, while a cached negative stops the
/// capability being exercised and so needs the TTL.
///
/// Disposable cache, never config — decode failure or schema drift
/// degrades to an empty store, i.e. claims trusted as before. LoomCore
/// cannot see the engine's `Capability` type, so the store speaks its raw
/// strings; the runtime converts.
///
/// **Unwired, and its identity is stale.** Nothing calls `demoted`,
/// `recordStrike`, or `recordSuccess`; `Executor.lastRun` collects the
/// evidence and nothing reads it. When that wiring lands, replace
/// `(bundleID, version, role)` with a `Surface` rung — inside a browser,
/// `role` cannot tell chrome from web content, so a demotion learned in a
/// page would silently apply to the app's own search box. Write at the
/// **role** rung specifically, never the identifier one: a key per individual
/// input would never accumulate `strikesToCommit`. And an explicit user entry
/// must silence the learner for that atom at that scope and below, or a user's
/// `.on` loses to an inference and clearing an override stops restoring
/// auto-detection. The store is empty in the field until wiring, so re-keying
/// then costs exactly what it costs now.
public enum LearnedPriors {
    static let storeKey = "learnedCapabilityPriors"
    static let strikesToCommit = 2

    /// Curated known liars — version- and role-agnostic, folded into the
    /// same lookup (the disable-list seed pattern).
    static let seeds: [String: Set<String>] = [:]

    struct Record: Codable, Equatable {
        var bundleID: String
        var version: String      // "" when unresolvable
        var role: String         // "" when unresolvable
        var capability: String   // Capability.rawValue
        var strikes: Int
        var committed: Bool
    }

    struct Store: Codable {
        var schema = 1
        var records: [Record] = []
    }

    /// Committed demotions for one binding identity, seeds included.
    public static func demoted(bundleID: String, version: String?, role: String?) -> Set<String> {
        var demoted = seeds[bundleID] ?? []
        let version = version ?? ""
        let role = role ?? ""
        for record in load().records
        where record.committed && record.bundleID == bundleID
            && record.version == version && record.role == role {
            demoted.insert(record.capability)
        }
        return demoted
    }

    /// One observed, attributed settle failure. Returns true exactly when
    /// this strike commits the demotion (the false→true transition).
    @discardableResult
    public static func recordStrike(
        bundleID: String, version: String?, role: String?, capability: String
    ) -> Bool {
        var store = load()
        let version = version ?? ""
        let role = role ?? ""
        // Version expiry made physical: an update re-opens the trial.
        let before = store.records.count
        store.records.removeAll { $0.bundleID == bundleID && $0.version != version }
        let pruned = store.records.count != before

        if let index = store.records.firstIndex(where: {
            $0.bundleID == bundleID && $0.version == version
                && $0.role == role && $0.capability == capability
        }) {
            // Already demoted: stray strikes (a stale cursor's collapse
            // write) must not churn the store or re-trigger republishes.
            guard !store.records[index].committed else {
                if pruned { save(store) }
                return false
            }
            store.records[index].strikes += 1
            let committed = store.records[index].strikes >= strikesToCommit
            store.records[index].committed = committed
            save(store)
            return committed
        }

        let committed = strikesToCommit <= 1
        store.records.append(Record(
            bundleID: bundleID, version: version, role: role,
            capability: capability, strikes: 1, committed: committed
        ))
        save(store)
        return committed
    }

    /// One observed, attributed settle success: clears pending strikes.
    /// Committed demotions are never promoted here — a demoted capability
    /// is unused and generates no evidence; only the TTL re-opens it.
    public static func recordSuccess(
        bundleID: String, version: String?, role: String?, capability: String
    ) {
        var store = load()
        let version = version ?? ""
        let role = role ?? ""
        let before = store.records.count
        store.records.removeAll {
            $0.bundleID == bundleID && $0.version == version && $0.role == role
                && $0.capability == capability && !$0.committed
        }
        // Honest apps hit this path on every command: zero writes.
        guard store.records.count != before else { return }
        save(store)
    }

    // MARK: - Persistence (a JSON string, so `defaults read` stays legible)

    private static func load() -> Store {
        guard let json = UserDefaults.standard.string(forKey: storeKey),
              let data = json.data(using: .utf8),
              let store = try? JSONDecoder().decode(Store.self, from: data),
              store.schema == 1 else { return Store() }
        return store
    }

    private static func save(_ store: Store) {
        guard let data = try? JSONEncoder().encode(store),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: storeKey)
    }
}
