/// Lowers a `LogicalPlan` into a `PhysicalPlan` for one field, under one
/// capability profile.
///
/// The planner is a **simulator, not a translator**: it walks the logical
/// steps carrying a predicted field state (the context), and for each step
/// picks the first lane that applies, emits concrete steps, updates the
/// prediction, and derives the settle expectation from that same
/// prediction. `lowerMove` and `lowerSelect` try the lanes in this order:
///
/// 1. **The app's keys**, under `nativeMotions`: its word, paragraph, row
///    and page keys, landing wherever the app decides.
/// 2. **Native line and document keys**, where selections cannot be
///    written: ⌃A ⌃E ⌘↑ ⌘↓, shifted to select, with only a column counted.
/// 3. **A** (AX write): compute exact offsets with `TextModel`, set ranges,
///    adding arrow keys at a Chromium paragraph end, where a write lands on
///    the next paragraph. Or **B** (read, no write): the same exact math,
///    actuated as counted keystrokes and verified by read-back — reads
///    turn key synthesis into a dumb actuator.
/// 4. **C** (blind): Cocoa-approximate chords plus clipboard captures for
///    anything needing content.
///
/// A lane that does not apply leaves the step to the next one. A lane that
/// applies but cannot realize the step rejects it, as running out of lanes
/// does, and a rejected step rejects the whole plan: `[.bell]`,
/// all-or-nothing, mirroring vim's execute-or-bell. The planner is pure —
/// it never talks to AX, and it writes no state (it only *authors* commit
/// steps for the reducer).
public enum PhysicalPlanner {
    /// Out-of-band, so the plan still stores only the program; only the step's type says which lowering rejected.
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
            for step in lowered {
                switch step {
                case .press, .typeText, .clipboardCut, .clipboardCopy, .clipboardInsert: context.keysQueued = true
                case .settle, .softSettle: context.keysQueued = false
                default: break
                }
            }
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

        /// Posted events not yet settled, which an AX write would overtake at the window server.
        var keysQueued = false

        let webContent: Bool

        /// Everything else is in `AXValue` offsets; ranges leave for the field through these.
        var breaks: ParagraphBreaks?

        /// A typed `\n` may have made a paragraph or a line break.
        var breaksUncertain = false

        /// Chromium leaves a new empty paragraph out of `AXValue` until it holds text, so after a blind newline the length is unknown.
        var lengthUncertain = false

        /// `text` less `AXValue`, whose length settles check: the empty paragraphs put back as lines.
        let valueGap: Int

        let holdsEmptyParagraphs: Bool

        /// Where empty paragraphs were found, an edit that empties or fills a line leaves `AXValue`'s length and the
        /// paragraph sides guesses: which of them `AXValue` shows changes with it.
        var paragraphsUncertain = false

        var textlessLeaves = false

        init(snapshot: FieldSnapshot) {
            text = snapshot.text
            selection = snapshot.selection
            anchor = snapshot.anchor
            webContent = snapshot.webContent
            breaks = snapshot.breaks
            emptyParagraphCaret = snapshot.caretInEmptyParagraph ? snapshot.selection : nil
            textlessLeaves = snapshot.textlessLeaves
            valueGap = snapshot.valueGap
            holdsEmptyParagraphs = snapshot.holdsEmptyParagraphs
            if let cursor = snapshot.cursor, !cursor.isEmpty, cursor == snapshot.selection {
                // The engine plans from the collapsed gap, not the block.
                let gap = cursor.lowerBound
                selection = gap..<gap
                cursorCollapse = gap
            }
        }

        var model: TextModel? { text.map(TextModel.init) }

        /// What a settle expects `AXValue`'s length to be.
        var valueLength: Int? { lengthUncertain || paragraphsUncertain ? nil : text.map { $0.utf16.count - valueGap } }

        func field(_ range: Range<Int>) -> Range<Int> {
            breaks?.fieldRange(range) ?? range
        }

        /// The snapshot's caret when it is in an empty paragraph, which `AXValue` can leave out and read beside, so a
        /// key pressed from it can seem to do nothing when it did.
        let emptyParagraphCaret: Range<Int>?

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
            let before = model
            text = model?.replacing(range, with: replacement)
            if holdsEmptyParagraphs, !replacement.contains("\n"), let before, let after = model {
                let caret = range.lowerBound + replacement.utf16.count
                paragraphsUncertain = paragraphsUncertain || before.touchesEmptyLine(range)
                    || after.touchesEmptyLine(range.lowerBound..<caret)
            }
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
        _ context: Context, profile: CapabilityProfile, hard: Bool = true,
        blame: Expectation.Blame? = nil, selectedText: String? = nil
    ) -> [PhysicalStep] {
        guard profile.has(.readCaret), let selection = context.selection else { return [] }
        let length = profile.has(.readLength) ? context.valueLength : nil
        var expectation = Expectation(
            selection: context.breaksUncertain ? nil : context.field(selection),
            length: length,
            edge: context.breaksUncertain || context.paragraphsUncertain ? nil : context.edge(selection.upperBound),
            selectedText: selectedText
        )
        expectation.blame = blame
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

    /// A misread caret puts keys and writes on other text while every offset reads back as planned (LIN-1533).
    static func checkSelectedText(
        _ text: String, context: Context, profile: CapabilityProfile
    ) -> [PhysicalStep] {
        guard !text.isEmpty, profile.has(.readSelectedText) else { return [] }
        // `AXSelectedText` omits paragraph breaks.
        let selected = context.selection.flatMap { selection in context.breaks?.fieldText(text, at: selection) } ?? text
        return settle(context, profile: profile, selectedText: selected)
    }
}

