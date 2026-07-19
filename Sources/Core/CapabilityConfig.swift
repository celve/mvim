import Foundation

/// Per-app capability policy: shipped seeds plus the user's overrides.
///
/// Config, not evidence — `LearnedPriors` records what fields *did*; this
/// store records what curation and the user *decided*. LoomCore cannot see
/// the engine's `Capability` type, so the store speaks its raw strings and
/// the runtime converts (the LearnedPriors pattern).
///
/// Seeds are compiled in and never written to defaults: the persisted
/// dictionary holds only user choices, so shipped seed changes always reach
/// users (no register-defaults trade-off). Overrides are subtractive
/// against mechanism truth — an explicit `.on` un-seeds curation, never a
/// failed probe.
public enum CapabilityConfig {
    static let storeKey = "capabilityOverrides"

    /// A user's per-(app, capability) choice. Absent = auto: defer to the
    /// probe and the seeds.
    public enum Override: String, Sendable {
        case on, off
    }

    /// Curated apps where a capability defaults off. Notion reacts to any
    /// standing selection (floating toolbar, collaborator highlights), so
    /// the block cursor may not be left drawn there.
    static let seeds: [String: Set<String>] = [
        "notion.id": ["drawCursor"],
    ]

    public static func seededOff(bundleID: String, capability: String) -> Bool {
        seeds[bundleID]?.contains(capability) ?? false
    }

    public static func userOverride(for bundleID: String, capability: String) -> Override? {
        guard let store = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: [String: String]],
              let raw = store[bundleID]?[capability] else { return nil }
        return Override(rawValue: raw)
    }

    /// `nil` clears back to auto. Emptied entries are pruned so
    /// `defaults read` shows exactly the choices the user has made.
    public static func setUserOverride(_ override: Override?, for bundleID: String, capability: String) {
        var store = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: [String: String]]) ?? [:]
        var app = store[bundleID] ?? [:]
        app[capability] = override?.rawValue
        store[bundleID] = app.isEmpty ? nil : app
        if store.isEmpty {
            UserDefaults.standard.removeObject(forKey: storeKey)
        } else {
            UserDefaults.standard.set(store, forKey: storeKey)
        }
    }
}
