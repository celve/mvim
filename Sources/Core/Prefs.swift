import Foundation

/// What vim does in one app: engage where a textual field proves itself
/// (`auto`), never (`off`), or bind the app itself when no accessibility
/// surface exists (`forced` — lane-C chords, explicit opt-in only).
public enum VimPolicy: String, CaseIterable, Sendable {
    case auto, off, forced
}

/// The key that enters Normal mode: ⌃[ always does, and `escape` adds Esc.
public enum NormalModeKey: String, CaseIterable, Sendable {
    case controlBracket, escape
}

/// The neutral Prefs store — Core's UserDefaults-backed configuration
/// surface. First resident: the per-app vim policy, consulted by the
/// runtime at *binding* time (never per keystroke).
public enum Prefs {
    static let disabledIDsKey = "disabledBundleIDs"
    static let disabledPrefixesKey = "disabledBundleIDPrefixes"
    static let enabledIDsKey = "enabledBundleIDs"
    static let forcedIDsKey = "forcedBundleIDs"
    static let normalModeKeyKey = "normalModeKey"

    /// Apps where engaging vim is destructive by default: terminals (Esc
    /// must reach the shell, or the real vim running inside) and editors
    /// whose users run their own vim emulation.
    static let seedDisabledIDs = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.apple.dt.Xcode",
        "dev.zed.Zed",
        "com.qvacua.VimR",
        "com.neovide.neovide",
    ]
    static let seedDisabledPrefixes = ["com.jetbrains."]

    /// Seeds apply until the user writes a key; a written key then owns its
    /// value, so removals of seeded entries persist. (Trade-off: future seed
    /// additions won't reach users who have written the key.)
    public static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            disabledIDsKey: seedDisabledIDs,
            disabledPrefixesKey: seedDisabledPrefixes,
            enabledIDsKey: [String](),
            forcedIDsKey: [String](),   // forced is opt-in: never seeded
        ])
    }

    public static var normalModeKey: NormalModeKey {
        get {
            UserDefaults.standard.string(forKey: normalModeKeyKey).flatMap(NormalModeKey.init(rawValue:))
                ?? .controlBracket
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: normalModeKeyKey) }
    }

    public static func policy(for bundleID: String) -> VimPolicy {
        if stringArray(forcedIDsKey).contains(bundleID) { return .forced }
        return isDisabled(bundleID: bundleID) ? .off : .auto
    }

    /// Invariant: `setPolicy(p, for: id)` ⟹ `policy(for: id) == p` — even
    /// for seeded or prefix-family apps (the picker must never show a lie).
    public static func setPolicy(_ policy: VimPolicy, for bundleID: String) {
        var forced = stringArray(forcedIDsKey)
        switch policy {
        case .forced:
            if !forced.contains(bundleID) { forced.append(bundleID) }
            setDisabled(false, for: bundleID)
        case .off:
            forced.removeAll { $0 == bundleID }
            setDisabled(true, for: bundleID)
        case .auto:
            forced.removeAll { $0 == bundleID }
            setDisabled(false, for: bundleID)
        }
        UserDefaults.standard.set(forced, forKey: forcedIDsKey)
    }

    public static func isDisabled(bundleID: String) -> Bool {
        matches(bundleID,
                exact: stringArray(disabledIDsKey),
                prefixes: stringArray(disabledPrefixesKey),
                exceptions: stringArray(enabledIDsKey))
    }

    public static func setDisabled(_ disabled: Bool, for bundleID: String) {
        var exact = stringArray(disabledIDsKey)
        var exceptions = stringArray(enabledIDsKey)
        if disabled {
            exceptions.removeAll { $0 == bundleID }
            if !exact.contains(bundleID) { exact.append(bundleID) }
        } else {
            exact.removeAll { $0 == bundleID }
            // A prefix-disabled app (JetBrains family) can only be re-enabled
            // by exception — the prefix itself stays.
            if stringArray(disabledPrefixesKey).contains(where: { bundleID.hasPrefix($0) }),
               !exceptions.contains(bundleID) {
                exceptions.append(bundleID)
            }
        }
        UserDefaults.standard.set(exact, forKey: disabledIDsKey)
        UserDefaults.standard.set(exceptions, forKey: enabledIDsKey)
    }

    /// The pure matching core: exceptions override prefix families, never an
    /// exact entry (`setDisabled` keeps an ID out of both lists anyway).
    static func matches(_ id: String, exact: [String], prefixes: [String], exceptions: [String]) -> Bool {
        if exact.contains(id) { return true }
        if exceptions.contains(id) { return false }
        return prefixes.contains { id.hasPrefix($0) }
    }

    private static func stringArray(_ key: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }
}
