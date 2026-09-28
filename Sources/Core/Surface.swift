/// The identity a capability answer is keyed by: the text engine behind a
/// field, not the app that happens to host it.
///
/// One app can host several engines with different truths. A browser's own
/// search box is AppKit; the `<input>` in the page it is showing is not; both
/// report `AXTextField`. Keyed by bundle ID alone, denying a capability for
/// the page also denies it for the chrome, and there is no way to say
/// otherwise. The shipped `notion.id` seed shows the same category error from
/// the other side: it earns its denials because each Notion block is its own
/// contenteditable — a fact about *notion.so*, expressible today only because
/// Notion ships an Electron wrapper.
///
/// A surface expands into a **ladder** of string rungs, narrowest first, and
/// every lookup is a walk down it. A bare bundle ID is still the last rung, so
/// every override written before this type existed keeps resolving unchanged.
///
/// Pure by construction: no `UserDefaults`, no AX, no `Foundation`. The store
/// shell and the AX walk that fills a surface live elsewhere, so the rung
/// algebra and the precedence walks stay under `make test` (the
/// `Prefs.matches` pattern — a decision core extracted away from its store).
public struct Surface: Equatable, Hashable, Sendable {
    public var bundleID: String?

    /// Host of the enclosing web area; `nil` for a native field.
    ///
    /// The full host, not eTLD+1: `docs.google.com` and `mail.google.com` are
    /// genuinely different editors, so subdomain sensitivity is correctness
    /// rather than a limitation.
    public var origin: String?

    /// The field's AX role. Names the *kind* of field within a site — the unit
    /// behind "all text fields on notion.so".
    public var role: String?

    /// A stable-ish identifier for this one field (`AXIdentifier` natively,
    /// `AXDOMIdentifier` in web content), when the app or page supplies one.
    ///
    /// Deliberately not validated. Generated ids (React's `:r1:`, Radix's
    /// `radix-:r3:`) are unstable across loads, but a heuristic that tried to
    /// spot them would be wrong in both directions. Instead the menu names the
    /// rung verbatim so the user judges, and a stale id simply stops matching
    /// and falls through to the wider rungs — a non-destructive failure.
    public var identifier: String?

    public init(
        bundleID: String? = nil,
        origin: String? = nil,
        role: String? = nil,
        identifier: String? = nil
    ) {
        self.bundleID = bundleID
        self.origin = origin
        self.role = role
        self.identifier = identifier
    }

    /// The site half — everything but the element.
    ///
    /// `FocusTracker.transition` compares *this*, never the whole surface: in a
    /// block editor every block is a different element, so a full comparison
    /// would make `sameDocument` unreachable and end the vim session on every
    /// line move, which is the exact failure `fieldIsSession` exists to prevent.
    public var site: Surface {
        Surface(bundleID: bundleID, origin: origin, role: role)
    }
}

// MARK: - Rungs

public extension Surface {
    /// A rung's separator. Bundle IDs and hosts cannot contain it; identifiers
    /// can, so they are escaped on the way in.
    static let separator = "|"

    /// Every rung this surface answers to, **narrowest first**.
    ///
    ///     com.dia.app|notion.so|id:search-input   the one field
    ///     com.dia.app|notion.so|role:AXTextField  all text fields on that site
    ///     com.dia.app|notion.so                   that site in that app
    ///     web:notion.so                           that site in ANY browser (seeds only)
    ///     com.dia.app                             the whole app — today's key
    ///
    /// A native field has no origin and collapses to the app-prefixed element
    /// rungs plus the bare bundle ID.
    ///
    /// Both element rungs coexist by design: an identified field still inherits
    /// from the role rung, so "all text fields on notion.so" covers identified
    /// and anonymous fields alike.
    ///
    /// `web:` sits *below* the app rung deliberately — a site's own nature
    /// (a block editor is a block editor everywhere) is more specific than a
    /// blanket statement about the app hosting it.
    var rungs: [String] {
        var rungs: [String] = []
        // The prefix the element rungs hang off: the site when there is one,
        // otherwise the app.
        let prefix: String?
        if let bundleID, let origin {
            prefix = bundleID + Self.separator + origin
        } else {
            prefix = bundleID
        }

        if let prefix {
            if let identifier, !identifier.isEmpty {
                rungs.append(prefix + Self.separator + "id:" + Self.escape(identifier))
            }
            if let role, !role.isEmpty {
                rungs.append(prefix + Self.separator + "role:" + role)
            }
            // Only a real site rung; when prefix IS the bundle ID it is the app
            // rung, appended once at the end.
            if origin != nil { rungs.append(prefix) }
        }
        if let origin { rungs.append(Self.webRung(origin)) }
        if let bundleID { rungs.append(bundleID) }
        return rungs
    }

    /// The rung the **learner** writes at: every field of this role on this
    /// site (or in this app, natively).
    ///
    /// Deliberately not the identifier rung. A demotion has to accumulate two
    /// consecutive strikes to commit, and a key per individual `<input>` would
    /// scatter the evidence so thinly it never would — the user visits a given
    /// field once or twice, but hits fields *of a kind* constantly. Reads still
    /// walk the whole ladder; only writes are pinned here.
    ///
    /// `nil` when there is no role or no app to hang it on, in which case there
    /// is nothing stable enough to learn against.
    var roleRung: String? {
        guard let role, !role.isEmpty else { return nil }
        guard let bundleID else { return nil }
        let prefix = origin.map { bundleID + Self.separator + $0 } ?? bundleID
        return prefix + Self.separator + "role:" + role
    }

