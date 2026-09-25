/// Cocoa's standard key bindings over plain text, as measured in `NSTextView`: where the planner expects lane B's
/// keys to land, and what the Sim's field does with them.
struct KeyModel {
    var text: String
    var anchor: Int
    var focus: Int

    /// Graphemes per visual row for ↓ ↑ ⌘← ⌘→; nil lays each line on one row.
    var wrap: Int?

    var selection: Range<Int> { min(anchor, focus)..<max(anchor, focus) }

    /// Applies one press; false for a key the model does not know.
    mutating func press(_ chord: Chord) -> Bool {
        let model = TextModel(text)
        let shift = chord.modifiers.contains(.shift)
        let collapsed = anchor == focus
        let moved: Int
        switch Chord(chord.key, chord.modifiers.subtracting(.shift)) {
        case .deleteBack where !shift:
            let range = collapsed ? model.advance(focus, byGraphemes: -1)..<focus : selection
            text = model.replacing(range, with: "")
            anchor = range.lowerBound
            focus = range.lowerBound
            return true
        case .left:
            moved = !shift && !collapsed ? selection.lowerBound : model.advance(focus, byGraphemes: -1)
        case .right:
            moved = !shift && !collapsed ? selection.upperBound : model.advance(focus, byGraphemes: 1)
        case .paragraphStart:
            moved = model.lineStart(of: shift ? focus : selection.lowerBound)
        case .paragraphEnd:
            moved = model.lineEnd(of: shift ? focus : selection.upperBound)
        case .documentStart:
            moved = 0
        case .documentEnd:
            moved = model.length
        case .selectAll where !shift:
            anchor = 0
            focus = model.length
            return true
        case .lineStart:
            moved = row(of: shift ? focus : selection.lowerBound, in: model).start
        case .lineEnd:
            moved = row(of: shift ? focus : selection.upperBound, in: model).end
        case .down:
            moved = vertical(from: shift ? focus : selection.upperBound, by: 1, in: model)
        case .up:
            moved = vertical(from: shift ? focus : selection.lowerBound, by: -1, in: model)
        case .wordRight:
            moved = wordEnd(from: shift ? focus : selection.upperBound, in: model)
        case .wordLeft:
            moved = wordStart(from: shift ? focus : selection.lowerBound, in: model)
        case .paragraphForward where !shift:
            let from = selection.upperBound
            moved = from < model.length ? model.lineEnd(of: model.advance(from, byGraphemes: 1)) : from
        case .paragraphBackward where !shift:
            let from = selection.lowerBound
            moved = from > 0 ? model.lineStart(of: model.advance(from, byGraphemes: -1)) : 0
        case .pageForward where !shift:
            moved = (0..<Self.pageRows).reduce(selection.upperBound) { at, _ in vertical(from: at, by: 1, in: model) }
        case .pageBackward where !shift:
            moved = (0..<Self.pageRows).reduce(selection.lowerBound) { at, _ in vertical(from: at, by: -1, in: model) }
        default:
            return false
        }
        focus = moved
        if !shift { anchor = moved }
        return true
    }

    static let pageRows = 10

    /// Letter, digit and underscore runs; real apps also split Chinese by dictionary.
    private func wordEnd(from offset: Int, in model: TextModel) -> Int {
        var at = offset
        while at < model.length, !isWord(at, in: model) { at = model.advance(at, byGraphemes: 1) }
        while at < model.length, isWord(at, in: model) { at = model.advance(at, byGraphemes: 1) }
        return at
    }

    private func wordStart(from offset: Int, in model: TextModel) -> Int {
        var at = offset
        while at > 0, !isWord(model.advance(at, byGraphemes: -1), in: model) { at = model.advance(at, byGraphemes: -1) }
        while at > 0, isWord(model.advance(at, byGraphemes: -1), in: model) { at = model.advance(at, byGraphemes: -1) }
        return at
    }

    private func isWord(_ offset: Int, in model: TextModel) -> Bool {
        guard let character = model.substring(offset..<model.advance(offset, byGraphemes: 1)).first else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }

    /// The visual row holding `offset`: a line's graphemes cut every `wrap`, the caret on a cut starting the next row.
    private func row(of offset: Int, in model: TextModel) -> (start: Int, end: Int, index: Int, column: Int) {
        let line = model.lineStart(of: offset)
        let end = model.lineEnd(of: offset)
        let width = wrap ?? Int.max
        let count = model.graphemes(in: line..<end)
        let column = model.graphemes(in: line..<offset)
        let index = count == 0 ? 0 : min(column / width, (count - 1) / width)
        let start = model.advance(line, byGraphemes: index * width)
        let last = index == (count == 0 ? 0 : (count - 1) / width)
        return (start, last ? end : model.advance(start, byGraphemes: width), index, column - index * width)
    }

    /// ↓ and ↑: the same visual column one row over; past the first or last row, the text's end.
    private func vertical(from offset: Int, by delta: Int, in model: TextModel) -> Int {
        let here = row(of: offset, in: model)
        let rowEnd = model.lineEnd(of: offset)
        let target: Int
        if delta > 0 {
            if here.end < rowEnd {
                target = here.end
            } else if rowEnd < model.length {
                target = rowEnd + 1
            } else {
                return model.length
            }
        } else {
            let line = model.lineStart(of: offset)
            if here.start > line {
                target = model.advance(here.start, byGraphemes: -1)
            } else if line > 0 {
                target = line - 1
            } else {
                return 0
            }
        }
        let over = row(of: target, in: model)
        return min(model.advance(over.start, byGraphemes: here.column), over.end)
    }
}
