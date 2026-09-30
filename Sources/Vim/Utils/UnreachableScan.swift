/// Confirms in a Chromium field's tree which lines are list markers and which are chips, with their paragraphs (LIN-1652).
public struct UnreachableScan<Node> {
    /// Nil when a read fails for any reason but the attribute's absence. One read.
    private let block: (Node) -> EmptyBlockScan<Node>.Block?
    /// A node's plain offset from the field's start, at its start or its end; nil on a failed read. Two reads.
    private let offset: (Node, _ end: Bool) -> Int?
    private let budget: Int
    public private(set) var reads = 0

    /// Reads by tree path, so candidates in one list or paragraph share them.
    private var blocks: [[Int]: EmptyBlockScan<Node>.Block] = [:]
    private var starts: [[Int]: Int] = [:]
    private var ends: [[Int]: Int] = [:]

    public init(
        budget: Int, block: @escaping (Node) -> EmptyBlockScan<Node>.Block?, offset: @escaping (Node, _ end: Bool) -> Int?
    ) {
        self.budget = budget
        self.block = block
        self.offset = offset
    }

    /// Nil on any failed read or past the budget.
    public mutating func run(blocks roots: [Node], candidates: UnreachableLines.Candidates) -> UnreachableLines.Found? {
        var markers: [Int] = []
        var chips: [UnreachableLines.Chip] = []
        for candidate in candidates.markers {
            guard let hit = descend(to: candidate, in: roots) else { return nil }
            if case .marker = hit { markers.append(candidate.lowerBound) }
        }
        for candidate in candidates.chips {
            guard let hit = descend(to: candidate, in: roots) else { return nil }
            if case .chip(let range, let paragraph) = hit { chips.append(UnreachableLines.Chip(range: range, paragraph: paragraph)) }
        }
        return UnreachableLines.Found(markers: markers, chips: chips)
    }

    private enum Hit {
        case marker
        case chip(Range<Int>, paragraph: Range<Int>)
        case neither
    }

    /// Descends through the children holding the candidate's start, found by binary search on their starts.
    private mutating func descend(to candidate: Range<Int>, in roots: [Node]) -> Hit? {
        var siblings = roots
        var path: [Int] = []
        var parent: (node: Node, start: Int)?
        var inList = false
        for _ in 0..<16 {
            var low = 0
            var high = siblings.count - 1
            var hit: (index: Int, start: Int)?
            while low <= high {
                let middle = (low + high) / 2
                guard let start = start(of: siblings[middle], at: path + [middle]) else { return nil }
                if start <= candidate.lowerBound {
                    hit = (middle, start)
                    low = middle + 1
                } else {
                    high = middle - 1
                }
            }
            guard let hit else { return .neither }
            let here = path + [hit.index]
            let node = siblings[hit.index]
            guard let read = read(node, at: here) else { return nil }
            if hit.start == candidate.lowerBound, read.subrole == "AXApplicationGroup" {
                guard let parent else { return .neither }
                guard let chipEnd = end(of: node, at: here), let paragraphEnd = end(of: parent.node, at: path) else { return nil }
                // Chromium puts a space after a chip on the chip's line.
                guard chipEnd > candidate.lowerBound + 1, chipEnd <= candidate.upperBound else { return .neither }
                return .chip(hit.start..<chipEnd, paragraph: parent.start..<paragraphEnd)
            }
            if inList, hit.start == candidate.lowerBound, read.children.count > 1 {
                guard let end = end(of: read.children[0], at: here + [0]) else { return nil }
                if end == candidate.upperBound { return .marker }
            }
            if read.role == "AXStaticText" || read.children.isEmpty { return .neither }
            inList = read.role == "AXList"
            parent = (node, hit.start)
            siblings = read.children
            path = here
        }
        return nil
    }

    private mutating func start(of node: Node, at path: [Int]) -> Int? {
        if let known = starts[path] { return known }
        guard spend(2), let start = offset(node, false) else { return nil }
        starts[path] = start
        return start
    }

    private mutating func end(of node: Node, at path: [Int]) -> Int? {
        if let known = ends[path] { return known }
        guard spend(2), let end = offset(node, true) else { return nil }
        ends[path] = end
        return end
    }

    private mutating func read(_ node: Node, at path: [Int]) -> EmptyBlockScan<Node>.Block? {
        if let known = blocks[path] { return known }
        guard spend(1), let read = block(node) else { return nil }
        blocks[path] = read
        return read
    }

    private mutating func spend(_ count: Int) -> Bool {
        reads += count
        return reads <= budget
    }
}
