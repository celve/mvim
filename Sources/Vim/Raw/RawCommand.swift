/// A syntax-level representation of a Vim command.
///
/// `RawCommand` deliberately does not depend on editor state. For example, `i`
/// always means "enter Insert mode before the cursor" here; deciding whether
/// that action is currently legal belongs to the logical planning layer.
///
/// Parsing is total: an empty or partially typed command is `.incomplete`, and
/// a command supplied by a mapping or plug-in is `.custom`. This means callers
/// never need to discard input merely because this file does not know a future
/// Vim command.
public struct RawCommand: Equatable, Hashable, Sendable {
    public let source: String
    public let register: Register?
    public let count: Int?
    public let intent: Intent

    /// Parses one complete (or currently incomplete) Normal-mode command.
    ///
    /// Key notation such as `<Esc>`, `<C-r>`, and `<C-w>` is accepted in
    /// addition to ordinary characters. A literal escape character is also
    /// recognized.
    public init(_ source: String) {
        let parsed = Parser.parse(source)
        self.source = source
        self.register = parsed.register
        self.count = parsed.count
        self.intent = parsed.intent
    }

    public static func parse(_ source: String) -> RawCommand {
        RawCommand(source)
    }

    /// Vim treats an omitted count as one.
    public var effectiveCount: Int { count ?? 1 }

    public var isComplete: Bool {
        if case .incomplete = intent { return false }
        return true
    }
}

// MARK: - Public command model

public extension RawCommand {
    enum Intent: Equatable, Hashable, Sendable {
        case modeChange(ModeChange)
        case motion(Motion)
        case operatorCommand(OperatorCommand)
        case edit(Edit)
        case search(Search)
        case commandLine(CommandLine)
        case history(HistoryAction)
        case `repeat`(RepeatAction)
        case macro(MacroAction)
        case mark(MarkAction)
        case view(ViewAction)
        case window(WindowAction)
        case fold(FoldAction)
        case incomplete(IncompleteCommand)

        /// A mapping, plug-in command, or built-in command not yet given a
        /// more specific semantic representation.
        case custom(keys: String)
    }

    enum ModeChange: Equatable, Hashable, Sendable {
        case normal
        case insert(InsertPosition)
        case replace
        case virtualReplace
        case visual(VisualSelection)
        case commandLine
        case ex
    }

    enum InsertPosition: String, Equatable, Hashable, Sendable {
        case beforeCursor
        case afterCursor
        case firstNonBlank
        case endOfLine
        case newLineAbove
        case newLineBelow
        case lastInsert
    }

    enum VisualSelection: String, Equatable, Hashable, Sendable {
        case character
        case line
        case block
        case previous
    }

    struct OperatorCommand: Equatable, Hashable, Sendable {
        public let kind: OperatorKind
        public let targetCount: Int?
        public let target: OperatorTarget

        public init(kind: OperatorKind, targetCount: Int? = nil, target: OperatorTarget) {
            self.kind = kind
            self.targetCount = targetCount
            self.target = target
        }
    }

    enum OperatorKind: String, Equatable, Hashable, Sendable {
        case delete
        case change
        case yank
        case shiftRight
        case shiftLeft
        case indent
        case swapCase
        case lowercase
        case uppercase
        case filter
        case format
        case formatKeepCursor
        case createFold
    }

    enum OperatorTarget: Equatable, Hashable, Sendable {
        case pending
        case line
        case motion(Motion)
        case textObject(TextObject)
        case custom(keys: String)
    }

    enum Edit: Equatable, Hashable, Sendable {
        case deleteCharacter(Direction)
        case substituteCharacter
        case substituteLine
        case changeToLineEnd
        case deleteToLineEnd
        case yankLine
        case replaceCharacter(Character)
        case joinLines(keepWhitespace: Bool)
        case put(PutAction)
        case toggleCase
        case increment
        case decrement
    }

    struct CommandLine: Equatable, Hashable, Sendable {
        public let command: String
        public let isSubmitted: Bool

        public init(command: String, isSubmitted: Bool) {
            self.command = command
            self.isSubmitted = isSubmitted
        }
    }

