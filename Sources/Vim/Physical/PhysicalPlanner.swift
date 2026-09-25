/// Lowers a `LogicalPlan` into a `PhysicalPlan` for one field, under one
/// capability profile.
///
/// The planner is a **simulator, not a translator**: it walks the logical
/// steps carrying a predicted field state (the context), and for each step
/// picks the best satisfiable lane, emits concrete steps, updates the
/// prediction, and derives the settle expectation from that same
/// prediction. Three lanes emerge:
///
/// - **A** (AX write): compute exact offsets with `TextModel`, set ranges.
/// - **B** (read, no write): same exact math, actuated as counted
///   keystrokes and verified by read-back — reads turn key synthesis into a
///   dumb actuator.
/// - **C** (blind): Cocoa-approximate chords plus clipboard captures for
///   anything needing content.
///
/// A step no lane can realize rejects the whole plan: `[.bell]`,
/// all-or-nothing, mirroring vim's execute-or-bell. The planner is pure —
/// it never talks to AX, and it writes no state (it only *authors* commit
/// steps for the reducer).
public enum PhysicalPlanner {
    /// Out-of-band, so the plan still stores only the program; the step's type narrows the 26 sites.
    public struct Rejection: Equatable, Sendable {
        public let index: Int
        public let step: LogicalStep

        public init(index: Int, step: LogicalStep) {
            self.index = index
            self.step = step
        }
    }

    /// Out-of-band for the same reason `Rejection` is: the plan stores only the program.
    public struct Planning: Equatable, Sendable {
        public let plan: PhysicalPlan
        public let rejection: Rejection?

        /// The range the plan meant to replace, in field offsets; nil in the blind lane, which has no offsets.
        public let operand: Range<Int>?

        public init(plan: PhysicalPlan, rejection: Rejection?, operand: Range<Int>?) {
            self.plan = plan
            self.rejection = rejection
            self.operand = operand
        }

        /// Whether the run died checking the selected text: other text is selected, however its offsets read.
        public func abortedAtTextCheck(_ index: Int?) -> Bool {
            guard let index, plan.steps.indices.contains(index),
                  case .settle(let expectation) = plan.steps[index] else { return false }
            return expectation.selectedText != nil
        }
    }

    /// The plan alone — tests and any caller with no use for the rest.
    public static func plan(_ logical: LogicalPlan, snapshot: FieldSnapshot) -> PhysicalPlan {
        planning(logical, snapshot: snapshot).plan
    }

    /// `plan` plus what only the planner knows: why it rejected, and the operand.
    public static func planning(
        _ logical: LogicalPlan, snapshot: FieldSnapshot
    ) -> Planning {
        let profile = snapshot.capabilities
        var context = Context(snapshot: snapshot)
        var steps: [PhysicalStep] = []
        // The field shows our block cursor: physically collapse it to its
        // gap before the plan acts, so no step ever operates on the
        // presentation selection. Empty and bell-only plans skip this —
        // they touch nothing and the cursor stays up.
        if let gap = context.cursorCollapse, !logical.steps.isEmpty, !isBellOnly(logical) {
            if profile.has(.writeSelection) {
                steps += write(gap..<gap, context: context)
            } else {
                // Settled, so a later AX write cannot overtake the ←.
                steps.append(.press(.left, count: 1))
                steps += settle(context, profile: profile)
            }
        }
        for (index, step) in logical.steps.enumerated() {
            guard let lowered = lower(step, context: &context, profile: profile) else {
                return Planning(plan: .rejected, rejection: Rejection(index: index, step: step), operand: nil)
            }
            steps.append(contentsOf: lowered)
        }
        return Planning(plan: PhysicalPlan(steps: steps), rejection: nil, operand: context.operand)
    }

    private static func isBellOnly(_ logical: LogicalPlan) -> Bool {
        logical.steps.allSatisfy { step in
            if case .bell = step { return true }
            return false
        }
    }
}

// MARK: - Planning context

private extension PhysicalPlanner {
    /// The predicted field: seeded from the snapshot, mutated as the plan is
    /// simulated. `selection == nil` means unknown; `selectionOpaque` means a
    /// selection exists on screen but its offsets are unknown (made blind).
    struct Context {
        var text: String?
        var selection: Range<Int>?
        var selectionOpaque = false
        var selectionWise: VisualKind?
        var anchor: Int?
        var nextSlot = 0

        /// Non-nil when the snapshot's selection is our drawn block cursor:
        /// the gap to collapse to before the plan acts.
        var cursorCollapse: Int?

        /// The last predicted edit's range, in field offsets — the one in flight if the plan dies.
        var operand: Range<Int>?

        /// Everything else is in `AXValue` offsets; ranges leave for the field through these.
        var breaks: ParagraphBreaks?

        /// A typed `\n` may have made a paragraph or a line break.
        var breaksUncertain = false

