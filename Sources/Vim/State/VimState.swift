/// The durable Vim semantics that macOS cannot represent.
///
/// Every fact in a running Vim belongs to exactly one of three owners:
///
/// - The **host field** owns what it can already answer — text content,
///   cursor, selection range. That is read fresh from AX into a snapshot at
///   planning time and never cached here; a copy would only drift.
/// - The **interceptor** owns keys in flight — the multi-key command buffer,
///   the search and command-line prompts, the macro tape, the Insert-mode
///   keystroke log. Those facts die when the current command finishes
///   assembling, and reach the engine only as payloads of a completed command.
/// - `VimState` owns the rest: whatever must survive *between* completed
///   commands for the next one to be interpreted correctly.
///
/// The state therefore changes at most once per completed command, speaks
/// text offsets and semantics but never keys in flight, and stays a pure
/// value type with no AppKit/AX dependency.
public struct VimState: Equatable, Sendable {
    /// Cross-field Vim memory; survives focus changes.
    public var session: Session

    /// Semantics of the focused field. The runtime watches focus and resets
    /// this when it moves — `VimState` itself does not track field identity.
    public var field: Field

    public init(session: Session = Session(), field: Field = Field()) {
        self.session = session
        self.field = field
    }

    public static let initial = VimState()
}

// MARK: - Session

public extension VimState {
    /// Vim memory that outlives any particular text field.
    struct Session: Equatable, Sendable {
        public var registers: Registers

        /// Drives `n`/`N`; synthesizes the `/` register.
        public var lastSearch: SearchMemory?

        /// Drives `;` and `,`.
        public var lastFind: FindMemory?

        /// The change `.` replays.
        public var lastChange: ChangeMemory?

        /// Text typed during the last completed Insert session; synthesizes
        /// the `.` register.
        public var lastInsert: String?

        /// The register a macro is currently recording into. Only the flag
        /// lives here — the tape accumulates in the interceptor and arrives
        /// as register content when recording stops. The planner needs the
        /// flag to read a bare `q` as "stop recording" rather than as an
        /// incomplete command awaiting a register name.
        public var recording: Register?

        /// Drives `@@`.
        public var lastPlayedMacro: Register?

        public init(
            registers: Registers = Registers(),
            lastSearch: SearchMemory? = nil,
            lastFind: FindMemory? = nil,
            lastChange: ChangeMemory? = nil,
            lastInsert: String? = nil,
            recording: Register? = nil,
            lastPlayedMacro: Register? = nil
        ) {
            self.registers = registers
            self.lastSearch = lastSearch
            self.lastFind = lastFind
            self.lastChange = lastChange
            self.lastInsert = lastInsert
            self.recording = recording
            self.lastPlayedMacro = lastPlayedMacro
        }
    }
}

// MARK: - Field

public extension VimState {
    /// Semantics of the focused field. Offsets index the field's text as it
    /// was when they were captured; nothing here is authoritative about the
    /// text itself.
    struct Field: Equatable, Sendable {
        /// The current residency. `.normal` is only the engine's neutral
        /// default — the runtime applies the per-app entry policy on focus.
        public var mode: Mode

        /// Offset where the current (or, until focus moves, the most recent)
        /// Insert/Replace session began; becomes mark `^` on exit and drives
        /// `gi`. `nil` when the field's cursor could not be read.
        public var insertStart: Int?

        /// Local marks a–z plus the implicit marks (`` ` ``, `.`, `^`).
        public var marks: [Character: MarkPoint]

        /// The last Visual selection, for `gv`.
        public var lastVisual: VisualMemory?

        /// The drawn Normal-mode block cursor — the fact macOS cannot
        /// represent: the field's current selection is a *cursor*, not a
        /// selection. nil when none is drawn (Insert/Visual, blind fields,
        /// end-of-line).
        public var cursor: Range<Int>?

        public init(
            mode: Mode = .normal,
            insertStart: Int? = nil,
            marks: [Character: MarkPoint] = [:],
            lastVisual: VisualMemory? = nil,
            cursor: Range<Int>? = nil
        ) {
            self.mode = mode
            self.insertStart = insertStart
            self.marks = marks
            self.lastVisual = lastVisual
            self.cursor = cursor
        }
    }
}

// MARK: - Mode

public extension VimState {
    /// A mode Vim is *resident* in between commands. Transient states —
    /// operator-pending, a half-typed prompt — are properties of the
    /// interceptor's buffer, not of the engine.
    ///
    /// Visual carries its context as an associated value so kind and anchor
    /// cannot disagree with residency.
    enum Mode: Equatable, Sendable {
        case normal
        case insert
        case replace
        case visual(VisualContext)

        /// A session where keys reach the app untouched.
        public var isInserting: Bool {
            switch self {
            case .insert, .replace: return true
            case .normal, .visual: return false
            }
        }

        /// Visual resolved to Normal: its anchor names a selection, so it is
        /// not a mode to revive when reading one has just failed.
        public var nonVisual: Mode {
            if case .visual = self { return .normal }
            return self
        }
    }

