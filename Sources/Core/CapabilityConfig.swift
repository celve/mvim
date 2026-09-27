import Foundation

/// Shipped seeds plus the user's persisted overrides, in raw strings since LoomCore cannot see `Capability`.
public enum CapabilityConfig {
    static let storeKey = "capabilityOverrides"

    /// A user's per-(surface, capability) choice. Absent = auto: defer to the
    /// probe and the seeds.
    public enum Override: String, Sendable {
        case on, off
    }

    /// Where an answer came from, so the menu can mark the entry in force.
    /// The rung is what the checkmark lands on; badges never show it.
    public struct Resolution: Equatable, Sendable {
        public let override: Override?
        public let overrideRung: String?
        public let seededOffRung: String?

        public var isSeededOff: Bool { seededOffRung != nil }

        /// No entry at any rung — defer to the probe.
        public static let auto = Resolution(override: nil, overrideRung: nil, seededOffRung: nil)
    }

    /// Both ladder walks for one capability, narrowest first.
    ///
    /// Kept as two independent walks on purpose — see `SurfaceLadder.seedEntry`.
    /// Merging them would let a seed at a narrow rung beat a user's `.on` at a
    /// wide one, contradicting the law that an explicit `.on` un-seeds.
    public static func resolve(_ surface: Surface, capability: String) -> Resolution {
        resolve(surface, rungs: surface.rungs, store: load(), capability: capability)
    }

    /// Every capability against one surface, reading the store once.
    ///
    /// The batching instinct the AX layer already follows: nine separate
    /// `resolve` calls would re-read and re-cast the defaults dictionary nine
    /// times per bind, and the rungs are the same for all of them.
    public static func resolveAll(
        _ surface: Surface, capabilities: [String]
    ) -> [String: Resolution] {
        let rungs = surface.rungs
        let store = load()
        return Dictionary(uniqueKeysWithValues: capabilities.map {
            ($0, resolve(surface, rungs: rungs, store: store, capability: $0))
        })
    }

    private static func resolve(
        _ surface: Surface, rungs: [String], store: SurfaceLadder.UserStore, capability: String
    ) -> Resolution {
        let user = SurfaceLadder.userEntry(capability, rungs: rungs, store: store)
        return Resolution(
            override: user.flatMap { Override(rawValue: $0.value) },
            overrideRung: user?.rung,
            seededOffRung: SurfaceLadder.seedEntry(
                capability, rungs: rungs, seeds: CapabilitySeeds.denied
            )
        )
    }

    /// Store a choice at `rung`, clearing the same capability at every narrower
    /// rung so the menu's checkmark cannot lie (the `Prefs.setPolicy`
    /// invariant). `override` of `nil` is Auto: clear it at every rung.
    public static func setUserOverride(
        _ override: Override?, at rung: String?, on surface: Surface, capability: String
    ) {
        save(SurfaceLadder.setting(
            override?.rawValue, capability, at: rung, rungs: surface.rungs, store: load()
        ))
    }

    /// Drop every capability stored at `rung` and at every narrower rung — the
    /// menu's "Clear overrides…" actions.
    public static func clearOverrides(atAndBelow rung: String, on surface: Surface) {
        save(SurfaceLadder.clearing(atAndBelow: rung, rungs: surface.rungs, store: load()))
    }

    // MARK: - Persistence

    private static func load() -> SurfaceLadder.UserStore {
        UserDefaults.standard.dictionary(forKey: storeKey) as? SurfaceLadder.UserStore ?? [:]
    }

    private static func save(_ store: SurfaceLadder.UserStore) {
        // `SurfaceLadder` already prunes emptied rungs, so an empty store here
        // means the user has no choices left and the key should go entirely.
        if store.isEmpty {
            UserDefaults.standard.removeObject(forKey: storeKey)
        } else {
            UserDefaults.standard.set(store, forKey: storeKey)
        }
    }
}