    enum RepeatAction: Equatable, Hashable, Sendable {
        case lastChange
        case lastSubstitution(withFlags: Bool)
        case lastExCommand
    }

    enum MacroAction: Equatable, Hashable, Sendable {
        case startRecording(register: Character)
        case stopRecording
        case play(register: Character)
        case replayLast
    }

    enum MarkAction: Equatable, Hashable, Sendable {
        case set(Character)
        case delete(Character)
        case deleteAllLocal
    }

    enum ViewAction: Equatable, Hashable, Sendable {
        case cursorAtTop(firstNonBlank: Bool)
        case cursorAtCenter(firstNonBlank: Bool)
        case cursorAtBottom(firstNonBlank: Bool)
        case horizontal(Direction, toEdge: Bool)
        case custom(keys: String)
    }

    struct WindowAction: Equatable, Hashable, Sendable {
        /// The keys following `<C-w>`. Window commands are intentionally kept
        /// as keys because Vim and plug-ins add to this namespace freely.
        public let keys: String

        public init(keys: String) {
            self.keys = keys
        }
    }

    enum FoldAction: Equatable, Hashable, Sendable {
        case open(recursive: Bool)
        case close(recursive: Bool)
        case toggle(recursive: Bool)
        case delete(recursive: Bool)
        case openAll
        case closeAll
        case enable
        case disable
        case toggleEnabled
        case custom(keys: String)
    }

    enum IncompleteCommand: Equatable, Hashable, Sendable {
        case command
        case register
        case operatorTarget(OperatorKind)
        case characterArgument(prefix: String)
        case macroRegister
        case markName
        case search(direction: Direction, pattern: String)
        case commandLine(String)
        case namespace(String)
    }
}

// MARK: - Key spellings

public extension TextObject {
    /// The two-key text-object spelling (`iw`, `ap`, `i(`, …). Lives in the
    /// Raw layer because Model stays key-blind; public because Visual mode
    /// uses the same spelling outside operator position, where the
    /// Normal-mode parser can only classify the keys as `.custom`.
    init?(keys: String) {
        guard keys.count == 2, let scopeKey = keys.first, let objectKey = keys.last else {
            return nil
        }
        let scope: TextObjectScope
        switch scopeKey {
        case "i": scope = .inner
        case "a": scope = .around
        default: return nil
        }

        let kind: TextObjectKind
        switch objectKey {
        case "w": kind = .word(bigWord: false)
        case "W": kind = .word(bigWord: true)
        case "s": kind = .sentence
        case "p": kind = .paragraph
        case "b", "(", ")": kind = .block(delimiter: "(")
        case "B", "{", "}": kind = .block(delimiter: "{")
        case "[", "]": kind = .block(delimiter: "[")
        case "<", ">": kind = .block(delimiter: "<")
        case "\"", "'", "`": kind = .quote(objectKey)
        case "t": kind = .tag
        default: kind = .custom(objectKey)
        }
        self.init(scope: scope, kind: kind)
    }
}

// MARK: - Parser

private extension RawCommand {
    struct Parsed {
        let register: Register?
        let count: Int?
        let intent: Intent
    }

    enum Parser {
        static func parse(_ source: String) -> Parsed {
            if source.isEmpty {
                return Parsed(register: nil, count: nil, intent: .incomplete(.command))
            }

            var keys = source
            var register: Register?
            var count: Int?

            // Vim accepts count and register prefixes in either order and
            // repeated (`2"a3dd`); successive counts multiply.
            prefixes: while let first = keys.first {
                switch first {
                case "\"":
                    guard keys.count >= 2 else {
                        return Parsed(register: register, count: count, intent: .incomplete(.register))
                    }
                    let nameIndex = keys.index(after: keys.startIndex)
                    register = Register(keys[nameIndex])
                    keys = String(keys[keys.index(after: nameIndex)...])
                case "1"..."9":
                    let countResult = consumeCount(from: keys)
                    count = multiply(count, countResult.count)
                    keys = countResult.remainder
                default:
                    break prefixes
                }
            }

            guard !keys.isEmpty else {
                return Parsed(register: register, count: count, intent: .incomplete(.command))
            }

            return Parsed(register: register, count: count, intent: parseIntent(keys))
        }

