/// The gate between the hardware and the engine: which keystrokes are vim's
/// at all. Pure and keycode-aware — the one layer that is both, which is why
/// it lives here and not in `Raw/`, whose stated invariant is that keycodes
/// never reach it, nor in `Runtime/`, which `make test` cannot compile.
///
/// This is a **gate, not a translator**. Returning a token *is* the decision
/// to consume the key: `RawMonitor.feedCommand` hands back only an idle
/// Normal-mode `<Esc>`, and `RawCommand`'s parse is total, so an unrecognized
/// token becomes `.custom` → `.bell(.unsupported)` → consumed anyway. Every `nil`
/// below is a key the app keeps; every token is a promise that vim does
/// something with it.
///
/// The rule is that **modifier chords belong to the app**. ⌘ and ⌥ are never
/// vim's; ⌃ is vim's only for the three chords the engine can actually
/// execute; ⇧ is transparent on the navigation cluster. Bare Tab and bare
/// Enter deliberately stay vim's — this layer has no field-shape context, and
/// handing a bare printable key back would type into the field while Normal
/// mode is engaged, which is the one thing modality may not do.
public enum KeyNotation {
    /// The modifier state — a local projection of Core's `Mods`, because this
    /// layer is pure and `Mods` lives in LoomCore. Same move as
    /// `RawMonitor.Mode`; the runtime adapter maps between the two.
    public struct Chord: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Chord(rawValue: 1 << 0)
        public static let option  = Chord(rawValue: 1 << 1)
        public static let control = Chord(rawValue: 1 << 2)
        public static let shift   = Chord(rawValue: 1 << 3)
        public static let fn      = Chord(rawValue: 1 << 4)   // Fn / Globe
    }

    /// nil means "not vim's key" — the controller passes it through untouched
    /// and the app sees the keystroke it expects.
    ///
    /// `characters` is the tap's layout- and shift-resolved text, so non-US
    /// layouts resolve without a keycode table; `keyCode` is consulted only
    /// for keys that carry no usable character of their own.
    public static func token(
        keyCode: Int, chord: Chord, characters: String, profile: CapabilityProfile = CapabilityProfile(),
        escapeEngages: Bool = false
    ) -> String? {
        // ⌘ belongs to the system, whatever the key rides with it.
        if chord.contains(.command) { return nil }

        let scalar = characters.unicodeScalars.first

        // ⌃[ is the engage/cancel key, and it is resolved *before* the ⌥
        // rejection below on purpose: on layouts where `[` itself needs
        // Option (German ⌥5, Spanish ⌥(), ⌃[ physically IS a ⌃⌥ chord, and
        // rejecting it would leave Normal mode unreachable — the app inert.
        // The keycode route is the layout-independent one: keycode 33 is the
        // `[` key's physical position whatever glyph it prints.
        if chord.contains(.control), scalar?.value == 0x1B || keyCode == leftBracket {
            return "<C-[>"
        }

        // ⌥ belongs to the app and to the layout. It also mangles the
        // character — ⌥j resolves to "∆" — so it must be rejected before the
        // character path, never after.
        if chord.contains(.option) { return nil }

        // Physical Esc is vim's only when the user chose it; apps keep it for their cancels otherwise.
        if keyCode == escape { return escapeEngages ? "<Esc>" : nil }

        // Keys with no character identity of their own. They must be decided
        // by keycode, because macOS resolves them to control characters:
        // Home is U+0001 and every F-key is U+0010, so letting them reach the
        // ⌃-letter branch read ⌃Home as vim's <C-a> and ⌃F2 as <C-p>. Bare,
        // they passed only by the accident of being < 0x20 — made explicit
        // here so it stops depending on a coincidence.
        if foreignKeys.contains(keyCode) { return nil }

        // The navigation cluster: vim's when bare, the app's the moment ⌃
        // rides along (⌃↑ is Mission Control, ⌃⇥ the next tab). ⇧ stays
        // transparent — ⇧← is still a motion.
        //
        // `.fn` is deliberately not consulted here: macOS sets it across this
        // whole cluster even when Globe is not physically held, so branching
        // on it would kill the arrow keys.
        if let navigation = navigationTokens[keyCode] {
            return chord.contains(.control) ? nil : navigation
        }

        // Tab is the one bare key an app also owns chorded — ⌃⇥ switches
        // tabs, ⇧⇥ reverses focus. Unlike the cluster above, ⇧ is *not*
        // transparent: ⇧⇥ is a focus command that inserts nothing, so handing
        // it back cannot break modality.
        if keyCode == tab {
            return chord.isDisjoint(with: [.control, .shift]) ? "\t" : nil
        }

        guard let scalar else { return nil }

        if chord.contains(.control) {
            // Control chords arrive as control characters: ⌃r is U+0012.
            guard (1...26).contains(scalar.value),
                  let letter = UnicodeScalar(scalar.value + 96) else { return nil }
            let character = Character(letter)
            guard boundControlLetters.contains(character)
                || (profile.has(.nativeMotions) && nativeControlLetters.contains(character)) else { return nil }
            return "<C-\(character)>"
        }

        // Globe chords over a character key are macOS's own shortcuts — 🌐E
        // opens the emoji picker, 🌐F fullscreens — and they arrive with a
        // bare letter in `characters`, so the fn bit is the only thing
        // separating 🌐E from `e`.
        //
        // UNVERIFIED on real hardware: this is the file's sole `.fn` branch,
        // and it is reachable only for keys the tables above did not claim.
        // If some keyboard ever reports fn on ordinary typing, this line eats
        // all of Normal mode — the signature is "the menu bar says Normal but
        // every key types". The navigation cluster is immune by construction.
        if chord.contains(.fn) { return nil }

        if scalar.value < 0x20 { return nil }
        return characters
    }
}

