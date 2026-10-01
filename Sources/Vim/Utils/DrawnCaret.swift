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

    /// Also when an inline group it starts or ends is beside one, as the bold group that holds it before a code span.
    public static func isCode(_ subrole: String?) -> Bool {
        subrole == code
    }

    /// Links and style groups sit inside a paragraph, so a drawn caret's paragraph is the first ancestor that is neither.
    public static func isInline(role: String?, subrole: String?) -> Bool {
        role == "AXLink" || subrole?.hasSuffix("StyleGroup") == true
    }

    /// The `AXValue` units one adds: two in the middle of its paragraph, one at its start or at its end.
    public static func length(_ place: UnreachableLines.Caret.Place) -> Int {
        place == .middle ? 2 : 1
    }

    /// Typing there lands in its paragraph, which starts or ends there.
    public static func side(_ place: UnreachableLines.Caret.Place) -> ParagraphBreaks.Side {
        place == .start ? .start(skipping: 0) : .end
    }
}
