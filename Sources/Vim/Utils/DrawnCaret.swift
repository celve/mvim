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

    /// The `AXValue` units one at plain `offset` adds: two inside `paragraph`, one at its start or at its end.
    public static func length(at offset: Int, paragraph: Range<Int>) -> Int {
        offset == paragraph.lowerBound || paragraph.upperBound - offset <= 1 ? 1 : 2
    }

    /// Typing there lands at `paragraph`'s start, or else in the paragraph it ends.
    public static func side(at offset: Int, paragraph: Range<Int>) -> ParagraphBreaks.Side {
        offset == paragraph.lowerBound ? .start(skipping: 0) : .end
    }
}