// MARK: - Lanes

private extension PhysicalPlanner {
    /// A lane's answer for a step: its steps, `next` where it does not apply, or `reject`, which rings the plan.
    enum Lane {
        case steps([PhysicalStep])
        case next
        case reject

        func or(_ lane: () -> Lane) -> Lane {
            guard case .next = self else { return self }
            return lane()
        }

        /// A `lower*` function's answer: nil where a lane rejected, or where no lane applied.
        var lowered: [PhysicalStep]? {
            guard case .steps(let steps) = self else { return nil }
            return steps
        }
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
        appMove(destination, context: &context, profile: profile)
            .or { exactMove(destination, context: &context, profile: profile) }
            .or { blindMove(destination, context: &context) }
            .lowered
    }

    /// Lanes 2 and 3, which share the model's target: native keys where they reach it, else lane A or B.
    static func exactMove(
        _ destination: LogicalStep.Destination, context: inout Context, profile: CapabilityProfile
    ) -> Lane {
        guard let model = context.model(for: destination, profile), let selection = context.selection else {
            return .next
        }
        guard let target = resolve(destination, model: model, from: selection.lowerBound) else { return .reject }
        return nativeMove(destination, to: target, model: model, context: &context, profile: profile).or {
            let actuation: [PhysicalStep]
            if profile.has(.writeSelection) {
                actuation = write(target..<target, context: context)
            } else {
                actuation = keyPath(from: selection, to: target, model: model)
            }
            context.selection = target..<target
            context.selectionOpaque = false
            return .steps(actuation + settle(context, profile: profile))
        }
    }

    static func blindMove(_ destination: LogicalStep.Destination, context: inout Context) -> Lane {
        guard case .motion(let motion, let count) = destination,
              let blind = blindMoveChord(motion) else { return .next }
        context.selection = nil
        context.selectionOpaque = false
        return .steps([.press(blind.chord, count: blind.counted ? count : 1)])
    }
}

// MARK: - Native keys

private extension PhysicalPlanner {
    /// Chords pressed together, then one settle; a group that blames a key holds that key alone.
    typealias KeyGroup = (chords: [Chord], blame: Capability?)

    /// Moves by paragraph and document keys, counting only the column; `next` where lane B counts it all.
    static func nativeMove(
        _ destination: LogicalStep.Destination?, to target: Int, model: TextModel,
        context: inout Context, profile: CapabilityProfile
    ) -> Lane {
        guard !profile.has(.writeSelection), let position = context.position else { return .next }
        let line = model.lineStart(of: position)
        let targetLine = model.lineStart(of: target)
        var groups: [KeyGroup]
        switch destination {
        case .motion(.lineStart, _)?:
            guard profile.has(.lineStartKey) else { return .next }
            groups = [([.paragraphStart], .lineStartKey)]
        case .motion(.lineEnd, let count)?:
            guard profile.has(.lineEndKey) else { return .next }
            groups = [([.paragraphEnd], .lineEndKey), (repeated([.right, .paragraphEnd], count - 1), nil)]
        case .motion(.fileStart, _)?:
            guard profile.has(.documentStartKey) else { return .next }
            groups = [([.documentStart], .documentStartKey)]
        case .motion(.fileEnd, _)?:
            guard profile.has(.documentEndKey), profile.has(.lineStartKey) else { return .next }
            groups = [([.documentEnd], .documentEndKey), ([.paragraphStart], .lineStartKey)]
        default:
            // `j`/`k` press their key even where the caret stays put, so a settle checks the line they start from.
            var vertical: Direction?
            if case .motion(.line(let direction, _), _)? = destination { vertical = direction }
            guard targetLine != line || vertical != nil else { return .next }
            if targetLine > line || vertical == .down {
                guard profile.has(.lineEndKey) else { return .next }
                let lines = model.newlineCount(in: line..<targetLine)
                var hops: [Chord] = lines > 0 ? [.right] : []
                hops += repeated([.paragraphEnd, .right], lines - 1)
                groups = [([.paragraphEnd], .lineEndKey), (hops, nil)]
            } else {
                guard profile.has(.lineStartKey) else { return .next }
                let lines = model.newlineCount(in: targetLine..<line)
                groups = [([.paragraphStart], .lineStartKey), (repeated([.left, .paragraphStart], lines), nil)]
            }
        }
        // Only the column is counted, in its own settle so the line the field reports decides it.
        var landing = KeyModel(text: model.text, anchor: position, focus: position)
        guard groups.flatMap(\.chords).allSatisfy({ landing.press($0) }),
              model.lineStart(of: landing.focus) == targetLine else { return .next }
        let reached = landing.focus
        let step: Chord = target > reached ? .right : .left
        groups.append((Array(repeating: step, count: model.graphemes(in: min(reached, target)..<max(reached, target))), nil))
        return pressing(groups, to: target..<target, context: &context, profile: profile)
    }

