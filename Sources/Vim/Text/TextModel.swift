/// Pure vim text math over one snapshot of field text.
///
/// Every offset entering or leaving this type is a **UTF-16 code unit**
/// offset — AX's currency. Grapheme handling (what an arrow key moves over,
/// what a `Character` is) happens internally, so the offset↔grapheme hazard
/// lives and dies in this file. Zero dependencies; the physical planner's
/// lanes A and B are its only callers.
public struct TextModel: Equatable, Sendable {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var length: Int { text.utf16.count }

    // MARK: - Offsets

    public func clamp(_ offset: Int) -> Int {
        min(max(offset, 0), length)
    }

    private func index(_ offset: Int) -> String.Index {
        String.Index(utf16Offset: clamp(offset), in: text)
    }

    private func offset(_ index: String.Index) -> Int {
        index.utf16Offset(in: text)
    }

    /// Grapheme-wise advance, clamped to the text. Negative moves left.
    public func advance(_ offset: Int, byGraphemes n: Int) -> Int {
        let i = index(offset)
        let limit = n >= 0 ? text.endIndex : text.startIndex
        let j = text.index(i, offsetBy: n, limitedBy: limit) ?? limit
        return self.offset(j)
    }

    /// The number of arrow-key presses spanning a range.
    public func graphemes(in range: Range<Int>) -> Int {
        text.distance(from: index(range.lowerBound), to: index(range.upperBound))
    }

    public func substring(_ range: Range<Int>) -> String {
        String(text[index(range.lowerBound)..<index(range.upperBound)])
    }

    public func replacing(_ range: Range<Int>, with replacement: String) -> String {
        var copy = text
        copy.replaceSubrange(index(range.lowerBound)..<index(range.upperBound), with: replacement)
        return copy
    }

    public func newlineCount(in range: Range<Int>) -> Int {
        text[index(range.lowerBound)..<index(range.upperBound)].reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }

    // MARK: - Lines

    /// Offset just after the previous newline (or 0). A caret sitting on a
    /// newline belongs to the line that newline terminates.
    public func lineStart(of o: Int) -> Int {
        let i = index(o)
        guard let newline = text[..<i].lastIndex(of: "\n") else { return 0 }
        return offset(text.index(after: newline))
    }

    /// Offset of the line's newline (or the text end): the end-of-line gap.
    public func lineEnd(of o: Int) -> Int {
        let i = index(o)
        guard let newline = text[i...].firstIndex(of: "\n") else { return length }
        return offset(newline)
    }

    public func firstNonBlank(inLineOf o: Int) -> Int {
        var i = index(lineStart(of: o))
        let end = index(lineEnd(of: o))
        while i < end, text[i] == " " || text[i] == "\t" {
            i = text.index(after: i)
        }
        return offset(i)
    }

    /// Whole lines from the line containing `a` through the line containing
    /// `b`, in either order.
    public func lineSpan(from a: Int, to b: Int, includingTerminator: Bool) -> Range<Int> {
        let start = lineStart(of: min(a, b))
        var end = lineEnd(of: max(a, b))
        if includingTerminator, end < length { end += 1 }
        return start..<end
    }

    /// N whole lines starting at the line containing `o`.
    public func lines(from o: Int, count: Int, includingTerminator: Bool) -> Range<Int> {
        let start = lineStart(of: o)
        var end = lineEnd(of: o)
        var remaining = count - 1
        while remaining > 0, end < length {
            end = lineEnd(of: end + 1)
            remaining -= 1
        }
        if includingTerminator, end < length { end += 1 }
        return start..<end
    }

    /// `j`/`k`: move whole lines, preserving the grapheme column, clamped to
    /// the target line's end.
    public func verticalMove(from o: Int, by delta: Int, firstNonBlank fnb: Bool) -> Int {
        var start = lineStart(of: o)
        let column = graphemes(in: start..<o)
        var remaining = delta
        while remaining > 0 {
            let end = lineEnd(of: start)
            guard end < length else { break }
            start = end + 1
            remaining -= 1
        }
        while remaining < 0, start > 0 {
            start = lineStart(of: start - 1)
            remaining += 1
        }
        if fnb { return firstNonBlank(inLineOf: start) }
        return min(advance(start, byGraphemes: column), lineEnd(of: start))
    }

