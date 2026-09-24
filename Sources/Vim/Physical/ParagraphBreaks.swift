/// Where a field's selection offsets part from its `AXValue` offsets.
///
/// Chromium's rich-text fields read and write `AXSelectedTextRange` in their
/// text content, which is `AXValue` without the `\n` Chromium generates where a
/// paragraph or list item starts. The planner keeps `AXValue` offsets and
/// crosses into field offsets only at the field's edge; a field with no breaks
/// yet still gets an empty map, so a paragraph it gains is counted.
public struct ParagraphBreaks: Equatable, Sendable {
    /// Ascending `AXValue` offsets of the generated `\n`s.
    public let offsets: [Int]

    public init(offsets: [Int] = []) {
        self.offsets = offsets
    }

    /// Nil when `fieldText` is not `value` with some `\n`s taken out.
    public init?(value: String, fieldText: String) {
        let value = Array(value.utf16)
        let field = Array(fieldText.utf16)
        let newline: UInt16 = 10
        var offsets: [Int] = []
        var i = 0
        var j = 0
        while i < value.count {
            guard value[i] == newline else {
                guard j < field.count, field[j] == value[i] else { return nil }
                i += 1
                j += 1
                continue
            }
            var valueRun = 0
            while i + valueRun < value.count, value[i + valueRun] == newline { valueRun += 1 }
            var fieldRun = 0
            while j + fieldRun < field.count, field[j + fieldRun] == newline { fieldRun += 1 }
            guard fieldRun <= valueRun else { return nil }
            // Chromium generates the break before a paragraph's text, so it leads any newline that text starts with.
            offsets += i..<(i + valueRun - fieldRun)
            i += valueRun
            j += fieldRun
        }
        guard j == field.count else { return nil }
        self.offsets = offsets
    }
}

public extension ParagraphBreaks {
    /// Which end of a selection a question is about.
    enum End: Equatable, Sendable {
        case lower
        case upper
    }

    func fieldOffset(_ valueOffset: Int) -> Int {
        valueOffset - offsets.prefix { $0 < valueOffset }.count
    }

    func fieldRange(_ range: Range<Int>) -> Range<Int> {
        fieldOffset(range.lowerBound)..<fieldOffset(range.upperBound)
    }

    /// Every `AXValue` offset a field offset names: more than one only where a paragraph ends and the next begins.
    func valueOffsets(_ fieldOffset: Int) -> ClosedRange<Int> {
        var before = 0
        var at = 0
        for (index, offset) in offsets.enumerated() {
            let position = offset - index
            if position < fieldOffset {
                before += 1
            } else if position == fieldOffset {
                at += 1
            } else {
                break
            }
        }
        return (fieldOffset + before)...(fieldOffset + before + at)
    }

    /// A field selection in `AXValue` offsets; nil when a paragraph boundary stays unresolved.
    ///
    /// `startsNode` is asked only at a boundary, and says whether that end sits
    /// at the start of its own node — the next paragraph — rather than the end
    /// of the last one.
    func valueRange(_ field: Range<Int>, startsNode: (End) -> Bool?) -> Range<Int>? {
        func resolve(_ fieldOffset: Int, _ end: End) -> Int? {
            let candidates = valueOffsets(fieldOffset)
            guard candidates.count > 1 else { return candidates.lowerBound }
            guard let starts = startsNode(end) else { return nil }
            return starts ? candidates.upperBound : candidates.lowerBound
        }
        guard let lower = resolve(field.lowerBound, .lower),
              let upper = resolve(field.upperBound, .upper) else { return nil }
        // Ends that share a field offset can arrive in either order: a backward selection over a break alone.
        return min(lower, upper)..<max(lower, upper)
    }

    /// The breaks once `range` holds `replacement`, each `\n` typed in taken as a new paragraph.
    func replacing(_ range: Range<Int>, with replacement: String) -> ParagraphBreaks {
        let delta = replacement.utf16.count - range.count
        var result = offsets.filter { $0 < range.lowerBound }
        for (index, unit) in replacement.utf16.enumerated() where unit == 10 {
            result.append(range.lowerBound + index)
        }
        result += offsets.filter { $0 >= range.upperBound }.map { $0 + delta }
        return ParagraphBreaks(offsets: result)
    }
}