    /// The app-independent rung for a site. Seeds only — the menu never writes
    /// it, because "notion.so in every browser I will ever install" is a claim
    /// curation makes, not one a user makes from a menu standing in one app.
    static func webRung(_ origin: String) -> String { "web:" + origin }

    /// A seed-only rung past every ladder, so curation can deny an atom everywhere.
    static let everywhere = "*"

    /// Identifiers are arbitrary strings from a DOM; a raw `|` would forge a
    /// rung boundary. Escaped rather than rejected — the key is only ever
    /// generated and compared, never parsed back, so this just has to avoid
    /// collisions while staying legible under `defaults read`.
    ///
    /// Hand-rolled to keep this file `Foundation`-free: it compiles into the
    /// permission-free test binary, which links nothing but the stdlib.
    static func escape(_ identifier: String) -> String {
        identifier
            .split(separator: Character(separator), omittingEmptySubsequences: false)
            .joined(separator: "%7C")
    }

    /// Lowercased, `www.` dropped. `nil` for anything that cannot name a site
    /// (a `file://` URL, an empty host).
    static func normalizedHost(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }
}

// MARK: - Scopes (what the menu may write)

public extension Surface {
    /// A rung a user is allowed to configure, paired with what it means.
    ///
    /// The `web:` rung is absent on purpose (seeds only). UI strings are not
    /// here either — the app layer names rows; this type names rungs.
    enum Scope: Equatable, Sendable {
        /// This one field, by its identifier.
        case field(identifier: String)
        /// Every field of this role on this site (or in this app, natively).
        case fieldsOfRole(String)
        /// This site in this app.
        case site(String)
        /// The whole app.
        case app
    }

    /// The scopes the menu offers, narrowest first, each with the rung it
    /// writes. Collapses naturally: no identifier drops `.field`, a native
    /// field drops `.site`.
    var writableScopes: [(scope: Scope, rung: String)] {
        var scopes: [(Scope, String)] = []
        let prefix: String?
        if let bundleID, let origin {
            prefix = bundleID + Self.separator + origin
        } else {
            prefix = bundleID
        }
        if let prefix {
            if let identifier, !identifier.isEmpty {
                scopes.append((.field(identifier: identifier),
                               prefix + Self.separator + "id:" + Self.escape(identifier)))
            }
            if let role, !role.isEmpty {
                scopes.append((.fieldsOfRole(role), prefix + Self.separator + "role:" + role))
            }
            if let origin { scopes.append((.site(origin), prefix)) }
        }
        if let bundleID { scopes.append((.app, bundleID)) }
        return scopes
    }
}

// MARK: - The precedence walks

/// The pure core of per-surface capability config: two ladder walks and the
/// write rule that keeps them honest.
///
/// Kept apart from `CapabilityConfig` so it can be compiled into the
/// permission-free test binary, which does not build `Sources/Core` wholesale.
/// Capabilities are raw strings here for the same reason they are there —
/// LoomCore cannot see the engine's `Capability` type.
public enum SurfaceLadder {
    /// The user's stored choices, as the beliefs file's `overrides` hold them.
    public typealias UserStore = [String: [String: String]]
    /// Compiled-in curation: rung → the capabilities it denies.
    public typealias Seeds = [String: Set<String>]

    /// The narrowest rung carrying a user choice for `capability`.
    ///
    /// The rung comes back with the value because the menu needs it: the
    /// checkmark marks *which* stored entry is in force, and that is the only
    /// place the rung is surfaced — badges stay short.
    public static func userEntry(
        _ capability: String, rungs: [String], store: UserStore
    ) -> (rung: String, value: String)? {
        for rung in rungs {
            if let value = store[rung]?[capability] { return (rung, value) }
        }
        return nil
    }

    /// The narrowest rung seeding `capability` off.
    ///
    /// **Deliberately a separate walk from `userEntry`.** A single first-hit
    /// walk over a merged view would let a seed at `web:notion.so` beat a
    /// user's `.on` at the app rung, contradicting the law that an explicit
    /// `.on` un-seeds curation. Resolving the two independently and feeding
    /// them to the existing precedence table keeps that law verbatim.
    public static func seedEntry(
        _ capability: String, rungs: [String], seeds: Seeds
    ) -> String? {
        for rung in rungs + [Surface.everywhere] where seeds[rung]?.contains(capability) == true {
            return rung
        }
        return nil
    }

    /// Stores `value` at `rung` and clears narrower rungs, so "the picker must never show a lie" (`Prefs`); nil clears every rung.
    public static func setting(
        _ value: String?,
        _ capability: String,
        at rung: String?,
        rungs: [String],
        store: UserStore
    ) -> UserStore {
        var store = store
        // Auto, or a rung we do not recognise: clear the atom everywhere.
        guard let value, let rung, let index = rungs.firstIndex(of: rung) else {
            for rung in rungs { store[rung]?[capability] = nil }
            return pruned(store)
        }
        for narrower in rungs[..<index] { store[narrower]?[capability] = nil }
        store[rung, default: [:]][capability] = value
        return pruned(store)
    }

    /// Drop every capability stored at `rung` and at every narrower rung — the
    /// menu's "Clear overrides…" actions. A scope the user cannot see below
    /// would otherwise be unreachable from the surface they are standing in.
    public static func clearing(
        atAndBelow rung: String, rungs: [String], store: UserStore
    ) -> UserStore {
        var store = store
        guard let index = rungs.firstIndex(of: rung) else { return store }
        for rung in rungs[...index] { store[rung] = nil }
        return pruned(store)
    }

    private static func pruned(_ store: UserStore) -> UserStore {
        store.filter { !$0.value.isEmpty }
    }
}
