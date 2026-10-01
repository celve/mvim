import ApplicationServices
import Core

/// Reads prove the read capabilities; settable flags only claim the writes, which beliefs then correct.
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
        // No read can try a key; the settle after one is its trial.
        if available.contains(.readText), available.contains(.readCaret) { available.formUnion(Capability.nativeKeys) }
        return CapabilityProfile(available: available)
    }

    /// Config and beliefs key on the field's surface, not its app: a browser's search box and a page `<input>` differ.
    public static func resolve(
        _ element: AXUIElement, surface: Surface, versions: Versions, chromium: Bool
    ) -> (profile: CapabilityProfile, report: CapabilityReport, beliefs: ResolvedBeliefs) {
        let probed = probe(element)
        let current = Beliefs.shared.current()
        if let problem = current.problem { Diag.beliefsFile(problem) }
        let contents = current.contents
        let config = CapabilityConfig.resolveAll(
            surface, capabilities: Capability.allCases.map(\.rawValue), overrides: contents.overrides
        )
        let choices = Dictionary(uniqueKeysWithValues: Capability.allCases.map { capability -> (Capability, ConfigChoice) in
            let resolution = config[capability.rawValue] ?? .auto
            let override = resolution.override.map { $0 == .on ? ConfigChoice.Override.on : .off }
            return (capability, ConfigChoice(override: override, seededOff: resolution.isSeededOff))
        })
        let beliefs = contents.store.resolve(
            rungs: surface.rungs, rung: surface.roleRung, versions: versions, chromium: chromium,
            children: Snapshotter.hasParagraphs(element), userPinsOffsets: choices[.readCaret]?.override != nil
        )
        let resolved = CapabilityResolver.resolve(probed: probed, config: choices, beliefs: beliefs)
        return (resolved.profile, resolved.report, beliefs)
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
    public struct Reading {
        public let snapshot: FieldSnapshot
        public let observed: Learning.Observation
        /// Markers read under `value` for evidence alone; `markers` says whether they answered.
        public let sampled: Bool
        public let markers: Bool
        public let reads: FieldReads
        /// This text's empty-paragraph discovery, to hand back next time; nil where none applies.
        public let emptyParagraphs: EmptyParagraphs.Memo?
        /// This text's list-marker and chip discovery, the same way.
        public let unreachable: UnreachableLines.Memo?
    }

    public static func snapshot(
        of element: AXUIElement,
        capabilities: CapabilityProfile,
        anchor: Int?,
        cursor: Range<Int>?,
        chromium: Bool = false,
        model: ReadModel = ReadModel(answer: .value),
        sampling: OffsetsSampling = OffsetsSampling(),
        known: EmptyParagraphs.Memo? = nil,
        knownUnreachable: UnreachableLines.Memo? = nil
    ) -> Reading {
        func stable(_ known: EmptyParagraphs.Memo?, _ knownUnreachable: UnreachableLines.Memo?) -> Reading {
            var reading = read(of: element, capabilities: capabilities, anchor: anchor, cursor: cursor, chromium: chromium,
                               model: model, sampling: sampling, known: known, knownUnreachable: knownUnreachable)
            for _ in 0..<2 {
                // Linear draws and removes carets beside code spans while a read runs, which leaves its parts disagreeing.
                guard reading.snapshot.breaks != nil, AX.value(of: element) != reading.reads.text else { break }
                reading = read(of: element, capabilities: capabilities, anchor: anchor, cursor: cursor, chromium: chromium,
                               model: model, sampling: sampling, known: known, knownUnreachable: knownUnreachable)
            }
            return reading
        }
        return settled(stable(known, knownUnreachable), in: element) {
            stable($0.emptyParagraphs ?? known, $0.unreachable ?? knownUnreachable)
        }
    }

    private static func read(
        of element: AXUIElement,
        capabilities: CapabilityProfile,
        anchor: Int?,
        cursor: Range<Int>?,
        chromium: Bool,
        model: ReadModel,
        sampling: OffsetsSampling,
        known: EmptyParagraphs.Memo?,
        knownUnreachable: UnreachableLines.Memo?
    ) -> Reading {
        let blocks = AX.childCount(of: element)
        let (current, source) = model.reading(chromium: chromium, children: blocks.map { $0 > 0 } ?? true)
        // Observation keeps running under `untrusted`, whose withheld caret is still read.
        let caret = capabilities.has(.readCaret) || model.learned == .untrusted
        // Under `value` only a sample fetches the marker range, once the batch shows it can tell.
        let readsMarkers = caret && current != .value
        // One IPC for the volatile half; capabilities gate which slots are used, not fetched.
        var names = [
            kAXValueAttribute,               // 0
            kAXSelectedTextRangeAttribute,   // 1
            kAXNumberOfCharactersAttribute,  // 2
            "AXDOMIdentifier",               // 3: present, even empty, only in web content (see `GateAttributes`)
            kAXSelectedTextAttribute,        // 4
        ]
        if readsMarkers { names.append(kAXSelectedTextMarkerRangeAttribute) }   // 5
        let reads = AX.attributes(names, of: element)
        let plain = reads.range(1).map { $0.location..<($0.location + $0.length) }
        let sampled = caret && current == .value && source.observes && sampling.samples(text: reads.string(0), plain: plain)
        var marked = readsMarkers || sampled ? markedSelection(of: element, selected: reads.textMarkerRange(5)) : nil
        var range = marked?.range
        // Inside a code span starting the field, the marker reads past the field's end, while the plain read is right.
        if let upper = range?.upperBound, upper > (reads.int(2) ?? .max),
           upper > (AX.markerText(of: element).map { FieldReads.withoutAttachments($0).utf16.count } ?? .max) {
            marked = nil
            range = plain
        }
        let side = marked.map { sides(of: $0) }
        var snapshotReads = FieldSnapshot.Reads(
            field: FieldReads(text: reads.string(0), plain: plain, selectedText: reads.string(4)),
            length: reads.int(2), webContent: reads.string(3) != nil, blocks: blocks, marked: range
        )
        var memo = known
        var unreachable = knownUnreachable
        func take(_ need: FieldSnapshot.Need) {
            switch need {
            case .side(let end):
                snapshotReads.sides.updateValue(side?(end), forKey: end)
            case .emptyParagraph:
                snapshotReads.inEmptyParagraph = marked?.inEmptyParagraph ?? false
            case .emptyParagraphs(let value, let markers):
                let found = EmptyParagraphDiscovery.found(in: element, markers: markers, budget: EmptyParagraphs.readBudget)?.found
                memo = EmptyParagraphs.Memo(value: value, markers: markers, blocks: blocks, found: found)
            case .unreachable(let value, let markers, let candidates):
                let found = UnreachableDiscovery.found(
                    in: element, markers: markers, candidates: candidates, budget: UnreachableLines.readBudget
                )?.found
                unreachable = UnreachableLines.Memo(value: value, markers: markers, blocks: blocks, found: found)
            }
        }
        if let range {
            let text = MarkerReads.takesText(reads.string(0)) ? AX.markerText(of: element) : nil
            let aligned = FieldSnapshot.Step.run(taking: take) {
                MarkerReads.aligning(value: reads.string(0), range: range, text: text, sides: snapshotReads.sides)
            }
            snapshotReads.field.markers = aligned.reads
            snapshotReads.markerText = aligned.text
        }
        let observed = Learning.observe(snapshotReads.field, before: current, source: source, newEngine: model.newEngine)
        let built = FieldSnapshot.Step.run(taking: take) {
            FieldSnapshot.build(
                snapshotReads, capabilities: capabilities, answer: observed.after, anchor: anchor, cursor: cursor, memo: memo,
                unreachable: unreachable
            )
        }
        return Reading(
            snapshot: built.snapshot, observed: observed, sampled: sampled, markers: marked != nil, reads: snapshotReads.field,
            emptyParagraphs: built.memo, unreachable: built.unreachable
        )
    }

    /// Chromium's `<textarea>` and `<input>` have no children; a failed count takes the marker read.
    static func hasParagraphs(_ element: AXUIElement) -> Bool {
        AX.childCount(of: element).map { $0 > 0 } ?? true
    }

    /// Each end's side, read once per end, and once for a caret, whose ends share a marker.
    private static func sides(of marked: AX.MarkedSelection) -> (ParagraphBreaks.End) -> ParagraphBreaks.Side? {
        var read: [ParagraphBreaks.End: ParagraphBreaks.Side?] = [:]
        return { end in
            let key = marked.isCollapsed ? .lower : end
            if let known = read[key] { return known }
            let side = paragraphSide(of: marked, upper: end == .upper)
            read[key] = side
            return side
        }
    }

    /// Where typing at a boundary end would land; nil when a read fails.
    static func paragraphSide(of marked: AX.MarkedSelection, upper: Bool) -> ParagraphBreaks.Side? {
        if let drawn = drawnCaret(onMarkerOf: marked, upper: upper) { return DrawnCaret.side(drawn.place) }
        switch marked.side(upper: upper) {
        case .end?: return .end
        case nil: return nil
        case let side?:
            switch marked.opening(upper: upper, editable: side == .between) {
            case .text?: return .start(skipping: 0)
            case .listMarker(let length)?: return .start(skipping: length)
            case .uneditable?: return .end
            case nil: return nil
            }
        }
    }
}
