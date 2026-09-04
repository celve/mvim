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
