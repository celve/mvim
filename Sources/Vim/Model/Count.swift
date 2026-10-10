/// How large a command's count may be, and how often one may repeat what no text bounds.
public enum Count {
    /// Vim's own ceiling, low enough that a sum or product of two counts fits in an `Int`.
    public static let max = 999_999_999

    /// The most times a count repeats a key, a paste or a copy of text where the field's text does not stop it sooner.
    public static let repeatLimit = 1_000

    /// `2d3w` is six words; past the ceiling the product stays there, as in Vim.
    public static func product(_ count: Int, _ other: Int) -> Int {
        let (product, overflow) = count.multipliedReportingOverflow(by: other)
        return overflow ? max : Swift.min(product, max)
    }
}
