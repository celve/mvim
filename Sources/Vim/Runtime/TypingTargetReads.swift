import ApplicationServices
import Core

/// `TypingTarget` over the accessibility tree (LIN-1742).
enum TypingTargetReads {
    static func field(for reported: AXUIElement) -> AXUIElement? {
        TypingTarget.field(for: reported, read: read, caretField: caretField)
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

    /// `AXEditableAncestor` is Chromium's nearest text field at or above a node, whatever the depth between them.
    private static func caretField(of reported: AXUIElement) -> AXUIElement? {
        AX.caretNode(of: reported).flatMap { AX.attributes(["AXEditableAncestor"], of: $0).element(0) }
    }
}
