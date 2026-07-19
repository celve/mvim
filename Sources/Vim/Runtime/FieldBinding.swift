import ApplicationServices
import LoomCore

/// Probes what a focused field can do. Static probe only for now: trial
/// reads *prove* the read capabilities; settable flags *claim* the writes.
/// The lazy write probe and learned per-app priors arrive with the learner.
public enum FieldProber {
    public static func probe(_ element: AXUIElement) -> CapabilityProfile {
        var available: Set<Capability> = []
        if AX.value(of: element) != nil { available.insert(.readText) }
        if AX.selectedRange(of: element) != nil { available.insert(.readCaret) }
        if AX.length(of: element) != nil { available.insert(.readLength) }
        if AX.selectedText(of: element) != nil { available.insert(.readSelectedText) }
        if AX.rangeSettable(element) { available.insert(.writeSelection) }
        if AX.isInsertable(element) { available.insert(.insertText) }
        return CapabilityProfile(available: available)
    }

    /// The engage verdict for one element, from a single AX round trip.
    public struct FieldGate {
        public let isTextual: Bool
        public let isSecure: Bool
        public let isEnabled: Bool
        public var engageable: Bool { isTextual && !isSecure && isEnabled }
    }

    /// Whether Norm should engage at all. Conservative on purpose: only
    /// concrete text roles — engaging in a web area or list view would eat
    /// navigation keys the app owns. Secure fields are caught by role OR
    /// subrole: `NSSecureTextField` keeps role `AXTextField` and reveals
    /// itself only in the subrole.
    public static func gate(_ element: AXUIElement) -> FieldGate {
        let attributes = AX.gateAttributes(of: element)
        let textual: Bool
        switch attributes.role {
        case "AXTextField", "AXTextArea", "AXComboBox": textual = true
        default: textual = false
        }
        let secure = attributes.role == "AXSecureTextField"
            || attributes.subrole == "AXSecureTextField"
        return FieldGate(isTextual: textual, isSecure: secure, isEnabled: attributes.enabled)
    }
}

/// Reads the volatile half of a `FieldSnapshot`, fresh per command.
public enum Snapshotter {
    public static func snapshot(
        of element: AXUIElement,
        capabilities: CapabilityProfile,
        anchor: Int?,
        cursor: Range<Int>?
    ) -> FieldSnapshot {
        let text = capabilities.has(.readText) ? AX.value(of: element) : nil
        var selection: Range<Int>?
        if capabilities.has(.readCaret), let range = AX.selectedRange(of: element) {
            selection = range.location..<(range.location + range.length)
        }
        let length = capabilities.has(.readLength) ? AX.length(of: element) : nil
        // The drawn cursor counts only while it still IS the selection;
        // otherwise the selection is the user's.
        let stampedCursor = (cursor != nil && !cursor!.isEmpty && cursor == selection) ? cursor : nil
        return FieldSnapshot(
            capabilities: capabilities,
            text: text,
            selection: selection,
            length: length,
            anchor: anchor,
            cursor: stampedCursor
        )
    }
}
