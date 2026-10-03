/// Finds the field typing reaches where Chromium reports its highlighted popup row as focused; pure, so `make test` covers it.
public enum TypingTarget {
    /// The roles mvim engages on.
    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// Deep enough for a row in a tree's nested groups.
    public static let ownerHops = 8

    /// A row and its list lie in their field's page, so nothing at or above one is looked at.
    private static let page = "AXWebArea"

    /// One node's batched read; a failed one leaves `role` nil.
    public struct Reading<Node> {
        public var role: String?
        public var parent: Node?
        /// `AXOwns`, which in Chromium is the list, grid or tree holding the node's `aria-activedescendant`, and nothing else.
        public var owns: [Node]
        public var isChromium: Bool

        public init(role: String?, parent: Node? = nil, owns: [Node] = [], isChromium: Bool = true) {
            self.role = role
            self.parent = parent
            self.owns = owns
            self.isChromium = isChromium
        }
    }

    /// The field holding the caret, when it owns `reported` or an ancestor of it; nil for a text field and outside Chromium.
    public static func field<Node: Equatable>(
        for reported: Node, read: (Node) -> Reading<Node>, caretField: (Node) -> Node?
    ) -> Node? {
        let focus = read(reported)
        guard focus.isChromium, let role = focus.role, !textRoles.contains(role), role != page,
              let field = caretField(reported) else { return nil }
        let held = read(field)
        // Chromium leaves the caret in a field that focus has left, and such a field owns nothing of the new focus.
        guard let heldRole = held.role, textRoles.contains(heldRole), !held.owns.isEmpty else { return nil }
        var ancestor = reported
        var reading: Reading<Node>? = focus
        for _ in 0..<ownerHops {
            if held.owns.contains(ancestor) { return field }
            let current = reading ?? read(ancestor)
            guard current.role != page, let parent = current.parent else { return nil }
            ancestor = parent
            reading = nil
        }
        return held.owns.contains(ancestor) ? field : nil
    }
}