    // MARK: - Words

    private enum CharClass {
        case whitespace
        case keyword
        case punctuation
    }

    private func charClass(_ c: Character, big: Bool) -> CharClass {
        if c == " " || c == "\t" || c == "\n" || c == "\r" { return .whitespace }
        if big { return .keyword }
        if c.isLetter || c.isNumber || c == "_" { return .keyword }
        return .punctuation
    }

    /// `w`/`W`: start of the next word.
    public func wordForward(from o: Int, big: Bool) -> Int {
        var i = index(o)
        guard i < text.endIndex else { return length }
        let cls = charClass(text[i], big: big)
        if cls != .whitespace {
            while i < text.endIndex, charClass(text[i], big: big) == cls {
                i = text.index(after: i)
            }
        }
        while i < text.endIndex, charClass(text[i], big: big) == .whitespace {
            i = text.index(after: i)
        }
        return offset(i)
    }

    /// `b`/`B`: start of the previous word.
    public func wordBackward(from o: Int, big: Bool) -> Int {
        var i = index(o)
        guard i > text.startIndex else { return 0 }
        i = text.index(before: i)
        while i > text.startIndex, charClass(text[i], big: big) == .whitespace {
            i = text.index(before: i)
        }
        guard charClass(text[i], big: big) != .whitespace else { return offset(i) }
        let cls = charClass(text[i], big: big)
        while i > text.startIndex {
            let previous = text.index(before: i)
            guard charClass(text[previous], big: big) == cls else { break }
            i = previous
        }
        return offset(i)
    }

    /// `e`/`E`: the offset **of** the last character of the word — the gap
    /// before it. An inclusive span adds one grapheme to cover it.
    public func wordEnd(from o: Int, big: Bool) -> Int {
        var i = index(o)
        guard i < text.endIndex else { return o }
        i = text.index(after: i)
        while i < text.endIndex, charClass(text[i], big: big) == .whitespace {
            i = text.index(after: i)
        }
        guard i < text.endIndex else { return advance(length, byGraphemes: -1) }
        let cls = charClass(text[i], big: big)
        while true {
            let next = text.index(after: i)
            guard next < text.endIndex, charClass(text[next], big: big) == cls else { break }
            i = next
        }
        return offset(i)
    }

    /// `iw`/`aw`: the run containing the caret (whitespace counts as a run,
    /// as in vim); `around` extends over trailing blanks, or leading ones
    /// when there are none trailing. Newlines never join an `aw`.
    public func wordObject(at o: Int, around: Bool, big: Bool) -> Range<Int> {
        guard length > 0 else { return 0..<0 }
        var i = index(o)
        if i == text.endIndex { i = text.index(before: i) }
        let cls = charClass(text[i], big: big)
        var start = i
        while start > text.startIndex {
            let previous = text.index(before: start)
            guard charClass(text[previous], big: big) == cls, text[previous] != "\n" else { break }
            start = previous
        }
        var end = text.index(after: i)
        while end < text.endIndex, charClass(text[end], big: big) == cls, text[end] != "\n" {
            end = text.index(after: end)
        }
        var lo = offset(start)
        var hi = offset(end)
        if around, cls != .whitespace {
            let trailingStart = hi
            var j = index(hi)
            while j < text.endIndex, text[j] == " " || text[j] == "\t" {
                j = text.index(after: j)
            }
            hi = offset(j)
            if hi == trailingStart {
                var k = index(lo)
                while k > text.startIndex {
                    let previous = text.index(before: k)
                    guard text[previous] == " " || text[previous] == "\t" else { break }
                    k = previous
                }
                lo = offset(k)
            }
        }
        return lo..<hi
    }

    // MARK: - Find and search

