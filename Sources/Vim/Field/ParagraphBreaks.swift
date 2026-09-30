/// The `\n`s Chromium adds to `AXValue` at paragraph starts, which its selection offsets skip.
public struct ParagraphBreaks: Equatable, Sendable {
    /// Ascending `AXValue` offsets of the generated `\n`s.
    public let offsets: [Int]

    /// Field text the model folds out, as no caret reaches it (LIN-1652); ascending.
    public let hidden: [Hidden]

    /// Stands before the model character at `at`; an empty run marks a folded line that held no field text.
    public struct Hidden: Equatable, Sendable {
        public let at: Int
        public let text: String
        public let kind: Kind

        public enum Kind: Equatable, Sendable {
            /// A list marker or a text-less block, which the caret passes.
            case structure
            /// Chromium's own list marker, which starts its item's line and reads as a boundary a side skips past.
            case prefix
            /// The rest of an atom's text, such as a chip's label, whose first unit stands for it in the model.
            case atom
            /// A `<br>` ending a paragraph after a chip: a caret after the chip reads past it, a selection stops before it.
            case trailingBreak
        }

        public init(at: Int, text: String, kind: Kind = .structure) {
            self.at = at
            self.text = text
            self.kind = kind
        }

        /// A marker or a text-less block, which an edit moves with its line.
        public var isStructure: Bool { kind == .structure || kind == .prefix }

        public var isMarker: Bool { isStructure && !text.isEmpty }
    }

    public init(offsets: [Int] = [], hidden: [Hidden] = []) {
        self.offsets = offsets
        self.hidden = hidden
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
        hidden = []
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
            + hidden.prefix { $0.at <= valueOffset }.reduce(0) { $0 + $1.text.utf16.count }
    }

    func fieldRange(_ range: Range<Int>) -> Range<Int> {
        guard !range.isEmpty else { return fieldOffset(range.lowerBound)..<fieldOffset(range.upperBound) }
        func end(_ offset: Int) -> Int { fieldOffset(offset) - (endsBeforeBreak(offset) ? 1 : 0) }
        return end(range.lowerBound)..<end(range.upperBound)
    }

    /// A trailing `<br>` at `offset`, which a caret there reads past and a selection's end there stops before.
    func endsBeforeBreak(_ offset: Int) -> Bool {
        hidden.contains { $0.at == offset && $0.kind == .trailingBreak }
    }

    /// The model character at `offset` stands for an atom, such as a chip, which keys cross in one step.
    func isAtom(_ offset: Int) -> Bool {
        hidden.contains { $0.at == offset + 1 && $0.kind == .atom }
    }

    /// Model offsets of the atoms.
    var atoms: Set<Int> {
        Set(hidden.filter { $0.kind == .atom }.map { $0.at - 1 })
    }

    /// `text` at `range` with each atom's whole text, as a register keeps it.
    func withAtoms(_ text: String, at range: Range<Int>) -> String {
        let runs = hidden.filter { $0.kind == .atom && range.lowerBound < $0.at && $0.at <= range.upperBound }
        guard !runs.isEmpty else { return text }
        var units = Array(text.utf16)
        for run in runs.reversed() { units.insert(contentsOf: run.text.utf16, at: run.at - range.lowerBound) }
        return String(decoding: units, as: UTF16.self)
    }