        var textlessLeaves = false

        init(snapshot: FieldSnapshot) {
            text = snapshot.text
            selection = snapshot.selection
            anchor = snapshot.anchor
            breaks = snapshot.breaks
            textlessLeaves = snapshot.textlessLeaves
            if let cursor = snapshot.cursor, !cursor.isEmpty, cursor == snapshot.selection {
                // The engine plans from the collapsed gap, not the block.
                let gap = cursor.lowerBound
                selection = gap..<gap
                cursorCollapse = gap
            }
        }

        var model: TextModel? { text.map(TextModel.init) }

        func field(_ range: Range<Int>) -> Range<Int> {
            breaks?.fieldRange(range) ?? range
        }

        /// Typing over `range` would drop a break that may bound an `<hr>` or a table cell, which no typed text rebuilds.
        func retypesStructure(_ range: Range<Int>) -> Bool {
            textlessLeaves && (breaks?.offsets.contains { range.contains($0) } ?? false)
        }

        /// Which side of a paragraph boundary `offset` is on; nil off a boundary.
        func edge(_ offset: Int) -> Expectation.Edge? {
            guard let breaks else { return nil }
            let candidates = breaks.valueOffsets(breaks.fieldOffset(offset))
            guard candidates.count > 1 else { return nil }
            // Between two breaks is a line Chromium makes for a text-less or uneditable element, past the paragraph's end.
            return offset == candidates.lowerBound ? .paragraphEnd : .paragraphStart
        }

        /// The model, but only where its geography is trustworthy.
        ///
        /// A block-scoped field's text is locally true and globally false:
        /// exact within the caret's block, a lie about everything past it.
        /// This cannot be folded into `model` — its consumers span three
        /// trust classes (geography, local content, staleness witnesses),
        /// and blanket-nilling would demote the field to lane C, killing
        /// `ciw`, `x`, `dw`, `f` and all register fidelity to fix a `j` bug.
        /// The trust decision is inherently per-destination.
        func model(for destination: LogicalStep.Destination, _ profile: CapabilityProfile) -> TextModel? {
            guard profile.has(.wholeDocument) || !PhysicalPlanner.isDocumentScoped(destination) else {
                return nil
            }
            return model
        }

        func model(for target: LogicalStep.SelectionTarget, _ profile: CapabilityProfile) -> TextModel? {
            guard profile.has(.wholeDocument) || !PhysicalPlanner.isDocumentScoped(target) else {
                return nil
            }
            return model
        }

        /// Line-counting work (`J`, linewise put) needs geography
        /// unconditionally — there is no line-local version of it.
        func linewiseModel(_ profile: CapabilityProfile) -> TextModel? {
            profile.has(.wholeDocument) ? model : nil
        }

        var position: Int? { selection?.lowerBound }
        var caret: Int? { selection.flatMap { $0.isEmpty ? $0.lowerBound : nil } }

        mutating func takeSlot() -> CaptureSlot {
            defer { nextSlot += 1 }
            return CaptureSlot(id: nextSlot)
        }

        /// Apply a predicted edit: text surgery, caret after the replacement.
        mutating func applyEdit(range: Range<Int>, replacement: String) {
            // An empty range is a plain insert, which replaces nothing.
            if !range.isEmpty { operand = field(range) }
            text = model?.replacing(range, with: replacement)
            if let current = breaks {
                breaks = current.replacing(range, with: replacement)
                breaksUncertain = breaksUncertain || replacement.contains("\n")
            }
            let caretAfter = range.lowerBound + replacement.utf16.count
            selection = caretAfter..<caretAfter
            selectionOpaque = false
        }

        /// The field did something we cannot predict (undo, blind typing).
        mutating func invalidate() {
            text = nil
            selection = nil
            selectionOpaque = false
        }
    }

    /// One settle per state-changing logical step, built from the prediction.
    ///
    /// `hard` follows an AX write: non-convergence aborts and rings. A blind
    /// action passes `hard: false` — the poll still runs as a barrier, but a
    /// mismatch is not a failure (the app, not us, decided what the keystroke
    /// did), so it proceeds instead of aborting the mode change behind it.
    static func settle(
        _ context: Context, profile: CapabilityProfile, hard: Bool = true, selectedText: String? = nil
    ) -> [PhysicalStep] {
        guard profile.has(.readCaret), let selection = context.selection else { return [] }
        let length = profile.has(.readLength) ? context.text.map { $0.utf16.count } : nil
        let expectation = Expectation(
            selection: context.breaksUncertain ? nil : context.field(selection),
            length: length,
            edge: context.breaksUncertain ? nil : context.edge(selection.upperBound),
            selectedText: selectedText
        )
        return [hard ? .settle(expectation) : .softSettle(expectation)]
    }

