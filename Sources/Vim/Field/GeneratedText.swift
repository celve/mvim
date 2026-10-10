/// Text a page generates in a field, such as an empty editor's placeholder, which is none of the field's (LIN-1930).
public enum GeneratedText {
    /// A field showing only a placeholder is a few nodes deep; past this many reads it keeps its text.
    public static let readBudget = 16

    /// One empty paragraph shows its `<br>` as at most one `\n`; a field of more shows more, and reads as it did.
    public static func mayFill(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.filter { $0 == 10 }.count <= 1
    }

    /// `value` is `texts` alone, but for that `\n`.
    public static func fills(_ value: String, with texts: [String]) -> Bool {
        let shown = value.utf16.filter { $0 != 10 }
        return mayFill(value) && !shown.isEmpty && shown == texts.joined().utf16.filter { $0 != 10 }
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
