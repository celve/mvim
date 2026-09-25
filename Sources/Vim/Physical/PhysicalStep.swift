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
        }
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
    static let selectLeft = Chord(.arrowLeft, [.shift])
    static let selectRight = Chord(.arrowRight, [.shift])
    static let selectDown = Chord(.arrowDown, [.shift])
    static let selectWordRight = Chord(.arrowRight, [.shift, .option])
    static let selectLineEnd = Chord(.arrowRight, [.shift, .command])
    static let paragraphStart = Chord(.character("a"), [.control])
    static let paragraphEnd = Chord(.character("e"), [.control])
    static let selectAll = Chord(.character("a"), [.command])
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

    public func matches(_ observed: Range<Int>) -> Bool {
        switch self {
        case .exact(let range):
            return observed == range
        case .caretAfter(let offset, let strict):
            return observed.isEmpty && (strict ? observed.lowerBound > offset : observed.lowerBound >= offset)
        case .caretBefore(let offset, let strict):
            return observed.isEmpty && (strict ? observed.lowerBound < offset : observed.lowerBound <= offset)
        }
    }
}

/// The planner's prediction of the field after a step, checked by the
/// settle engine. Fields are optional in the shape of what is readable.
///
/// `selection` is in the field's own offsets; `length` is always `AXValue`'s.
public struct Expectation: Equatable, Sendable {
    public let landing: Landing?
    public let length: Int?

    /// Which side of a paragraph boundary the selection's upper end is on,
    /// where its field offset names both; only a text-marker read can tell.
    public let edge: Edge?

    public enum Edge: Equatable, Sendable {
        case paragraphEnd
        case paragraphStart
    }

    /// `AXSelectedText`: offsets alone pass a selection Chromium read shifted (LIN-1533), its text does not.
    public let selectedText: String?

    /// The native key this settle checks.
    public var blame: Blame?

    /// A failed settle demotes `capability` when the field still reads as one of `unmoved` (the key did
    /// nothing), or when a key that only ever leaves a caret left a selection.
    public struct Blame: Equatable, Sendable {
        public let capability: Capability
        public let unmoved: [Range<Int>]
        public let leavesCaret: Bool

        public init(capability: Capability, unmoved: [Range<Int>], leavesCaret: Bool = false) {
            self.capability = capability
            self.unmoved = unmoved
            self.leavesCaret = leavesCaret
        }
    }

    public init(selection: Range<Int>? = nil, length: Int? = nil, edge: Edge? = nil, selectedText: String? = nil) {
        self.init(landing: selection.map(Landing.exact), length: length, edge: edge, selectedText: selectedText)
    }

    public init(
        landing: Landing?, length: Int? = nil, edge: Edge? = nil, blame: Blame? = nil, selectedText: String? = nil
    ) {
        self.landing = landing
        self.length = length
        self.edge = edge
        self.blame = blame
        self.selectedText = selectedText
    }

    public var selection: Range<Int>? {
        guard case .exact(let range)? = landing else { return nil }
        return range
    }

    /// Arguments are what the field answered; `nil` is a non-answer and satisfies nothing.
    public func matches(
        selection observed: Range<Int>?, length observedLength: Int?, selectedText observedText: String? = nil
    ) -> Bool {
        if let landing {
            guard let observed, landing.matches(observed) else { return false }
        }
        if let length, observedLength != length { return false }
        if let selectedText, observedText != selectedText { return false }
        return true
    }

    /// The key a non-converged settle blames, given the last selection it read.
    public func blamed(observed: Range<Int>?) -> Capability? {
        guard let blame, let observed,
              blame.unmoved.contains(observed) || (blame.leavesCaret && !observed.isEmpty) else { return nil }
        return blame.capability
    }
}

// MARK: - Recorder

extension Expectation {
    /// `sel=4..9 len=15`, then `text=(5)` — a length, never the text. Also renders an observation, which is the
    /// same shape.
    var traceFields: String {
        let selection = landing.map(\.traceName) ?? "nil"
        var fields = "sel=\(selection) len=\(length.map(String.init) ?? "nil")"
        fields += selectedText.map { " text=(\($0.utf16.count))" } ?? ""
        if let edge {
            fields += edge == .paragraphStart ? " edge=start" : " edge=end"
        }
        return fields
    }
}

extension Landing {
    var traceName: String {
        switch self {
        case .exact(let range): return "\(range.lowerBound)..\(range.upperBound)"
        case .caretAfter(let offset, let strict): return (strict ? ">" : ">=") + "\(offset)"
        case .caretBefore(let offset, let strict): return (strict ? "<" : "<=") + "\(offset)"
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
        }
    }
}
