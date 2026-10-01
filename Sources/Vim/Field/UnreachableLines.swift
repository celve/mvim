/// Folds out of the model what no caret reaches in Linear's editor: markers, text-less blocks and chips' lines (LIN-1652).
public enum UnreachableLines {
    /// The model without those lines, and the breaks that map it back to the field.
    public struct Model: Equatable, Sendable {
        public let text: String
        public let breaks: ParagraphBreaks
        /// How many `AXValue` units the fold took out, which settles still count.
        public let folded: Int
        /// The plain offset of the `<br>` after a caret drawn at a paragraph's end, which `breaks` count as gone.
        public var drawnBreak: Int?
    }

    /// An inline atom, such as a mention chip, in plain offsets: a caret crosses it in one step.
    public struct Chip: Equatable, Sendable {
        public let range: Range<Int>
        /// The paragraph holding it, with the `<br>` Linear adds after a chip that ends it.
        public let paragraph: Range<Int>

        public init(range: Range<Int>, paragraph: Range<Int>) {
            self.range = range
            self.paragraph = paragraph
        }

        var inlineBefore: Bool { paragraph.lowerBound < range.lowerBound }

        /// The paragraph ends in the `<br>` after it, where `plain` has its `\n`.
        func endsParagraph(in plain: [UInt16]) -> Bool {
            paragraph.upperBound == range.upperBound + 1 && plain.indices.contains(range.upperBound)
                && plain[range.upperBound] == 10
        }

        /// The paragraph goes on past the chip's line, which ends at `lineEnd`.
        func inlineAfter(lineEnd: Int, in plain: [UInt16]) -> Bool {
            paragraph.upperBound > lineEnd && !endsParagraph(in: plain)
        }
    }

    /// The lines worth confirming in the tree, in plain ranges.
    public struct Candidates: Equatable, Sendable {
        public let markers: [Range<Int>]
        public let chips: [Range<Int>]
        /// Plain offsets of empty lines after a generated break holding one text-less leaf, and the caret's by any leaf.
        public let carets: [Int]

        public init(markers: [Range<Int>], chips: [Range<Int>], carets: [Int] = []) {
            self.markers = markers
            self.chips = chips
            self.carets = carets
        }

        public var isEmpty: Bool { markers.isEmpty && chips.isEmpty && carets.isEmpty }
    }

    /// Linear's caret drawn at an inline code span's edge (LIN-1683), whose line and generated breaks are no text.
    public struct Caret: Equatable, Sendable {
        public let offset: Int
        public let place: Place

        /// Where in its paragraph: at the start the break before its line is the paragraph's, at the end a `<br>` follows.
        public enum Place: Equatable, Sendable {
            case start
            case middle
            case end
        }

        public init(offset: Int, place: Place) {
            self.offset = offset
            self.place = place
        }
    }

    /// What discovery confirmed: the plain starts of list markers, the chips, and a drawn caret.
    public struct Found: Equatable, Sendable {
        public let markers: [Int]
        public let chips: [Chip]
        public let carets: [Caret]

        public init(markers: [Int], chips: [Chip], carets: [Caret] = []) {
            self.markers = markers
            self.chips = chips
            self.carets = carets
        }
    }

    /// Discovery for one field text, kept until the text or its blocks change.
    public struct Memo: Equatable, Sendable {
        public let value: String
        public let markers: String
        public let blocks: Int?
        /// Nil when discovery failed, so markers and chips stay lines.
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

    /// The most AX reads one discovery may spend; a larger field keeps its markers and chips as lines.
    public static let readBudget = 1024

    /// Lines shaped like a marker or starting with one and a space, lines starting as Linear's chips do, and drawn carets'.
    public static func candidates(text: String, breaks: ParagraphBreaks, raw: String? = nil, caret: Int? = nil) -> Candidates {
        let leaves = raw.map(leafCounts) ?? [:]
        let generated = Set(breaks.offsets)
        let length = text.utf16.count
        var markers: [Range<Int>] = []
        var chips: [Range<Int>] = []
        var carets: [Int] = []
        for line in lines(of: text) {
            let start = breaks.fieldOffset(line.start)
            if isMarkerShaped(line.units) {
                markers.append(start..<(start + line.units.count))
            } else if let count = prefixLength(line.units) {
                markers.append(start..<(start + count))
            }
            if line.units.starts(with: [0x2060, 0x00A0]) { chips.append(start..<(start + line.units.count)) }
            if line.units.isEmpty, line.start == 0 || generated.contains(line.start - 1), line.start < length, leaves[start] == 1 {
                carets.append(start)
            }
        }
        // One can share its offset with a to-do's checkbox, or have no line after a `<br>`.
        if let caret, leaves[caret] != nil, !carets.contains(caret) { carets.append(caret) }
        return Candidates(markers: markers, chips: chips, carets: carets)
    }

    /// How many U+FFFCs the marker text has at each plain offset: one per text-less leaf.
    static func leafCounts(_ raw: String) -> [Int: Int] {
        var leaves: [Int: Int] = [:]
        var plain = 0
        for unit in raw.utf16 {
            if unit == 0xFFFC { leaves[plain, default: 0] += 1 } else { plain += 1 }
        }
        return leaves
    }

