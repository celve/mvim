import ApplicationServices
import LoomCore

/// Probes what a focused field can do. Trial reads *prove* the read
/// capabilities; settable flags *claim* the writes — and the claims are
/// corrected by `LearnedPriors`, the lazy write probe's result cache
/// (real commands are the probe; settle verdicts are its readings).
public enum FieldProber {
    /// Three IPCs, not six: the four read trials ride one batch, and the two
    /// settable flags use a different API (`AXUIElementIsAttributeSettable`)
    /// that has no multi-attribute form.
    public static func probe(_ element: AXUIElement) -> CapabilityProfile {
        var available: Set<Capability> = []
        let reads = AX.attributes([
            kAXValueAttribute,               // 0
            kAXSelectedTextRangeAttribute,   // 1
            kAXNumberOfCharactersAttribute,  // 2
            kAXSelectedTextAttribute,        // 3
        ], of: element)
        if reads.string(0) != nil { available.insert(.readText) }
        if reads.range(1) != nil { available.insert(.readCaret) }
        if reads.int(2) != nil { available.insert(.readLength) }
        if reads.string(3) != nil { available.insert(.readSelectedText) }
        if AX.rangeSettable(element) { available.insert(.writeSelection) }
        if AX.isInsertable(element) { available.insert(.insertText) }
        return CapabilityProfile(available: available)
    }

    /// The full resolution for one binding: probed truth, minus what the field
    /// has demonstrably failed to deliver, minus the user's demotions — then the
    /// policy atoms derived from their parent mechanisms under `CapabilityConfig`
    /// seeds and overrides. The profile is what the planner consumes; the report
    /// is the menu's why.
    ///
    /// The `surface` is the whole point: config is keyed by the text engine
    /// behind the field, not by the app hosting it, so a browser's own search
    /// box and an `<input>` in the page it is showing resolve independently
    /// even though both report `AXTextField`. `appVersion` keys the learner's
    /// TTL — an app update re-opens every trial it had concluded.
    public static func resolve(
        _ element: AXUIElement, surface: Surface, appVersion: String?
    ) -> (profile: CapabilityProfile, report: CapabilityReport) {
        let probed = probe(element)
        var statuses: [Capability: CapabilityStatus] = [:]
        var entries: [Capability: CapabilityReport.Entry] = [:]

        // One store read for all nine atoms — the ladder is the same for each.
        let config = CapabilityConfig.resolveAll(
            surface, capabilities: Capability.allCases.map(\.rawValue)
        )
        func choice(_ capability: Capability) -> CapabilityConfig.Override? {
            config[capability.rawValue]?.override
        }
        // Only the write mechanisms are ever in here: they are the only claims
        // a settle can contradict.
        let learned = LearnedPriors.demoted(rungs: surface.rungs, version: appVersion)

        // Mechanism atoms: probe truth wins upward, and two things subtract from
        // it — evidence (the field failed to deliver) and the user's `off`. An
        // explicit `on` un-does the evidence exactly the way it un-seeds
        // curation, so a decision always outranks an inference.
        for capability in Capability.allCases where capability.species == .mechanism {
            let entry: CapabilityReport.Entry
            if probed.has(capability), choice(capability) == .off {
                entry = CapabilityReport.Entry(status: .unavailable, source: .user)
            } else if probed.has(capability),
                      learned.contains(capability.rawValue),
                      choice(capability) != .on {
                entry = CapabilityReport.Entry(status: .unavailable, source: .learned)
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
            let resolved = config[capability.rawValue] ?? .auto
            let userChoice = resolved.override
            // Seeds and the user's choice come from two separate ladder walks,
            // so a seed at a narrow rung and an `.on` at a wide one are both
            // visible here — and the precedence below is the one this table
            // always had, unchanged.
            let seeded = resolved.isSeededOff
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
        /// The field's own name, when it has one — the narrowest rung capability
        /// config can be keyed at. Rides the gate's existing round trip.
        public let identifier: String?
        /// Web content, so worth the parent walk that finds its origin. Rides
        /// the same round trip; native fields skip the walk entirely.
        public let isWebElement: Bool
        /// Chromium's, whose rich-text fields need their caret read another way.
        public let isChromium: Bool
        public var engageable: Bool { isTextual && !isSecure && isEnabled }
    }

    /// Whether mvim should engage at all. Conservative on purpose: only
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
            role: attributes.role,
            identifier: attributes.identifier,
            isWebElement: attributes.isWebElement,
            isChromium: attributes.isChromium
        )
    }
}

/// Reads the volatile half of a `FieldSnapshot`, fresh per command.
public enum Snapshotter {
    public static func snapshot(
        of element: AXUIElement,
        capabilities: CapabilityProfile,
        anchor: Int?,
        cursor: Range<Int>?,
        chromium: Bool = false
    ) -> FieldSnapshot {
        let paragraphs = chromium && hasParagraphs(element)
        // One IPC for the whole volatile half. The capabilities gate which
        // slots are *used*, not which are fetched — a batch costs the same
        // round trip either way, and branching the attribute list per profile
        // would buy nothing.
        var names = [
            kAXValueAttribute,               // 0
            kAXSelectedTextRangeAttribute,   // 1
            kAXNumberOfCharactersAttribute,  // 2
        ]
        if paragraphs { names.append(kAXSelectedTextMarkerRangeAttribute) }   // 3
        let reads = AX.attributes(names, of: element)
        let text = capabilities.has(.readText) ? reads.string(0) : nil
        var selection: Range<Int>?
        if capabilities.has(.readCaret), let range = reads.range(1) {
            selection = range.location..<(range.location + range.length)
        }
        var breaks: ParagraphBreaks?
        if paragraphs {
            breaks = ParagraphBreaks()
            if capabilities.has(.readCaret) {
                (selection, breaks) = paragraphRead(of: element, text: text, marked: reads.textMarkerRange(3))
            }
        }
        let length = capabilities.has(.readLength) ? reads.int(2) : nil
        // The drawn cursor counts only while it still IS the selection;
        // otherwise the selection is the user's.
        let stampedCursor = (cursor != nil && !cursor!.isEmpty && cursor == selection) ? cursor : nil
        return FieldSnapshot(
            capabilities: capabilities,
            text: text,
            selection: selection,
            length: length,
            anchor: anchor,
            cursor: stampedCursor,
            breaks: breaks
        )
    }

    /// Chromium's contenteditables expose children and read in text content; its `<textarea>` and `<input>` do neither.
    static func hasParagraphs(_ element: AXUIElement) -> Bool {
        (AX.childCount(of: element) ?? 0) > 0
    }

    /// The selection in `AXValue` offsets, nil when it cannot be placed there, and the breaks it was placed by.
    ///
    /// Only the markers count: the plain read may name the block's start for a caret between elements.
    private static func paragraphRead(
        of element: AXUIElement, text: String?, marked selected: AnyObject?
    ) -> (selection: Range<Int>?, breaks: ParagraphBreaks) {
        guard let text, let marked = AX.markedSelection(of: element, selected: selected) else {
            return (nil, ParagraphBreaks())
        }
        let field = marked.range
        var breaks = ParagraphBreaks()
        if text.contains("\n") {
            guard let aligned = AX.textContent(of: element).flatMap({ ParagraphBreaks(value: text, fieldText: $0) }) else {
                return (nil, breaks)
            }
            breaks = aligned
        }
        return (breaks.valueRange(field) { end in marked.startsParagraph(upper: end == .upper) }, breaks)
    }
}