    /// Chromium lands a write at a boundary on the next paragraph, so paragraph ends are reached by keys.
    static func write(_ range: Range<Int>, context: Context) -> [PhysicalStep] {
        let field = context.field(range)
        if !range.isEmpty, context.edge(range.lowerBound) == .paragraphEnd, let model = context.model {
            return [
                .setSelection(field.lowerBound..<field.lowerBound),
                .press(.left, count: 1),
                .press(.selectRight, count: model.graphemes(in: range)),
            ]
        }
        let step = PhysicalStep.setSelection(field)
        guard context.edge(range.upperBound) == .paragraphEnd else { return [step] }
        return [step, .press(range.isEmpty ? .left : .selectLeft, count: 1)]
    }

    static func presses(_ steps: [PhysicalStep]) -> Bool {
        steps.contains { if case .press = $0 { return true }; return false }
    }

    /// Before an edit replaces a selection keys made: Chromium's misread caret puts
    /// them on other text while every offset reads back as planned (LIN-1533).
    static func checkSelectedText(
        _ text: String, context: Context, profile: CapabilityProfile
    ) -> [PhysicalStep] {
        guard !text.isEmpty, !profile.has(.writeSelection), profile.has(.readSelectedText) else { return [] }
        // `AXSelectedText` omits paragraph breaks.
        let selected = context.selection.flatMap { selection in context.breaks?.fieldText(text, at: selection) } ?? text
        return settle(context, profile: profile, selectedText: selected)
    }
}

// MARK: - Step dispatch

private extension PhysicalPlanner {
    static func lower(
        _ step: LogicalStep,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        switch step {
        case .moveCaret(let destination):
            return lowerMove(destination, context: &context, profile: profile)
        case .select(let target):
            return lowerSelect(target, context: &context, profile: profile)
        case .extendSelection(let destination):
            return lowerExtend(destination, context: &context, profile: profile)
        case .collapseSelection(let edge):
            return lowerCollapse(edge, context: &context, profile: profile)
        case .swapSelectionEnds:
            return nil   // needs Visual-kind context; arrives with visual round 2
        case .deleteSelection(let register):
            return lowerDelete(into: register, context: &context, profile: profile)
        case .yankSelection(let register):
            return lowerYank(into: register, context: &context, profile: profile)
        case .replaceSelection(let replacement):
            return lowerTypeOver(replacement, context: &context, profile: profile)
        case .transformSelection(let transform):
            return lowerTransform(transform, context: &context, profile: profile)
        case .insertText(let insertion):
            return lowerTypeOver(insertion, context: &context, profile: profile)
        case .put(let source, let action, let count):
            return lowerPut(source, action, count: count, context: &context, profile: profile)
        case .joinLines(let count, let keepWhitespace):
            return lowerJoin(count: count, keepWhitespace: keepWhitespace, context: &context, profile: profile)
        case .setMode(let mode):
            return lowerSetMode(mode, context: &context)
        case .setMark(let name):
            return lowerSetMark(name, context: &context)
        case .history(let action):
            context.invalidate()
            switch action {
            case .undo: return [.press(.undo, count: 1)]
            case .redo: return [.press(.redo, count: 1)]
            case .olderTextState, .newerTextState: return nil
            }
        case .commit(let effect):
            return [.commit(effect)]
        case .renderCursor:
            return lowerRenderCursor(context: &context, profile: profile)
        case .bell:
            return [.bell]
        }
    }

    /// Best-effort by design: a cursor that cannot be drawn — or may not be
    /// (`drawCursor` is the standing selection's permission, distinct from
    /// the actuation writes) — is a bare caret, never a bell. No settle —
    /// cosmetic divergence must not abort the plan.
    static func lowerRenderCursor(context: inout Context, profile: CapabilityProfile) -> [PhysicalStep]? {
        guard profile.has(.writeSelection),
              profile.has(.drawCursor),
              let model = context.model,
              let gap = context.caret else {
            return [.commit(.setCursor(nil))]
        }
        let end = model.advance(gap, byGraphemes: 1)
        guard end > gap, gap < model.lineEnd(of: gap) else {
            return [.commit(.setCursor(nil))]   // end of line/text: nothing to cover
        }
        context.selection = gap..<end
        return write(gap..<end, context: context) + [.commit(.setCursor(gap..<end))]
    }
}

// MARK: - Destinations

private extension PhysicalPlanner {
    static func resolve(_ destination: LogicalStep.Destination, model: TextModel, from position: Int) -> Int? {
        switch destination {
        case .motion(let motion, let count):
            return model.destination(of: motion, from: position, count: count)
        case .offset(let offset):
            return model.clamp(offset)
        case .mark(let point, let lineWise):
            guard model.isValid(point) else { return nil }   // stale mark: reject, never jump wrong
            return lineWise ? model.firstNonBlank(inLineOf: point.offset) : model.clamp(point.offset)
        }
    }

