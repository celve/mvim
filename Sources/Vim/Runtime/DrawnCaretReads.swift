import ApplicationServices
import Core

/// Linear's caret drawn at an inline code span's edge, read over AX (LIN-1683); `DrawnCaret` has the rules.
extension Snapshotter {
    struct Drawn {
        let node: AXUIElement
        let offset: Int
        let paragraph: Range<Int>
    }

    /// The marker selection, with a caret Chromium reads at a paragraph's end moved to the caret Linear draws there.
    static func markedSelection(of element: AXUIElement, selected: AnyObject? = nil) -> AX.MarkedSelection? {
        guard let marked = AX.markedSelection(of: element, selected: selected) else { return nil }
        return misread(marked, in: element) ?? marked
    }

    /// The `AXValue` units a caret drawn at a collapsed read adds, which a settle leaves out of the length.
    static func drawnLength(at marked: AX.MarkedSelection) -> Int {
        guard let drawn = drawnCaret(near: marked), drawn.offset == marked.range.lowerBound else { return 0 }
        return DrawnCaret.length(at: drawn.offset, paragraph: drawn.paragraph)
    }

    /// Keys leave the caret outside a code span's start with its marker on the paragraph at its length.
    private static func misread(_ marked: AX.MarkedSelection, in element: AXUIElement) -> AX.MarkedSelection? {
        guard marked.isCollapsed, let node = marked.node(upper: false), AX.role(of: node) == kAXGroupRole,
              AX.childCount(of: node).map({ $0 > 1 }) == true, marked.side(upper: false) == .end,
              let drawn = drawnCaret(near: marked), drawn.offset < marked.range.lowerBound else { return nil }
        return AX.markedSelection(at: drawn.node, in: element)
    }

    /// A read whose marker sits on the drawn caret itself, whose own side would name the next paragraph.
    static func drawnCaret(onMarkerOf marked: AX.MarkedSelection, upper: Bool) -> Drawn? {
        guard marked.isCollapsed, let node = marked.node(upper: upper),
              AX.attributes([kAXSubroleAttribute], of: node).string(0) == "AXEmptyGroup" else { return nil }
        return drawnCaret(near: marked)
    }

    /// Up from the caret's node to its paragraph, then among its children and its code spans' ends.
    static func drawnCaret(near marked: AX.MarkedSelection) -> Drawn? {
        guard marked.isCollapsed, var paragraph = marked.node(upper: false) else { return nil }
        for _ in 0..<4 {
            let reads = AX.attributes([kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute], of: paragraph)
            if !(reads.elements(2) ?? []).isEmpty, !DrawnCaret.isInline(role: reads.string(0), subrole: reads.string(1)) { break }
            guard let parent = AX.parent(of: paragraph) else { return nil }
            paragraph = parent
        }
        guard let children = AX.children(of: paragraph), (1...64).contains(children.count) else { return nil }
        let reads = children.map { AX.attributes([kAXSubroleAttribute, kAXChildrenAttribute], of: $0) }
        let subroles = reads.map { $0.string(0) }
        var caret: AXUIElement?
        for (index, read) in reads.enumerated() where caret == nil {
            let inner = read.elements(1) ?? []
            if DrawnCaret.isEmptyGroup(subrole: subroles[index], children: inner.count),
               DrawnCaret.isCaret(parent: nil, previous: index > 0 ? subroles[index - 1] : nil,
                                  next: index + 1 < children.count ? subroles[index + 1] : nil) {
                caret = children[index]
            } else if subroles[index] == "AXCodeStyleGroup", inner.count > 1 {
                caret = [inner[0], inner[inner.count - 1]].first { node in
                    let edge = AX.attributes([kAXSubroleAttribute, kAXChildrenAttribute], of: node)
                    return DrawnCaret.isEmptyGroup(subrole: edge.string(0), children: edge.elements(1)?.count ?? 0)
                }
            }
        }
        let element = marked.element
        guard let caret, let offset = AX.plainRange(of: caret, in: element)?.lowerBound,
              let range = AX.plainRange(of: paragraph, in: element) else { return nil }
        return Drawn(node: caret, offset: offset, paragraph: range)
    }
}
