/// Finds the field typing reaches where Chromium reports its highlighted popup row as focused; pure, so `make test` covers it.
public enum TypingTarget {
    /// The roles mvim engages on.
    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// Deep enough for a row in a tree's nested groups.
    public static let ownerHops = 8

    /// A row and its list lie in their field's page, so nothing at or above one is looked at.
    private static let page = "AXWebArea"

    /// Chromium gives a button or a link no selection container, so one reported as focused has the real focus.
    private static let notRows: Set<String> = ["AXButton", "AXLink"]

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

    /// What typing reaches: `reported`, or the field that `field` finds for it.
    public static func target<Node: Equatable>(
        of reported: Node, bound: Node?, field: (Node) -> Node?, refocus: () -> Node?
    ) -> Node {
        if reported == bound { return reported }
        if let owner = field(reported) { return owner }
        // A menu replacing its rows can destroy the reported one mid-read, and a miss would cost the bound field its mode.
        guard let bound, let current = refocus(), current != reported else { return reported }
        return current == bound || field(current) == bound ? bound : reported
    }

    /// The `<input>` or `<textarea>` holding the caret, when it owns `reported` or an ancestor of it; nil outside Chromium.
    public static func field<Node: Equatable>(
        for reported: Node, read: (Node) -> Reading<Node>, caret: (Node) -> Node?, hasChildren: (Node) -> Bool
    ) -> Node? {
        let focus = read(reported)
        guard focus.isChromium, let role = focus.role, !textRoles.contains(role), !notRows.contains(role), role != page,
              let field = caret(reported) else { return nil }
        let held = read(field)
        // The caret's node is a control only while that control has the real focus: left behind, it reads on the text inside.
        guard let heldRole = held.role, textRoles.contains(heldRole), !held.owns.isEmpty else { return nil }
        // A rich editor's caret reads the same with the focus or without, and unlike a control the editor has children.
        guard !hasChildren(field) else { return nil }
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
