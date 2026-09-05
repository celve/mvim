/// The atoms the physical planner consults about a focused field.
///
/// Two species live here. **Mechanism** atoms are proven by the AX probe and
/// each maps to one concrete AX call. **Policy** atoms are never probed —
/// they are *decided*, subtractively, by shipped seeds and the user, against
/// a parent mechanism whose absence moots the question. The unifying
/// invariant is not "an AX mechanism" but "a per-field boolean the planner
/// consults that a user can see and demote in one menu".
///
/// Ambient powers (key synthesis, clipboard transactions, ⌘Z) are
/// permission-level constants, not capabilities.
public enum Capability: String, CaseIterable, Equatable, Hashable, Sendable {
    /// `AXValue` / `AXStringForRange`: the field's text can be read.
    case readText

    /// `AXNumberOfCharacters`: cheap length reads for settle checks.
    case readLength

    /// `AXSelectedTextRange` (get): caret and selection can be read.
    case readCaret

    /// `AXSelectedText` (get): selection content without the clipboard.
    case readSelectedText

    /// `AXSelectedTextRange` (set): the golden write — exact select/move.
    case writeSelection

    /// `AXSelectedText` (set): exact insertion/replacement.
    case insertText

    /// The standing-cursor *role* of `writeSelection`'s mechanism: may the
    /// Normal-mode block cursor be left drawn as a persistent selection?
    /// Never probed; "available" means *permitted*, resolved by the runtime
    /// (writeSelection minus seeds and user config). Selection-reactive apps
    /// (Notion's floating toolbar) attach UI to any standing selection, so
    /// presentation must be deniable separately from actuation, which
    /// transient command selections keep using regardless. Subtractive only.
    case drawCursor

    /// Does the readable text span the whole navigable document?
    ///
    /// The policy atom that answers a question about *truth* rather than
    /// permission. In a block editor (Notion) each block is its own
    /// contenteditable, so `AXValue` is one block, not the page: the model
    /// is exact within the block — `w`, `f`, `ciw`, `x` are all correct —
    /// and a lie about everything past it. `j` then resolves to the offset
    /// it started at and executes a flawless no-op.
    ///
    /// Denied, the planner stops trusting the model for geography beyond
    /// the caret's line and routes those steps to the blind lane, whose
    /// Cocoa chords cross blocks natively. Local exactness is untouched.
    ///
    /// Never probed — no AX attribute answers it — and **never learned**:
    /// `LearnedPriors` demotes from failed settles, and a block-scoped
    /// field's settles *pass*. That is the bug; there is no signal. Seeds
    /// and the user's override are the only sources. Subtractive only.
    case wholeDocument

    /// Is each focused field its own vim session?
    ///
    /// The entry policy opens every newly-bound field in Insert, on the
    /// assumption that a new element means the user moved somewhere new. In
    /// a block editor that assumption breaks: `j` crosses into the next
    /// block, which is a different element, and the session would end
    /// mid-motion — Normal mode would drop to Insert on every line move.
    ///
    /// Denied, an element change *inside the same document* continues the
    /// session instead of starting one (see `FocusTransition`). Available —
    /// the default everywhere — is the long-standing behavior: every focus
    /// change is a session boundary.
    ///
    /// Distinct from `wholeDocument`, deliberately: that atom is about the
    /// *text*'s scope and is read by the planner, this one is about
    /// *session* identity and is read by the runtime's focus logic. An app
    /// can want one without the other, and each is togglable per app.
    ///
    /// The one atom with no parent mechanism — no AX call gates whether a
    /// focus change ends a session. Never probed, never learned.
    case fieldIsSession
}

public extension Capability {
    /// How this atom is resolved. See the type's doc comment.
    enum Species: Equatable, Sendable {
        case mechanism
        case policy
    }

    var species: Species {
        switch self {
        case .drawCursor, .wholeDocument, .fieldIsSession:
            return .policy
        case .readText, .readLength, .readCaret, .readSelectedText, .writeSelection, .insertText:
            return .mechanism
        }
    }

