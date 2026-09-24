/// One concrete executable action. This is the machine code of the engine:
/// offsets, chords, pasteboard transactions, and state commits — nothing
/// symbolic left. The executor runs steps in order; a failed `settle` ends the
/// run, and only the residency commits behind it still land.
public enum PhysicalStep: Equatable, Sendable {
    /// AX: set the selected range (UTF-16 units; an empty range is the caret).
    case setSelection(Range<Int>)

    /// AX: replace the selection with literal text; `""` deletes it.
    case replaceSelection(String)

    /// Post a chord `count` times.
    case press(Chord, count: Int)

    /// Type text as synthesized keystrokes (replaces any selection).
    case typeText(String)

    /// Post ⌘X — the field cuts its selection to the pasteboard, which IS
    /// the register (see `TextPayload.pasteboard`). Fire-and-forget:
    /// nothing read back, nothing waited on, silence on failure.
    case clipboardCut

    /// Post ⌘C — copy without mutating. Fire-and-forget, as above.
    case clipboardCopy

    /// Set pasteboard → ⌘V → return (restore is deferred executor hygiene).
    /// `nil` pastes whatever is on the pasteboard as-is (registers `+`/`*`
    /// and pasteboard markers), with no set and no restore.
    case clipboardInsert(String?)

    /// AX: read the selected text into the slot without touching anything.
    case captureSelectedText(into: CaptureSlot)

    /// Wait for the field to converge on the planner's prediction; on timeout,
    /// ring and end the run, sparing only residency. Follows an **AX write** —
    /// non-convergence means the write silently didn't take.
    case settle(Expectation)

    /// The best-effort twin of `settle`, following a **blind** action
    /// (synthesized keys). It polls the same way — so a later step that reads
    /// AX state still sees the action land — but on timeout it **proceeds**
    /// rather than aborting, and never rings. A blind action's exact result
    /// was never ours to guarantee, so a mismatch is not a failure: it must
    /// not take down the mode change that follows a blind `ciw`/`o`/`s`.
    case softSettle(Expectation)

    /// Hand an effect to the reducer (capture slots resolved to literals).
    case commit(VimEffect)

    /// The rest of the plan per reading of the field; the executor runs the lowest world the settles still match.
    case branch([Branch])

    /// Signal invalidity; changes nothing. A plan that cannot be realized
    /// in this field is exactly `[.bell]`.
    case bell
}

public extension PhysicalStep {
    /// Whether executing this step changes the field's text content. Sole
    /// consumer: dot-worthiness — the runtime records a change body only
    /// for plans that mutate.
    var mutatesText: Bool {
        switch self {
        case .replaceSelection, .typeText, .clipboardInsert, .clipboardCut:
            return true
        case .press(let chord, _):
            return chord.mutatesText
        case .setSelection, .clipboardCopy, .captureSelectedText, .settle, .softSettle, .commit, .bell:
            return false
        case .branch(let branches):
            return branches.contains { $0.steps.contains(where: \.mutatesText) }
        }
    }
}

/// The continuation of the worlds whose keys agree from here; world 0 reads `AXValue` offsets (see `PhysicalPlanner`).
public struct Branch: Equatable, Sendable {
    public let worlds: Set<Int>
    public let steps: [PhysicalStep]

    public init(worlds: Set<Int>, steps: [PhysicalStep]) {
        self.worlds = worlds
        self.steps = steps
    }

    /// The branch holding the lowest world the field's answers still match (nil: every world), else the first.
    public static func chosen(from branches: [Branch], consistent: Set<Int>?) -> Branch? {
        let lowest = branches.flatMap(\.worlds).filter { consistent?.contains($0) ?? true }.min()
        return branches.first { lowest.map($0.worlds.contains) ?? false } ?? branches.first
    }
}

// MARK: - Chords

/// A symbolic keystroke. Keycodes are the runtime's business; the pure
/// layer never speaks hardware.
public struct Chord: Equatable, Hashable, Sendable {
    public let key: Key
    public let modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public var shifted: Chord {
        Chord(key, modifiers.union(.shift))
    }

