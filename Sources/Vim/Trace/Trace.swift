/// Engine values as short strings. Pure, so `make test` pins the rule that none holds user text.
enum Trace {
    // MARK: - Ranges

    static func range(_ range: Range<Int>?) -> String {
        guard let range else { return "nil" }
        return "\(range.lowerBound)..\(range.upperBound)"
    }

    static func optional(_ value: Int?) -> String {
        guard let value else { return "nil" }
        return "\(value)"
    }
}
