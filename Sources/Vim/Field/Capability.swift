/// The atoms the physical planner consults about a focused field.
///
/// Two species live here. **Mechanism** atoms are proven by the AX probe and
/// each maps to one concrete AX call. **Policy** atoms are *decided*,
/// subtractively, by shipped seeds, the user and, for `blockScoped`, the
/// probe's enclosing field, against a parent mechanism whose absence moots
/// the question. The unifying
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

    /// False in block editors (Notion), whose `AXValue` is one block: the probe's enclosing field or a seed says so, as no settle can tell.
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
    /// focus change ends a session. Never learned: a seed, the user or the
    /// probe's enclosing field denies it.
    case fieldIsSession

    /// ⌃A and ⇧⌃A: to the start of the caret's paragraph, which is uvim's line.
    case lineStartKey

    /// ⌃E and ⇧⌃E: to the end of the caret's paragraph.
    case lineEndKey

    /// ⌘↑ and ⇧⌘↑: to the start of the document.
    case documentStartKey

    /// ⌘↓ and ⇧⌘↓: to the end of the document.
    case documentEndKey

    /// Opt-in: word, paragraph and page motions press the app's own keys.
    case nativeMotions

    /// ⌥← ⌥→ and their ⇧ forms: by the app's words.
    case wordKeys

    /// ⌥↑ ⌥↓: to the app's paragraph start and end.
    case paragraphKeys
}

public extension Capability {
    /// How this atom is resolved. See the type's doc comment.
    enum Species: Equatable, Sendable {
        case mechanism
        case policy
    }

    var species: Species {
        switch self {
        case .drawCursor, .wholeDocument, .fieldIsSession, .nativeMotions:
            return .policy
        case .readText, .readLength, .readCaret, .readSelectedText, .writeSelection, .insertText,
             .lineStartKey, .lineEndKey, .documentStartKey, .documentEndKey, .wordKeys, .paragraphKeys:
            return .mechanism
        }
    }

    /// Lane B's keys: the probe claims them, and a settle that finds a key did nothing demotes it.
    static let nativeKeys: Set<Capability> = [
        .lineStartKey, .lineEndKey, .documentStartKey, .documentEndKey, .wordKeys, .paragraphKeys,
    ]

    /// What a field denies by naming a bigger editable field around itself: it is one block of that document.
    static let blockScoped: Set<Capability> = [.wholeDocument, .fieldIsSession]

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
    /// do not fork — `.on` and auto coincide except against a seed or an
    /// enclosing field.
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
        /// The AX trial — or, for `drawCursor`, its writeSelection mechanism; for a native key, the probe's claim;
        /// for a `blockScoped` atom that is off, the enclosing field the probe read.
        case probed
        /// A shipped `CapabilityConfig` seed.
        case seeded
        /// The user's menu override.
        case user
        /// A belief: a write or key failed, or, for `readCaret`, no read model fits.
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
        case .lineStartKey: return "KA"
        case .lineEndKey: return "KE"
        case .documentStartKey: return "KT"
        case .documentEndKey: return "KB"
        case .nativeMotions: return "NM"
        case .wordKeys: return "WK"
        case .paragraphKeys: return "PK"
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