    /// Lane B's actuator: exact target, dumb keys. Deterministic regardless
    /// of the app's column memory — vertical first, then home, then right.
    ///
    /// Its cross-line branch stays correct under a block-scoped field: this
    /// is only ever reached through a model that already passed the
    /// `wholeDocument` gate, so either the span is same-line or the block
    /// has real internal geography (a Notion code block).
    static func keyPath(from selection: Range<Int>, to: Int, model: TextModel) -> [PhysicalStep] {
        // ← collapses a selection to its start from either end.
        var presses: [PhysicalStep] = selection.isEmpty ? [] : [.press(.left, count: 1)]
        let from = selection.lowerBound
        guard from != to else { return presses }
        let fromLine = model.lineStart(of: from)
        let toLine = model.lineStart(of: to)
        if fromLine == toLine {
            let count = model.graphemes(in: min(from, to)..<max(from, to))
            return presses + [.press(to > from ? .right : .left, count: count)]
        }
        let lines = model.newlineCount(in: min(fromLine, toLine)..<max(fromLine, toLine))
        presses.append(.press(toLine > fromLine ? .down : .up, count: lines))
        presses.append(.press(.lineStart, count: 1))
        let column = model.graphemes(in: toLine..<to)
        if column > 0 {
            presses.append(.press(.right, count: column))
        }
        return presses
    }

    /// Does resolving this need the model to describe geography beyond the
    /// caret's line?
    ///
    /// Classified by **intent**, not by whether a given resolution happens
    /// to cross a line. `TextModel` classes `\n` as whitespace, so `w`/`b`/
    /// `e` walk across lines — but only incidentally, and inside a block
    /// they are exact, so they stay on the model. `j` is *defined* by the
    /// crossing, so it cannot. At a block boundary `w` merely stalls: a
    /// degradation, not a wrong action.
    static func isDocumentScoped(_ motion: Motion) -> Bool {
        switch motion {
        case .line(.up, _), .line(.down, _), .displayLine:
            return true
        case .fileStart, .fileEnd, .search:
            return true
        case .paragraph, .sentence, .section, .page, .scrollLine, .screenLine:
            return true
        default:
            // character, word, find, lineStart, lastNonBlank, column,
            // matchingItem, repeatFind, mark, custom — line-local, or
            // resolved away before they reach here.
            return false
        }
    }

    static func isDocumentScoped(_ destination: LogicalStep.Destination) -> Bool {
        switch destination {
        case .motion(.lineEnd, let count):
            return count > 1   // `2$` walks a line down first
        case .motion(let motion, _):
            return isDocumentScoped(motion)
        case .offset, .mark:
            // Absolute offsets against a block-relative model are a category
            // error: `gi` has no staleness witness at all, and a wrong-block
            // jump followed by Insert is the worst failure available.
            return true
        }
    }

    static func isDocumentScoped(_ target: LogicalStep.SelectionTarget) -> Bool {
        switch target {
        case .span(let destination, _):
            return isDocumentScoped(destination)
        case .lineSpan:
            return true
        case .lines(let count, _):
            // `dd` stays exact: blind would select across a block boundary
            // unpredictably AND lose register fidelity. Emptying the block
            // is the lesser, predictable wrong.
            return count > 1
        case .remembered:
            return true   // absolute offsets
        case .textObject, .toLineEnd, .current:
            return false
        }
    }

    /// Lane C's chord table. `counted` is false where repetition is
    /// meaningless (line ends, document ends).
    static func blindMoveChord(_ motion: Motion) -> (chord: Chord, counted: Bool)? {
        switch motion {
        case .character(.left): return (.left, true)
        case .character(.right): return (.right, true)
        case .line(.down, _): return (.down, true)
        case .line(.up, _): return (.up, true)
        case .word(.forward, _, _): return (.wordRight, true)
        case .word(.backward, _, _): return (.wordLeft, true)
        case .lineStart: return (.lineStart, false)
        case .lineEnd, .lastNonBlank: return (.lineEnd, false)
        case .fileStart: return (.documentStart, false)
        case .fileEnd: return (.documentEnd, false)
        default: return nil
        }
    }

    static func lowerMove(
        _ destination: LogicalStep.Destination,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        if let model = context.model(for: destination, profile), let selection = context.selection {
            let position = selection.lowerBound
            guard let target = resolve(destination, model: model, from: position) else { return nil }
            let actuation: [PhysicalStep]
            if profile.has(.writeSelection) {
                actuation = write(target..<target, context: context)
            } else {
                actuation = keyPath(from: selection, to: target, model: model)
            }
            context.selection = target..<target
            context.selectionOpaque = false
            return actuation + settle(context, profile: profile)
        }
        guard case .motion(let motion, let count) = destination,
              let blind = blindMoveChord(motion) else { return nil }
        context.selection = nil
        context.selectionOpaque = false
        return [.press(blind.chord, count: blind.counted ? count : 1)]
    }
}