    /// The `AXValue` offsets a field offset names: two at a paragraph boundary.
    func valueOffsets(_ fieldOffset: Int) -> ClosedRange<Int> {
        guard hidden.isEmpty else { return foldedOffsets(fieldOffset) }
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

    /// A field offset inside a hidden run names the offset the run stands before; its start is the one before that.
    private func foldedOffsets(_ fieldOffset: Int) -> ClosedRange<Int> {
        var low = 0
        var high = fieldOffset + offsets.count
        while low < high {
            let middle = (low + high) / 2
            if self.fieldOffset(middle) < fieldOffset { low = middle + 1 } else { high = middle }
        }
        guard self.fieldOffset(low) == fieldOffset else { return low...low }
        var upper = low
        while self.fieldOffset(upper + 1) == fieldOffset { upper += 1 }
        if let run = hidden.first(where: { $0.at == upper + 1 && $0.kind == .prefix }),
           self.fieldOffset(upper + 1) - run.text.utf16.count == fieldOffset {
            upper += 1
        }
        return low...upper
    }

    /// In `AXValue` offsets, asking `side` at a boundary or the field's start; nil if unresolved.
    func valueRange(_ field: Range<Int>, side: (End) -> Side?) -> Range<Int>? {
        func resolve(_ fieldOffset: Int, _ end: End) -> Int? {
            let candidates = valueOffsets(fieldOffset)
            guard candidates.count > 1 || candidates.lowerBound == 0 else { return candidates.lowerBound }
            switch side(end) {
            case .end?: return candidates.lowerBound
            case .start(let skipping)?:
                let folded = hidden.contains { $0.at == candidates.upperBound && $0.kind == .prefix }
                return candidates.upperBound + (folded ? 0 : skipping)
            case nil: return nil
            }
        }
        guard let lower = resolve(field.lowerBound, .lower),
              let upper = resolve(field.upperBound, .upper) else { return nil }
        // A backward selection over a break alone resolves its ends reversed.
        return min(lower, upper)..<max(lower, upper)
    }

    /// `text` at `range` without its breaks and with its hidden runs, as `AXSelectedText` reads it.
    func fieldText(_ text: String, at range: Range<Int>) -> String {
        let inside = Set(offsets.filter { range.contains($0) }.map { $0 - range.lowerBound })
        let runs = hidden.filter { covered($0, by: range) && !$0.text.isEmpty }
        guard !inside.isEmpty || !runs.isEmpty else { return text }
        var units: [UInt16] = []
        var next = runs.makeIterator()
        var run = next.next()
        for (index, unit) in text.utf16.enumerated() {
            while let current = run, current.at - range.lowerBound == index {
                units += current.text.utf16
                run = next.next()
            }
            if !inside.contains(index) { units.append(unit) }
        }
        while let current = run {
            units += current.text.utf16
            run = next.next()
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// The breaks after an edit, a typed `\n` a new paragraph; `keepingCovered` moves the last marker it covers to its start.
    func replacing(_ range: Range<Int>, with replacement: String, keepingCovered: Bool = false) -> ParagraphBreaks {
        let delta = replacement.utf16.count - range.count
        var result = offsets.filter { $0 < range.lowerBound }
        for (index, unit) in replacement.utf16.enumerated() where unit == 10 {
            result.append(range.lowerBound + index)
        }
        result += offsets.filter { $0 >= range.upperBound }.map { $0 + delta }
        var kept: [Hidden] = []
        var moved: [Hidden] = []
        var marker: Hidden?
        // A chip's `<br>` goes with the chip.
        let chips = Set(hidden.filter { $0.kind == .atom && covered($0, by: range) }.map(\.at))
        for run in hidden {
            if covered(run, by: range) || run.kind == .trailingBreak && chips.contains(run.at) {
                if run.isMarker { marker = run }
            } else if run.at < range.lowerBound || run.at == range.lowerBound && run.kind != .trailingBreak {
                kept.append(run)
            } else {
                moved.append(Hidden(at: run.at + delta, text: run.text, kind: run.kind))
            }
        }
        if keepingCovered, let marker { kept.append(Hidden(at: range.lowerBound, text: marker.text, kind: marker.kind)) }
        return ParagraphBreaks(offsets: result, hidden: kept + moved)
    }

    /// Whether an edit of `range` takes a hidden run with it.
    func covers(_ range: Range<Int>) -> Bool {
        hidden.contains { covered($0, by: range) }
    }

    /// A trailing `<br>` goes with the model's `\n` at its offset; other runs with the character before theirs.
    private func covered(_ run: Hidden, by range: Range<Int>) -> Bool {
        run.kind == .trailingBreak ? range.contains(run.at) : range.lowerBound < run.at && run.at <= range.upperBound
    }

    /// Whether `range` holds an atom, which typed text cannot rebuild.
    func coversAtom(_ range: Range<Int>) -> Bool {
        hidden.contains { $0.kind == .atom && range.lowerBound < $0.at && $0.at <= range.upperBound }
    }
}