    /// The Visual-mode state macOS cannot hold: an AX selection is location
    /// plus length with no direction, so the fixed end must be remembered
    /// here for motions to know which end moves.
    struct VisualContext: Equatable, Sendable {
        public var kind: VisualKind

        /// Text offset of the fixed end of the selection.
        public var anchor: Int

        public init(kind: VisualKind, anchor: Int) {
            self.kind = kind
            self.anchor = anchor
        }
    }
}

// MARK: - Session memories

public extension VimState {
    /// A submitted search. Only `.forward`/`.backward` occur.
    struct SearchMemory: Equatable, Sendable {
        public let pattern: String
        public let direction: Direction

        public init(pattern: String, direction: Direction) {
            self.pattern = pattern
            self.direction = direction
        }
    }

    /// The last `f`/`F`/`t`/`T` target. Field names mirror `Motion.find` so
    /// the planner copies them across directly.
    struct FindMemory: Equatable, Sendable {
        public let character: Character
        public let direction: Direction
        public let beforeCharacter: Bool

        public init(character: Character, direction: Direction, beforeCharacter: Bool) {
            self.character = character
            self.direction = direction
            self.beforeCharacter = beforeCharacter
        }
    }

    /// What `.` replays, kept in the shape `.` overrides it: `3.` replaces
    /// the count wholesale and `"x.` the register, so both stay separate
    /// from the body. The body is the count/register-stripped key sequence —
    /// including any Insert-mode payload and terminating Esc — and re-enters
    /// the engine through the ordinary Raw → Logical → Physical pipeline.
    struct ChangeMemory: Equatable, Sendable {
        public let body: String
        public let count: Int?
        public let register: Register?

        public init(body: String, count: Int? = nil, register: Register? = nil) {
            self.body = body
            self.count = count
            self.register = register
        }
    }
}

// MARK: - Registers

public extension VimState {
    /// Stored register contents. Storage only — the routing lore (unnamed
    /// mirroring, the 1–9 delete ring, `0` staying yank-only, uppercase
    /// append) belongs to the reducer, so it exists in exactly one place.
    struct Registers: Equatable, Sendable {
        /// The unnamed register `"`, written by every yank and delete. The
        /// ONLY slot that can hold a pasteboard marker: a marker is truthful
        /// only while it denotes the *most recent* blind capture — which is
        /// exactly what the pasteboard holds. A second marker anywhere else
        /// would denote an older capture the pasteboard no longer has.
        public var unnamed: RegisterSlot?

        /// a–z. Uppercase names are the append spelling of the same slots.
        public var named: [Character: RegisterContent]

        /// Index n is register "n: 0 is the yank register, 1–9 the delete
        /// ring. Always exactly ten entries.
        public var numbered: [RegisterContent?]

        /// The small-delete register `-`: deletes of less than one line.
        public var smallDelete: RegisterContent?

        public init(
            unnamed: RegisterSlot? = nil,
            named: [Character: RegisterContent] = [:],
            numbered: [RegisterContent?] = Array(repeating: nil, count: 10),
            smallDelete: RegisterContent? = nil
        ) {
            self.unnamed = unnamed
            self.named = named
            self.numbered = numbered
            self.smallDelete = smallDelete
        }
    }
}

public extension VimState.Session {
    /// Read-side register routing. Write-side routing arrives with the
    /// reducer.
    ///
    /// `+` and `*` return `nil` here deliberately: the pasteboard is state
    /// macOS *does* have, so the physical layer must route those names
    /// before consulting `VimState` (and only ever *consumes* the pasteboard
    /// via a synthesized ⌘V — never a direct read, which would race the
    /// app's asynchronous processing of the ⌘X that filled it). The black
    /// hole `_` reads empty; `%`, `:`, and `=` are unsupported.
    func register(_ name: Character) -> RegisterSlot? {
        switch name {
        case "\"":
            return registers.unnamed
        case "a"..."z":
            return registers.named[name].map { .content($0) }
        case "A"..."Z":
            guard let lowered = name.lowercased().first else { return nil }
            return registers.named[lowered].map { .content($0) }
        case "0"..."9":
            guard let digit = name.wholeNumberValue, registers.numbered.indices.contains(digit) else {
                return nil
            }
            return registers.numbered[digit].map { .content($0) }
        case "-":
            return registers.smallDelete.map { .content($0) }
        case "/":
            return lastSearch.map { .content(RegisterContent(text: $0.pattern, wise: .character)) }
        case ".":
            return lastInsert.map { .content(RegisterContent(text: $0, wise: .character)) }
        default:
            return nil
        }
    }
}

// MARK: - Recorder

/// On the Optional, because an unbound binding has a mode to report and the runtime
/// only ever holds one of these.
extension Optional where Wrapped == VimState.Mode {
    var traceName: String {
        switch self {
        case .none: return "unbound"
        case .normal: return "normal"
        case .insert: return "insert"
        case .replace: return "replace"
        case .visual: return "visual"
        }
    }
}