// MARK: - Selection

private extension PhysicalPlanner {
    static func selectionRange(
        for target: LogicalStep.SelectionTarget,
        model: TextModel,
        at position: Int,
        context: Context
    ) -> Range<Int>? {
        switch target {
        case .span(let destination, let inclusive):
            guard var end = resolve(destination, model: model, from: position) else { return nil }
            if inclusive { end = model.advance(end, byGraphemes: 1) }
            return min(position, end)..<max(position, end)
        case .lineSpan(let destination, let interior):
            guard let end = resolve(destination, model: model, from: position) else { return nil }
            return model.lineSpan(from: position, to: end, includingTerminator: !interior)
        case .lines(let count, let interior):
            return model.lines(from: position, count: count, includingTerminator: !interior)
        case .textObject(let object, let count):
            guard case .word(let big) = object.kind else { return nil }
            var range = model.wordObject(at: position, around: object.scope == .around, big: big)
            for _ in 1..<max(1, count) {
                let next = model.wordObject(at: range.upperBound, around: object.scope == .around, big: big)
                range = range.lowerBound..<next.upperBound
            }
            return range
        case .toLineEnd:
            return position..<model.lineEnd(of: position)
        case .current:
            guard let selection = context.selection, !selection.isEmpty else { return nil }
            return selection
        case .remembered(let memory):
            return model.clamp(memory.range.lowerBound)..<model.clamp(memory.range.upperBound)
        }
    }

    static func blindSelect(_ target: LogicalStep.SelectionTarget) -> [PhysicalStep]? {
        switch target {
        case .span(let destination, _):
            guard case .motion(let motion, let count) = destination,
                  let blind = blindMoveChord(motion) else { return nil }
            return [.press(blind.chord.shifted, count: blind.counted ? count : 1)]
        case .lines(let count, let interior):
            if interior {
                var steps: [PhysicalStep] = [.press(.lineStart, count: 1)]
                if count > 1 { steps.append(.press(.selectDown, count: count - 1)) }
                steps.append(.press(.selectLineEnd, count: 1))
                return steps
            }
            return [.press(.lineStart, count: 1), .press(.selectDown, count: count)]
        case .toLineEnd:
            return [.press(.selectLineEnd, count: 1)]
        case .textObject(let object, _):
            guard case .word = object.kind else { return nil }
            return [.press(.wordLeft, count: 1), .press(.selectWordRight, count: 1)]
        case .lineSpan(let destination, let interior):
            // `dj`, `dG`: whole lines from here through the destination's
            // line. Only vertical destinations have a blind spelling — a
            // lineSpan to a mark has none and rings.
            guard case .motion(let motion, let count) = destination else { return nil }
            var steps: [PhysicalStep] = [.press(.lineStart, count: 1)]
            switch motion {
            case .line(.down, _):
                // count lines below, plus the caret's own.
                steps.append(.press(.selectDown, count: interior ? count : count + 1))
            case .fileEnd:
                steps.append(.press(Chord.documentEnd.shifted, count: 1))
            default:
                return nil
            }
            if interior, case .line = motion {
                steps.append(.press(.selectLineEnd, count: 1))
            }
            return steps
        case .current:
            return []   // whatever is on screen is the operand
        case .remembered:
            return nil
        }
    }

    static func lowerSelect(
        _ target: LogicalStep.SelectionTarget,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        if let model = context.model(for: target, profile), let selection = context.selection {
            let position = selection.lowerBound
            guard let range = selectionRange(for: target, model: model, at: position, context: context) else {
                return nil
            }
            context.selectionWise = target.wise ?? context.selectionWise ?? .character
            context.selectionOpaque = false
            if range == context.selection {
                return []   // already selected (Visual operators)
            }
            if profile.has(.writeSelection) {
                context.selection = range
                return write(range, context: context) + settle(context, profile: profile)
            }
            var presses = keyPath(from: selection, to: range.lowerBound, model: model)
            let count = model.graphemes(in: range)
            if count > 0 {
                presses.append(.press(.selectRight, count: count))
            }
            context.selection = range
            return presses + settle(context, profile: profile)
        }
        guard let presses = blindSelect(target) else { return nil }
        context.selection = nil
        context.selectionOpaque = true
        context.selectionWise = target.wise ?? .character
        return presses
    }

    static func lowerExtend(
        _ destination: LogicalStep.Destination,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        if profile.has(.writeSelection),
           let model = context.model(for: destination, profile),
           let selection = context.selection,
           let anchor = context.anchor {
            let head = selection.lowerBound == anchor ? selection.upperBound : selection.lowerBound
            guard let target = resolve(destination, model: model, from: head) else { return nil }
            let range = min(anchor, target)..<max(anchor, target)
            context.selection = range
            return write(range, context: context) + settle(context, profile: profile)
        }
        // Blind: the app owns the anchor. This deliberately ignores
        // `context.anchor` — mixing a stored engine offset with a live app
        // selection is exactly where this would go silently wrong. The
        // selection becomes opaque, so a following operator takes the
        // clipboard path (`lowerDelete`/`lowerYank` already branch on it).
        guard case .motion(let motion, let count) = destination,
              let blind = blindMoveChord(motion) else { return nil }
        context.selection = nil
        context.selectionOpaque = true
        return [.press(blind.chord.shifted, count: blind.counted ? count : 1)]
    }

