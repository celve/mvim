/// One concrete executable action. This is the machine code of the engine:
/// offsets, chords, pasteboard transactions, and state commits — nothing
/// symbolic left. The executor runs steps in order and aborts the remainder
/// when a `settle` fails.
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

    /// Wait for the field to converge on the planner's prediction; on
    /// timeout, abort the rest of the plan and ring.
    case settle(Expectation)

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
        case .setSelection, .clipboardCopy, .captureSelectedText, .settle, .commit, .bell:
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
    static let selectRight = Chord(.arrowRight, [.shift])
    static let selectDown = Chord(.arrowDown, [.shift])
    static let selectWordRight = Chord(.arrowRight, [.shift, .option])
    static let selectLineEnd = Chord(.arrowRight, [.shift, .command])
    static let deleteBack = Chord(.delete)
    static let undo = Chord(.character("z"), [.command])
    static let redo = Chord(.character("z"), [.command, .shift])
}

// MARK: - Expectations

/// The planner's prediction of the field after a step, checked by the
/// settle engine. Fields are optional in the shape of what is readable.
public struct Expectation: Equatable, Sendable {
    public let selection: Range<Int>?
    public let length: Int?

    public init(selection: Range<Int>? = nil, length: Int? = nil) {
        self.selection = selection
        self.length = length
    }
}
