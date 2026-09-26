/// Curation's and the user's say over one atom, as `CapabilityConfig` resolved it.
public struct ConfigChoice: Equatable, Sendable {
    public enum Override: Equatable, Sendable {
        case on, off
    }

    public var override: Override?
    public var seededOff: Bool

    public init(override: Override? = nil, seededOff: Bool = false) {
        self.override = override
        self.seededOff = seededOff
    }
}

/// Probed truth, minus what the field has failed to deliver, minus the user's demotions; then the policy
/// atoms from their parent mechanisms under seeds and overrides.
public enum CapabilityResolver {
    public static func resolve(
        probed: CapabilityProfile, config: [Capability: ConfigChoice], beliefs: ResolvedBeliefs
    ) -> (profile: CapabilityProfile, report: CapabilityReport) {
        var learned = beliefs.broken
        if beliefs.readModel.answer == .untrusted { learned.insert(.readCaret) }
        return resolve(probed: probed, config: config, learned: learned)
    }

    public static func resolve(
        probed: CapabilityProfile, config: [Capability: ConfigChoice], learned: Set<Capability>
    ) -> (profile: CapabilityProfile, report: CapabilityReport) {
        var entries: [Capability: CapabilityReport.Entry] = [:]
        // An explicit `on` undoes evidence exactly the way it un-seeds curation.
        for capability in Capability.allCases where capability.species == .mechanism {
            let choice = config[capability]?.override
            if probed.has(capability), choice == .off {
                entries[capability] = CapabilityReport.Entry(status: .unavailable, source: .user)
            } else if probed.has(capability), learned.contains(capability), choice != .on {
                entries[capability] = CapabilityReport.Entry(status: .unavailable, source: .learned)
            } else {
                entries[capability] = CapabilityReport.Entry(status: probed.has(capability) ? .available : .unavailable, source: .probed)
            }
        }
        // `.on` un-seeds curation only: a missing mechanism stays missing, and a parentless policy is ungated.
        let unavailable = CapabilityReport.Entry(status: .unavailable, source: .probed)
        for capability in Capability.allCases where capability.species == .policy {
            let mechanism = capability.parent.map { entries[$0] ?? unavailable }
            let choice = config[capability] ?? ConfigChoice()
            if let mechanism, mechanism.status != .available {
                entries[capability] = CapabilityReport.Entry(status: .unavailable, source: mechanism.source)
            } else if choice.override == .off {
                entries[capability] = CapabilityReport.Entry(status: .unavailable, source: .user)
            } else if choice.seededOff, choice.override != .on {
                entries[capability] = CapabilityReport.Entry(status: .unavailable, source: .seeded)
            } else {
                entries[capability] = CapabilityReport.Entry(status: .available, source: choice.override == .on ? .user : .probed)
            }
        }
        return (CapabilityProfile(statuses: entries.mapValues(\.status)), CapabilityReport(entries: entries))
    }
}