    static func lowerCollapse(
        _ edge: LogicalStep.SelectionEdge,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        if let selection = context.selection {
            guard !selection.isEmpty else { return [] }
            let target: Int
            switch edge {
            case .start:
                target = selection.lowerBound
            case .end:
                target = selection.upperBound
            case .head:
                guard let anchor = context.anchor else { return nil }
                target = selection.lowerBound == anchor ? selection.upperBound : selection.lowerBound
            }
            let towardStart = target == selection.lowerBound
            context.selection = target..<target
            if profile.has(.writeSelection) {
                return write(target..<target, context: context) + settle(context, profile: profile)
            }
            return [.press(towardStart ? .left : .right, count: 1)] + settle(context, profile: profile)
        }
        if context.selectionOpaque {
            context.selectionOpaque = false
            context.selection = nil
            switch edge {
            case .start: return [.press(.left, count: 1)]
            case .end: return [.press(.right, count: 1)]
            case .head: return nil
            }
        }
        return []   // nothing selected, nothing to collapse
    }
}

// MARK: - Mutation

private extension PhysicalPlanner {
    /// Register wise-ness from selection kind. No blockwise selection is
    /// planned yet, so the width is never real.
    static func registerWise(_ kind: VisualKind?) -> Wise {
        switch kind ?? .character {
        case .character: return .character
        case .line: return .line
        case .block: return .block(width: 0)
        }
    }

    static func lowerDelete(
        into register: Register?,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        let wise = registerWise(context.selectionWise)
        let blackhole = register?.name == "_"
        if let model = context.model, let selection = context.selection {
            guard !selection.isEmpty else { return [] }
            let content = model.substring(selection)
            var steps = checkSelectedText(content, context: context, profile: profile)
            steps.append(profile.has(.insertText) ? .replaceSelection("") : .press(.deleteBack, count: 1))
            context.applyEdit(range: selection, replacement: "")
            // Blind (press) delete: soft — a mismatch must not abort the
            // `setMode(.insert)` that follows a `ciw`/`s`/`cc`.
            steps += settle(context, profile: profile, hard: profile.has(.insertText))
            if !blackhole {
                steps.append(.commit(.deleted(into: register, content: .literal(content), wise: wise)))
            }
            return steps
        }
        guard context.selectionOpaque else { return nil }
        context.selectionOpaque = false
        context.invalidate()
        if blackhole {
            return [.press(.deleteBack, count: 1)]
        }
        // Blind delete IS the cut: the pasteboard becomes the register
        // (clipboard=unnamed), nothing is read back, silence on failure.
        return [
            .clipboardCut,
            .commit(.deleted(into: register, content: .pasteboard, wise: wise)),
        ]
    }

    static func lowerYank(
        into register: Register?,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        guard register?.name != "_" else { return [] }
        let wise = registerWise(context.selectionWise)
        if let model = context.model, let selection = context.selection {
            guard !selection.isEmpty else { return [] }
            return [.commit(.yanked(into: register, content: .literal(model.substring(selection)), wise: wise))]
        }
        guard context.selectionOpaque else { return nil }
        // An opaque selection was built by presses, which are QUEUED at the
        // window server; an AX read is synchronous and would beat them,
        // capturing the selection as it was before. Channels must not cross:
        // ⌘C rides the same queue as the presses and therefore sees them.
        // (This is why the tempting `readSelectedText` fast path — instant,
        // and literal text instead of a pasteboard marker — is wrong here.)
        return [.clipboardCopy, .commit(.yanked(into: register, content: .pasteboard, wise: wise))]
    }

    /// `insertText` and `replaceSelection` are the same lowering: AX
    /// replacement replaces whatever is selected, and a caret is an empty
    /// selection; typed text replaces a selection too.
    static func lowerTypeOver(
        _ replacement: String,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        if let selection = context.selection, context.retypesStructure(selection) { return nil }
        let action: PhysicalStep = profile.has(.insertText)
            ? .replaceSelection(replacement)
            : .typeText(replacement)
        if let selection = context.selection, let model = context.model {
            let check = checkSelectedText(model.substring(selection), context: context, profile: profile)
            context.applyEdit(range: selection, replacement: replacement)
            // Blind (typeText) over-type: soft, so a mismatch does not abort
            // the `setMode(.insert)` behind an `o`/`O`/`i`.
            return check + [action] + settle(context, profile: profile, hard: profile.has(.insertText))
        }
        context.invalidate()
        return [action]
    }

