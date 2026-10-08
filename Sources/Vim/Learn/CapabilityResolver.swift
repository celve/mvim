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

/// Probed truth minus learned failures and the user's Off; policies then follow their parent mechanisms.
public enum CapabilityResolver {
    /// `enclosed` is the probe's other answer: the field names a bigger editable field around itself.
    public static func resolve(
        probed: CapabilityProfile, enclosed: Bool = false, config: [Capability: ConfigChoice], beliefs: ResolvedBeliefs
    ) -> (profile: CapabilityProfile, report: CapabilityReport) {
        var learned = beliefs.broken
        if beliefs.readModel.answer == .untrusted { learned.insert(.readCaret) }
        return resolve(probed: probed, enclosed: enclosed, config: config, learned: learned)
    }

    public static func resolve(
        probed: CapabilityProfile, enclosed: Bool = false, config: [Capability: ConfigChoice], learned: Set<Capability>
    ) -> (profile: CapabilityProfile, report: CapabilityReport) {
        var entries: [Capability: CapabilityReport.Entry] = [:]
        // An explicit On overrules evidence as it un-seeds curation.
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
        // On un-seeds a policy and overrules the probe's enclosing field, but cannot revive a missing mechanism; a parentless policy is ungated.
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
            } else if enclosed, Capability.blockScoped.contains(capability), choice.override != .on {
                entries[capability] = CapabilityReport.Entry(status: .unavailable, source: .probed)
            } else {
                entries[capability] = CapabilityReport.Entry(status: .available, source: choice.override == .on ? .user : .probed)
            }
        }
        return (CapabilityProfile(statuses: entries.mapValues(\.status)), CapabilityReport(entries: entries))
    }
}