        static func parseIntent(_ keys: String) -> Intent {
            if let mode = parseModeChange(keys) {
                return .modeChange(mode)
            }

            if let commandLine = parseCommandLine(keys) {
                return commandLine
            }

            if let search = parseSearch(keys) {
                return search
            }

            if let macro = parseMacro(keys) {
                return macro
            }

            if let mark = parseMark(keys) {
                return mark
            }

            if let edit = parseEdit(keys) {
                return .edit(edit)
            }

            if let history = parseHistory(keys) {
                return .history(history)
            }

            if let repeatAction = parseRepeat(keys) {
                return .repeat(repeatAction)
            }

            if let window = parseWindow(keys) {
                return window
            }

            if let motion = parseMotion(keys) {
                return .motion(motion)
            }

            if let operation = parseOperator(keys) {
                return operation
            }

            if let foldOrView = parseFoldOrView(keys) {
                return foldOrView
            }

            if ["r", "f", "F", "t", "T", "'", "`"].contains(keys) {
                return .incomplete(.characterArgument(prefix: keys))
            }

            if ["g", "[", "]", "Z"].contains(keys) {
                return .incomplete(.namespace(keys))
            }

            return .custom(keys: keys)
        }

        static func parseModeChange(_ keys: String) -> ModeChange? {
            switch keys {
            case "i": return .insert(.beforeCursor)
            case "a": return .insert(.afterCursor)
            case "I": return .insert(.firstNonBlank)
            case "A": return .insert(.endOfLine)
            case "O": return .insert(.newLineAbove)
            case "o": return .insert(.newLineBelow)
            case "gi": return .insert(.lastInsert)
            case "R": return .replace
            case "gR": return .virtualReplace
            case "v": return .visual(.character)
            case "V": return .visual(.line)
            case "<C-v>", "<C-V>", "\u{16}": return .visual(.block)
            case "gv": return .visual(.previous)
            case ":": return .commandLine
            case "Q": return .ex
            case "<Esc>", "<C-[>", "\u{1B}": return .normal
            default: return nil
            }
        }

        static func parseCommandLine(_ keys: String) -> Intent? {
            guard keys.first == ":" else { return nil }
            let body = String(keys.dropFirst())
            let submitted = removingSubmitKey(from: body)
            if submitted.wasRemoved {
                return .commandLine(CommandLine(command: submitted.text, isSubmitted: true))
            }
            return .commandLine(CommandLine(command: body, isSubmitted: false))
        }

        static func parseSearch(_ keys: String) -> Intent? {
            if keys.first == "/" || keys.first == "?" {
                let direction: Direction = keys.first == "/" ? .forward : .backward
                let body = String(keys.dropFirst())
                let submitted = removingSubmitKey(from: body)
                let search = Search(
                    direction: direction,
                    pattern: submitted.text,
                    isSubmitted: submitted.wasRemoved
                )
                return .search(search)
            }

            switch keys {
            case "n":
                return .search(Search(direction: .forward, isSubmitted: true))
            case "N":
                return .search(Search(direction: .backward, isSubmitted: true))
            case "*":
                return .search(Search(direction: .forward, isSubmitted: true, wordUnderCursor: .wholeWord))
            case "#":
                return .search(Search(direction: .backward, isSubmitted: true, wordUnderCursor: .wholeWord))
            case "g*":
                return .search(Search(direction: .forward, isSubmitted: true, wordUnderCursor: .partialWord))
            case "g#":
                return .search(Search(direction: .backward, isSubmitted: true, wordUnderCursor: .partialWord))
            default:
                return nil
            }
        }

        static func parseMacro(_ keys: String) -> Intent? {
            if keys == "@:" {
                return .repeat(.lastExCommand)
            }
            if ["q:", "q/", "q?"].contains(keys) {
                return .custom(keys: keys)
            }
            if keys == "q" {
                return .macro(.stopRecording)
            }
            if keys == "@" {
                return .incomplete(.macroRegister)
            }
            if keys == "@@" {
                return .macro(.replayLast)
            }
            if keys.first == "q", keys.count == 2, let name = keys.last {
                return .macro(.startRecording(register: name))
            }
            if keys.first == "@", keys.count == 2, let name = keys.last {
                return .macro(.play(register: name))
            }
            return nil
        }