    /// Typed keys mutate; ⌘-shortcuts do not — deliberately, so undo is not
    /// a "change" for dot purposes. Paste always goes through
    /// `clipboardInsert`, never a bare chord.
    public var mutatesText: Bool {
        switch key {
        case .delete, .forwardDelete, .enter:
            return true
        case .character:
            return modifiers.subtracting(.shift).isEmpty
        case .arrowLeft, .arrowRight, .arrowUp, .arrowDown, .escape:
            return false
        }
    }
}

public enum Key: Equatable, Hashable, Sendable {
    case arrowLeft
    case arrowRight
    case arrowUp
    case arrowDown
    case delete
    case forwardDelete
    case enter
    case escape
    case character(Character)
}

public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let command = Modifiers(rawValue: 1 << 2)
    public static let control = Modifiers(rawValue: 1 << 3)
}

/// The Cocoa navigation vocabulary the planner speaks.
public extension Chord {
    static let left = Chord(.arrowLeft)
    static let right = Chord(.arrowRight)
    static let up = Chord(.arrowUp)
    static let down = Chord(.arrowDown)
    static let wordLeft = Chord(.arrowLeft, [.option])
    static let wordRight = Chord(.arrowRight, [.option])
    static let lineStart = Chord(.arrowLeft, [.command])
    static let lineEnd = Chord(.arrowRight, [.command])
    static let documentStart = Chord(.arrowUp, [.command])
    static let documentEnd = Chord(.arrowDown, [.command])
    static let selectRight = Chord(.arrowRight, [.shift])
    static let selectDown = Chord(.arrowDown, [.shift])
    static let selectWordRight = Chord(.arrowRight, [.shift, .option])
    static let selectLineEnd = Chord(.arrowRight, [.shift, .command])
    static let selectLeft = Chord(.arrowLeft, [.shift])
    static let paragraphStart = Chord(.character("a"), [.control])
    static let paragraphEnd = Chord(.character("e"), [.control])
    static let deleteBack = Chord(.delete)
    static let undo = Chord(.character("z"), [.command])
    static let redo = Chord(.character("z"), [.command, .shift])
}

// MARK: - Expectations

/// Where a settle expects the selection: a prediction, or a relation to a read for keys the app lands.
public enum Landing: Equatable, Sendable {
    case exact(Range<Int>)
    case caretAfter(Int, strict: Bool)
    case caretBefore(Int, strict: Bool)
    /// A non-empty selection with one end at the offset, reaching forward or backward from it.
    case extending(from: Int, forward: Bool)
    /// A non-empty selection that contains the character after the offset.
    case covering(Int)

    public func matches(_ observed: Range<Int>) -> Bool {
        switch self {
        case .exact(let range):
            return observed == range
        case .caretAfter(let offset, let strict):
            return observed.isEmpty && (strict ? observed.lowerBound > offset : observed.lowerBound >= offset)
        case .caretBefore(let offset, let strict):
            return observed.isEmpty && (strict ? observed.lowerBound < offset : observed.lowerBound <= offset)
        case .extending(let offset, let forward):
            return !observed.isEmpty && (forward ? observed.lowerBound == offset : observed.upperBound == offset)
        case .covering(let offset):
            return observed.lowerBound <= offset && offset < observed.upperBound
        }
    }
}

/// The planner's prediction of the field after a step, checked by the
/// settle engine. Fields are optional in the shape of what is readable.
public struct Expectation: Equatable, Sendable {
    public let landing: Landing?
    public let length: Int?

    /// The world `landing` and `length` predict.
    public var world = 0

    /// The same settle as other worlds read it.
    public var alternatives: [Alternative]

    /// The native key this settle checks.
    public var blame: Blame?

    public struct Alternative: Equatable, Sendable {
        public let world: Int
        public let selection: Range<Int>?
        public let length: Int?

        public init(world: Int, selection: Range<Int>?, length: Int?) {
            self.world = world
            self.selection = selection
            self.length = length
        }
    }

