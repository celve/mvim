import ApplicationServices
import AppKit
import CoreGraphics

/// Thin, honest wrappers over the macOS Accessibility API — Norm's copy of
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
    public static func selectedRange(of element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let value = ref else { return nil }
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
    }

    public static func gateAttributes(of element: AXUIElement) -> GateAttributes {
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXEnabledAttribute] as CFArray
        var values: CFArray?
        // Without .stopOnError, failed slots come back as AXValue error
        // markers; the casts turn them into nil → the per-attribute defaults.
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(), &values) == .success,
              let list = values as? [AnyObject], list.count == 3 else {
            return GateAttributes(role: nil, subrole: nil, enabled: true)
        }
        return GateAttributes(
            role: list[0] as? String,
            subrole: list[1] as? String,
            enabled: list[2] as? Bool ?? true
        )
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