        static func parseMark(_ keys: String) -> Intent? {
            if keys == "m" {
                return .incomplete(.markName)
            }
            if keys.first == "m", keys.count == 2, let name = keys.last {
                return .mark(.set(name))
            }
            return nil
        }

        static func parseEdit(_ keys: String) -> Edit? {
            switch keys {
            case "x", "<Del>": return .deleteCharacter(.forward)
            case "X": return .deleteCharacter(.backward)
            case "s": return .substituteCharacter
            case "S": return .substituteLine
            case "C": return .changeToLineEnd
            case "D": return .deleteToLineEnd
            case "Y": return .yankLine
            case "J": return .joinLines(keepWhitespace: false)
            case "gJ": return .joinLines(keepWhitespace: true)
            case "p": return .put(PutAction(position: .after))
            case "P": return .put(PutAction(position: .before))
            case "gp": return .put(PutAction(position: .after, moveCursorAfterText: true))
            case "gP": return .put(PutAction(position: .before, moveCursorAfterText: true))
            case "]p": return .put(PutAction(position: .after, adjustIndent: true))
            case "[p": return .put(PutAction(position: .before, adjustIndent: true))
            case "~": return .toggleCase
            case "<C-a>", "\u{01}": return .increment
            case "<C-x>", "\u{18}": return .decrement
            default:
                if keys.first == "r", keys.count == 2, let replacement = keys.last {
                    return .replaceCharacter(replacement)
                }
                return nil
            }
        }

        static func parseHistory(_ keys: String) -> HistoryAction? {
            switch keys {
            case "u": return .undo
            case "<C-r>", "\u{12}": return .redo
            case "g-": return .olderTextState
            case "g+": return .newerTextState
            default: return nil
            }
        }

        static func parseRepeat(_ keys: String) -> RepeatAction? {
            switch keys {
            case ".": return .lastChange
            case "&": return .lastSubstitution(withFlags: false)
            case "g&": return .lastSubstitution(withFlags: true)
            case "@:": return .lastExCommand
            default: return nil
            }
        }

        static func parseWindow(_ keys: String) -> Intent? {
            let prefixes = ["<C-w>", "<C-W>", "\u{17}"]
            guard let prefix = prefixes.first(where: { keys.hasPrefix($0) }) else { return nil }
            let suffix = String(keys.dropFirst(prefix.count))
            if suffix.isEmpty {
                return .incomplete(.namespace(prefix))
            }
            return .window(WindowAction(keys: suffix))
        }

        static func parseFoldOrView(_ keys: String) -> Intent? {
            guard keys.first == "z" else { return nil }
            guard keys.count > 1 else { return .incomplete(.namespace("z")) }

            switch keys {
            case "zo": return .fold(.open(recursive: false))
            case "zO": return .fold(.open(recursive: true))
            case "zc": return .fold(.close(recursive: false))
            case "zC": return .fold(.close(recursive: true))
            case "za": return .fold(.toggle(recursive: false))
            case "zA": return .fold(.toggle(recursive: true))
            case "zd": return .fold(.delete(recursive: false))
            case "zD": return .fold(.delete(recursive: true))
            case "zR": return .fold(.openAll)
            case "zM": return .fold(.closeAll)
            case "zn": return .fold(.disable)
            case "zN": return .fold(.enable)
            case "zi": return .fold(.toggleEnabled)
            case "zt": return .view(.cursorAtTop(firstNonBlank: false))
            case "z<CR>", "z\r", "z\n": return .view(.cursorAtTop(firstNonBlank: true))
            case "zz", "z.": return .view(.cursorAtCenter(firstNonBlank: keys == "z."))
            case "zb": return .view(.cursorAtBottom(firstNonBlank: false))
            case "z-": return .view(.cursorAtBottom(firstNonBlank: true))
            case "zh": return .view(.horizontal(.left, toEdge: false))
            case "zl": return .view(.horizontal(.right, toEdge: false))
            case "zH": return .view(.horizontal(.left, toEdge: true))
            case "zL": return .view(.horizontal(.right, toEdge: true))
            default: return .custom(keys: keys)
            }
        }

