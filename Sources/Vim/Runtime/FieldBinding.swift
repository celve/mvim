import ApplicationServices
import LoomCore

/// Why each atom of one binding resolved the way it did — the menu's badge
/// vocabulary. Runtime-only: provenance never enters the snapshot or the
/// planner, which consume the bare `CapabilityProfile`.
public struct CapabilityReport: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// The AX trial — or, for `drawCursor`, its writeSelection mechanism.
        case probed
        /// A shipped `CapabilityConfig` seed.
        case seeded
        /// The user's menu override.
        case user
    }

    public struct Entry: Equatable, Sendable {
        public let status: CapabilityStatus
        public let source: Source

        public init(status: CapabilityStatus, source: Source) {
            self.status = status
            self.source = source
        }
    }

    public var entries: [Capability: Entry]

    public init(entries: [Capability: Entry] = [:]) {
        self.entries = entries
    }
}

/// Probes what a focused field can do. Trial reads *prove* the read
/// capabilities; settable flags *claim* the writes — and the claims are
/// corrected by `LearnedPriors`, the lazy write probe's result cache
/// (real commands are the probe; settle verdicts are its readings).
public enum FieldProber {
    public static func probe(_ element: AXUIElement) -> CapabilityProfile {
        var available: Set<Capability> = []
        if AX.value(of: element) != nil { available.insert(.readText) }
        if AX.selectedRange(of: element) != nil { available.insert(.readCaret) }
        if AX.length(of: element) != nil { available.insert(.readLength) }
        if AX.selectedText(of: element) != nil { available.insert(.readSelectedText) }
        if AX.rangeSettable(element) { available.insert(.writeSelection) }
        if AX.isInsertable(element) { available.insert(.insertText) }
        return CapabilityProfile(available: available)
    }

    /// The full resolution for one binding: probed truth minus the user's
    /// demotions, then the policy atoms derived from their parent mechanisms
    /// under `CapabilityConfig` seeds and overrides. (The learner's
    /// committed demotions subtract in the mechanism loop when that wiring
    /// lands.) The profile is what the planner consumes; the report is the
    /// menu's why.
    public static func resolve(
        _ element: AXUIElement, bundleID: String?
    ) -> (profile: CapabilityProfile, report: CapabilityReport) {
        let probed = probe(element)
        var statuses: [Capability: CapabilityStatus] = [:]
        var entries: [Capability: CapabilityReport.Entry] = [:]

        func choice(_ capability: Capability) -> CapabilityConfig.Override? {
            guard let bundleID else { return nil }
            return CapabilityConfig.userOverride(for: bundleID, capability: capability.rawValue)
        }

        // Mechanism atoms: an override may only demote — probe truth wins
        // upward, the user's off wins downward.
        for capability in Capability.allCases where capability.species == .mechanism {
            let entry: CapabilityReport.Entry
            if probed.has(capability), choice(capability) == .off {
                entry = CapabilityReport.Entry(status: .unavailable, source: .user)
            } else {
                entry = CapabilityReport.Entry(
                    status: probed.has(capability) ? .available : .unavailable,
                    source: .probed
                )
            }
            statuses[capability] = entry.status
            entries[capability] = entry
        }

        // Policy atoms: their parent mechanism, seed- and user-gated. `.on`
        // un-seeds curation only — a missing mechanism stays missing. The
        // mechanism loop above has already run, so every parent is resolved;
        // this stands in only if that ever stops being true.
        let unavailableEntry = CapabilityReport.Entry(status: .unavailable, source: .probed)
        for capability in Capability.allCases where capability.species == .policy {
            // A parentless policy is ungated — nothing about the field can
            // moot it, so it answers to seeds and the user alone. Absent
            // this, `mechanism` is nil and the check below would deny it
            // permanently.
            let mechanism = capability.parent.map { entries[$0] ?? unavailableEntry }
            let userChoice = choice(capability)
            let seeded = bundleID.map {
                CapabilityConfig.seededOff(bundleID: $0, capability: capability.rawValue)
            } ?? false
            let entry: CapabilityReport.Entry
            if let mechanism, mechanism.status != .available {
                entry = CapabilityReport.Entry(status: .unavailable, source: mechanism.source)
            } else if userChoice == .off {
                entry = CapabilityReport.Entry(status: .unavailable, source: .user)
            } else if seeded, userChoice != .on {
                entry = CapabilityReport.Entry(status: .unavailable, source: .seeded)
            } else {
                entry = CapabilityReport.Entry(status: .available, source: userChoice == .on ? .user : .probed)
            }
            statuses[capability] = entry.status
            entries[capability] = entry
        }

        return (CapabilityProfile(statuses: statuses), CapabilityReport(entries: entries))
    }

    /// The engage verdict for one element, from a single AX round trip.
    /// `role` rides along for the learner's binding identity.
    public struct FieldGate {
        public let isTextual: Bool
        public let isSecure: Bool
        public let isEnabled: Bool
        public let role: String?
        public var engageable: Bool { isTextual && !isSecure && isEnabled }
    }

    /// Whether Norm should engage at all. Conservative on purpose: only
    /// concrete text roles — engaging in a web area or list view would eat
    /// navigation keys the app owns. Secure fields are caught by role OR
    /// subrole: `NSSecureTextField` keeps role `AXTextField` and reveals
    /// itself only in the subrole.
    public static func gate(_ element: AXUIElement) -> FieldGate {
        let attributes = AX.gateAttributes(of: element)
        let textual: Bool
        switch attributes.role {
        case "AXTextField", "AXTextArea", "AXComboBox": textual = true
        default: textual = false
        }
        let secure = attributes.role == "AXSecureTextField"
            || attributes.subrole == "AXSecureTextField"
        return FieldGate(
            isTextual: textual,
            isSecure: secure,
            isEnabled: attributes.enabled,
            role: attributes.role
        )
    }
}

/// Reads the volatile half of a `FieldSnapshot`, fresh per command.
public enum Snapshotter {
    public static func snapshot(
        of element: AXUIElement,
        capabilities: CapabilityProfile,
        anchor: Int?,
        cursor: Range<Int>?
    ) -> FieldSnapshot {
        let text = capabilities.has(.readText) ? AX.value(of: element) : nil
        var selection: Range<Int>?
        if capabilities.has(.readCaret), let range = AX.selectedRange(of: element) {
            selection = range.location..<(range.location + range.length)
        }
        let length = capabilities.has(.readLength) ? AX.length(of: element) : nil
        // The drawn cursor counts only while it still IS the selection;
        // otherwise the selection is the user's.
        let stampedCursor = (cursor != nil && !cursor!.isEmpty && cursor == selection) ? cursor : nil
        return FieldSnapshot(
            capabilities: capabilities,
            text: text,
            selection: selection,
            length: length,
            anchor: anchor,
            cursor: stampedCursor
        )
    }
}
