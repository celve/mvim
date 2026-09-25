/// The `\n`s Chromium adds to `AXValue` at paragraph starts, which its selection offsets skip.
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
            // Chromium's break precedes any newline the paragraph's own text starts with.
            offsets += i..<(i + valueRun - fieldRun)
            i += valueRun
            j += fieldRun
        }
        guard j == field.count else { return nil }
        self.offsets = offsets
    }
}

public extension ParagraphBreaks {
    enum End: Equatable, Sendable {
        case lower
        case upper
    }

    enum Side: Equatable, Sendable {
        case end
        /// The next paragraph's start, past `skipping` characters of a list marker.
        case start(skipping: Int)
    }

    func fieldOffset(_ valueOffset: Int) -> Int {
        valueOffset - offsets.prefix { $0 < valueOffset }.count
    }

    func fieldRange(_ range: Range<Int>) -> Range<Int> {
        fieldOffset(range.lowerBound)..<fieldOffset(range.upperBound)
    }

    /// The `AXValue` offsets a field offset names: two at a paragraph boundary.
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

    /// In `AXValue` offsets, asking `side` at a boundary or the field's start; nil if unresolved.
    func valueRange(_ field: Range<Int>, side: (End) -> Side?) -> Range<Int>? {
        func resolve(_ fieldOffset: Int, _ end: End) -> Int? {
            let candidates = valueOffsets(fieldOffset)
            guard candidates.count > 1 || candidates.lowerBound == 0 else { return candidates.lowerBound }
            switch side(end) {
            case .end?: return candidates.lowerBound
            case .start(let skipping)?: return candidates.upperBound + skipping
            case nil: return nil
            }
        }
        guard let lower = resolve(field.lowerBound, .lower),
              let upper = resolve(field.upperBound, .upper) else { return nil }
        // A backward selection over a break alone resolves its ends reversed.
        return min(lower, upper)..<max(lower, upper)
    }

    /// `text` at `range` without its breaks, as `AXSelectedText` reads it.
    func fieldText(_ text: String, at range: Range<Int>) -> String {
        let inside = Set(offsets.filter { range.contains($0) }.map { $0 - range.lowerBound })
        guard !inside.isEmpty else { return text }
        let units = text.utf16.enumerated().filter { !inside.contains($0.offset) }.map(\.element)
        return String(decoding: units, as: UTF16.self)
    }

    /// The breaks after an edit, counting each typed `\n` as a new paragraph.
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
