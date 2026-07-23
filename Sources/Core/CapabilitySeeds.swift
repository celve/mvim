/// Shipped curation: surfaces where a capability defaults off.
///
/// Compiled in and never written to defaults, so a seed change always reaches
/// users — the deliberate opposite of `Prefs`, which seeds via
/// `register(defaults:)` and trades future seed additions for the ability to
/// remember a removal. Nothing here is probed; seeds are decided, and the
/// user's explicit `.on` un-seeds any of them.
///
/// Pure and `Foundation`-free so `make test` can pin the real literal rather
/// than a copy of it: a renamed atom or a rung no surface can produce would
/// otherwise orphan curation in silence.
public enum CapabilitySeeds {
    /// Rung → the capabilities it denies. Keys are `Surface` rungs, so curation
    /// can speak about an app (`notion.id`), a site in any browser
    /// (`web:notion.so`), or anything narrower.
    ///
    /// Notion earns three denials — presentational, epistemic, sessional — all
    /// downstream of one fact: each block is its own contenteditable. It reacts
    /// to any standing selection (floating toolbar, collaborator highlights),
    /// so the block cursor may not be left drawn there; the focused element's
    /// text is one block rather than the page, so vertical motions would
    /// resolve inside a document they cannot see; and crossing into the next
    /// block changes the focused element, which must not end the vim session
    /// the way moving to a genuinely new field does.
    ///
    /// That fact is about **notion.so**, not about a macOS app — it was only
    /// expressible as `notion.id` because Notion ships an Electron wrapper.
    /// Both rungs are seeded now, so Notion in a browser tab earns the same
    /// three denials while the browser's own chrome keeps all of them.
    public static let denied: [String: Set<String>] = [
        "notion.id": ["drawCursor", "wholeDocument", "fieldIsSession"],
        "web:notion.so": ["drawCursor", "wholeDocument", "fieldIsSession"],
    ]
}
