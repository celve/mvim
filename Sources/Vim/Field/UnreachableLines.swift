/// Folds out of the model the `AXValue` lines Chromium makes for what no caret reaches: a list item's marker, which
/// Linear draws as a block of its own, each text-less leaf that is a block, such as a to-do's checkbox, and the `<br>`
/// Linear puts after a chip that ends its paragraph, where the caret reads past it (LIN-1652).
public enum UnreachableLines {
    /// The model without those lines, and the breaks that map it back to the field.
    public struct Model: Equatable, Sendable {
        public let text: String
        public let breaks: ParagraphBreaks
        /// How many `AXValue` units the fold took out, which settles still count.
        public let folded: Int
    }

    /// What discovery confirmed, in plain offsets.
    public struct Found: Equatable, Sendable {
        /// The starts of the lines that are list markers.
        public let markers: [Int]
        /// Where each list holding one ends.
        public let listEnds: [Int]

        public init(markers: [Int], listEnds: [Int]) {
            self.markers = markers
            self.listEnds = listEnds
        }
    }

    /// Discovery's list markers for one field text, kept until the text or its blocks change.
    public struct Memo: Equatable, Sendable {
        public let value: String
        public let markers: String
        public let blocks: Int?
        /// Nil when discovery failed, so markers stay lines.
        public let found: Found?

        public init(value: String, markers: String, blocks: Int?, found: Found?) {
            self.value = value
            self.markers = markers
            self.blocks = blocks
            self.found = found
        }

        public func holds(value: String, markers: String, blocks: Int?) -> Bool {
            self.value == value && self.markers == markers && self.blocks == blocks
        }
    }

    /// The most AX reads one discovery may spend; a larger field keeps its markers as lines.
    public static let readBudget = 512

    /// Plain ranges of the lines shaped like a list marker, which discovery confirms or not.
    public static func candidates(text: String, breaks: ParagraphBreaks) -> [Range<Int>] {
        lines(of: text).compactMap { line in
            guard isMarkerShaped(line.units) else { return nil }
            let start = breaks.fieldOffset(line.start)
            return start..<(start + line.units.count)
        }
    }

    /// Plain offsets of the `<br>`s that end a list item's paragraph after a chip: not an empty paragraph's, and just
    /// before a list item or a list's end.
    public static func trailingBreaks(in plain: String, found: Found, empty: Set<Int>) -> Set<Int> {
        let starts = Set(found.markers + found.listEnds)
        let units = Array(plain.utf16)
        return Set(units.indices.filter { units[$0] == 10 && !empty.contains($0) && starts.contains($0 + 1) })
    }

    /// `markers`: plain starts of confirmed list markers; `raw`: the marker text, whose U+FFFCs place the leaves;
    /// `trailing`: plain offsets of the `<br>`s that end a paragraph after a chip.
    public static func fold(
        text: String, breaks: ParagraphBreaks, raw: String, markers: Set<Int>, trailing: Set<Int> = []
    ) -> Model {
        let generated = Set(breaks.offsets)
        var leaves: [Int: Int] = [:]
        var plain = 0
        for unit in raw.utf16 {
            if unit == 0xFFFC { leaves[plain, default: 0] += 1 } else { plain += 1 }
        }
        var dropped = Set<Int>()
        var converted = Set<Int>()
        var runs: [(before: Int, text: String)] = []
        let units = Array(text.utf16)
        for line in lines(of: text) {
            let end = line.start + line.units.count
            let terminated = generated.contains(end) && end < units.count
            let start = breaks.fieldOffset(line.start)
            let trailingBreak = end < units.count && !generated.contains(end) && trailing.contains(breaks.fieldOffset(end))
            if trailingBreak {
                // Ending the field, it would leave an empty last line no caret reaches.
                if breaks.fieldOffset(end) + 1 == plain { dropped.insert(end) } else { converted.insert(end) }
                runs.append((end, "\n"))
            }
            if line.units.isEmpty, trailingBreak, let count = leaves[start], count > 0, line.start > 0,
               generated.contains(line.start - 1), !dropped.contains(line.start - 1) {
                // The image Linear adds while the caret is after the chip joins the chip's line.
                leaves[start] = count - 1
                dropped.insert(line.start - 1)
            } else if line.units.isEmpty {
                guard terminated, let count = leaves[start], count > 0 else { continue }
                leaves[start] = count - 1
                dropped.insert(end)
                runs.append((end + 1, ""))
            } else if markers.contains(start), isMarkerShaped(line.units) {
                // An empty item's marker ends in its paragraph's `<br>`, whose line stays.
                dropped.formUnion(line.start..<(terminated ? end + 1 : end))
                runs.append((terminated ? end + 1 : end, String(decoding: line.units, as: UTF16.self)))
            }
        }
        guard !dropped.isEmpty || !converted.isEmpty else { return Model(text: text, breaks: breaks, folded: 0) }
        var kept: [UInt16] = []
        var shift = [Int](repeating: 0, count: units.count + 1)
        for (index, unit) in units.enumerated() {
            shift[index] = index - kept.count
            if !dropped.contains(index) { kept.append(unit) }
        }
        shift[units.count] = units.count - kept.count
        var hidden: [ParagraphBreaks.Hidden] = []
        for run in runs {
            let at = run.before - shift[run.before]
            if let last = hidden.last, last.at == at {
                hidden[hidden.count - 1] = .init(at: at, text: last.text + run.text)
            } else {
                hidden.append(.init(at: at, text: run.text))
            }
        }
        let offsets = (breaks.offsets + converted).sorted().filter { !dropped.contains($0) }.map { $0 - shift[$0] }
        return Model(
            text: String(decoding: kept, as: UTF16.self), breaks: ParagraphBreaks(offsets: offsets, hidden: hidden),
            folded: dropped.count
        )
    }

    /// One bullet, or up to four letters or digits and a `.` or `)`, as Linear numbers its levels.
    static func isMarkerShaped(_ units: [UInt16]) -> Bool {
        if units.count == 1 { return "•◦▪▫‣⁃■□●○–-*".utf16.contains(units[0]) }
        guard (2...5).contains(units.count), let last = units.last, last == 0x2E || last == 0x29 else { return false }
        return String(decoding: units.dropLast(), as: UTF16.self).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func lines(of text: String) -> [(start: Int, units: [UInt16])] {
        let units = Array(text.utf16)
        var lines: [(start: Int, units: [UInt16])] = []
        var start = 0
        for index in 0...units.count where index == units.count || units[index] == 10 {
            lines.append((start, Array(units[start..<index])))
            start = index + 1
        }
        return lines
    }
}
