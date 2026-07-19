import Foundation

/// The neutral Prefs store — LoomCore's UserDefaults-backed configuration
/// surface. First resident: the per-app vim-mode disable list, consulted by
/// the runtime at *binding* time (never per keystroke).
public enum Prefs {
    static let disabledIDsKey = "disabledBundleIDs"
    static let disabledPrefixesKey = "disabledBundleIDPrefixes"
    static let enabledIDsKey = "enabledBundleIDs"

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
        ])
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
