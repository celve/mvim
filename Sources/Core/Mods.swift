import CoreGraphics

/// Canonical modifier set — decoupled from the CGEvent bit layout so
/// persisted preferences stay stable. Norm's copy carries no NSEvent or
/// Carbon conversions (no recorder, no Carbon hotkeys).
public struct Mods: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = Mods(rawValue: 1 << 0)
    public static let option  = Mods(rawValue: 1 << 1)
    public static let control = Mods(rawValue: 1 << 2)
    public static let shift   = Mods(rawValue: 1 << 3)
    public static let fn      = Mods(rawValue: 1 << 4)   // Fn / Globe

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// From CGEvent flags (the event tap).
    public init(cgFlags: CGEventFlags) {
        var mods: Mods = []
        if cgFlags.contains(.maskCommand)     { mods.insert(.command) }
        if cgFlags.contains(.maskAlternate)   { mods.insert(.option) }
        if cgFlags.contains(.maskControl)     { mods.insert(.control) }
        if cgFlags.contains(.maskShift)       { mods.insert(.shift) }
        if cgFlags.contains(.maskSecondaryFn) { mods.insert(.fn) }
        self = mods
    }

    public var glyphs: String {
        var glyphs = ""
        if contains(.fn)      { glyphs += "🌐" }
        if contains(.control) { glyphs += "⌃" }
        if contains(.option)  { glyphs += "⌥" }
        if contains(.shift)   { glyphs += "⇧" }
        if contains(.command) { glyphs += "⌘" }
        return glyphs
    }
}
