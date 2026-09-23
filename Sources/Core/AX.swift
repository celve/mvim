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
            isWebElement: domIdentifier != nil
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

        /// `AXURL` answers an `NSURL`, not a `String` — `string(_:)` is an
        /// unguarded `as? String` and would silently return nil for it.
        public func url(_ index: Int) -> String? {
            (slot(index) as? NSURL)?.absoluteString
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
            guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
                  let value = ref else { return NSNull() }
            return value
        })
    }

    /// The URL of the web area enclosing `element`, or nil when there is none
    /// — i.e. when the field is native chrome rather than page content.
    ///
    /// The one question `AXRole` cannot answer: a browser's own search box and
    /// an `<input>` in the page it is showing are both `AXTextField`, and only
    /// their ancestry tells them apart.
    ///
    /// **Round trips are the whole design constraint here.** Every AX read is
    /// a synchronous Mach call bounded by `setGlobalMessagingTimeout`, so an
    /// unbounded walk is a hang on the tap thread. Three bounds:
    ///
    /// - one batched read per hop (role, parent, URL together), so finding the
    ///   web area costs no extra call to then read its URL;
    /// - termination on `AXWindow` / `AXApplication`, which a native field
    ///   reaches in a few hops — nothing above a window can be a web area;
    /// - a hard `maxHops` backstop for hosts that answer neither.
    ///
    /// The caller gates this on `GateAttributes.isWebElement`, so a native
    /// field never walks. The cap is a logical-depth backstop, not a time
    /// budget: the real bound is the per-hop messaging timeout, and a hop that
    /// times out returns no parent and stops the walk. It is set well above
    /// observed depth — Dia sat a GitHub `<input>` seven hops under its web
    /// area — because a field nested in a modal or a sub-frame goes deeper, and
    /// overshooting the cap silently costs the site scoping.
    public static func enclosingWebURL(of element: AXUIElement, maxHops: Int = 16) -> String? {
        var current = element
        for _ in 0..<maxHops {
            // Exactly one round trip per level: role and URL answer "is this
            // the web area, and what is it showing?", parent carries the walk.
            // The focused element itself is a text field, never a web area, so
            // the first iteration's role check costs nothing it would not have
            // paid anyway to reach the parent.
            let reads = attributes([
                kAXRoleAttribute,    // 0
                "AXURL",             // 1
                kAXParentAttribute,  // 2
            ], of: current)
            switch reads.string(0) {
            case "AXWebArea":
                return reads.url(1)
            // Nothing above a window is web content; stop before paying for the
            // app element and the system-wide root.
            case "AXWindow", "AXApplication":
                return nil
            default:
                break
            }
            guard let parent = reads.element(2) else { return nil }
            current = parent
        }
        return nil
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