// MARK: - The tables

private extension KeyNotation {
    static let tab = 48            // kVK_Tab
    static let leftBracket = 33    // kVK_ANSI_LeftBracket
    static let escape = 53         // kVK_Escape

    /// The navigation cluster, vim's when unchorded. Return and keypad Enter
    /// ride along: bare Enter stays vim's for the same reason bare Tab does —
    /// in a multi-line field handing it back would type a newline in Normal
    /// mode. Making Tab and Enter field-shape-aware is a deliberate follow-up.
    static let navigationTokens: [Int: String] = [
        123: "<Left>", 124: "<Right>", 125: "<Down>", 126: "<Up>",
        51: "<BS>",                                  // kVK_Delete
        117: "<Del>",                                // kVK_ForwardDelete
        36: "<CR>", 76: "<CR>"                       // Return, keypad Enter
    ]

    /// Keys vim never binds, bare or chorded; adding one is a fix or a no-op, never a regression.
    static let foreignKeys: Set<Int> = [
        115, 116, 119, 121, 114,            // Home, PgUp, End, PgDn, Help
        71, 110,                            // keypad Clear, contextual menu
        72, 73, 74,                         // volume up/down, mute
        102, 104,                           // JIS Eisu / Kana — IME toggles
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,   // F1–F12
        105, 107, 113, 106, 64, 79, 80, 90                        // F13–F20
    ]

    /// The ⌃-letters vim claims — **what the engine executes, not what the
    /// parser recognizes.** The parser binds eleven, but nine of them plan to
    /// a bare `.bell`: increment/decrement are unsupported, the page and
    /// scroll motions have no physical lowering, and `<C-w>` buffers, eats the
    /// following key, then bells. Claiming those would steal ⌃a, ⌃e, ⌃d and
    /// friends — the emacs bindings every Cocoa text field honors — to play a
    /// beep.
    ///
    /// So the set is the two that work (`<C-r>` redo, `<C-v>` visual block);
    /// `<C-[>` is handled above, ahead of the ⌥ rejection. The engine tests
    /// derive this set from the planners and fail if it drifts, so
    /// implementing the page motions will say so out loud.
    static let boundControlLetters: Set<Character> = ["r", "v"]

    static let nativeControlLetters: Set<Character> = ["f", "b"]
}