    /// The mechanism a policy atom rides on: no mechanism, no question. Its
    /// absence makes the policy unavailable regardless of seeds or the user
    /// — `.on` un-seeds curation, it never conjures a missing mechanism.
    ///
    /// `nil` means the policy is ungated: nothing about the field can moot
    /// it, so it answers to seeds and the user alone (`fieldIsSession`).
    ///
    /// The policies deny different things: `drawCursor` off means "you may
    /// not", `wholeDocument` and `fieldIsSession` off mean "it is not true".
    /// The subtractive law is kept verbatim for all three so the semantics
    /// do not fork — and since none is probed, `.on` and auto coincide
    /// except against a seed.
    var parent: Capability? {
        switch self {
        case .drawCursor: return .writeSelection
        case .wholeDocument: return .readText
        default: return nil
        }
    }
}

public enum CapabilityStatus: String, Equatable, Sendable {
    case available
    case unavailable
    case unknown
}

/// A frozen per-field answer the physical planner consults. The runtime
/// prober fills it (static probe on focus, lazy write probe, learned
/// per-app priors) and refreshes it when focus moves; the planner never
/// talks to AX. At planning time only `.available` counts — an unknown
/// capability is planned around, never assumed.
public struct CapabilityProfile: Equatable, Sendable {
    public var statuses: [Capability: CapabilityStatus]

    public init(statuses: [Capability: CapabilityStatus] = [:]) {
        self.statuses = statuses
    }

    public init(available: Set<Capability>) {
        statuses = Dictionary(uniqueKeysWithValues: available.map { ($0, .available) })
    }

    public func has(_ capability: Capability) -> Bool {
        statuses[capability] == .available
    }
}

/// Why each atom resolved as it did. Here, not beside the impure `FieldProber`, so `make test` reaches it.
public struct CapabilityReport: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// The AX trial — or, for `drawCursor`, its writeSelection mechanism.
        case probed
        /// A shipped `CapabilityConfig` seed.
        case seeded
        /// The user's menu override.
        case user
        /// A committed `LearnedPriors` demotion: the field claimed this write
        /// and then failed to deliver it. A suggestion, not a decision — the
        /// user can promote it (Off) or overrule it (On).
        case learned
    }

    public struct Entry: Equatable, Sendable {
        public let status: CapabilityStatus
        public let source: Source

        public init(status: CapabilityStatus, source: Source) {
            self.status = status
            self.source = source
        }
    }

    public var entries: [Capability: Entry]

    public init(entries: [Capability: Entry] = [:]) {
        self.entries = entries
    }
}

// MARK: - Recorder

extension Capability {
    /// The storage key doubles as the log spelling; kept separate so either may move.
    var traceName: String { rawValue }

    var traceCode: String {
        switch self {
        case .readText: return "RT"
        case .readLength: return "RL"
        case .readCaret: return "RC"
        case .readSelectedText: return "RS"
        case .writeSelection: return "WS"
        case .insertText: return "IT"
        case .drawCursor: return "DC"
        case .wholeDocument: return "WD"
        case .fieldIsSession: return "FS"
        }
    }
}

extension Set where Element == Capability {
    /// Declaration order — a `Set` has none.
    var traceNames: String {
        "[" + Capability.allCases.filter { self.contains($0) }.map(\.traceName).joined(separator: " ") + "]"
    }
}

extension CapabilityStatus {
    var traceCode: String {
        switch self {
        case .available: return "+"
        case .unavailable: return "-"
        case .unknown: return "?"
        }
    }
}

extension CapabilityReport.Source {
    var traceCode: String {
        switch self {
        case .probed: return "p"
        case .seeded: return "s"
        case .user: return "u"
        case .learned: return "l"
        }
    }
}

extension CapabilityReport {
    /// `RT+p RL+p WS-l …` in `allCases` order; status `+ - ?`, source `p s u l`, `??` absent.
    var traceGrid: String {
        var out = ""
        for capability in Capability.allCases {
            if !out.isEmpty { out += " " }
            out += capability.traceCode
            guard let entry = entries[capability] else {
                out += "??"
                continue
            }
            out += entry.status.traceCode + entry.source.traceCode
        }
        return out
    }
}
