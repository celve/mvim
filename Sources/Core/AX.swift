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
