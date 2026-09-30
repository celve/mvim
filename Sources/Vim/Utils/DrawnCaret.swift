/// Linear draws the caret at an inline code span's edge as an empty group, inside the code's group or beside it (LIN-1683).
public enum DrawnCaret {
    static let code = "AXCodeStyleGroup"

    /// A group with no children and no text: an empty paragraph's block, or a drawn caret.
    public static func isEmptyGroup(subrole: String?, children: Int) -> Bool {
        subrole == "AXEmptyGroup" && children == 0
    }

    /// An empty group is a drawn caret when its parent or a sibling next to it is a code span's group.
    public static func isCaret(parent: String?, previous: String?, next: String?) -> Bool {
        parent == code || previous == code || next == code
    }

    /// Links and style groups sit inside a paragraph, so a drawn caret's paragraph is the first ancestor that is neither.
    public static func isInline(role: String?, subrole: String?) -> Bool {
        role == "AXLink" || subrole?.hasSuffix("StyleGroup") == true
    }
}
