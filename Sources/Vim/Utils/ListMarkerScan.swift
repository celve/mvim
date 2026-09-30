/// Tells which marker-shaped lines of a Chromium field are list markers: a list item's first child, where the item has
/// more. A paragraph that only reads `1.` is not one. Pure over its reads, so `make test` drives it with a fake tree (LIN-1652).
public struct ListMarkerScan<Node> {
    /// Nil when a read fails for any reason but the attribute's absence. One read.
    private let block: (Node) -> EmptyBlockScan<Node>.Block?
    /// A node's plain offset from the field's start, at its start or its end; nil on a failed read. Two reads.
    private let offset: (Node, _ end: Bool) -> Int?
    private let budget: Int
    public private(set) var reads = 0

    /// Reads by tree path, so candidates in one list share them.
    private var blocks: [[Int]: EmptyBlockScan<Node>.Block] = [:]
    private var starts: [[Int]: Int] = [:]

    public init(
        budget: Int, block: @escaping (Node) -> EmptyBlockScan<Node>.Block?, offset: @escaping (Node, _ end: Bool) -> Int?
    ) {
        self.budget = budget
        self.block = block
        self.offset = offset
    }

    /// Plain starts of the candidates that are list markers; nil on any failed read or past the budget.
    public mutating func run(blocks roots: [Node], candidates: [Range<Int>]) -> [Int]? {
        var found: [Int] = []
        for candidate in candidates {
            guard let marker = isMarker(candidate, in: roots) else { return nil }
            if marker { found.append(candidate.lowerBound) }
        }
        return found
    }

    /// Descends through the children holding the candidate's start, found by binary search on their starts.
    private mutating func isMarker(_ candidate: Range<Int>, in roots: [Node]) -> Bool? {
        var siblings = roots
        var path: [Int] = []
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
            guard let hit else { return false }
            let here = path + [hit.index]
            guard let read = read(siblings[hit.index], at: here) else { return nil }
            if inList, hit.start == candidate.lowerBound, read.children.count > 1 {
                guard spend(2), let end = offset(read.children[0], true) else { return nil }
                if end == candidate.upperBound { return true }
            }
            if read.role == "AXStaticText" || read.children.isEmpty { return false }
            inList = read.role == "AXList"
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
