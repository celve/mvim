import ApplicationServices
import AppKit
import CoreGraphics

/// Thin, honest wrappers over the macOS Accessibility API — mvim's copy of
/// the shared Loom substrate, trimmed to the vim probe/read/write surface.
public enum AX {
    @discardableResult
    public static func ensureTrusted(prompt: Bool = true) -> Bool {
        if AXIsProcessTrusted() { return true }
        guard prompt else { return false }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Every AX read is a synchronous Mach call serviced by the target app's
    /// main thread; the system default lets one busy app hang us ~6s per
    /// call. Set on the system-wide element this bounds every call the
    /// process makes. Call once at startup.
    public static func setGlobalMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    /// The focused UI element, resolved overlay-aware: if a non-activating
    /// accessory panel (Raycast/Spotlight) is frontmost and differs from the
    /// system-wide focus, prefer it. Preserved from the validated Loom
    /// prototype.
    public static func focusedElement() -> AXUIElement? {
        let systemwide = AXUIElementCreateSystemWide()
        let sysFocused = copyElement(systemwide, kAXFocusedUIElementAttribute)
        let sysPid = sysFocused.flatMap { pid(of: $0) }

        if let sysFocused, let sysPid,
           sysPid == NSWorkspace.shared.frontmostApplication?.processIdentifier {
            return sysFocused
        }
        if let top = topmostWindowOwnerPID(), top != sysPid,
           NSRunningApplication(processIdentifier: top)?.activationPolicy == .accessory {
            let appElement = AXUIElementCreateApplication(top)
            if let focused = copyElement(appElement, kAXFocusedUIElementAttribute),
               pid(of: focused) == top {
                return focused
            }
        }
        if let sysFocused { return sysFocused }
        if let app = NSWorkspace.shared.frontmostApplication {
            return copyElement(AXUIElementCreateApplication(app.processIdentifier),
                               kAXFocusedUIElementAttribute)
        }
        return nil
    }

    // MARK: - Reads

    public static func value(of element: AXUIElement) -> String? {
        copyString(element, kAXValueAttribute)
    }

    public static func length(of element: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &ref) == .success,
              let length = ref as? Int else { return nil }
        return length
    }

    /// The current selection range (caret = `location` when `length == 0`).
    /// UTF-16 units.
    ///
    /// The type-ID check precedes the cast — the `copyElement` pattern. An
    /// app answering this attribute with anything that is not an `AXValue`
    /// would otherwise trap in the AX read path.
    public static func selectedRange(of element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue((value as! AXValue), .cfRange, &range) ? range : nil
    }

    public static func selectedText(of element: AXUIElement) -> String? {
        copyString(element, kAXSelectedTextAttribute)
    }

    public static func role(of element: AXUIElement) -> String? {
        copyString(element, kAXRoleAttribute)
    }

    /// A password / secure text field — never drive these.
    public static func isSecure(_ element: AXUIElement) -> Bool {
        role(of: element) == "AXSecureTextField"
    }

