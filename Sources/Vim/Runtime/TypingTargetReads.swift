import ApplicationServices
import Core

/// `TypingTarget` over the accessibility tree (LIN-1742).
enum TypingTargetReads {
    static func field(for reported: AXUIElement) -> AXUIElement? {
        // A failed count answers that it has children, which leaves the field unbound.
        TypingTarget.field(for: reported, read: read, caret: AX.caretNode) { AX.childCount(of: $0) != 0 }
    }

    private static func read(_ node: AXUIElement) -> TypingTarget.Reading<AXUIElement> {
        let reads = AX.attributes([
            kAXRoleAttribute,            // 0
            kAXParentAttribute,          // 1
            "AXOwns",                    // 2
            AX.chromiumNodeIDAttribute,  // 3
        ], of: node)
        return TypingTarget.Reading(
            role: reads.string(0), parent: reads.element(1), owns: reads.elements(2) ?? [], isChromium: reads.string(3) != nil
        )
    }
}
