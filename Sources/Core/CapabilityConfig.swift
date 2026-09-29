/// Shipped seeds plus the user's overrides from the beliefs file, in raw strings since LoomCore cannot see `Capability`.
public enum CapabilityConfig {
    /// A user's per-(surface, capability) choice. Absent = auto: defer to the
    /// probe and the seeds.
    public enum Override: String, Sendable {
        case on, off
    }

    /// Where an answer came from: the menu checks the entry in force and names its rung in the row's subtitle.
    public struct Resolution: Equatable, Sendable {
        public let override: Override?
        public let overrideRung: String?
        public let seededOffRung: String?

        public var isSeededOff: Bool { seededOffRung != nil }

        /// No entry at any rung — defer to the probe.
        public static let auto = Resolution(override: nil, overrideRung: nil, seededOffRung: nil)
    }

    /// Both ladder walks for one capability, kept apart so a user's `.on` always un-seeds (see `SurfaceLadder.seedEntry`).
    public static func resolve(
        _ surface: Surface, capability: String, overrides: SurfaceLadder.UserStore
    ) -> Resolution {
        resolve(surface, rungs: surface.rungs, store: overrides, capability: capability)
    }

    /// Every capability against one surface, computing its rungs once.
    public static func resolveAll(
        _ surface: Surface, capabilities: [String], overrides: SurfaceLadder.UserStore
    ) -> [String: Resolution] {
        let rungs = surface.rungs
        return Dictionary(uniqueKeysWithValues: capabilities.map {
            ($0, resolve(surface, rungs: rungs, store: overrides, capability: $0))
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

    /// A choice at `rung` clears narrower rungs so the menu's checkmark cannot lie; nil is Auto, cleared everywhere.
    public static func setting(
        _ override: Override?, at rung: String?, on surface: Surface, capability: String,
        in overrides: SurfaceLadder.UserStore
    ) -> SurfaceLadder.UserStore {
        SurfaceLadder.setting(override?.rawValue, capability, at: rung, rungs: surface.rungs, store: overrides)
    }

    /// The menu's "Clear overrides…": every capability at `rung` and every narrower rung.
    public static func clearing(
        atAndBelow rung: String, on surface: Surface, in overrides: SurfaceLadder.UserStore
    ) -> SurfaceLadder.UserStore {
        SurfaceLadder.clearing(atAndBelow: rung, rungs: surface.rungs, store: overrides)
    }
}
