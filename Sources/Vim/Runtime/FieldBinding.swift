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

    /// Whether Norm should engage at all. Conservative on purpose: only
    /// concrete text roles — engaging in a web area or list view would eat
    /// navigation keys the app owns.
    public static func isTextual(_ element: AXUIElement) -> Bool {
        switch AX.role(of: element) {
        case "AXTextField", "AXTextArea", "AXComboBox":
            return true
        default:
            return false
        }
    }
}

/// Reads the volatile half of a `FieldSnapshot`, fresh per command.
public enum Snapshotter {
    public static func snapshot(
        of element: AXUIElement,
        capabilities: CapabilityProfile,
        anchor: Int?
    ) -> FieldSnapshot {
        let text = capabilities.has(.readText) ? AX.value(of: element) : nil
        var selection: Range<Int>?
        if capabilities.has(.readCaret), let range = AX.selectedRange(of: element) {
            selection = range.location..<(range.location + range.length)
        }
        let length = capabilities.has(.readLength) ? AX.length(of: element) : nil
        return FieldSnapshot(
            capabilities: capabilities,
            text: text,
            selection: selection,
            length: length,
            anchor: anchor
        )
    }
}