    /// Line-shaped selections by native keys, as many as the command counts, since keys past the end do nothing;
    /// `next` where lane B counts them.
    static func nativeSelect(
        _ target: LogicalStep.SelectionTarget, range: Range<Int>,
        context: inout Context, profile: CapabilityProfile
    ) -> Lane {
        guard !profile.has(.writeSelection) else { return .next }
        let groups: [KeyGroup]
        switch target {
        case .lines(let count, let interior):
            groups = linesDown(count, newline: !interior)
        case .lineSpan(to: .motion(.line(.down, _), let count), let interior):
            groups = linesDown(count + 1, newline: !interior)
        case .lineSpan(to: .motion(.line(.up, _), let count), let interior):
            groups = [([.paragraphEnd], .lineEndKey), (interior ? [] : [.right, .selectLeft], nil),
                      ([Chord.paragraphStart.shifted], .lineStartKey),
                      (repeated([.selectLeft, Chord.paragraphStart.shifted], count), nil)]
        case .lineSpan(to: .motion(.fileEnd, _), _):
            groups = [([.paragraphStart], .lineStartKey), ([Chord.documentEnd.shifted], .documentEndKey)]
        case .lineSpan(to: .motion(.fileStart, _), let interior):
            groups = [([.paragraphEnd], .lineEndKey), (interior ? [] : [.right], nil),
                      ([Chord.documentStart.shifted], .documentStartKey)]
        case .toLineEnd:
            groups = [([Chord.paragraphEnd.shifted], .lineEndKey)]
        case .span(to: .motion(.lineEnd, let count), false):
            groups = [([Chord.paragraphEnd.shifted], .lineEndKey),
                      (repeated([.selectRight, Chord.paragraphEnd.shifted], count - 1), nil)]
        case .span(to: .motion(.lineStart(firstNonBlank: false), _), false):
            groups = [([Chord.paragraphStart.shifted], .lineStartKey)]
        default:
            return .next
        }
        return pressing(groups, to: range, context: &context, profile: profile)
    }

    /// ⌃A, then ⇧⌃E per line with ⇧→ between, and ⇧→ once more for the last newline.
    static func linesDown(_ count: Int, newline: Bool) -> [KeyGroup] {
        var rest = repeated([.selectRight, Chord.paragraphEnd.shifted], count - 1)
        if newline { rest.append(.selectRight) }
        return [([.paragraphStart], .lineStartKey), ([Chord.paragraphEnd.shifted], .lineEndKey), (rest, nil)]
    }

    /// Presses the groups from the context's caret, each followed by its settle; `next` unless they land on `target`.
    static func pressing(
        _ groups: [KeyGroup], to target: Range<Int>, context original: inout Context, profile: CapabilityProfile
    ) -> Lane {
        guard let text = original.text, let position = original.position else { return .next }
        let atoms = Set(groups.compactMap(\.blame))
        guard atoms.allSatisfy(profile.has) else { return .next }
        var context = original
        var steps = collapsing(&context)
        // One model throughout: which end of a selection moves is state the keys build up.
        var model = KeyModel(text: text, anchor: position, focus: position)
        for group in groups where !group.chords.isEmpty {
            for chord in group.chords {
                guard model.press(chord) else { return .next }
            }
            steps += keys(group.chords, blaming: group.blame, to: model.selection, context: &context, profile: profile)
        }
        guard model.selection == target else { return .next }
        original = context
        return .steps(steps)
    }

    static func repeated(_ chords: [Chord], _ times: Int) -> [Chord] {
        Array(repeatElement(chords, count: max(0, times)).joined())
    }