        static func parseOperator(_ keys: String) -> Intent? {
            // `<...>` is Vim key/mapping notation, not the `<` operator.
            if keys.first == "<", keys.contains(">") {
                return nil
            }

            let operators: [(prefix: String, kind: OperatorKind, lineRepeat: String)] = [
                ("g~", .swapCase, "~"),
                ("gu", .lowercase, "u"),
                ("gU", .uppercase, "U"),
                ("gq", .format, "q"),
                ("gw", .formatKeepCursor, "w"),
                ("zf", .createFold, "f"),
                ("d", .delete, "d"),
                ("c", .change, "c"),
                ("y", .yank, "y"),
                (">", .shiftRight, ">"),
                ("<", .shiftLeft, "<"),
                ("=", .indent, "="),
                ("!", .filter, "!")
            ]

            guard let operation = operators.first(where: { keys.hasPrefix($0.prefix) }) else {
                return nil
            }

            var targetKeys = String(keys.dropFirst(operation.prefix.count))
            if targetKeys.isEmpty {
                return .incomplete(.operatorTarget(operation.kind))
            }

            let targetCountResult = consumeCount(from: targetKeys)
            let targetCount = targetCountResult.count
            targetKeys = targetCountResult.remainder
            if targetKeys.isEmpty {
                return .incomplete(.operatorTarget(operation.kind))
            }

            if ["f", "F", "t", "T", "'", "`", "i", "a"].contains(targetKeys) {
                return .incomplete(.operatorTarget(operation.kind))
            }

            if let searchMotion = parseSearchMotion(targetKeys) {
                return .operatorCommand(OperatorCommand(
                    kind: operation.kind,
                    targetCount: targetCount,
                    target: .motion(searchMotion)
                ))
            }

            // Doubling an operator makes it linewise; multi-key operators
            // accept both the short and full spelling (`guu` and `gugu`).
            let target: OperatorTarget
            if targetKeys == operation.lineRepeat || targetKeys == operation.prefix {
                target = .line
            } else if let textObject = TextObject(keys: targetKeys) {
                target = .textObject(textObject)
            } else if let motion = parseMotion(targetKeys) {
                target = .motion(motion)
            } else {
                target = .custom(keys: targetKeys)
            }

            return .operatorCommand(OperatorCommand(
                kind: operation.kind,
                targetCount: targetCount,
                target: target
            ))
        }

