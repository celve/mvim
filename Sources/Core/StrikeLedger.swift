/// The lazy write probe's tally: how many times in a row a claimed AX write
/// has failed to land, per (surface rung, capability).
///
/// A write is the one capability that cannot be probed without performing it,
/// so the probe has to take the app's word and real commands become the trial.
/// A settle verdict is one reading of that trial, and this type decides when a
/// run of readings has become a conclusion worth remembering.
///
/// **One strike commits.** The fields this exists to catch — Electron
/// contenteditables that report `AXSelectedText` settable and then ignore the
/// write — fail *every single time*, so waiting for a second failure buys no
/// certainty and costs another broken command on every new surface. A settle
/// that has not converged after 250ms of polling is treated as proof enough.
///
/// The trade, stated plainly: an honest field having one bad moment (busy past
/// the settle window, or an autocomplete changing the length out from under the
/// prediction) is demoted on that one reading, with no forgiveness. The recovery
/// paths are the `✗ learned` badge, the user's one-click override, and the
/// version TTL — visible and cheap, but the demotion is silent until noticed.
/// `strikesToCommit` is the single knob if that proves too eager.
///
/// **The tally is ephemeral.** It lives for the process, never on disk — only
/// the *conclusion* is durable (see `LearnedPriors`, which stores commits and
/// nothing else). At a threshold of one the tally never actually holds a pending
/// count; what remains load-bearing is `committed`, which keeps a stray second
/// strike from re-firing the republish a commit triggers.
///
/// Pure by construction: no `Foundation`, no clock, no store, so `make test`
/// pins the commit rule directly rather than inferring it from a misbehaving app.
public struct StrikeLedger {
    /// Consecutive failures required before a demotion is believed.
    public static let strikesToCommit = 1

    /// `rung` and `capability` are raw strings for the same reason the stores
    /// are: LoomCore cannot see the engine's `Capability` type.
    struct Key: Hashable {
        let rung: String
        let capability: String
    }

    private var strikes: [Key: Int] = [:]
    /// Rungs already committed this session. Without it a stray strike against
    /// an already-demoted capability would re-commit and re-trigger the
    /// republish it causes — the demoted path is supposed to go quiet.
    private var committed: Set<Key> = []

    public init() {}

    /// One observed, attributed settle failure.
    ///
    /// Returns `true` **exactly** on the transition that commits — the caller
    /// treats that as "persist this demotion and re-resolve the binding", so it
    /// must never fire twice for the same conclusion.
    public mutating func strike(rung: String, capability: String) -> Bool {
        let key = Key(rung: rung, capability: capability)
        guard !committed.contains(key) else { return false }
        let count = (strikes[key] ?? 0) + 1
        guard count >= Self.strikesToCommit else {
            strikes[key] = count
            return false
        }
        strikes[key] = nil
        committed.insert(key)
        return true
    }

    /// One observed, attributed settle success: the run of failures is broken.
    ///
    /// Inert at a threshold of one — nothing can be pending — but kept so the
    /// threshold stays a single-line knob rather than a behaviour rewrite.
    ///
    /// A committed demotion is *not* undone here, at any threshold. Once demoted
    /// the capability stops being exercised, so it generates no evidence either
    /// way; only the version TTL in `LearnedPriors` re-opens the trial.
    public mutating func clear(rung: String, capability: String) {
        strikes[Key(rung: rung, capability: capability)] = nil
    }

    /// Pending strikes for one key — tests and diagnostics only.
    func pending(rung: String, capability: String) -> Int {
        strikes[Key(rung: rung, capability: capability)] ?? 0
    }
}