    /// `kAXEnabled`, defaulting to true when absent (most editable fields
    /// don't expose it); a present `false` means read-only.
    public static func isEnabled(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &ref) == .success,
              let enabled = ref as? Bool else { return true }
        return enabled
    }

    /// Everything the engage gate needs about an element, in ONE round trip.
    /// Secure fields hide behind the *subrole* (`NSSecureTextField` keeps
    /// role `AXTextField`), so both are fetched.
    public struct GateAttributes {
        public let role: String?
        public let subrole: String?
        public let enabled: Bool

        /// A name for this one field, when the app or page supplies one:
        /// `AXDOMIdentifier` in web content, `AXIdentifier` natively. Lets
        /// capability config address a single field rather than every field of
        /// its role. Empty strings are nil — a web element with no `id`
        /// answers `""`, which names nothing.
        public let identifier: String?

        /// Whether this element lives in web content, so only web fields pay
        /// the parent walk that finds their origin.
        ///
        /// The marker is `AXDOMIdentifier`'s *presence*, distinct from its
        /// value: a native field does not list the attribute at all, while a
        /// web input with no `id` lists it holding `""`. Confirmed against Dia
        /// — its native command bar omits it; a GitHub `<input>` lists it, its
        /// enclosing web area lists it empty. `""` therefore reads as web, and
        /// the batch resolves an absent attribute to nil and a present-empty
        /// one to `""`, which is exactly the distinction.
        public let isWebElement: Bool

        /// Chromium's rich-text fields select in text-content offsets, not `AXValue`'s.
        public let isChromium: Bool
    }

    public static func gateAttributes(of element: AXUIElement) -> GateAttributes {
        // Through the batch helper rather than a bare multi-read, so this
        // inherits the serial fallback — Electron hosts are exactly the case it
        // exists for, and they are exactly the hosts that carry web content.
        let reads = attributes([
            kAXRoleAttribute,     // 0
            kAXSubroleAttribute,  // 1
            kAXEnabledAttribute,  // 2
            "AXDOMIdentifier",    // 3
            "AXIdentifier",       // 4
            chromiumNodeIDAttribute,  // 5
        ], of: element)
        let domIdentifier = reads.string(3)
        let identifier = [domIdentifier, reads.string(4)]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        return GateAttributes(
            role: reads.string(0),
            subrole: reads.string(1),
            // Absent or unreadable reads permissively as enabled, as before:
            // a field we cannot ask about should not be silently un-engageable.
            enabled: reads.bool(2) ?? true,
            identifier: identifier,
            // Presence, not non-emptiness: `""` is a web input without an id.
            isWebElement: domIdentifier != nil,
            isChromium: reads.string(5) != nil
        )
    }

    // MARK: - Batched reads

    /// Several attributes from ONE round trip. Positional: `index` addresses
    /// `names[index]` as passed to `attributes(_:of:)`.
    ///
    /// Failed slots arrive as `AXValue` error markers (no `.stopOnError`) and
    /// the typed accessors resolve them to nil — the same verdict a failed
    /// serial read gives, so per-attribute semantics are unchanged and
    /// `!= nil` stays a valid capability test.
    public struct AttributeBatch {
        private let slots: [AnyObject]

        fileprivate init(slots: [AnyObject]) { self.slots = slots }

        public func string(_ index: Int) -> String? { slot(index) as? String }

        public func int(_ index: Int) -> Int? { slot(index) as? Int }

        public func bool(_ index: Int) -> Bool? { slot(index) as? Bool }

        /// Type-ID checked before the cast — the `copyElement` pattern. Error
        /// markers *are* `AXValue`s, so the `AXValueGetValue` result is what
        /// rejects them; the type check guards the case where an app answers
        /// with something that is not an `AXValue` at all, which would trap.
        public func range(_ index: Int) -> CFRange? {
            guard let slot = slot(index), CFGetTypeID(slot) == AXValueGetTypeID() else { return nil }
            var range = CFRange()
            return AXValueGetValue((slot as! AXValue), .cfRange, &range) ? range : nil
        }

        /// Type-ID checked before the cast, for the same reason `range(_:)` is:
        /// an app answering with a non-element would trap the force-cast.
        public func element(_ index: Int) -> AXUIElement? {
            guard let slot = slot(index), CFGetTypeID(slot) == AXUIElementGetTypeID() else { return nil }
            return (slot as! AXUIElement)
        }

        public func elements(_ index: Int) -> [AXUIElement]? { slot(index) as? [AXUIElement] }

        public func textMarkerRange(_ index: Int) -> AnyObject? {
            guard let slot = slot(index), CFGetTypeID(slot) == AXTextMarkerRangeGetTypeID() else { return nil }
            return slot
        }

        /// `AXURL` answers an `NSURL`, which `string(_:)` would read as nil.
        public func url(_ index: Int) -> URL? {
            (slot(index) as? NSURL) as URL?
        }

        /// Why a slot is empty; nil for one that read.
        public func error(_ index: Int) -> AXError? {
            guard let slot = slot(index), CFGetTypeID(slot) == AXValueGetTypeID() else { return nil }
            var error = AXError.success
            return AXValueGetValue((slot as! AXValue), .axError, &error) ? error : nil
        }

        private func slot(_ index: Int) -> AnyObject? {
            index < slots.count ? slots[index] : nil
        }
    }

    /// Read `names` in one IPC, falling back to serial reads when the app
    /// cannot service a multi-read.
    ///
    /// The fallback is load-bearing, not defensive dressing. Electron and
    /// Java AX hosts implement `CopyMultipleAttributeValues` inconsistently,
    /// and a whole-call failure resolving to empty slots would tell
    /// `FieldProber` the field has no capabilities at all — demoting a fully
    /// drivable field to the blind lane for as long as the binding lives. One
    /// recovery policy here keeps every call site free of its own.
    public static func attributes(_ names: [String], of element: AXUIElement) -> AttributeBatch {
        var values: CFArray?
        if AXUIElementCopyMultipleAttributeValues(
            element, names as CFArray, AXCopyMultipleAttributeOptions(), &values
        ) == .success, let list = values as? [AnyObject], list.count == names.count {
            return AttributeBatch(slots: list)
        }
        return AttributeBatch(slots: names.map { name -> AnyObject in
            var ref: CFTypeRef?
            var error = AXUIElementCopyAttributeValue(element, name as CFString, &ref)
            // Keep the batch's error marker, so `error(_:)` works on this path too.
            guard error == .success else {
                return AXValueCreate(.axError, &error).map { $0 as AnyObject } ?? NSNull()
            }
            return ref ?? NSNull()
        })
    }

    /// Walks up from `element` to the page that names its site, one batched read per hop.
    public static func enclosingWebArea(of element: AXUIElement) -> WebAreaWalk.Result {
        WebAreaWalk.walk(from: element, clock: { ProcessInfo.processInfo.systemUptime }) { current in
            let reads = attributes([
                kAXRoleAttribute,    // 0
                "AXURL",             // 1
                kAXParentAttribute,  // 2
            ], of: current)
            return WebAreaWalk.Reading(
                role: reads.string(0),
                address: reads.url(1).map { WebAreaWalk.Address(scheme: $0.scheme, host: $0.host) },
                parent: reads.element(2),
                parentError: reads.error(2)?.rawValue
            )
        }
    }

    // MARK: - Chromium's text markers

    /// Present on every element Chromium exposes and on nothing else.
    public static let chromiumNodeIDAttribute = "ChromeAXNodeId"

    public static func childCount(of element: AXUIElement) -> Int? {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success else {
            return nil
        }
        return count
    }

    /// A Chromium field's selection in text-content offsets, read through markers that follow the real caret.
    public struct MarkedSelection {
        public let range: Range<Int>
        let element: AXUIElement
        let lower: AXTextMarker
        let upper: AXTextMarker

        public var isCollapsed: Bool { CFEqual(lower, upper) }

        /// A caret whose marker sits on a block holding nothing but a line break: an empty paragraph, which `AXValue`
        /// can leave out and read the caret beside (LIN-1559). Any failed read answers no.
        public var inEmptyParagraph: Bool {
            guard isCollapsed, let node = AX.node(at: lower, in: element), let role = AX.role(of: node),
                  role != kAXStaticTextRole,
                  let range = textMarkerRange(parameterized("AXTextMarkerRangeForUIElement", node, of: element)),
                  let text = AX.text(from: AXTextMarkerRangeCopyStartMarker(range), to: AXTextMarkerRangeCopyEndMarker(range),
                                     in: element).map(MarkerText.plain) else { return false }
            return text.isEmpty || text == "\n"
        }

        public enum NodeSide: Equatable, Sendable {
            case start
            case end
            case between
        }

        /// Where an end sits in its marker's node; nil when a read fails.
        public func side(upper isUpper: Bool) -> NodeSide? {
            let marker = isUpper ? upper : lower
            guard let index = AX.parameterized("AXIndexForTextMarker", marker, of: element) as? Int else { return nil }
            guard index > 0 else { return .start }
            guard let anchor = AX.node(at: marker, in: element),
                  let length = AX.textLength(of: anchor, in: element) else { return nil }
            return index < length ? .between : .end
        }

        /// What follows an end: typing lands past a list marker and before uneditable text.
        public enum Opening: Equatable, Sendable {
            case text
            case listMarker(length: Int)
            case uneditable
        }

        /// Nil when any read fails; `editable: false` skips the settable read.
        public func opening(upper isUpper: Bool, editable: Bool) -> Opening? {
            guard let leaf = AX.leaf(at: isUpper ? upper : lower, in: element),
                  let role = AX.role(of: leaf) else { return nil }
            if role == "AXListMarker" {
                return AX.textLength(of: leaf, in: element).map { .listMarker(length: $0) }
            }
            guard editable else { return .text }
            return AX.rangeSettability(of: leaf).map { $0 ? .text : .uneditable }
        }
    }

    public static func markedSelection(of element: AXUIElement, selected: AnyObject? = nil) -> MarkedSelection? {
        guard let selection = textMarkerRange(selected ?? copyAttribute(element, kAXSelectedTextMarkerRangeAttribute)),
              let field = fieldMarkers(of: element) else { return nil }
        let first = AXTextMarkerRangeCopyStartMarker(selection)
        let second = AXTextMarkerRangeCopyEndMarker(selection)
        guard let firstOffset = offset(of: first, from: field.start, in: element) else { return nil }
        var secondOffset = firstOffset
        if !CFEqual(first, second) {
            guard let offset = offset(of: second, from: field.start, in: element) else { return nil }
            secondOffset = offset
        }
        // A backward selection's marker range starts at its larger end.
        let forward = firstOffset <= secondOffset
        return MarkedSelection(
            range: min(firstOffset, secondOffset)..<max(firstOffset, secondOffset),
            element: element,
            lower: forward ? first : second,
            upper: forward ? second : first
        )
    }

    /// Plain offsets in `markers` of the `<br>`s of Chromium's line-starting empty blocks; nil past `budget` reads (LIN-1612).
    public static func emptyParagraphs(of element: AXUIElement, markers: String, budget: Int) -> (found: [Int], reads: Int)? {
        var discovery = EmptyParagraphDiscovery(element: element, markers: markers, budget: budget)
        return discovery.run().map { ($0, discovery.reads) }
    }

    /// The field's `AXValue` without its paragraph breaks.
    public static func textContent(of element: AXUIElement) -> String? {
        markerText(of: element).map(MarkerText.plain)
    }

    public static func markerText(of element: AXUIElement) -> String? {
        guard let field = fieldMarkers(of: element) else { return nil }
        return text(from: field.start, to: AXTextMarkerRangeCopyEndMarker(field.range), in: element)
    }

    /// The leaf after a marker, which may be anchored on a container such as a list.
    private static func leaf(at marker: AXTextMarker, in field: AXUIElement) -> AXUIElement? {
        guard var node = node(at: marker, in: field),
              var offset = parameterized("AXIndexForTextMarker", marker, of: field) as? Int else { return nil }
        for _ in 0..<16 {
            guard let children = children(of: node) else { return nil }
            guard !children.isEmpty else { return node }
            guard let start = textStart(of: node, in: field) else { return nil }
            // Children run in text order; find the last one starting at or before the offset.
            var low = 0
            var high = children.count - 1
            var holder: (index: Int, start: Int)?
            while low <= high {
                let middle = (low + high) / 2
                guard let childStart = textStart(of: children[middle], in: field).flatMap({
                    plainLength(from: start, to: $0, in: field)
                }) else { return nil }
                if childStart <= offset {
                    holder = (middle, childStart)
                    low = middle + 1
                } else {
                    high = middle - 1
                }
            }
            guard let holder else { return node }
            node = children[holder.index]
            offset -= holder.start
        }
        return nil
    }

    /// Nil on a failed read, so a container is never taken for a leaf.
    private static func children(of node: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        switch AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &ref) {
        case .success: return ref as? [AXUIElement]
        case .noValue, .attributeUnsupported: return []
        default: return nil
        }
    }

    private static func textStart(of node: AXUIElement, in field: AXUIElement) -> AXTextMarker? {
        textMarkerRange(parameterized("AXTextMarkerRangeForUIElement", node, of: field)).map(AXTextMarkerRangeCopyStartMarker)
    }

    private static func node(at marker: AXTextMarker, in element: AXUIElement) -> AXUIElement? {
        guard let node = parameterized("AXUIElementForTextMarker", marker, of: element),
              CFGetTypeID(node) == AXUIElementGetTypeID() else { return nil }
        return (node as! AXUIElement)
    }

    private static func textLength(of node: AXUIElement, in element: AXUIElement) -> Int? {
        guard let range = textMarkerRange(parameterized("AXTextMarkerRangeForUIElement", node, of: element)) else {
            return nil
        }
        return plainLength(from: AXTextMarkerRangeCopyStartMarker(range), to: AXTextMarkerRangeCopyEndMarker(range), in: element)
    }

    private static func fieldMarkers(of element: AXUIElement) -> (range: AXTextMarkerRange, start: AXTextMarker)? {
        guard let range = textMarkerRange(parameterized("AXTextMarkerRangeForUIElement", element, of: element)) else {
            return nil
        }
        return (range, AXTextMarkerRangeCopyStartMarker(range))
    }

    private static func offset(of marker: AXTextMarker, from start: AXTextMarker, in element: AXUIElement) -> Int? {
        plainLength(from: start, to: marker, in: element)
    }

    /// In `AXIndexForTextMarker`'s units, which `AXLengthForTextMarkerRange` exceeds by each U+FFFC.
    private static func plainLength(from start: AXTextMarker, to end: AXTextMarker, in element: AXUIElement) -> Int? {
        text(from: start, to: end, in: element).map(MarkerText.plainLength)
    }

    /// Anchored at `end`: Chromium reads ends that compare equal from the focus on, so a later focus reads to the page's end.
    private static func text(from start: AXTextMarker, to end: AXTextMarker, in element: AXUIElement) -> String? {
        parameterized("AXStringForTextMarkerRange", AXTextMarkerRangeCreate(kCFAllocatorDefault, end, start), of: element) as? String
    }

    private static func textMarkerRange(_ value: AnyObject?) -> AXTextMarkerRange? {
        guard let value, CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
        return (value as! AXTextMarkerRange)
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref
    }

    fileprivate static func parameterized(_ attribute: String, _ parameter: AnyObject, of element: AXUIElement) -> AnyObject? {
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &ref) == .success else {
            return nil
        }
        return ref
    }

    /// Each `\n` of the marker text is a `<br>`: an empty block's, or a soft break's in a block with text.
    private struct EmptyParagraphDiscovery {
        let element: AXUIElement
        let budget: Int
        let plain: [UInt16]
        /// U+FFFCs before each raw offset: marker lengths count them, plain offsets do not.
        let objects: [Int]
        private(set) var reads = 0
        private var fieldStart: AXTextMarker?

        init(element: AXUIElement, markers: String, budget: Int) {
            self.element = element
            self.budget = budget
            let raw = Array(markers.utf16)
            plain = raw.filter { $0 != MarkerText.objectReplacement }
            var objects = [0]
            objects.reserveCapacity(raw.count + 1)
            for unit in raw { objects.append(objects[objects.count - 1] + (unit == MarkerText.objectReplacement ? 1 : 0)) }
            self.objects = objects
        }

        enum Verdict {
            case line
            /// An empty list item's paragraph, which shares its marker's line.
            case item
            case text(end: Int)
        }

        mutating func run() -> [Int]? {
            let candidates = plain.indices.filter { plain[$0] == 10 }
            guard !candidates.isEmpty else { return [] }
            guard spend(2), let field = AX.fieldMarkers(of: element), let blocks = AX.children(of: element),
                  reads + blocks.count <= budget else { return nil }
            fieldStart = field.start
            var found: [Int] = []
            for block in blocks {
                guard spend(1) else { return nil }
                let reads = AX.attributes([kAXSubroleAttribute, kAXChildrenAttribute], of: block)
                guard reads.string(0) == "AXEmptyGroup", reads.elements(1)?.isEmpty ?? true else { continue }
                guard let offset = offset(of: block, end: false) else { return nil }
                if plain.indices.contains(offset), plain[offset] == 10 { found.append(offset) }
            }
            // The rest are soft breaks or blocks nested in a quote, a table or a list.
            let known = Set(found)
            var covered = 0
            for b in candidates where b >= covered && !known.contains(b) {
                switch classify(b, in: blocks) {
                case nil: return nil
                case .line?: found.append(b)
                case .item?: break
                case .text(let end)?: covered = end
                }
            }
            return found.sorted()
        }

        /// Descends through the children holding plain offset `b`, found by binary search on their starts.
        mutating func classify(_ b: Int, in blocks: [AXUIElement]) -> Verdict? {
            var siblings = blocks
            for _ in 0..<16 {
                var low = 0
                var high = siblings.count - 1
                var hit: (index: Int, start: Int)?
                while low <= high {
                    let middle = (low + high) / 2
                    guard let start = offset(of: siblings[middle], end: false) else { return nil }
                    if start <= b {
                        hit = (middle, start)
                        low = middle + 1
                    } else {
                        high = middle - 1
                    }
                }
                guard let hit else { return .text(end: b + 1) }
                let block = siblings[hit.index]
                guard spend(1) else { return nil }
                let reads = AX.attributes([kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute], of: block)
                let children = reads.elements(2) ?? []
                if reads.string(1) == "AXEmptyGroup", children.isEmpty {
                    guard hit.start == b else { return .text(end: b + 1) }
                    guard hit.index > 0 else { return .line }
                    guard spend(1) else { return nil }
                    return AX.role(of: siblings[hit.index - 1]) == "AXListMarker" ? .item : .line
                }
                if reads.string(0) == kAXStaticTextRole || children.isEmpty {
                    guard let end = offset(of: block, end: true) else { return nil }
                    return .text(end: max(end, b + 1))
                }
                siblings = children
            }
            return nil
        }

        /// By `AXLengthForTextMarkerRange`, which moves no string, anchored at the later end as `text(from:to:)` is.
        mutating func offset(of block: AXUIElement, end: Bool) -> Int? {
            guard spend(2), let fieldStart,
                  let range = AX.textMarkerRange(AX.parameterized("AXTextMarkerRangeForUIElement", block, of: element)) else {
                return nil
            }
            let marker = end ? AXTextMarkerRangeCopyEndMarker(range) : AXTextMarkerRangeCopyStartMarker(range)
            let span = AXTextMarkerRangeCreate(kCFAllocatorDefault, marker, fieldStart)
            guard let length = AX.parameterized("AXLengthForTextMarkerRange", span, of: element) as? Int,
                  objects.indices.contains(length) else { return nil }
            return length - objects[length]
        }

        mutating func spend(_ count: Int) -> Bool {
            reads += count
            return reads <= budget
        }
    }

    // MARK: - Probes (settable flags: the write capabilities' claims)

    /// Whether the element accepts AX text insertion (`kAXSelectedText`
    /// settable). Terminals typically return false.
    public static func isInsertable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return error == .success && settable.boolValue
    }

    /// Whether the element accepts an AX caret/selection move
    /// (`kAXSelectedTextRange` settable). False for some web search fields.
    public static func rangeSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable)
        return error == .success && settable.boolValue
    }

    /// `rangeSettable` with a failed read as nil rather than false.
    public static func rangeSettability(of element: AXUIElement) -> Bool? {
        var settable: DarwinBoolean = false
        switch AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) {
        case .success: return settable.boolValue
        case .noValue, .attributeUnsupported: return false
        default: return nil
        }
    }

    // MARK: - Writes

    /// Target a span (move caret / select). Returns AXError so callers can
    /// detect rejection.
    @discardableResult
    public static func setSelectedRange(_ range: CFRange, on element: AXUIElement) -> AXError {
        var mutable = range
        guard let axValue = AXValueCreate(.cfRange, &mutable) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue)
    }

    /// Overwrite the current selection (surgical write; joins the app's
    /// native undo). NEVER set `kAXValue` — a whole-field write collapses
    /// the app's undo stack.
    @discardableResult
    public static func setSelectedText(_ text: String, on element: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
    }

    public static func ownerPID(of element: AXUIElement) -> pid_t? { pid(of: element) }

    // MARK: - helpers

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func pid(of element: AXUIElement) -> pid_t? {
        var processID: pid_t = 0
        return AXUIElementGetPid(element, &processID) == .success ? processID : nil
    }

    /// The frontmost on-screen layer-0 window owned by `pid`
    /// (`CGWindowListCopyWindowInfo` is z-ordered front→back across all
    /// displays). Bounds are global CG top-left coordinates. No Screen
    /// Recording needed: number/bounds/owner are ungated (only names are).
    public static func frontWindow(of pid: pid_t) -> (id: CGWindowID, bounds: CGRect)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in infos {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            // NSNumber → UInt32 must go through truncating; `as? CGWindowID`
            // bridging is unreliable.
            let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
            return (CGWindowID(truncating: number), bounds)
        }
        return nil
    }

    /// Whether `bounds` covers a whole display. Compared in the global CG
    /// top-left space (`CGDisplayBounds`) — never `NSScreen.frame`, which is
    /// flipped.
    public static func coversFullScreen(_ bounds: CGRect) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.contains { display in
            let frame = CGDisplayBounds(display)
            return abs(frame.minX - bounds.minX) <= 1 && abs(frame.minY - bounds.minY) <= 1
                && abs(frame.width - bounds.width) <= 1 && abs(frame.height - bounds.height) <= 1
        }
    }

    /// The window containing `element` — one AX round trip, compared with
    /// `CFEqual`.
    ///
    /// Deliberately not `frontWindow(of:)`: that answers "the frontmost
    /// window of this pid", which is a different question and lies whenever
    /// focus sits in a window that is not front (a peek modal, a second
    /// document). `kAXTopLevelUIElement` is the fallback — Electron hosts
    /// answer one attribute or the other inconsistently. Callers treat nil
    /// as "cannot tell" and fail closed.
    public static func window(of element: AXUIElement) -> AXUIElement? {
        copyElement(element, kAXWindowAttribute)
            ?? copyElement(element, kAXTopLevelUIElementAttribute)
    }

    /// Title of `pid`'s AX-focused window; nil for AX-silent or untitled
    /// apps (callers tolerate).
    public static func focusedWindowTitle(of pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        guard let window = copyElement(app, kAXFocusedWindowAttribute) else { return nil }
        return copyString(window, kAXTitleAttribute)
    }

    /// PID of the frontmost real (activatable) on-screen window, skipping
    /// our own process and Window-Server chrome.
    private static func topmostWindowOwnerPID() -> pid_t? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let selfPid = ProcessInfo.processInfo.processIdentifier
        for info in infos {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t, ownerPid != selfPid else { continue }
            guard let app = NSRunningApplication(processIdentifier: ownerPid),
                  app.activationPolicy == .regular || app.activationPolicy == .accessory else { continue }
            return ownerPid
        }
        return nil
    }
}
