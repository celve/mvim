/// Chromium's marker text holds a U+FFFC for each text-less leaf (an icon, an `<hr>`), which `AXValue` leaves out.
public enum MarkerText {
    static let objectReplacement: UInt16 = 0xFFFC

    public static func plain(_ text: String) -> String {
        String(decoding: text.utf16.filter { $0 != objectReplacement }, as: UTF16.self)
    }

    public static func plainLength(_ text: String) -> Int {
        text.utf16.reduce(0) { $1 == objectReplacement ? $0 : $0 + 1 }
    }
}
