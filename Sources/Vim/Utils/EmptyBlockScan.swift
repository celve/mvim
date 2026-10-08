/// Finds a field's empty blocks from the `\n`s of its plain marker text, each a `<br>`: an empty block's, or a soft
/// break's in a block with text. Pure over its reads, so `make test` drives it with a fake tree (LIN-1612).
public struct EmptyBlockScan<Node> {
    /// One node's role, subrole and children, with its DOM classes and how many quotes it is in, read together.
    public struct Block {
        public let role: String?
        public let subrole: String?
        public let children: [Node]
        public let classes: [String]
        public let quoteLevel: Int

        public init(role: String?, subrole: String?, children: [Node], classes: [String] = [], quoteLevel: Int = 0) {
            self.role = role
            self.subrole = subrole
            self.children = children
            self.classes = classes
            self.quoteLevel = quoteLevel
        }
    }

    /// Nil when a read fails for any reason but the attribute's absence. One read.
    private let block: (Node) -> Block?
    /// A node's plain offset from the field's start, at its start or its end; nil on a failed read. Two reads.
    private let offset: (Node, _ end: Bool) -> Int?
    private let budget: Int
    public private(set) var reads = 0
    /// The scan failed by running out of reads, not on a read.
    public private(set) var exhausted = false

    public init(budget: Int, block: @escaping (Node) -> Block?, offset: @escaping (Node, _ end: Bool) -> Int?) {
        self.budget = budget
        self.block = block
        self.offset = offset
    }

    private enum Verdict {
        case line
        /// An empty list item's paragraph, which shares its marker's line.
        case item
        case text(end: Int)
    }

    /// Ascending plain offsets of the `<br>`s of empty blocks that start a line; nil on any failed read or past the budget.
    public mutating func run(blocks: [Node], plain: [UInt16]) -> [Int]? {
        let candidates = plain.indices.filter { plain[$0] == 10 }
        guard !candidates.isEmpty else { return [] }
        guard reads + blocks.count <= budget else {
            exhausted = true
            return nil
        }
        var found: [Int] = []
        for node in blocks {
            guard spend(1), let read = block(node) else { return nil }
            guard read.subrole == "AXEmptyGroup", read.children.isEmpty else { continue }
            guard spend(2), let start = offset(node, false) else { return nil }
            if plain.indices.contains(start), plain[start] == 10 { found.append(start) }
        }
        // The rest are soft breaks or blocks nested in a quote, a table or a list.
        let known = Set(found)
        var covered = 0
        for b in candidates where b >= covered && !known.contains(b) {
            switch classify(b, in: blocks) {
            case nil: return nil
            case .line?: found.append(b)
            case .item?: break
            case .text(let end)?: covered = end
            }
        }
        return found.sorted()
    }

    /// Descends through the children holding plain offset `b`, found by binary search on their starts.
    private mutating func classify(_ b: Int, in blocks: [Node]) -> Verdict? {
        var siblings = blocks
        var parent: String?
        for _ in 0..<16 {
            var low = 0
            var high = siblings.count - 1
            var hit: (index: Int, start: Int)?
            while low <= high {
                let middle = (low + high) / 2
                guard spend(2), let start = offset(siblings[middle], false) else { return nil }
                if start <= b {
                    hit = (middle, start)
                    low = middle + 1
                } else {
                    high = middle - 1
                }
            }
            guard let hit else { return .text(end: b + 1) }
            let node = siblings[hit.index]
            guard spend(1), let read = block(node) else { return nil }
            if read.subrole == "AXEmptyGroup", read.children.isEmpty {
                guard hit.start == b else { return .text(end: b + 1) }
                // A caret drawn at a code span's end is followed by the `<br>` of the paragraph it ends (LIN-1683).
                if DrawnCaret.isCaret(parent: parent, previous: nil, next: nil) { return .text(end: b + 1) }
                guard hit.index > 0 else { return .line }
                guard spend(1), let previous = block(siblings[hit.index - 1]) else { return nil }
                // After a chip it is the image Linear puts there while the caret is beside it (LIN-1652).
                let drawn = DrawnCaret.isCaret(parent: nil, previous: previous.subrole, next: nil)
                if previous.subrole == "AXApplicationGroup" || drawn { return .text(end: b + 1) }
                return previous.role == "AXListMarker" ? .item : .line
            }
            if read.role == "AXStaticText" || read.children.isEmpty {
                guard spend(2), let end = offset(node, true) else { return nil }
                return .text(end: max(end, b + 1))
            }
            siblings = read.children
            parent = read.subrole
        }
        return nil
    }

    private mutating func spend(_ count: Int) -> Bool {
        reads += count
        exhausted = reads > budget
        return !exhausted
    }
}
