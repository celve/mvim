/// Puts back as lines the empty paragraphs Chromium's `AXValue` leaves out, whose `<br>`s its marker text keeps (LIN-1612).
public enum EmptyParagraphs {
    /// The planner's text with every empty paragraph a line, and the breaks that map it to the field's offsets.
    public struct Model: Equatable, Sendable {
        public let text: String
        public let breaks: ParagraphBreaks
        /// How much longer `text` is than `AXValue`, which settles still compare lengths with.
        public let gap: Int
    }

    /// Discovery's reads for one field text, kept until the text or its blocks change, or shifted across typing.
    public struct Memo: Equatable, Sendable {
        public let value: String
        public let markers: String
        public let blocks: Int?
        /// Nil when discovery failed, so the field keeps `AXValue`'s lines.
        public let found: [Int]?
        /// It failed by running out of reads, as a walk of the same blocks would again.
        public let exhausted: Bool
        public let origin: Discovery.Origin

        public init(
            value: String, markers: String, blocks: Int?, found: [Int]?, exhausted: Bool = false,
            origin: Discovery.Origin = .walked(.first)
        ) {
            self.value = value
            self.markers = markers
            self.blocks = blocks
            self.found = found
            self.exhausted = exhausted
            self.origin = origin
        }

        public func holds(value: String, markers: String, blocks: Int?) -> Bool {
            self.value == value && self.markers == markers && self.blocks == blocks
        }

        /// Itself while it holds, else shifted across the one run typed since, or why discovery walks again.
        public func carried(value: String, markers: String, blocks: Int?) -> Result<Memo, Discovery.Rewalk> {
            if holds(value: value, markers: markers, blocks: blocks) { return .success(self) }
            guard blocks != nil, self.blocks == blocks else { return .failure(.blocks) }
            return Discovery.run(markers: self.markers, value: self.value, to: markers, value: value).flatMap { edit in
                let run = edit.run
                var shifted: [Int]?
                if let found {
                    guard let moved = run.shifted(found) else { return .failure(.boundary) }
                    shifted = moved
                } else if !exhausted {
                    return .failure(.failed)
                }
                return .success(Memo(
                    value: value, markers: markers, blocks: blocks, found: shifted, exhausted: exhausted, origin: .shifted(run)
                ))
            }
        }
    }

    /// The most AX reads one discovery may spend; a larger field keeps `AXValue`'s lines.
    public static let readBudget = 256

    /// `found`: ascending plain marker offsets of the `<br>`s of empty paragraphs that start a line; nil if they do not fit.
    public static func restore(value: String, fieldText: String, aligned: ParagraphBreaks, found: [Int]) -> Model? {
        let v = Array(value.utf16)
        let f = Array(fieldText.utf16)
        let newline: UInt16 = 10
        guard !found.isEmpty else { return Model(text: value, breaks: aligned, gap: 0) }
        guard zip(found, found.dropFirst()).allSatisfy({ $0 < $1 }),
              found.allSatisfy({ f.indices.contains($0) && f[$0] == newline }) else { return nil }
        let empty = Set(found)
        // A field ending in an empty paragraph shows its `<br>` past the planner's last line.
        let last = found.last == f.count - 1
        var restoreAt: Set<Int> = []
        var dropAt: Int?
        for b in found {
            let candidates = aligned.valueOffsets(b)
            let at = candidates.upperBound
            guard at < v.count, v[at] == newline else { return nil }
            // The break before the first of a run that follows text, where `AXValue` has no line for it.
            if b > 0, !empty.contains(b - 1), candidates.count == 1, v[at - 1] != newline { restoreAt.insert(at) }
            if last, b == found.last { dropAt = at }
        }
        var model: [UInt16] = []
        var offsets: [Int] = []
        var shift = 0
        var nextAligned = aligned.offsets.makeIterator()
        var pending = nextAligned.next()
        for (i, unit) in v.enumerated() {
            if restoreAt.contains(i) {
                offsets.append(model.count)
                model.append(newline)
                shift += 1
            }
            if pending == i {
                guard i != dropAt else { return nil }
                offsets.append(i + shift)
                pending = nextAligned.next()
            }
            if i == dropAt {
                shift -= 1
                continue
            }
            model.append(unit)
        }
        let breaks = ParagraphBreaks(offsets: offsets)
        let text = String(decoding: model, as: UTF16.self)
        let expected = last ? Array(f.dropLast()) : f
        guard Array(breaks.fieldText(text, at: 0..<model.count).utf16) == expected,
              offsets.allSatisfy({ model.indices.contains($0) })
        else { return nil }
        return Model(text: text, breaks: breaks, gap: model.count - v.count)
    }
}