    /// `f`/`F`/`t`/`T`, within the caret's line. Returns the destination gap
    /// or nil when the character is not found (vim bells).
    public func findCharacter(_ target: Character, from o: Int, forward: Bool, before till: Bool, count: Int) -> Int? {
        var remaining = count
        if forward {
            var i = index(o)
            let end = index(lineEnd(of: o))
            guard i < end else { return nil }
            i = text.index(after: i)
            while i < end {
                if text[i] == target {
                    remaining -= 1
                    if remaining == 0 {
                        let found = offset(i)
                        return till ? advance(found, byGraphemes: -1) : found
                    }
                }
                i = text.index(after: i)
            }
            return nil
        }
        var i = index(o)
        let start = index(lineStart(of: o))
        while i > start {
            i = text.index(before: i)
            if text[i] == target {
                remaining -= 1
                if remaining == 0 {
                    let found = offset(i)
                    return till ? advance(found, byGraphemes: 1) : found
                }
            }
        }
        return nil
    }

    /// Literal, wrapping search. Returns the match start.
    public func search(_ pattern: String, from o: Int, forward: Bool, count: Int) -> Int? {
        guard !pattern.isEmpty else { return nil }
        let starts = matchStarts(of: pattern)
        guard !starts.isEmpty else { return nil }
        var current = o
        for _ in 0..<count {
            if forward {
                current = starts.first(where: { $0 > current }) ?? starts[0]
            } else {
                current = starts.last(where: { $0 < current }) ?? starts[starts.count - 1]
            }
        }
        return current
    }

    private func matchStarts(of pattern: String) -> [Int] {
        var result: [Int] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i...].hasPrefix(pattern) {
                result.append(offset(i))
            }
            i = text.index(after: i)
        }
        return result
    }

    // MARK: - Marks

    /// How many graphemes of context a mark witness captures on each side.
    private static let witnessRadius = 4

    public func witness(at o: Int) -> String {
        let lo = advance(o, byGraphemes: -Self.witnessRadius)
        let hi = advance(o, byGraphemes: Self.witnessRadius)
        return substring(lo..<hi)
    }

    public func markPoint(at o: Int) -> MarkPoint {
        MarkPoint(offset: clamp(o), textLength: length, context: witness(at: o))
    }

    public func isValid(_ mark: MarkPoint) -> Bool {
        mark.textLength == length && witness(at: mark.offset) == mark.context
    }

    // MARK: - Motion destinations

    /// The gap a motion lands on, or nil when the motion is unsupported here
    /// or finds nothing (both bell). Counts that name lines (`3G`) are not
    /// distinguishable from defaults at this level and are ignored for
    /// `fileStart`/`fileEnd`.
    public func destination(of motion: Motion, from o: Int, count: Int) -> Int? {
        switch motion {
        case .character(.left):
            return max(lineStart(of: o), advance(o, byGraphemes: -count))
        case .character(.right):
            return min(lineEnd(of: o), advance(o, byGraphemes: count))
        case .character:
            return nil
        case .line(let direction, let fnb) where direction == .up || direction == .down:
            return verticalMove(from: o, by: direction == .down ? count : -count, firstNonBlank: fnb)
        case .line:
            return nil
        case .word(let direction, let end, let big):
            var position = o
            for _ in 0..<count {
                switch (direction, end) {
                case (.forward, false): position = wordForward(from: position, big: big)
                case (.forward, true): position = wordEnd(from: position, big: big)
                case (.backward, false): position = wordBackward(from: position, big: big)
                default: return nil
                }
            }
            return position
        case .lineStart(let fnb):
            return fnb ? firstNonBlank(inLineOf: o) : lineStart(of: o)
        case .lineEnd:
            let base = count > 1 ? verticalMove(from: o, by: count - 1, firstNonBlank: false) : o
            return lineEnd(of: base)
        case .lastNonBlank:
            let start = lineStart(of: o)
            var i = index(lineEnd(of: o))
            while i > index(start) {
                i = text.index(before: i)
                if text[i] != " ", text[i] != "\t" { return offset(i) }
            }
            return start
        case .fileStart:
            return firstNonBlank(inLineOf: 0)
        case .fileEnd:
            return firstNonBlank(inLineOf: lineStart(of: length))
        case .find(let character, let direction, let before) where direction == .forward || direction == .backward:
            return findCharacter(character, from: o, forward: direction == .forward, before: before, count: count)
        case .find:
            return nil
        case .search(let search):
            guard let pattern = search.pattern, !pattern.isEmpty else { return nil }
            return self.search(pattern, from: o, forward: search.direction == .forward, count: count)
        default:
            return nil
        }
    }
}