    /// Presses `chords`, then settles on `landing`; a named key is blamed if it left a selection where it leaves a caret,
    /// if the field reads as before where it had somewhere to go, or if it landed elsewhere where lines are the model's.
    static func keys(
        _ chords: [Chord], blaming atom: Capability?, to landing: Range<Int>,
        context: inout Context, profile: CapabilityProfile
    ) -> [PhysicalStep] {
        let before = context.selection
        let model = context.model
        context.selection = landing
        context.selectionOpaque = false
        let leavesCaret = chords.allSatisfy { !$0.modifiers.contains(.shift) }
        let blame = atom.flatMap { atom -> Expectation.Blame? in
            guard let before, let model else { return nil }
            let emptyParagraph = before == context.emptyParagraphCaret
            let unmoved = emptyParagraph || mayStayPut(chords, from: before, in: model) ? [] : [context.field(before)]
            // Chromium's rich text can split one paragraph into several `AXValue` lines (a mention chip); nothing else does.
            let offTarget = context.breaks == nil
            var exemptions: [Expectation.Exemption] = []
            if emptyParagraph { exemptions.append(.init(.emptyParagraph, unmoved: [context.field(before)])) }
            if !offTarget { exemptions.append(.init(.paragraphLines, offTarget: true)) }
            guard !unmoved.isEmpty || leavesCaret || offTarget || !exemptions.isEmpty else { return nil }
            return Expectation.Blame(
                capability: atom, unmoved: unmoved, leavesCaret: leavesCaret, offTarget: offTarget, exemptions: exemptions
            )
        }
        var steps: [PhysicalStep] = []
        for chord in chords {
            if case .press(chord, let count)? = steps.last {
                steps[steps.count - 1] = .press(chord, count: count + 1)
            } else {
                steps.append(.press(chord, count: 1))
            }
        }
        return steps + settle(context, profile: profile, blame: blame)
    }

    /// Whether the keys may rightly leave the caret where it was: they had nowhere to go from it.
    static func mayStayPut(_ chords: [Chord], from read: Range<Int>, in model: TextModel) -> Bool {
        guard read.isEmpty else { return true }
        var keys = KeyModel(text: model.text, anchor: read.lowerBound, focus: read.lowerBound)
        guard chords.allSatisfy({ keys.press($0) }) else { return true }
        return keys.selection == read
    }

    /// In a field that claims the native keys, a yank within a line takes the text the field selected, which holds
    /// where a misread caret shifts the model's; Chromium's leaves paragraph breaks out, and deletes check it instead.
    static func registersFromField(_ content: String, _ profile: CapabilityProfile) -> Bool {
        !profile.has(.writeSelection) && profile.has(.readSelectedText)
            && Capability.nativeKeys.contains(where: profile.has) && !content.contains("\n")
    }

    /// ← first, so every key starts from a caret (LIN-1532).
    static func collapsing(_ context: inout Context) -> [PhysicalStep] {
        guard let selection = context.selection, !selection.isEmpty else { return [] }
        context.selection = selection.lowerBound..<selection.lowerBound
        return [.press(.left, count: 1)]
    }
}

// MARK: - The app's keys

/// Every landing is checked against p, the caret the field reported.
private extension PhysicalPlanner {
    struct AppKey {
        let chord: Chord
        let forward: Bool
        /// Demoted when the key misbehaves; nil where staying put is legitimate.
        let atom: Capability?
    }

    static func appKey(_ motion: Motion) -> AppKey? {
        switch motion {
        case .word(.forward, _, false): return AppKey(chord: .wordRight, forward: true, atom: .wordKeys)
        case .word(.backward, false, false): return AppKey(chord: .wordLeft, forward: false, atom: .wordKeys)
        case .paragraph(.forward): return AppKey(chord: .paragraphForward, forward: true, atom: .paragraphKeys)
        case .paragraph(.backward): return AppKey(chord: .paragraphBackward, forward: false, atom: .paragraphKeys)
        case .displayLine(.down): return AppKey(chord: .down, forward: true, atom: nil)
        case .displayLine(.up): return AppKey(chord: .up, forward: false, atom: nil)
        case .page(.forward, false): return AppKey(chord: .pageForward, forward: true, atom: nil)
        case .page(.backward, false): return AppKey(chord: .pageBackward, forward: false, atom: nil)
        case .line(.down, false): return AppKey(chord: .down, forward: true, atom: nil)
        case .line(.up, false): return AppKey(chord: .up, forward: false, atom: nil)
        default: return nil
        }
    }

    static func mustMove(from p: Int, forward: Bool, model: TextModel) -> Bool {
        forward ? p < model.length : p > 0
    }

    /// Exempt in web content: raw reads cannot tell a key that did nothing (LIN-1564).
    static func wordBlame(_ blame: Expectation.Blame?, context: Context) -> Expectation.Blame? {
        guard context.webContent, let blame else { return blame }
        return Expectation.Blame(capability: blame.capability, unmoved: blame.unmoved, leavesCaret: blame.leavesCaret,
                                 offTarget: blame.offTarget, exemptions: [.init(.webContent, all: true)])
    }

    /// `j`/`k` press ↓/↑ only where neither a write nor ⌃E/⌃A can land a line.
    static func movesByRow(_ motion: Motion, profile: CapabilityProfile) -> Bool {
        guard case .line(let direction, false) = motion else { return false }
        return !profile.has(.writeSelection) && !profile.has(direction == .down ? .lineEndKey : .lineStartKey)
    }

    static func isBlank(_ o: Int, in model: TextModel) -> Bool {
        model.substring(o..<model.advance(o, byGraphemes: 1)).first?.isWhitespace ?? true
    }