    static func lowerTransform(
        _ transform: LogicalStep.SelectionTransform,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        guard let model = context.model, let selection = context.selection, !selection.isEmpty,
              !context.retypesStructure(selection) else {
            return nil   // content must be readable to rewrite it
        }
        let original = model.substring(selection)
        let transformed: String
        switch transform {
        case .toggleCase:
            transformed = original.reduce(into: "") { result, character in
                if character.isUppercase {
                    result += character.lowercased()
                } else if character.isLowercase {
                    result += character.uppercased()
                } else {
                    result.append(character)
                }
            }
        case .lowercase:
            transformed = original.lowercased()
        case .uppercase:
            transformed = original.uppercased()
        case .shiftRight:
            transformed = mapLines(of: original) { Self.indentUnit + $0 }
        case .shiftLeft:
            transformed = mapLines(of: original) { line in
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                var trimmed = line[...]
                for _ in 0..<Self.indentUnit.count where trimmed.first == " " {
                    trimmed = trimmed.dropFirst()
                }
                return String(trimmed)
            }
        }
        let action: PhysicalStep = profile.has(.insertText)
            ? .replaceSelection(transformed)
            : .typeText(transformed)
        let check = checkSelectedText(original, context: context, profile: profile)
        context.applyEdit(range: selection, replacement: transformed)
        // Blind (typeText) transform: soft. The poll still lets the following
        // `collapseSelection` land its caret on a settled field.
        return check + [action] + settle(context, profile: profile, hard: profile.has(.insertText))
    }

    static let indentUnit = "    "

    static func mapLines(of text: String, _ transform: (String) -> String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { transform(String($0)) }
            .joined(separator: "\n")
    }

    static func lowerJoin(
        count: Int,
        keepWhitespace: Bool,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        // Definitionally cross-line, and there is no blind spelling: the
        // whitespace rules below are the whole point of the function, and a
        // chord approximation cannot compute them. Scoped fields ring.
        guard let model = context.linewiseModel(profile), let selection = context.selection else { return nil }
        let position = selection.lowerBound
        let range = model.lines(from: position, count: count, includingTerminator: false)
        guard !context.retypesStructure(range) else { return nil }
        let lines = model.substring(range)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.count > 1 else { return [] }
        var joined = lines[0]
        for line in lines.dropFirst() {
            if keepWhitespace {
                joined += line
            } else {
                let stripped = line.drop { $0 == " " || $0 == "\t" }
                joined += joined.isEmpty || joined.hasSuffix(" ") ? String(stripped) : " " + stripped
            }
        }
        var steps: [PhysicalStep] = []
        if profile.has(.writeSelection) {
            steps += write(range, context: context)
        } else {
            steps += keyPath(from: selection, to: range.lowerBound, model: model)
            steps.append(.press(.selectRight, count: model.graphemes(in: range)))
        }
        context.selection = range
        // Settled, so the AX replacement cannot overtake the selecting keys.
        var barrier = checkSelectedText(model.substring(range), context: context, profile: profile)
        if barrier.isEmpty, presses(steps), profile.has(.insertText) {
            barrier = settle(context, profile: profile)
        }
        steps += barrier
        steps.append(profile.has(.insertText) ? .replaceSelection(joined) : .typeText(joined))
        context.applyEdit(range: range, replacement: joined)
        // Settle follows the edit; blind (typeText) join is soft.
        return steps + settle(context, profile: profile, hard: profile.has(.insertText))
    }
}

// MARK: - Put

private extension PhysicalPlanner {
    static func lowerPut(
        _ source: LogicalStep.PutSource,
        _ action: PutAction,
        count: Int,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        switch source {
        case .pasteboard(let wise):
            // Content lives in macOS and is consumed ONLY via a synthesized
            // ⌘V — the event queue orders it behind the ⌘X that filled the
            // pasteboard; a direct engine read would race it. All lanes
            // paste this way; a readable field still positions exactly.
            var steps: [PhysicalStep] = []
            switch wise {
            case .character, .block:   // block degrades to characterwise
                if let model = context.model, let position = context.position {
                    let target = action.position == .after
                        ? min(model.advance(position, byGraphemes: 1), model.lineEnd(of: position))
                        : position
                    steps += moveSteps(to: target, context: &context, profile: profile)
                } else if action.position == .after {
                    steps.append(.press(.right, count: 1))
                }
            case .line:
                // Linewise cuts carry their own trailing newline and ⌘V is
                // verbatim, so the target must be a line START. Finding the
                // next line's start is document geography — a scoped field
                // drops to the blind branch below.
                if let model = context.linewiseModel(profile), let position = context.position {
                    let end = model.lineEnd(of: position)
                    let target = action.position == .after
                        ? (end >= model.length ? model.length : end + 1)
                        : model.lineStart(of: position)
                    steps += moveSteps(to: target, context: &context, profile: profile)
                } else if action.position == .after {
                    // Next line start. On the last line .down no-ops and the
                    // paste lands above — a well-formed line misplaced beats
                    // a malformed merge.
                    steps.append(.press(.down, count: 1))
                    steps.append(.press(.lineStart, count: 1))
                } else {
                    steps.append(.press(.lineStart, count: 1))
                }
            }
            steps += Array(repeating: PhysicalStep.clipboardInsert(nil), count: max(1, count))
            context.invalidate()
            return steps

        case .content(let content):
            guard !content.text.isEmpty else { return [] }
            let payload = String(repeating: content.text, count: max(1, count))
            switch content.wise {
            case .character, .block:   // block degrades to characterwise, v1
                return putCharacterwise(payload, action: action, context: &context, profile: profile)
            case .line:
                let text = payload.hasSuffix("\n") ? payload : payload + "\n"
                return putLinewise(text, action: action, context: &context, profile: profile)
            }
        }
    }

