/// Text a page generates in a field, such as an empty editor's placeholder, which is none of the field's (LIN-1930).
public enum GeneratedText {
    /// A field showing only a placeholder is a few nodes deep; past this many reads it keeps its text.
    public static let readBudget = 16

    /// `value` is `texts` alone, but for the `\n` Chromium adds for an empty paragraph's `<br>`.
    public static func fills(_ value: String, with texts: [String]) -> Bool {
        let shown = value.utf16.filter { $0 != 10 }
        return !shown.isEmpty && shown == texts.joined().utf16.filter { $0 != 10 }
    }
}

public extension FieldSnapshot.Reads {
    /// A field showing only its page's generated text holds none, its caret at the start; `raw` is what it answered.
    init(generatedOnly raw: FieldReads, length: Int?, webContent: Bool, blocks: Int?, markers: Bool) {
        self.init(
            field: FieldReads(
                text: raw.text.map { _ in "" }, plain: raw.plain.map { _ in 0..<0 }, selectedText: raw.selectedText.map { _ in "" },
                markers: markers ? MarkerReads(breaks: ParagraphBreaks(), value: 0..<0) : nil
            ),
            length: length.map { _ in 0 }, webContent: webContent, blocks: blocks, marked: markers ? 0..<0 : nil,
            inEmptyParagraph: false
        )
    }
}
