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
        var carets: [UnreachableLines.Caret] = []
        for candidate in candidates.markers {
            guard let hit = descend(to: candidate, in: roots) else { return nil }
            if case .marker = hit { markers.append(candidate.lowerBound) }
        }
        for candidate in candidates.chips {
            guard let hit = descend(to: candidate, in: roots) else { return nil }
            if case .chip(let range, let paragraph) = hit { chips.append(UnreachableLines.Chip(range: range, paragraph: paragraph)) }
        }
        for candidate in candidates.carets {
            guard let hit = caret(at: candidate, in: roots, path: [], ancestors: []) else { return nil }
            if let found = hit { carets.append(found) }
        }
        return UnreachableLines.Found(markers: markers, chips: chips, carets: carets)
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
            if inList, hit.start == candidate.lowerBound, let first = read.children.first {
                var marked = read.children.count > 1
                // An empty item of Chromium's own list holds its marker alone.
                if !marked {
                    guard let child = self.read(first, at: here + [0]) else { return nil }
                    marked = child.role == "AXListMarker"
                }
                if marked {
                    guard let end = end(of: first, at: here + [0]) else { return nil }
                    if end == candidate.upperBound { return .marker }
                }
            }
            if read.role == "AXStaticText" || read.children.isEmpty { return .neither }
            inList = read.role == "AXList"
            parent = (node, hit.start)
            siblings = read.children
            path = here
        }
        return nil
    }

    /// An ancestor of a drawn caret, nearest last: its reads, where it starts, and its place among its siblings.
    private struct Ancestor {
        let read: EmptyBlockScan<Node>.Block
        let start: Int
        let path: [Int]
        let siblings: [Node]

        var inline: Bool { DrawnCaret.isInline(role: read.role, subrole: read.subrole) }
    }

    /// The drawn caret among the nodes holding `p` at either end; `.some(nil)` where there is none, nil on a failed read.
    private mutating func caret(
        at p: Int, in siblings: [Node], path: [Int], ancestors: [Ancestor]
    ) -> UnreachableLines.Caret?? {
        guard ancestors.count < 16 else { return nil }
        var low = 0
        var high = siblings.count - 1
        var last: Int?
        while low <= high {
            let middle = (low + high) / 2
            guard let start = start(of: siblings[middle], at: path + [middle]) else { return nil }
            if start <= p {
                last = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard let last else { return .some(nil) }
        // Siblings are in text order, so those ending at or after `p` run back from the last starting at or before it.
        var first = last
        while first > 0 {
            guard let end = end(of: siblings[first - 1], at: path + [first - 1]) else { return nil }
            guard end >= p else { break }
            first -= 1
        }
        for index in first...last {
            let here = path + [index]
            guard let read = read(siblings[index], at: here) else { return nil }
            if DrawnCaret.isEmptyGroup(subrole: read.subrole, children: read.children.count) {
                guard let start = start(of: siblings[index], at: here) else { return nil }
                guard start == p else { continue }
                guard let place = place(of: here, among: siblings, under: ancestors) else { return nil }
                if let place { return .some(UnreachableLines.Caret(offset: p, place: place)) }
                continue
            }
            guard read.role != "AXStaticText", !read.children.isEmpty else { continue }
            guard let start = start(of: siblings[index], at: here) else { return nil }
            let ancestor = Ancestor(read: read, start: start, path: here, siblings: siblings)
            guard let found = caret(at: p, in: read.children, path: here, ancestors: ancestors + [ancestor]) else { return nil }
            if found != nil { return found }
        }
        return .some(nil)
    }

    /// Where a drawn caret at `path` sits in its paragraph; `.some(nil)` for an empty group that is none, nil on a failed read.
    private mutating func place(
        of path: [Int], among siblings: [Node], under ancestors: [Ancestor]
    ) -> UnreachableLines.Caret.Place?? {
        var drawn = false
        var index = path[path.count - 1]
        var level = siblings
        var levelPath = Array(path.dropLast())
        // Whether the empty group starts, and ends, each node from it up to this level.
        var atStart = true
        var atEnd = true
        var above = ancestors[...]
        while true {
            for (neighbour, touches) in [(index - 1, atStart), (index + 1, atEnd)]
            where touches && !drawn && level.indices.contains(neighbour) {
                guard let beside = read(level[neighbour], at: levelPath + [neighbour]) else { return nil }
                drawn = DrawnCaret.isCode(beside.subrole)
            }
            atStart = atStart && index == 0
            atEnd = atEnd && index == level.count - 1
            guard let parent = above.popLast(), parent.inline else { break }
            drawn = drawn || DrawnCaret.isCode(parent.read.subrole)
            index = parent.path[parent.path.count - 1]
            level = parent.siblings
            levelPath = Array(parent.path.dropLast())
        }
        guard drawn else { return .some(nil) }
        return .some(atStart ? .start : atEnd ? .end : .middle)
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