    static func putCharacterwise(
        _ payload: String,
        action: PutAction,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        if let model = context.model, let position = context.position {
            let target = action.position == .after
                ? min(model.advance(position, byGraphemes: 1), model.lineEnd(of: position))
                : position
            var steps = moveSteps(to: target, context: &context, profile: profile)
            steps += insertSteps(payload, after: steps, context: &context, profile: profile)
            return steps
        }
        var steps: [PhysicalStep] = []
        if action.position == .after {
            steps.append(.press(.right, count: 1))
        }
        steps.append(.clipboardInsert(payload))
        context.invalidate()
        return steps
    }

    static func putLinewise(
        _ text: String,
        action: PutAction,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        // "Is this the last line?" is document geography: in a scoped field
        // `model.length` is the block's end, not the page's.
        if let model = context.linewiseModel(profile), let position = context.position {
            var insertion = text
            let target: Int
            if action.position == .after {
                let end = model.lineEnd(of: position)
                if end >= model.length {
                    // Last line without a terminator: lead with the newline.
                    target = model.length
                    insertion = "\n" + String(text.dropLast())
                } else {
                    target = end + 1
                }
            } else {
                target = model.lineStart(of: position)
            }
            var steps = moveSteps(to: target, context: &context, profile: profile)
            steps += insertSteps(insertion, after: steps, context: &context, profile: profile)
            return steps
        }
        context.invalidate()
        if action.position == .after {
            return [.press(.lineEnd, count: 1), .clipboardInsert("\n" + String(text.dropLast()))]
        }
        return [.press(.lineStart, count: 1), .clipboardInsert(text)]
    }

    static func moveSteps(
        to target: Int,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep] {
        let steps: [PhysicalStep]
        if profile.has(.writeSelection) {
            steps = write(target..<target, context: context)
        } else if let model = context.model, let selection = context.selection {
            steps = keyPath(from: selection, to: target, model: model)
        } else {
            steps = []
        }
        context.selection = target..<target
        return steps
    }

    /// Bulk insertion at the predicted caret: AX when possible, paste
    /// otherwise (typing long content is slow and lossy).
    static func insertSteps(
        _ text: String,
        after positioning: [PhysicalStep],
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep] {
        let action: PhysicalStep = profile.has(.insertText)
            ? .replaceSelection(text)
            : .clipboardInsert(text)
        if let selection = context.selection, context.text != nil {
            // An AX insertion can overtake queued keys; a paste cannot.
            let barrier = presses(positioning) && profile.has(.insertText) ? settle(context, profile: profile) : []
            context.applyEdit(range: selection, replacement: text)
            // Blind (paste) insert is async: soft, so it never aborts what follows.
            return barrier + [action] + settle(context, profile: profile, hard: profile.has(.insertText))
        }
        context.invalidate()
        return [action]
    }
}

// MARK: - State-only steps

private extension PhysicalPlanner {
    static func lowerSetMode(_ mode: LogicalStep.Mode, context: inout Context) -> [PhysicalStep]? {
        switch mode {
        case .normal:
            return [.commit(.setMode(.normal))]
        case .insert:
            return [.commit(.setMode(.insert)), .commit(.setInsertStart(context.caret))]
        case .replace:
            return [.commit(.setMode(.replace)), .commit(.setInsertStart(context.caret))]
        case .visual(let kind):
            guard let anchor = context.position else { return nil }   // no anchor, no Visual
            return [.commit(.setMode(.visual(VimState.VisualContext(kind: kind, anchor: anchor))))]
        }
    }

    static func lowerSetMark(_ name: Character, context: inout Context) -> [PhysicalStep]? {
        guard let model = context.model, let caret = context.caret else { return nil }
        return [.commit(.setMark(name, model.markPoint(at: caret)))]
    }
}
