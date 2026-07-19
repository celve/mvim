/// A register name (`"a`, `"_`, `"+` …). Naming only — contents live in
/// `VimState`, write routing in its reducer, and `+`/`*` on the pasteboard.
public struct Register: Equatable, Hashable, Sendable {
    public let name: Character

    public init(_ name: Character) {
        self.name = name
    }
}

/// Register text plus the wise-ness that decides how a put rejoins the
/// text — the part of a yank macOS's pasteboard model has no slot for.
public struct RegisterContent: Equatable, Hashable, Sendable {
    public let text: String
    public let wise: Wise

    public init(text: String, wise: Wise) {
        self.text = text
        self.wise = wise
    }
}

public enum Wise: Equatable, Hashable, Sendable {
    case character
    case line

    /// Rectangular yanks remember their width because short lines pad when
    /// put back.
    case block(width: Int)
}

/// What a register slot holds: engine-stored text, or a marker meaning "the
/// content is whatever the macOS pasteboard holds" — vim's
/// `clipboard=unnamed`, for blind fields where text can never be read. Only
/// the wise survives in the engine; the text lives in macOS.
public enum RegisterSlot: Equatable, Hashable, Sendable {
    case content(RegisterContent)
    case pasteboard(wise: Wise)
}

/// How a put places register content relative to the caret.
public struct PutAction: Equatable, Hashable, Sendable {
    public let position: PutPosition
    public let moveCursorAfterText: Bool
    public let adjustIndent: Bool

    public init(
        position: PutPosition,
        moveCursorAfterText: Bool = false,
        adjustIndent: Bool = false
    ) {
        self.position = position
        self.moveCursorAfterText = moveCursorAfterText
        self.adjustIndent = adjustIndent
    }
}

public enum PutPosition: String, Equatable, Hashable, Sendable {
    case before
    case after
}