    /// `raw` is the marker text, whose U+FFFCs place the leaves.
    public static func fold(text: String, breaks: ParagraphBreaks, raw: String, found: Found) -> Model {
        let generated = Set(breaks.offsets)
        var leaves = leafCounts(raw)
        let plain = raw.utf16.count - leaves.values.reduce(0, +)
        let markers = Set(found.markers)
        var carets = Dictionary(found.carets.map { ($0.offset, $0) }) { first, _ in first }
        let chips = Dictionary(found.chips.map { ($0.range.lowerBound, $0) }) { first, _ in first }
        let plainUnits = Array(FieldReads.withoutAttachments(raw).utf16)
        let endings = Set(found.chips.filter { $0.endsParagraph(in: plainUnits) }.map(\.range.upperBound))
        var dropped = Set<Int>()
        var converted = Set<Int>()
        var drawnBreak: Int?
        var runs: [(before: Int, text: String, kind: ParagraphBreaks.Hidden.Kind)] = []
        let units = Array(text.utf16)
        // The last break the model keeps, and whether text it keeps came after it.
        var lastBreak: Int?
        var textSinceBreak = false
        for line in lines(of: text) {
            let end = line.start + line.units.count
            let terminated = end < units.count && generated.contains(end)
            let start = breaks.fieldOffset(line.start)
            var keepsTerminator = end < units.count
            // The `<br>` after a chip that ends its paragraph stays the line's end, which a caret reads past.
            let trailing = end < units.count && !generated.contains(end) && endings.contains(breaks.fieldOffset(end))
            if line.units.isEmpty, let caret = carets[start], line.start == 0 || generated.contains(line.start - 1),
               end < units.count, let count = leaves[start], count > 0 {
                // A drawn caret's breaks go, and the `<br>` after one ending its paragraph goes with the caret.
                leaves[start] = count - 1
                carets[start] = nil
                if line.start > 0, !terminated || caret.place != .start { dropped.insert(line.start - 1) }
                if terminated || breaks.fieldOffset(end) + 1 == plain {
                    // Ending the field, the `<br>` would leave an empty last line no caret reaches.
                    dropped.insert(end)
                    keepsTerminator = false
                } else {
                    converted.insert(end)
                }
                if !terminated { drawnBreak = start }
            } else if line.units.isEmpty, endings.contains(start), end < units.count, !generated.contains(end),
               let count = leaves[start], count > 0, let previous = lastBreak, previous == line.start - 1,
               generated.contains(previous) {
                // The image Linear adds while the caret is after the chip joins the chip's line.
                leaves[start] = count - 1
                dropped.insert(previous)
            } else if line.units.isEmpty {
                if terminated, let count = leaves[start], count > 0 {
                    leaves[start] = count - 1
                    dropped.insert(end)
                    runs.append((end + 1, "", .structure))
                    keepsTerminator = false
                }
            } else if markers.contains(start), isMarkerShaped(line.units) {
                // An empty item's marker ends in its paragraph's `<br>`, whose line stays.
                dropped.formUnion(line.start..<(terminated ? end + 1 : end))
                runs.append((terminated ? end + 1 : end, String(decoding: line.units, as: UTF16.self), .structure))
                keepsTerminator = !terminated
            } else if markers.contains(start), let count = prefixLength(line.units) {
                dropped.formUnion(line.start..<(line.start + count))
                runs.append((line.start + count, String(decoding: line.units[..<count], as: UTF16.self), .prefix))
                textSinceBreak = count < line.units.count
                // The `<br>` of an empty item ending the field leaves an empty last line no caret reaches.
                if count == line.units.count, end + 1 == units.count, breaks.fieldOffset(end) + 1 == plain {
                    dropped.insert(end)
                    keepsTerminator = false
                }
            } else if let chip = chips[start], chip.range.count <= line.units.count, chip.range.count > 1 {
                let labelEnd = line.start + chip.range.count
                dropped.formUnion((line.start + 1)..<labelEnd)
                runs.append((labelEnd, String(decoding: line.units[1..<chip.range.count], as: UTF16.self), .atom))
                if chip.inlineBefore, !textSinceBreak, let previous = lastBreak, generated.contains(previous) {
                    dropped.insert(previous)
                    lastBreak = nil
                }
                if terminated, chip.inlineAfter(lineEnd: start + line.units.count, in: plainUnits) {
                    dropped.insert(end)
                    keepsTerminator = false
                }
                textSinceBreak = true
            } else {
                textSinceBreak = true
            }
            if trailing {
                // Ending the field, it would leave an empty last line no caret reaches.
                if breaks.fieldOffset(end) + 1 == plain {
                    dropped.insert(end)
                    keepsTerminator = false
                } else {
                    converted.insert(end)
                }
                runs.append((end, "\n", .trailingBreak))
            }
            if keepsTerminator {
                lastBreak = end
                textSinceBreak = false
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
        let hidden = runs.map { ParagraphBreaks.Hidden(at: $0.before - shift[$0.before], text: $0.text, kind: $0.kind) }
        let offsets = (breaks.offsets + converted).sorted().filter { !dropped.contains($0) }.map { $0 - shift[$0] }
        return Model(
            text: String(decoding: kept, as: UTF16.self), breaks: ParagraphBreaks(offsets: offsets, hidden: hidden),
            folded: dropped.count, drawnBreak: drawnBreak
        )
    }

    /// One bullet, or up to four letters or digits and a `.` or `)`, as Linear numbers its levels.
    static func isMarkerShaped(_ units: [UInt16]) -> Bool {
        if units.count == 1 { return "•◦▪▫‣⁃■□●○–-*".utf16.contains(units[0]) }
        guard (2...5).contains(units.count), let last = units.last, last == 0x2E || last == 0x29 else { return false }
        return String(decoding: units.dropLast(), as: UTF16.self).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The length of a marker and the space after it that start a line, as Chromium draws its own list's markers.
    static func prefixLength(_ units: [UInt16]) -> Int? {
        (2...6).first { $0 <= units.count && units[$0 - 1] == 0x20 && isMarkerShaped(Array(units[..<($0 - 1)])) }
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
