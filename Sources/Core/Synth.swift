import AppKit
import CoreGraphics

/// Tags Norm's own synthesized CGEvents (via `kCGEventSourceUserData`) so the
/// consuming tap can bypass them — otherwise the engine would feed itself.
///
/// **The magic is a cross-app ABI.** Sotto tags its synthesized events with
/// the same value and both apps bypass tagged events before any handler runs;
/// never change it in one app without the other (see README).
public enum SynthTag {
    public static let magic: Int64 = 0x4C4F_4F4D   // 'LOOM'
    public static func tag(_ event: CGEvent?) { event?.setIntegerValueField(.eventSourceUserData, value: magic) }
    public static func isSelf(_ event: CGEvent) -> Bool { event.getIntegerValueField(.eventSourceUserData) == magic }
}

/// Synthesized-input primitives — the blind lane's actuator and the clipboard
/// paste fallback. Events go to the frontmost app (Norm is an accessory
/// agent). Requires Accessibility permission. Every event is tagged.
public enum Synth {
    private static let tapLocation: CGEventTapLocation = .cgSessionEventTap
    private static func source() -> CGEventSource? { CGEventSource(stateID: .combinedSessionState) }
    private static func nudge(_ seconds: Double = 0.012) { Thread.sleep(forTimeInterval: seconds) }

    /// Synthesize ⌘V (clipboard paste). Used by clipboard-insert steps.
    public static func commandV() { key(0x09, .maskCommand) }   // 0x09 = kVK_ANSI_V

    /// Post a key down+up with modifier flags (tagged).
    public static func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        let src = source()
        if let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
            down.flags = flags; SynthTag.tag(down); down.post(tap: tapLocation)
        }
        nudge()
        if let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
            up.flags = flags; SynthTag.tag(up); up.post(tap: tapLocation)
        }
        nudge()
    }

    public static func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], times count: Int) {
        for _ in 0..<max(0, count) { key(code, flags) }
    }

    /// Type arbitrary Unicode (emoji/CJK verbatim — no layout mapping), tagged.
    public static func type(_ text: String) {
        let src = source()
        let units = Array(text.utf16)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            SynthTag.tag(down); down.post(tap: tapLocation)
        }
        nudge()
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            SynthTag.tag(up); up.post(tap: tapLocation)
        }
        nudge()
    }

    /// Clipboard + ⌘V; saves/restores the prior clipboard string (best-effort).
    public static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        nudge(0.03); commandV(); nudge(0.08)
        pasteboard.clearContents(); if let saved { pasteboard.setString(saved, forType: .string) }
    }
}