    /// A failed settle demotes `capability` only when the field still reads as one of `unmoved`: the key did nothing.
    public struct Blame: Equatable, Sendable {
        public let capability: Capability
        public let unmoved: [Range<Int>]

        public init(capability: Capability, unmoved: [Range<Int>]) {
            self.capability = capability
            self.unmoved = unmoved
        }
    }

    public init(selection: Range<Int>? = nil, length: Int? = nil) {
        self.init(landing: selection.map(Landing.exact), length: length)
    }

    public init(landing: Landing?, length: Int? = nil, alternatives: [Alternative] = [], blame: Blame? = nil) {
        self.landing = landing
        self.length = length
        self.alternatives = alternatives
        self.blame = blame
    }

    public var selection: Range<Int>? {
        guard case .exact(let range)? = landing else { return nil }
        return range
    }

    var readsSelection: Bool { landing != nil || alternatives.contains { $0.selection != nil } }
    var readsLength: Bool { length != nil || alternatives.contains { $0.length != nil } }

    /// Arguments are what the field answered; `nil` is a non-answer and satisfies nothing.
    public func matches(selection observed: Range<Int>?, length observedLength: Int?) -> Bool {
        !worlds(matching: observed, length: observedLength).isEmpty
    }

    public func worlds(matching observed: Range<Int>?, length observedLength: Int?) -> Set<Int> {
        var worlds: Set<Int> = []
        if Self.meets(landing, length, observed, observedLength) { worlds.insert(world) }
        for alternative in alternatives
        where Self.meets(alternative.selection.map(Landing.exact), alternative.length, observed, observedLength) {
            worlds.insert(alternative.world)
        }
        return worlds
    }

    /// The key a non-converged settle blames, given the last selection it read.
    public func blamed(observed: Range<Int>?) -> Capability? {
        guard let blame, let observed, blame.unmoved.contains(observed) else { return nil }
        return blame.capability
    }

    private static func meets(
        _ landing: Landing?, _ length: Int?, _ observed: Range<Int>?, _ observedLength: Int?
    ) -> Bool {
        if let landing {
            guard let observed, landing.matches(observed) else { return false }
        }
        if let length, observedLength != length { return false }
        return true
    }
}

// MARK: - Recorder

extension Expectation {
    /// `sel=4..9 len=15`, then `or w1 sel=3..8 len=15` per alternative. Also renders an observation.
    var traceFields: String {
        var line = (world == 0 ? "" : "w\(world) ") + Self.fields(landing.map(\.traceName) ?? "nil", length)
        for alternative in alternatives {
            let selection = alternative.selection.map { Landing.exact($0).traceName } ?? "nil"
            line += " or w\(alternative.world) " + Self.fields(selection, alternative.length)
        }
        return line
    }

    private static func fields(_ selection: String, _ length: Int?) -> String {
        "sel=\(selection) len=\(length.map(String.init) ?? "nil")"
    }
}

extension Landing {
    var traceName: String {
        switch self {
        case .exact(let range): return "\(range.lowerBound)..\(range.upperBound)"
        case .caretAfter(let offset, let strict): return (strict ? ">" : ">=") + "\(offset)"
        case .caretBefore(let offset, let strict): return (strict ? "<" : "<=") + "\(offset)"
        case .extending(let offset, let forward): return forward ? "\(offset)->" : "<-\(offset)"
        case .covering(let offset): return "~\(offset)"
        }
    }
}

extension PhysicalStep {
    /// Its letter in the plan alphabet — see the README; `P3` is one press posting three times.
    var traceCode: String {
        switch self {
        case .setSelection: return "W"
        case .replaceSelection: return "R"
        case .press(_, let count): return count > 1 ? "P\(count)" : "P"
        case .typeText: return "T"
        case .clipboardCut: return "X"
        case .clipboardCopy: return "Y"
        case .clipboardInsert: return "V"
        case .captureSelectedText: return "G"
        case .settle: return "!"
        case .softSettle: return "?"
        case .commit: return "C"
        case .bell: return "B"
        case .branch(let branches):
            return "{" + branches.map { $0.steps.map(\.traceCode).joined() }.joined(separator: "|") + "}"
        }
    }
}
