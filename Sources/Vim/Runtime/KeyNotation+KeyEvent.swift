import LoomCore

/// The runtime half of the gate: a tapped `KeyEvent` in, the pure policy's
/// verdict out. Nothing but the mapping lives here — the policy itself sits in
/// `Key/KeyNotation.swift`, where `make test` can assert it without linking
/// LoomCore.
public extension KeyNotation {
    /// nil means "not vim's key" — the controller passes it through untouched.
    static func token(for event: KeyEvent) -> String? {
        guard event.kind == .keyDown else { return nil }
        return token(keyCode: event.keyCode, chord: Chord(event.mods), characters: event.characters)
    }
}

extension KeyNotation.Chord {
    /// A lossless projection: which bits actually matter is the policy's
    /// decision, made in one place, so this mapping never has an opinion.
    init(_ mods: Mods) {
        var chord: KeyNotation.Chord = []
        if mods.contains(.command) { chord.insert(.command) }
        if mods.contains(.option)  { chord.insert(.option) }
        if mods.contains(.control) { chord.insert(.control) }
        if mods.contains(.shift)   { chord.insert(.shift) }
        if mods.contains(.fn)      { chord.insert(.fn) }
        self = chord
    }
}
