/// The text a page generates in a field, which Chromium gives a negative node id as no DOM node backs it (LIN-1930).
public struct GeneratedTextScan<Node> {
    /// One node's role, `ChromeAXNodeId`, value and children, read together.
    public struct Read {
        public let role: String?
        public let id: Int?
        public let value: String?
        public let children: [Node]

        public init(role: String?, id: Int?, value: String? = nil, children: [Node] = []) {
            self.role = role
            self.id = id
            self.value = value
            self.children = children
        }
    }

    /// Nil on a failed read.
    private let read: (Node) -> Read?
    private let budget: Int
    public private(set) var reads = 0

    public init(budget: Int, read: @escaping (Node) -> Read?) {
        self.budget = budget
        self.read = read
    }

    /// The generated texts in tree order; nil at the page's own text or list marker, on a failed read, or past the budget.
    public mutating func run(roots: [Node]) -> [String]? {
        var texts: [String] = []
        var pending = Array(roots.reversed())
        while let node = pending.popLast() {
            reads += 1
            guard reads <= budget, let read = read(node) else { return nil }
            switch read.role {
            case "AXStaticText"?:
                guard let id = read.id, id < 0, let value = read.value else { return nil }
                texts.append(value)
            case "AXListMarker"?:
                return nil
            default:
                pending += read.children.reversed()
            }
        }
        return texts
    }
}
