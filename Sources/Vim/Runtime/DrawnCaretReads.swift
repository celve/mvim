import ApplicationServices
import Foundation
import Core

/// Linear's caret drawn at an inline code span's edge, read over AX (LIN-1683); `DrawnCaret` has the rules.
extension Snapshotter {
    /// The marker selection, with a caret Chromium reads at a paragraph's end moved to the caret Linear draws there.
    static func markedSelection(of element: AXUIElement, selected: AnyObject? = nil) -> AX.MarkedSelection? {
        guard let marked = AX.markedSelection(of: element, selected: selected) else { return nil }
        return misread(marked, in: element) ?? marked
    }

    /// The `AXValue` units a caret drawn at a collapsed read adds, which a settle leaves out of the length.
    static func drawnLength(at marked: AX.MarkedSelection) -> Int {
        guard marked.isCollapsed, let drawn = drawnCaret(at: marked.range.lowerBound, in: marked.element) else { return 0 }
        return DrawnCaret.length(drawn.place)
    }

    /// A read whose marker sits on the drawn caret, whose own side would name the next paragraph.
    static func drawnCaret(onMarkerOf marked: AX.MarkedSelection, upper: Bool) -> UnreachableLines.Caret? {
        guard marked.isCollapsed, let node = marked.node(upper: upper),
              AX.attributes([kAXSubroleAttribute], of: node).string(0) == "AXEmptyGroup" else { return nil }
        return drawnCaret(at: marked.range.lowerBound, in: marked.element)
    }

    /// Keys leave the caret outside a code span's start with its marker on the paragraph at its length.
    private static func misread(_ marked: AX.MarkedSelection, in element: AXUIElement) -> AX.MarkedSelection? {
        guard marked.isCollapsed, let paragraph = marked.node(upper: false), AX.role(of: paragraph) == kAXGroupRole,
              let count = AX.childCount(of: paragraph), (2...64).contains(count), marked.side(upper: false) == .end,
              let children = AX.children(of: paragraph) else { return nil }
        let reads = children.map { AX.attributes([kAXSubroleAttribute, kAXChildrenAttribute], of: $0) }
        let subroles = reads.map { $0.string(0) }
        let caret = children.indices.first { index in
            DrawnCaret.isEmptyGroup(subrole: subroles[index], children: reads[index].elements(1)?.count ?? 0)
                && DrawnCaret.isCaret(parent: nil, previous: index > 0 ? subroles[index - 1] : nil,
                                      next: index + 1 < children.count ? subroles[index + 1] : nil)
        }
        return caret.flatMap { AX.markedSelection(at: children[$0], in: element) }
    }

    /// `reading`, read `again` once Linear has drawn a caret it is about to and removed one it drew for a caret that left.
    static func settled(_ reading: Reading, in element: AXUIElement, again: (Reading) -> Reading) -> Reading {
        var reading = reading
        if waitsForDrawnCaret(reading.snapshot, in: element) { reading = again(reading) }
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline, lingers(reading.snapshot, in: element) {
            Thread.sleep(forTimeInterval: 0.02)
            reading = again(reading)
        }
        return reading
    }

    /// Waits for the caret Linear draws 20–160 ms late at a code span's end ending a paragraph, whose `<br>` moves offsets.
    static func waitsForDrawnCaret(_ snapshot: FieldSnapshot, in element: AXUIElement) -> Bool {
        // Keys still landing read as a selection, which may yet end at a code span's end.
        guard snapshot.breaks != nil, !snapshot.holdsDrawnCaret, let caret = snapshot.caret, let text = snapshot.text,
              TextModel(text).lineEnd(of: caret) == caret, let marked = AX.markedSelection(of: element),
              !marked.isCollapsed || atCodeEnd(marked) else { return false }
        let length = AX.attributes([kAXNumberOfCharactersAttribute], of: element).int(0)
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline, AX.attributes([kAXNumberOfCharactersAttribute], of: element).int(0) == length {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// A caret at the end of a code span's text, where Linear is about to draw one.
    private static func atCodeEnd(_ marked: AX.MarkedSelection) -> Bool {
        guard marked.side(upper: false) == .end, let node = marked.node(upper: false), AX.role(of: node) == kAXStaticTextRole,
              let parent = AX.parent(of: node) else { return false }
        return DrawnCaret.isCode(AX.attributes([kAXSubroleAttribute], of: parent).string(0))
    }

    /// A `<br>` Linear drew for a caret that has since left, which goes up to 300 ms later and moves every offset past it.
    static func lingers(_ snapshot: FieldSnapshot, in element: AXUIElement) -> Bool {
        guard let drawnBreak = snapshot.drawnBreak, let marked = AX.markedSelection(of: element) else { return false }
        return !marked.isCollapsed || marked.range.lowerBound != drawnBreak
    }

    /// The drawn caret at plain `offset`, confirmed as discovery confirms one; nil where there is none or a read fails.
    static func drawnCaret(at offset: Int, in element: AXUIElement) -> UnreachableLines.Caret? {
        guard let markers = AX.markerText(of: element), let tree = FieldTree(element, markers: markers) else { return nil }
        var scan = UnreachableScan<AXUIElement>(budget: 256, block: tree.block, offset: tree.offset)
        return scan.run(blocks: tree.blocks, candidates: UnreachableLines.Candidates(markers: [], chips: [], carets: [offset]))?
            .carets.first
    }
}
