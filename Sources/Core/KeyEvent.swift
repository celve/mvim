import CoreGraphics

/// Backend-agnostic key event, normalized from the event tap's `CGEvent`.
/// Norm's copy carries no NSEvent/recorder path — the tap is the only source.
public struct KeyEvent {
    public enum Kind { case keyDown, keyUp, flagsChanged }

    public let kind: Kind
    public let keyCode: Int
    public let mods: Mods
    public let isRepeat: Bool

    /// Layout+shift-resolved text (empty for flagsChanged). Straight from the
    /// event, so non-US layouts resolve without a keycode table.
    public let characters: String

    public init?(cgType: CGEventType, cgEvent: CGEvent) {
        switch cgType {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default: return nil
        }
        keyCode = Int(cgEvent.getIntegerValueField(.keyboardEventKeycode))
        mods = Mods(cgFlags: cgEvent.flags)
        isRepeat = cgEvent.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if cgType == .flagsChanged {
            characters = ""
        } else {
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 4)
            cgEvent.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
            characters = String(utf16CodeUnits: buffer, count: max(0, length))
        }
    }
}
