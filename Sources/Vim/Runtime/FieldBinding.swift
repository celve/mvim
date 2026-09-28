import ApplicationServices
import LoomCore

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
    }

    public static func snapshot(
        of element: AXUIElement,
        capabilities: CapabilityProfile,
        anchor: Int?,
        cursor: Range<Int>?,
        chromium: Bool = false,
        model: ReadModel = ReadModel(answer: .value),
        sampling: OffsetsSampling = OffsetsSampling(),
        known: EmptyParagraphs.Memo? = nil
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
        let marked = readsMarkers || sampled ? AX.markedSelection(of: element, selected: reads.textMarkerRange(5)) : nil
        let side = marked.map { sides(of: $0) }
        let markerReading = marked.flatMap { marked in
            side.map { markerReads(of: element, text: reads.string(0), marked: marked, side: $0) }
        }
        var fieldReads = FieldReads(
            text: reads.string(0),
            plain: plain,
            selectedText: reads.string(4),
            markers: markerReading?.reads
        )
        let observed = Learning.observe(fieldReads, before: current, source: source, newEngine: model.newEngine)
        let answer = observed.after
        // Only the snapshot reads the empty paragraph, which costs four more round trips.
        if answer == .textContent, let marked, fieldReads.markers?.breaks != nil {
            fieldReads.markers?.emptyParagraph = marked.inEmptyParagraph
        }
        var interpreted = fieldReads.interpreted(under: answer)
        if !capabilities.has(.readCaret) {
            interpreted = (nil, answer == .textContent ? ParagraphBreaks() : nil, false, false)
        }
        var text = capabilities.has(.readText) ? fieldReads.text : nil
        let length = capabilities.has(.readLength) ? reads.int(2) : nil
        var selection = interpreted.selection
        var breaks = interpreted.breaks
        var emptyParagraph = interpreted.emptyParagraph
        var gap = 0
        var holdsEmptyParagraphs = false
        var memo: EmptyParagraphs.Memo?
        // After the learner, which judges the reads as the field gave them.
        if answer == .textContent, let value = text, let aligned = breaks, let marked, let side,
           let raw = markerReading?.raw, case let plainMarkers = MarkerText.plain(raw), plainMarkers.utf16.contains(10) {
            memo = known.flatMap { $0.holds(value: value, markers: raw, blocks: blocks) ? $0 : nil }
                ?? EmptyParagraphs.Memo(
                    value: value, markers: raw, blocks: blocks,
                    found: AX.emptyParagraphs(of: element, markers: raw, budget: EmptyParagraphs.readBudget)?.found
                )
            if let found = memo?.found,
               let restored = EmptyParagraphs.restore(value: value, fieldText: plainMarkers, aligned: aligned, found: found),
               let resolved = restored.breaks.valueRange(marked.range, side: side),
               resolved.upperBound <= restored.text.utf16.count {
                text = restored.text
                breaks = restored.breaks
                selection = resolved
                gap = restored.gap
                holdsEmptyParagraphs = !found.isEmpty
                let model = TextModel(restored.text)
                // A caret on an empty line is in a paragraph the model already holds.
                let onEmptyLine = resolved.isEmpty && model.lineStart(of: resolved.lowerBound) == model.lineEnd(of: resolved.lowerBound)
                emptyParagraph = emptyParagraph && !onEmptyLine
            }
        }
        // The drawn cursor counts only while it still IS the selection;
        // otherwise the selection is the user's.
        let stampedCursor = (cursor != nil && !cursor!.isEmpty && cursor == selection) ? cursor : nil
        let snapshot = FieldSnapshot(
            capabilities: capabilities,
            text: text,
            selection: selection,
            length: length,
            anchor: anchor,
            cursor: stampedCursor,
            webContent: reads.string(3) != nil,
            breaks: breaks,
            caretInEmptyParagraph: emptyParagraph,
            textlessLeaves: interpreted.textlessLeaves,
            valueGap: gap,
            holdsEmptyParagraphs: holdsEmptyParagraphs
        )
        return Reading(
            snapshot: snapshot, observed: observed, sampled: sampled, markers: marked != nil, reads: fieldReads, emptyParagraphs: memo
        )
    }

    /// Chromium's `<textarea>` and `<input>` have no children; a failed count takes the marker read.
    static func hasParagraphs(_ element: AXUIElement) -> Bool {
        AX.childCount(of: element).map { $0 > 0 } ?? true
    }

    /// Also hands back the raw marker text, which empty-paragraph discovery starts from.
    private static func markerReads(
        of element: AXUIElement, text: String?, marked: AX.MarkedSelection, side: (ParagraphBreaks.End) -> ParagraphBreaks.Side?
    ) -> (reads: MarkerReads, raw: String?) {
        // A U+FFFC in `AXValue` is the page's own text, which the plain marker offsets drop as a placeholder.
        guard let text, !text.utf16.contains(0xFFFC) else { return (MarkerReads(breaks: nil, value: nil), nil) }
        var breaks = ParagraphBreaks()
        var textlessLeaves = false
        var raw: String?
        if text.contains("\n") {
            guard let markers = AX.markerText(of: element),
                  let aligned = ParagraphBreaks(value: text, fieldText: MarkerText.plain(markers)) else {
                return (MarkerReads(breaks: nil, value: nil), nil)
            }
            breaks = aligned
            textlessLeaves = markers.utf16.contains(0xFFFC)
            raw = markers
        }
        return (MarkerReads(breaks: breaks, value: breaks.valueRange(marked.range, side: side), textlessLeaves: textlessLeaves), raw)
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
