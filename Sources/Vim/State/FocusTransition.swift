/// How a focus change relates to the editing session vim is already in.
///
/// The runtime's entry policy — "fields open in Insert; ⌃[ engages Normal" —
/// long assumed that a new AX element *is* a new editing session. Those
/// coincide everywhere except a block editor, where each block is its own
/// element and a **vim motion changes the field**: `j` crosses into the next
/// block, focus moves, and the session would end mid-command.
///
/// So the runtime classifies the edge and this decides what survives it.
/// `VimState` itself tracks no field identity — the split is deliberate — so
/// the policy lives here, in the pure layer, where `make test` can pin it.
public enum FocusTransition: Equatable, Sendable {
    /// The identical element, republished — a capability re-resolve. Nothing
    /// moved, so nothing is stale.
    case sameElement

    /// A different element in the same document: a block editor's next
    /// block. Offsets are element-relative and therefore fiction now; the
    /// mode, and everything offset-free, is not.
    case sameDocument

    /// Genuinely elsewhere. The entry policy applies.
    case newSession
}

public extension FocusTransition {
    /// The monitor's keys-in-flight and the controller's open dot body are
    /// paired halves of one change body — they clear together or not at all.
    /// Both are offset-free (a key log and a command string), so a block
    /// crossing does not stale them: `ciwfoo⏎bar<Esc>`, where the `⏎` *made*
    /// the new block, must still record its dot body. Only a genuinely new
    /// session drops them.
    var clearsChangeInFlight: Bool { self == .newSession }

    /// Whether the drawn block cursor stays put. It survives only a
    /// republish of the same element — anywhere else the departing field
    /// must have it collapsed, and the engine must forget it.
    var preservesDrawnCursor: Bool { self == .sameElement }
}

public extension VimState.Field {
    /// The entry policy as a value: a fresh editing session opens in Insert,
    /// so typing just works and `⌃[` engages Normal.
    static let entry = Self(mode: .insert)

    /// What survives a focus change.
    ///
    /// `sameDocument` keeps residency and drops everything else, because
    /// every other member here is an **offset into the element we just
    /// left**: `insertStart` (`gi`, mark `^`), `marks`, `lastVisual` (`gv`),
    /// and the drawn `cursor`. In a block editor those offsets are
    /// block-relative, so carrying them would point them at another block's
    /// text.
    ///
    /// Visual is carried verbatim even though `Mode.visual` holds an anchor —
    /// the one offset that rides inside the mode. Dropping to Normal would
    /// break `v j j d` (the second `j` would move the caret instead of
    /// extending), and the stale anchor is inert on the paths a block editor
    /// actually takes: `lowerExtend`'s exact lane is precisely what a denied
    /// `wholeDocument` routes around, and a blind extend leaves the selection
    /// opaque anyway.
    func carried(across transition: FocusTransition) -> VimState.Field {
        switch transition {
        case .sameElement:
            return self
        case .sameDocument:
            return VimState.Field(mode: mode)
        case .newSession:
            return .entry
        }
    }
}

// MARK: - The rule

public extension FocusTransition {
    /// One bound field as the rule compares it; `Element` is an AX element at runtime.
    struct Focus<Element: Equatable, Site: Equatable> {
        public var element: Element
        public var pid: Int32
        /// Never the whole surface: a block editor hands out one element, and one identifier, per block.
        public var site: Site
        /// A forced binding's window number, its only identity: its element stands in for the whole app.
        public var forcedWindow: UInt32?
        /// How `fieldIsSession` resolved for the field.
        public var session: CapabilityReport.Entry?
        /// The outermost editable field around the element, where the page names another one: a block editor's page.
        public var enclosing: Element?
        /// The element's window, read only where `windowIsDocument`.
        public var window: Element?

        public init(
            element: Element, pid: Int32, site: Site, forcedWindow: UInt32? = nil, session: CapabilityReport.Entry? = nil,
            enclosing: Element? = nil, window: Element? = nil
        ) {
            self.element = element
            self.pid = pid
            self.site = site
            self.forcedWindow = forcedWindow
            self.session = session
            self.enclosing = enclosing
            self.window = window
        }

        /// The outermost editable field of the element's document, itself included; nil where the user's On keeps every field a session.
        var document: Element? {
            session == CapabilityReport.Entry(status: .available, source: .user) ? nil : enclosing ?? element
        }
    }

    /// A seed or the user denying `fieldIsSession` speaks of every field in the window; a field's enclosing one speaks of its page alone.
    static func windowIsDocument(_ session: CapabilityReport.Entry?) -> Bool {
        guard let session, session.status == .unavailable else { return false }
        return session.source != .probed
    }

    /// Which edge focus traversed: identity is the document, never the element, and anything unknown is a new session.
    static func between<Element, Site>(_ old: Focus<Element, Site>?, _ new: Focus<Element, Site>?) -> FocusTransition {
        guard let old, let new else { return .newSession }
        if old.forcedWindow != nil || new.forcedWindow != nil {
            return old.forcedWindow != nil && old.forcedWindow == new.forcedWindow && old.pid == new.pid ? .sameElement : .newSession
        }
        if old.element == new.element { return .sameElement }
        if let document = old.document, document == new.document { return .sameDocument }
        guard windowIsDocument(old.session), windowIsDocument(new.session), old.pid == new.pid, old.site == new.site,
              let window = old.window, window == new.window else { return .newSession }
        return .sameDocument
    }
}

// MARK: - Recorder

extension FocusTransition {
    var traceName: String {
        switch self {
        case .sameElement: return "sameElement"
        case .sameDocument: return "sameDocument"
        case .newSession: return "newSession"
        }
    }
}
