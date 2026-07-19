import CoreGraphics
import LoomCore

/// Translates a tapped `KeyEvent` into the token notation the engine speaks
/// (`"a"`, `"<C-r>"`, `"<C-[>"`). One notation, two layers: Core produces
/// events, this produces engine tokens; keycodes never cross the boundary.
public enum KeyNotation {
    /// nil means "not vim's key" — the controller passes it through
    /// untouched (⌘-chords belong to the system, dead keys produce nothing).
    public static func token(for event: KeyEvent) -> String? {
        guard event.kind == .keyDown else { return nil }
        if event.mods.contains(.command) { return nil }

        switch event.keyCode {
        // Physical Esc is NEVER vim's key: the app keeps its cancels,
        // dialogs, and TUI escapes. ⌃[ (below) is the engage/cancel key.
        case 53: return nil
        case 36, 76: return "<CR>"
        case 51: return "<BS>"
        case 117: return "<Del>"
        case 123: return "<Left>"
        case 124: return "<Right>"
        case 125: return "<Down>"
        case 126: return "<Up>"
        case 48: return "\t"
        default: break
        }

        guard let scalar = event.characters.unicodeScalars.first else { return nil }

        if event.mods.contains(.control) {
            // Control chords arrive as control characters: ⌃r is U+0012.
            if scalar.value == 0x1B { return "<C-[>" }   // the engage key
            if (1...26).contains(scalar.value), let letter = UnicodeScalar(scalar.value + 96) {
                return "<C-\(Character(letter))>"
            }
            return nil
        }

        if scalar.value < 0x20 { return nil }
        return event.characters
    }
}
