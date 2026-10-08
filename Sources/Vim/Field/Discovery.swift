/// What carries `EmptyParagraphs`' and `UnreachableLines`' discoveries across typed text instead of a new walk (LIN-1874).
public enum Discovery {
    /// One run of text typed or deleted between two texts, in plain offsets.
    public struct Run: Equatable, Sendable {
        /// Where the run starts: the latest it can and the earliest, which differ where its text repeats what is beside it.
        public let at: Int
        public let earliest: Int
        public let inserted: Int
        public let removed: Int

        /// Where text that went in at an offset lies against what starts or ends there.
        public enum Lands: Equatable, Sendable {
            case before
            case after
            case either
        }

        /// Nil unless `new` is `old` with one run inserted or removed that holds no line break or U+FFFC.
        public init?(from old: String, to new: String) {
            let a = Array(old.utf16)
            let b = Array(new.utf16)
            let late = Self.split(a, b, prefixFirst: true)
            let removed = a[late.prefix..<(a.count - late.suffix)]
            let inserted = b[late.prefix..<(b.count - late.suffix)]
            guard removed.isEmpty != inserted.isEmpty, !(removed + inserted).contains(where: { $0 == 10 || $0 == 0xFFFC })
            else { return nil }
            func plain(_ raw: Int) -> Int { a[..<raw].reduce(0) { $1 == 0xFFFC ? $0 : $0 + 1 } }
            at = plain(late.prefix)
            earliest = plain(Self.split(a, b, prefixFirst: false).prefix)
            self.inserted = inserted.count
            self.removed = removed.count
        }

        /// Where `offset` is after the run; nil where the run may lie on either side of it, or took it.
        public func shifted(_ offset: Int, lands: Lands = .either) -> Int? {
            if offset < earliest { return offset }
            if offset >= at + max(removed, 1) { return offset + inserted - removed }
            switch lands {
            case .before where removed == 0 && offset == at: return offset + inserted
            case .after where offset == earliest: return offset
            default: return nil
            }
        }

        func shifted(_ offsets: [Int], lands: Lands = .either) -> [Int]? {
            let moved = offsets.compactMap { shifted($0, lands: lands) }
            return moved.count == offsets.count ? moved : nil
        }

        public var traceField: String { "@\(at)\(removed > 0 ? "-\(removed)" : "+\(inserted)")" }

        /// The common prefix and suffix, whichever goes first taking all it can.
        private static func split(_ a: [UInt16], _ b: [UInt16], prefixFirst: Bool) -> (prefix: Int, suffix: Int) {
            let shorter = min(a.count, b.count)
            var prefix = 0
            var suffix = 0
            func growPrefix(_ limit: Int) { while prefix < limit, a[prefix] == b[prefix] { prefix += 1 } }
            func growSuffix(_ limit: Int) {
                while suffix < limit, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
            }
            if prefixFirst {
                growPrefix(shorter)
                growSuffix(shorter - prefix)
            } else {
                growSuffix(shorter)
                growPrefix(shorter - suffix)
            }
            return (prefix, suffix)
        }
    }

    /// Why discovery walks again rather than carry its last result to the field's text.
    public enum Rewalk: String, Error, Sendable {
        /// The field has no result yet.
        case first
        case blocks
        case roots
        /// The marker text changed by more than one run of text, or by a line break or an object.
        case edit
        /// `AXValue` did not change by a run as long as the marker text's.
        case value
        /// The last walk failed a read, which the next may not.
        case failed
        /// A line took or lost the shape of a list marker or a chip, so a walk would check other lines than the last one did.
        case candidates
        /// A result sits where the run may lie on either side of it.
        case boundary
    }

    /// How a result came to be.
    public enum Origin: Equatable, Sendable {
        case walked(Rewalk)
        case shifted(Run)

        public var traceField: String {
            switch self {
            case .walked(let why): return "walked=\(why.rawValue)"
            case .shifted(let run): return "shifted=\(run.traceField)"
            }
        }
    }

    /// The run typed between a result's texts and the field's, and the same run in `AXValue`'s own offsets.
    static func run(
        markers old: String, value oldValue: String, to markers: String, value: String
    ) -> Result<(run: Run, shown: Run), Rewalk> {
        guard let run = Run(from: old, to: markers) else { return .failure(.edit) }
        guard let shown = Run(from: oldValue, to: value), shown.inserted == run.inserted, shown.removed == run.removed else {
            return .failure(.value)
        }
        return .success((run, shown))
    }

    /// The `AXValue` a run went into, which shows each list marker, chip and code label on a line of its own.
    struct Lines {
        let value: [UInt16]
        let breaks: ParagraphBreaks
        let shown: Run

        init?(value: String, markers: String, shown: Run) {
            guard let breaks = ParagraphBreaks(value: value, fieldText: FieldReads.withoutAttachments(markers)) else { return nil }
            self.value = Array(value.utf16)
            self.breaks = breaks
            self.shown = shown
        }

        /// A line break lies between the run and the text starting at plain `start`, so the run is not that text's.
        func parted(before start: Int) -> Bool {
            let first = min(breaks.valueOffsets(start).upperBound, value.count)
            return shown.removed == 0 && shown.at <= first && value[shown.at..<first].contains(10)
        }

        /// A line break lies between the text ending at plain `end` and the run.
        func parted(after end: Int) -> Bool {
            guard end > 0 else { return false }
            let next = breaks.valueOffsets(end - 1).upperBound + 1
            return next <= shown.earliest && value[next..<shown.earliest].contains(10)
        }

        /// Where the run lies against text starting, or ending, at `x`: settled only at the run's own offset, across a line break.
        func start(_ x: Int, _ run: Run) -> Run.Lands { x == run.at && parted(before: x) ? .before : .either }
        func end(_ x: Int, _ run: Run) -> Run.Lands { x == run.earliest && parted(after: x) ? .after : .either }

        func shifted(_ range: Range<Int>, _ run: Run) -> Range<Int>? {
            guard let lower = run.shifted(range.lowerBound, lands: start(range.lowerBound, run)),
                  let upper = run.shifted(range.upperBound, lands: end(range.upperBound, run)), lower <= upper else { return nil }
            return lower..<upper
        }

        /// The plain extent of the list marker starting at `start`: its whole line, or the prefix before its item's text.
        func marker(at start: Int) -> Range<Int>? {
            let first = breaks.valueOffsets(start).upperBound
            guard first <= value.count else { return nil }
            let line = Array(value[first...].prefix { $0 != 10 })
            let length = UnreachableLines.isMarkerShaped(line) ? line.count : UnreachableLines.prefixLength(line)
            return length.map { start..<(start + $0) }
        }

        /// The run stays off `item`'s own text, or meets it only at an edge a line break parts it from.
        func clear(of item: Range<Int>, _ run: Run) -> Bool {
            guard run.removed == 0 else { return run.earliest >= item.upperBound || run.at + run.removed <= item.lowerBound }
            let first = max(run.earliest, item.lowerBound)
            let last = min(run.at, item.upperBound)
            guard first <= last else { return true }
            guard first == last else { return false }
            if first == item.lowerBound { return parted(before: first) }
            return first == item.upperBound && parted(after: first)
        }
    }
}