        static func parseMotion(_ keys: String) -> Motion? {
            switch keys {
            case "h", "<Left>", "<BS>": return .character(.left)
            case "l", "<Right>", " ": return .character(.right)
            case "j", "<Down>": return .line(.down, firstNonBlank: false)
            case "k", "<Up>": return .line(.up, firstNonBlank: false)
            case "gj": return .displayLine(.down)
            case "gk": return .displayLine(.up)
            case "+", "<CR>", "\r", "\n": return .line(.down, firstNonBlank: true)
            case "-": return .line(.up, firstNonBlank: true)
            case "w": return .word(.forward, end: false, bigWord: false)
            case "W": return .word(.forward, end: false, bigWord: true)
            case "e": return .word(.forward, end: true, bigWord: false)
            case "E": return .word(.forward, end: true, bigWord: true)
            case "b": return .word(.backward, end: false, bigWord: false)
            case "B": return .word(.backward, end: false, bigWord: true)
            case "ge": return .word(.backward, end: true, bigWord: false)
            case "gE": return .word(.backward, end: true, bigWord: true)
            case "0", "g0": return .lineStart(firstNonBlank: false)
            case "^", "g^": return .lineStart(firstNonBlank: true)
            case "$", "g$": return .lineEnd
            case "g_": return .lastNonBlank
            case "|": return .column
            case "gg": return .fileStart
            case "G": return .fileEnd
            case "H": return .screenLine(.top)
            case "M": return .screenLine(.middle)
            case "L": return .screenLine(.bottom)
            case "(": return .sentence(.backward)
            case ")": return .sentence(.forward)
            case "{": return .paragraph(.backward)
            case "}": return .paragraph(.forward)
            case "[[": return .section(.backward, .section)
            case "]]": return .section(.forward, .section)
            case "[]": return .section(.backward, .closeBrace)
            case "][": return .section(.forward, .openBrace)
            case "[m", "[M": return .section(.backward, keys == "[m" ? .methodStart : .methodEnd)
            case "]m", "]M": return .section(.forward, keys == "]m" ? .methodStart : .methodEnd)
            case "%": return .matchingItem
            case ";": return .repeatFind(oppositeDirection: false)
            case ",": return .repeatFind(oppositeDirection: true)
            case "<C-f>", "\u{06}": return .page(.forward, halfPage: false)
            case "<C-b>", "\u{02}": return .page(.backward, halfPage: false)
            case "<C-d>", "\u{04}": return .page(.forward, halfPage: true)
            case "<C-u>", "\u{15}": return .page(.backward, halfPage: true)
            case "<C-e>", "\u{05}": return .scrollLine(.forward)
            case "<C-y>", "\u{19}": return .scrollLine(.backward)
            default:
                if let find = parseFindMotion(keys) { return find }
                if let mark = parseMarkMotion(keys) { return mark }
                if let search = parseSearchMotion(keys) { return search }
                return nil
            }
        }

        static func parseSearchMotion(_ keys: String) -> Motion? {
            guard keys.first == "/" || keys.first == "?" else { return nil }
            let direction: Direction = keys.first == "/" ? .forward : .backward
            let body = String(keys.dropFirst())
            let submitted = removingSubmitKey(from: body)
            return .search(Search(
                direction: direction,
                pattern: submitted.text,
                isSubmitted: submitted.wasRemoved
            ))
        }

        static func parseFindMotion(_ keys: String) -> Motion? {
            guard keys.count == 2, let prefix = keys.first, let character = keys.last else {
                return nil
            }
            switch prefix {
            case "f": return .find(character: character, direction: .forward, beforeCharacter: false)
            case "F": return .find(character: character, direction: .backward, beforeCharacter: false)
            case "t": return .find(character: character, direction: .forward, beforeCharacter: true)
            case "T": return .find(character: character, direction: .backward, beforeCharacter: true)
            default: return nil
            }
        }

        static func parseMarkMotion(_ keys: String) -> Motion? {
            guard keys.count == 2, let prefix = keys.first, let name = keys.last else {
                return nil
            }
            switch prefix {
            case "'": return .mark(name: name, lineWise: true)
            case "`": return .mark(name: name, lineWise: false)
            default: return nil
            }
        }

        static func multiply(_ existing: Int?, _ next: Int?) -> Int? {
            guard let next else { return existing }
            guard let existing else { return next }
            let (product, overflow) = existing.multipliedReportingOverflow(by: next)
            return overflow ? Int.max : product
        }

        static func consumeCount(from keys: String) -> (count: Int?, remainder: String) {
            guard let first = keys.first, first >= "1", first <= "9" else {
                return (nil, keys)
            }

            var index = keys.startIndex
            var value = 0
            while index < keys.endIndex {
                let character = keys[index]
                guard let digit = character.wholeNumberValue, digit < 10 else { break }
                let (timesTen, multiplyOverflow) = value.multipliedReportingOverflow(by: 10)
                let (next, addOverflow) = timesTen.addingReportingOverflow(digit)
                value = multiplyOverflow || addOverflow ? Int.max : next
                index = keys.index(after: index)
            }
            return (value, String(keys[index...]))
        }

        static func removingSubmitKey(from text: String) -> (text: String, wasRemoved: Bool) {
            for suffix in ["<CR>", "\r", "\n"] where text.hasSuffix(suffix) {
                return (String(text.dropLast(suffix.count)), true)
            }
            return (text, false)
        }
    }
}