    /// No app word crosses a blank, so this run bounds any word at `o`.
    static func run(at o: Int, in model: TextModel) -> Range<Int> {
        guard !isBlank(o, in: model) else { return o..<o }
        var lower = o, upper = o
        while lower > 0, !isBlank(model.advance(lower, byGraphemes: -1), in: model) { lower = model.advance(lower, byGraphemes: -1) }
        while upper < model.length, !isBlank(upper, in: model) { upper = model.advance(upper, byGraphemes: 1) }
        return lower..<upper
    }

    static func isWordCharacter(_ o: Int, in model: TextModel) -> Bool {
        model.substring(o..<model.advance(o, byGraphemes: 1)).first.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
    }

    static func hasWord(_ run: Range<Int>, in model: TextModel) -> Bool {
        model.substring(run).contains { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func wordRunBefore(_ c: Int, in model: TextModel) -> Int {
        guard c > 0 else { return 0 }
        let found = run(at: model.advance(c, byGraphemes: -1), in: model)
        return hasWord(found, in: model) ? found.count : 0
    }

    /// How far `words` app words reach; like the keys, it skips punctuation-only runs.
    static func wordReach(from o: Int, words: Int, forward: Bool, in model: TextModel) -> Int {
        var at = o
        for _ in 0..<max(1, words) {
            while true {
                let blanksDone: Int
                if forward {
                    var next = at
                    while next < model.length, isBlank(next, in: model) { next = model.advance(next, byGraphemes: 1) }
                    blanksDone = next
                    guard blanksDone < model.length else { at = model.length; break }
                    let found = run(at: blanksDone, in: model)
                    at = found.upperBound
                    if hasWord(found, in: model) { break }
                } else {
                    var next = at
                    while next > 0, isBlank(model.advance(next, byGraphemes: -1), in: model) { next = model.advance(next, byGraphemes: -1) }
                    blanksDone = next
                    guard blanksDone > 0 else { at = 0; break }
                    let found = run(at: model.advance(blanksDone, byGraphemes: -1), in: model)
                    at = found.lowerBound
                    if hasWord(found, in: model) { break }
                }
            }
        }
        return abs(at - o)
    }

    /// Where ⌥→ ⌥← from a blank lands.
    static func nextWordStart(after o: Int, in model: TextModel) -> Int? {
        var at = o
        while at < model.length {
            if isWordCharacter(at, in: model) { return at }
            at = model.advance(at, byGraphemes: 1)
        }
        return nil
    }

    /// What `iw` finds at p; `trailing` is blanks to the text's end.
    enum Under: Equatable {
        case letter
        case blank(nextWord: Int)
        case trailing
    }

    static func under(_ c: Int, in model: TextModel) -> Under {
        guard isBlank(c, in: model) else { return .letter }
        return nextWordStart(after: c, in: model).map { .blank(nextWord: $0) } ?? .trailing
    }

    /// The word p is in or starts, else the one ending at p.
    static func wordKeys(
        after under: Under, at p: Int, model: TextModel, context: Context, profile: CapabilityProfile
    ) -> [PhysicalStep] {
        let before = p > 0 ? run(at: model.advance(p, byGraphemes: -1), in: model) : p..<p
        switch under {
        case .letter:
            return selectBack(to: .caretAfter(p, strict: true), within: run(at: p, in: model), context: context, profile: profile)
        case .blank:
            return [.press(.wordLeft, count: 1),
                    appSettle(.caretBefore(p, strict: true), blame: nil, keeps: 0, context: context, profile: profile)]
                + selectBack(to: .exact(p..<p), within: before, context: context, profile: profile)
        case .trailing:
            return selectBack(to: .exact(p..<p), within: before, context: context, profile: profile)
        }
    }

    /// The selection must be exactly the kept span, inside `within`.
    static func selectBack(to end: Landing, within: Range<Int>, context: Context, profile: CapabilityProfile) -> [PhysicalStep] {
        [.press(.wordRight, count: 1),
         appSettle(end, blame: nil, keeps: 1, context: context, profile: profile),
         .press(.selectWordLeft, count: 1),
         appSettle(.between(0, 1), blame: wordBlame(Expectation.Blame(capability: .wordKeys, unmoved: []), context: context),
                   within: within, context: context, profile: profile)]
    }

    /// Scripts written without spaces, where one run holds many words.
    static func isUnspaced(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xF900...0xFAFF, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    enum Edge { case start, end }

    static func edge(at c: Int, in model: TextModel) -> Edge? {
        let before = c > 0 && isWordCharacter(model.advance(c, byGraphemes: -1), in: model)
        let after = isWordCharacter(c, in: model)
        return before == after ? nil : after ? .start : .end
    }

    /// Whether the reach ends a plain word run, so the span is known exactly.
    static func oneWordRun(_ reached: Range<Int>, forward: Bool, in model: TextModel) -> Bool {
        let characters = Array(model.substring(reached))
        let word = { (c: Character) in c.isLetter || c.isNumber || c == "_" }
        let rest = forward ? Array(characters.drop { !word($0) }) : Array(characters.reversed().drop { !word($0) })
        return !rest.isEmpty && rest.allSatisfy(word)
    }

    /// Out and back to p with the unshifted keys; the selection must be exactly their span.
    static func exactSpanKeys(
        _ p: Int, forward: Bool, fromStart: Bool, count: Int, reached: Range<Int>, context: Context, profile: CapabilityProfile
    ) -> [PhysicalStep] {
        let (out, back): (Chord, Chord) = forward ? (.wordRight, .wordLeft) : (.wordLeft, .wordRight)
        let (far, near) = forward ? (1, 0) : (0, 1)
        let leaves = forward == fromStart
        return [.press(out, count: count),
                appSettle(forward ? .caretAfter(p, strict: true) : .caretBefore(p, strict: true), blame: nil, keeps: far,
                          context: context, profile: profile)]
            // From the other edge: one word further back, then one out.
            + (leaves ? [.press(back, count: count)] : [.press(back, count: count + 1), .press(out, count: 1)])
            + [appSettle(.exact(p..<p), blame: nil, keeps: near, context: context, profile: profile),
                .press(forward ? .selectWordRight : .selectWordLeft, count: count),
                appSettle(.between(0, 1), blame: wordBlame(Expectation.Blame(capability: .wordKeys, unmoved: []), context: context),
                          within: reached, context: context, profile: profile)]
    }

    /// Where ⌥→ ⌥← lands: exactly on the next word from a blank, else at or before p.
    static func roundTripLanding(_ under: Under, at p: Int) -> Landing {
        if case .blank(let next) = under { return .exact(next..<next) }
        return .caretBefore(p, strict: false)
    }

    /// Checks precede selections, so a failure strands a caret, not a selection.
    static func wordAtCaretKeys(_ p: Int, model: TextModel, context: Context, profile: CapabilityProfile) -> [PhysicalStep]? {
        let under = under(p, in: model)
        if under != .letter, wordRunBefore(p, in: model) == 0 { return nil }
        return [.press(.wordRight, count: 1), .press(.wordLeft, count: 1),
                appSettle(roundTripLanding(under, at: p), blame: nil, keeps: 0, context: context, profile: profile)]
            + wordKeys(after: under, at: p, model: model, context: context, profile: profile)
    }

    /// Landings come in `AXValue` offsets and leave in the field's, with the side a boundary caret must settle on.
    static func appSettle(
        _ landing: Landing, blame: Expectation.Blame?, keeps: Int? = nil, within: Range<Int>? = nil,
        context: Context, profile: CapabilityProfile
    ) -> PhysicalStep {
        let length = profile.has(.readLength) ? context.valueLength : nil
        let read: Landing
        var edge: Expectation.Edge?
        switch landing {
        case .exact(let range):
            read = .exact(context.field(range))
            edge = context.paragraphsUncertain ? nil : context.edge(range.upperBound)
        case .caretAfter(let o, let strict):
            read = .caretAfter(context.field(o..<o).lowerBound, strict: strict)
        case .caretBefore(let o, let strict):
            read = .caretBefore(context.field(o..<o).lowerBound, strict: strict)
        case .between:
            read = landing
        }
        var expectation = Expectation(landing: read, length: length, edge: edge, blame: blame)
        expectation.within = within.map(context.field)
        expectation.longest = expectation.within?.count
        expectation.keeps = keeps
        return .settle(expectation)
    }

    /// Blamed only if the field still reads p after the keys.
    static func stuck(_ atom: Capability?, at p: Int, context: Context) -> Expectation.Blame? {
        atom.map { Expectation.Blame(capability: $0, unmoved: [context.field(p..<p)]) }
    }

    /// A key may land across paragraph breaks alone, which the field's offsets skip.
    static func mayCrossOnlyBreaks(from p: Int, forward: Bool, context: Context) -> Bool {
        context.breaks?.offsets.contains(forward ? p : p - 1) ?? false
    }

    static func appMove(
        _ destination: LogicalStep.Destination, context: inout Context, profile: CapabilityProfile
    ) -> Lane {
        guard profile.has(.nativeMotions), case .motion(let motion, let count) = destination,
              let key = appKey(motion) else { return .next }
        guard let model = context.model(for: destination, profile), let selection = context.selection,
              profile.has(.readCaret) else {
            // Lane C already maps words and lines.
            if key.atom == .wordKeys { return .next }
            if case .line = motion { return .next }
            context.selection = nil
            context.selectionOpaque = false
            return .steps([.press(key.chord, count: count)])
        }
        // Exact fields keep vim's words.
        if key.atom == .wordKeys, profile.has(.writeSelection) { return .next }
        if case .line = motion, !movesByRow(motion, profile: profile) { return .next }
        if let atom = key.atom, !profile.has(atom) { return .next }
        let p = selection.lowerBound
        let strict = mustMove(from: p, forward: key.forward, model: model)
            && !mayCrossOnlyBreaks(from: p, forward: key.forward, context: context)
        let landing: Landing = key.forward ? .caretAfter(p, strict: strict) : .caretBefore(p, strict: strict)
        context.selection = nil
        context.selectionOpaque = false
        return .steps((selection.isEmpty ? [] : [.press(.left, count: 1)]) + [
            .press(key.chord, count: count),
            // Blamed for leaving a selection, or, outside web content, for staying put.
            appSettle(landing, blame: key.atom.map {
                let stuck = strict ? [context.field(p..<p)] : []
                return context.webContent
                    ? Expectation.Blame(capability: $0, unmoved: [], leavesCaret: true,
                                        exemptions: stuck.isEmpty ? [] : [.init(.webContent, unmoved: stuck)])
                    : Expectation.Blame(capability: $0, unmoved: stuck, leavesCaret: true)
            }, context: context, profile: profile),
        ])
    }

    /// Rejects a span its keys cannot prove, since vim's words may not be the app's.
    static func appSelect(
        _ target: LogicalStep.SelectionTarget, context: inout Context, profile: CapabilityProfile
    ) -> Lane {
        guard profile.has(.nativeMotions) else { return .next }
        let span: AppKey?
        switch target {
        case .textObject(TextObject(scope: .inner, kind: .word(bigWord: false)), 1):
            span = nil
        case .span(.motion(let motion, _), _):
            guard let key = appKey(motion), key.atom == .wordKeys else { return .next }
            span = key
        default:
            return .next
        }
        guard let model = context.model(for: target, profile), let selection = context.selection,
              profile.has(.readCaret) else {
            // ⌥→ first, so a caret at a word's start stays in that word.
            guard span == nil else { return .next }
            context.selection = nil
            context.selectionOpaque = true
            context.selectionWise = .character
            return .steps([.press(.wordRight, count: 1), .press(.wordLeft, count: 1), .press(.selectWordRight, count: 1)])
        }
        guard !profile.has(.writeSelection), profile.has(.wordKeys) else { return .next }
        let p = selection.lowerBound
        var steps: [PhysicalStep] = selection.isEmpty ? [] : [.press(.left, count: 1)]
        if let key = span, case .span(.motion(_, let count), _) = target {
            let reach = wordReach(from: p, words: count, forward: key.forward, in: model)
            let reached = key.forward ? p..<min(model.length, p + reach) : max(0, p - reach)..<p
            // Proven at an edge, predicted in a plain word, else refused.
            if let edge = edge(at: p, in: model) {
                steps += exactSpanKeys(p, forward: key.forward, fromStart: edge == .start, count: count, reached: reached,
                                       context: context, profile: profile)
            } else if model.substring(reached).contains(where: isUnspaced) {
                // The app may see a word edge here the model cannot; it rings if not.
                steps += exactSpanKeys(p, forward: key.forward, fromStart: key.forward, count: count, reached: reached,
                                       context: context, profile: profile)
            } else if oneWordRun(reached, forward: key.forward, in: model) {
                steps.append(.press(key.forward ? .selectWordRight : .selectWordLeft, count: count))
                let blame = wordBlame(stuck(.wordKeys, at: p, context: context), context: context)
                steps.append(appSettle(.exact(reached), blame: blame, context: context, profile: profile))
            } else {
                return .reject
            }
        } else {
            guard let keys = wordAtCaretKeys(p, model: model, context: context, profile: profile) else { return .reject }
            steps += keys
        }
        context.selection = nil
        context.selectionOpaque = true
        context.selectionWise = .character
        return .steps(steps)
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

    static func blindSelectKeys(_ target: LogicalStep.SelectionTarget) -> [PhysicalStep]? {
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
        appSelect(target, context: &context, profile: profile)
            .or { exactSelect(target, context: &context, profile: profile) }
            .or { blindSelect(target, context: &context) }
            .lowered
    }

    /// Lanes 2 and 3, which share the model's range: native keys where they select it, else lane A or B.
    static func exactSelect(
        _ target: LogicalStep.SelectionTarget, context: inout Context, profile: CapabilityProfile
    ) -> Lane {
        guard let model = context.model(for: target, profile), let selection = context.selection else { return .next }
        guard let range = selectionRange(for: target, model: model, at: selection.lowerBound, context: context) else {
            return .reject
        }
        context.selectionWise = target.wise ?? context.selectionWise ?? .character
        context.selectionOpaque = false
        // Pressed even where nothing is to select, so a settle checks the caret the command starts from.
        return nativeSelect(target, range: range, context: &context, profile: profile).or {
            if range == context.selection {
                return .steps([])   // already selected (Visual operators)
            }
            if profile.has(.writeSelection) {
                context.selection = range
                return .steps(write(range, context: context) + settle(context, profile: profile))
            }
            var presses = keyPath(from: selection, to: range.lowerBound, model: model)
            let count = model.graphemes(in: range)
            if count > 0 {
                presses.append(.press(.selectRight, count: count))
            }
            context.selection = range
            return .steps(presses + settle(context, profile: profile))
        }
    }

    static func blindSelect(_ target: LogicalStep.SelectionTarget, context: inout Context) -> Lane {
        guard let presses = blindSelectKeys(target) else { return .next }
        context.selection = nil
        context.selectionOpaque = true
        context.selectionWise = target.wise ?? .character
        return .steps(presses)
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
            let content = model.substring(selection)
            guard registersFromField(content, profile) else {
                return [.commit(.yanked(into: register, content: .literal(content), wise: wise))]
            }
            let slot = context.takeSlot()
            return [.captureSelectedText(into: slot), .commit(.yanked(into: register, content: .captured(slot), wise: wise))]
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
        let action = profile.has(.insertText) ? .replaceSelection(replacement) : blindText(replacement, context: context)
        if let selection = context.selection, let model = context.model {
            let check = checkSelectedText(model.substring(selection), context: context, profile: profile)
            context.applyEdit(range: selection, replacement: replacement)
            // Blind (typeText) over-type: soft, so a mismatch does not abort
            // the `setMode(.insert)` behind an `o`/`O`/`i`.
            let steps = check + [action] + settle(context, profile: profile, hard: profile.has(.insertText))
            context.lengthUncertain = context.lengthUncertain
                || !profile.has(.insertText) && context.breaks != nil && replacement.contains("\n")
            return steps
        }
        context.invalidate()
        // Blind keys may still be queued, and typing or pasting rides the same queue.
        return [context.keysQueued ? blindText(replacement, context: context) : action]
    }

    /// A typed `\n` makes no paragraph in Chromium's rich text, and ⏎ would send a chat message, so web content pastes it.
    static func blindText(_ text: String, context: Context) -> PhysicalStep {
        context.webContent && text.contains("\n") ? .clipboardInsert(text) : .typeText(text)
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
        let action = profile.has(.insertText) ? .replaceSelection(transformed) : blindText(transformed, context: context)
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
        var settled = false
        if profile.has(.writeSelection) {
            steps += write(range, context: context)
        } else {
            switch nativeSelect(.lines(count: count, interior: true), range: range,
                                context: &context, profile: profile) {
            case .steps(let keys):
                steps += keys
                settled = true
            case .next:
                steps += keyPath(from: selection, to: range.lowerBound, model: model)
                steps.append(.press(.selectRight, count: model.graphemes(in: range)))
            case .reject:
                return nil
            }
        }
        context.selection = range
        // Settled, so the AX replacement cannot overtake the selecting keys.
        var barrier = checkSelectedText(model.substring(range), context: context, profile: profile)
        if barrier.isEmpty, !settled, presses(steps), profile.has(.insertText) {
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
                    guard let moved = moveSteps(to: target, context: &context, profile: profile) else { return nil }
                    steps += moved
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
                    guard let moved = moveSteps(to: target, as: lineTarget(action, end: end, model: model),
                                                context: &context, profile: profile) else { return nil }
                    steps += moved
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
                // Each copy is a whole line: a last line or `cc` leaves its register without the newline.
                let line = content.text.hasSuffix("\n") ? content.text : content.text + "\n"
                return putLinewise(String(repeating: line, count: max(1, count)), action: action,
                                   context: &context, profile: profile)
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
            guard var steps = moveSteps(to: target, context: &context, profile: profile) else { return nil }
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
            let end = model.lineEnd(of: position)
            if action.position == .after {
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
            guard var steps = moveSteps(to: target, as: lineTarget(action, end: end, model: model),
                                        context: &context, profile: profile) else { return nil }
            steps += insertSteps(insertion, after: steps, context: &context, profile: profile)
            return steps
        }
        context.invalidate()
        if action.position == .after {
            return [.press(.lineEnd, count: 1), .clipboardInsert("\n" + String(text.dropLast()))]
        }
        return [.press(.lineStart, count: 1), .clipboardInsert(text)]
    }

    /// What a linewise put's target is to the native keys; nil for the next line's start, which is a hop.
    static func lineTarget(_ action: PutAction, end: Int, model: TextModel) -> LogicalStep.Destination? {
        guard action.position == .after else { return .motion(.lineStart(firstNonBlank: false), count: 1) }
        return end >= model.length ? .motion(.lineEnd, count: 1) : nil
    }

    static func moveSteps(
        to target: Int,
        as destination: LogicalStep.Destination? = nil,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        let steps: [PhysicalStep]
        if profile.has(.writeSelection) {
            steps = write(target..<target, context: context)
        } else if let model = context.model, let selection = context.selection {
            switch nativeMove(destination, to: target, model: model, context: &context, profile: profile) {
            case .steps(let keys): return keys
            case .next: steps = keyPath(from: selection, to: target, model: model)
            case .reject: return nil
            }
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
            // An AX insertion can overtake queued keys; a paste cannot, and native keys already settled.
            let pressed = positioning.last.map { if case .press = $0 { return true }; return false } ?? false
            let barrier = pressed && profile.has(.insertText) ? settle(context, profile: profile) : []
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
