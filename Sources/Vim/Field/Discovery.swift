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
        /// The walk read a node's start or end where the run may lie on either side of it.
        case boundary
        /// A walk now would read what the last one did not, or its reads were not kept.
        case unread
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

    /// The `AXValue` a run went into, whose line breaks show which side of a node's start or end the run is on.
    struct Lines {
        let value: [UInt16]
        let breaks: ParagraphBreaks
        let shown: Run
        private let added: Set<Int>

        init?(value: String, markers: String, shown: Run) {
            guard let breaks = ParagraphBreaks(value: value, fieldText: FieldReads.withoutAttachments(markers)) else { return nil }
            self.value = Array(value.utf16)
            self.breaks = breaks
            self.shown = shown
            added = Set(breaks.offsets)
        }

        /// A line break lies between the run and the text starting at plain `start`, so the run is not that text's.
        func parted(before start: Int) -> Bool {
            let first = min(breaks.valueOffsets(start).upperBound, value.count)
            return shown.removed == 0 && shown.at <= first && onlyAdded(shown.at..<first)
        }

        /// A line break lies between the text ending at plain `end` and the run.
        func parted(after end: Int) -> Bool {
            guard end > 0 else { return false }
            let next = breaks.valueOffsets(end - 1).upperBound + 1
            return next <= shown.earliest && onlyAdded(next..<shown.earliest)
        }

        /// `window` is line breaks Chromium added, in a run of newlines holding none of the text's, whose order `breaks` only guesses.
        private func onlyAdded(_ window: Range<Int>) -> Bool {
            guard !window.isEmpty else { return false }
            var lower = window.lowerBound
            var upper = window.upperBound
            while lower > 0, value[lower - 1] == 10 { lower -= 1 }
            while upper < value.count, value[upper] == 10 { upper += 1 }
            return (lower..<upper).allSatisfy(added.contains)
        }

        /// Where the run lies against text starting, or ending, at `x`: settled only at the run's own offset, across a line break.
        func start(_ x: Int, _ run: Run) -> Run.Lands { x == run.at && parted(before: x) ? .before : .either }
        func end(_ x: Int, _ run: Run) -> Run.Lands { x == run.earliest && parted(after: x) ? .after : .either }

        func shifted(_ range: Range<Int>, _ run: Run) -> Range<Int>? {
            guard let lower = run.shifted(range.lowerBound, lands: start(range.lowerBound, run)),
                  let upper = run.shifted(range.upperBound, lands: end(range.upperBound, run)), lower <= upper else { return nil }
            return lower..<upper
        }

        /// Where a node starting or ending at plain `x` is after the run; nil where the run may lie on either side of it.
        func boundary(_ x: Int, _ run: Run) -> Int? {
            // Every node boundary at the run's offset moves with the leaf the run went into, which only a line break shows.
            if run.removed > 0, x == run.earliest { return x }
            switch (start(x, run), end(x, run)) {
            case (.before, .after): return nil
            case (.before, _): return run.shifted(x, lands: .before)
            case (_, let lands): return run.shifted(x, lands: lands)
            }
        }
    }

    /// What a walk read, by tree path: what the same tree answers after typing moved its text, so the walk can be replayed.
    public struct Reads: Equatable, Sendable {
        struct Shape: Equatable, Sendable {
            let role: String?
            let subrole: String?
            let children: Int
            let classes: [String]
            let quoteLevel: Int
        }

        struct Key: Hashable, Sendable {
            let path: [Int]
            let end: Bool
        }

        /// The scan's budget, which a replay spends as the walk did.
        public let budget: Int
        var roots: Int?
        var shapes: [[Int]: Shape] = [:]
        var offsets: [Key: Int] = [:]
        /// Offsets `moved` dropped, for lying where the run may be on either side of them.
        var blurred: Set<Key> = []

        public init(budget: Int) {
            self.budget = budget
        }

        func moved(across run: Run, lines: Lines) -> Reads {
            var moved = self
            moved.offsets = [:]
            for (key, offset) in offsets {
                if let new = lines.boundary(offset, run) { moved.offsets[key] = new } else { moved.blurred.insert(key) }
            }
            return moved
        }
    }

    /// A node with its path from the field, which a walk's reads are kept by.
    public struct Pathed<Node> {
        public let node: Node
        let path: [Int]
    }

    /// The reads a scan walks a tree by, kept as it reads them.
    public final class Recorder<Node> {
        public private(set) var reads: Reads
        private let readBlock: (Node) -> EmptyBlockScan<Node>.Block?
        private let readOffset: (Node, _ end: Bool) -> Int?

        public init(
            budget: Int, block: @escaping (Node) -> EmptyBlockScan<Node>.Block?, offset: @escaping (Node, _ end: Bool) -> Int?
        ) {
            reads = Reads(budget: budget)
            readBlock = block
            readOffset = offset
        }

        public func roots(_ nodes: [Node]) -> [Pathed<Node>] {
            reads.roots = nodes.count
            return nodes.enumerated().map { Pathed(node: $1, path: [$0]) }
        }

        public func block(_ pathed: Pathed<Node>) -> EmptyBlockScan<Pathed<Node>>.Block? {
            guard let read = readBlock(pathed.node) else { return nil }
            reads.shapes[pathed.path] = Reads.Shape(
                role: read.role, subrole: read.subrole, children: read.children.count, classes: read.classes,
                quoteLevel: read.quoteLevel
            )
            return EmptyBlockScan.Block(
                role: read.role, subrole: read.subrole,
                children: read.children.enumerated().map { Pathed(node: $1, path: pathed.path + [$0]) }, classes: read.classes,
                quoteLevel: read.quoteLevel
            )
        }

        public func offset(_ pathed: Pathed<Node>, _ end: Bool) -> Int? {
            guard let offset = readOffset(pathed.node, end) else { return nil }
            reads.offsets[Reads.Key(path: pathed.path, end: end)] = offset
            return offset
        }
    }

    /// A walk's reads answering a scan over paths; the first it lacks stops the scan and says why.
    final class Replay {
        let reads: Reads
        private(set) var refusal: Rewalk?

        init(_ reads: Reads) {
            self.reads = reads
        }

        func roots(_ count: Int) -> [[Int]] {
            if reads.roots != count { refusal = .unread }
            return (0..<count).map { [$0] }
        }

        func block(_ path: [Int]) -> EmptyBlockScan<[Int]>.Block? {
            guard let shape = reads.shapes[path] else {
                refusal = .unread
                return nil
            }
            return EmptyBlockScan.Block(
                role: shape.role, subrole: shape.subrole, children: (0..<shape.children).map { path + [$0] },
                classes: shape.classes, quoteLevel: shape.quoteLevel
            )
        }

        func offset(_ path: [Int], _ end: Bool) -> Int? {
            let key = Reads.Key(path: path, end: end)
            guard let offset = reads.offsets[key] else {
                refusal = reads.blurred.contains(key) ? .boundary : .unread
                return nil
            }
            return offset
        }
    }
}
