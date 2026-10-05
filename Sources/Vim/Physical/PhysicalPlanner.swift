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
///    written: ⌃A ⌃E ⌘↑ ⌘↓, shifted to select, with only a column counted;
///    and ⌃A or ⌃E to a line's start or end that a folded field's write
///    would reach only with arrows after it.
/// 3. **A** (AX write): compute exact offsets with `TextModel`, set ranges,
///    adding arrow keys at a Chromium paragraph end, where a write lands on
///    the next paragraph. Or **B** (read, no write): the same exact math,
///    actuated as counted keystrokes and verified by read-back — reads
///    turn key synthesis into a dumb actuator. Lanes 2 and B take a
///    `Route` where it presses fewer keys than counting, until it misses.
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

    /// `plan` plus what only the planner knows: why it rejected, and the operand; `missed` routes are planned without.
    public static func planning(
        _ logical: LogicalPlan, snapshot: FieldSnapshot, missed: Set<Route> = []
    ) -> Planning {
        let profile = snapshot.capabilities
        var context = Context(snapshot: snapshot)
        context.missed = missed
        var steps: [PhysicalStep] = []
        // Writes in a folded field mix with keys at its line edges (LIN-1685).
        let foldedWrites = profile.has(.writeSelection) && context.folded
        // The field shows our block cursor: physically collapse it to its
        // gap before the plan acts, so no step ever operates on the
        // presentation selection. Empty and bell-only plans skip this —
        // they touch nothing and the cursor stays up.
        var uncover: [PhysicalStep] = []
        if let gap = context.cursorCollapse, !logical.steps.isEmpty, !isBellOnly(logical) {
            uncover = collapse(to: gap, context: context, profile: profile)
            context.queue(uncover)
            context.drawnBreak = nil
            context.unmoved = false
        }
        for (index, step) in logical.steps.enumerated() {
            let caret = context.unmoved ? context.caret : nil
            // An AX write would overtake keys still queued, so a write after them waits for them to settle.
            let barrier = foldedWrites && context.keysQueued ? settle(context, profile: profile) : []
            guard var lowered = lower(step, context: &context, profile: profile) else {
                return Planning(plan: .rejected, rejection: Rejection(index: index, step: step), operand: nil)
            }
            // ⇧→ and ⇧⌃E do nothing from inside a code span's start, which a caret mvim did not place may be (LIN-1683).
            if let caret, let first = lowered.firstIndex(where: moves), case .press(let chord, _) = lowered[first],
               let prefix = outside(before: chord, at: caret, context: context, profile: profile) {
                lowered.insert(contentsOf: prefix, at: first)
            }
            if let first = lowered.first(where: moves), isWrite(first) {
                lowered.insert(contentsOf: barrier, at: 0)
            }
            steps.append(contentsOf: lowered)
            context.queue(lowered)
            if lowered.contains(where: moves) {
                context.drawnBreak = nil
                context.unmoved = false
            }
        }
        // ⌃A and ⌃E land alike from the cursor's one character, so a plan they start leaves it be.
        if foldedWrites, let first = steps.first(where: moves), case .press(let chord, _) = first,
           [.paragraphStart, .paragraphEnd].contains(chord) {
            uncover = []
        }
        return Planning(plan: PhysicalPlan(steps: uncover + steps), rejection: nil, operand: context.operand)
    }

    static func isWrite(_ step: PhysicalStep) -> Bool {
        switch step {
        case .setSelection, .replaceSelection: true
        default: false
        }
    }

    /// A step that can take the caret from where the snapshot saw it.
    static func moves(_ step: PhysicalStep) -> Bool {
        switch step {
        case .setSelection, .replaceSelection, .press, .typeText, .clipboardCut, .clipboardInsert: true
        default: false
        }
    }

    private static func isBellOnly(_ logical: LogicalPlan) -> Bool {
        logical.steps.allSatisfy { step in
            if case .bell = step { return true }
            return false
        }
    }
}

// MARK: - Repair and release

public extension PhysicalPlanner {
    /// Collapses a selection an aborted run left to its start, in field offsets; `snapshot` reads the field as it is.
    static func collapse(
        _ selection: Range<Int>, misread: Bool = false, side: ParagraphBreaks.Side? = nil, paragraphs: Bool = false,
        snapshot: FieldSnapshot? = nil, profile: CapabilityProfile
    ) -> PhysicalPlan {
        // After a failed text check the offsets name other text than is selected, and ← collapses whatever is.
        guard !misread else { return PhysicalPlan(.press(.left, count: 1)) }
        var start = selection.lowerBound
        var field = FieldSnapshot(capabilities: profile, selection: start..<start, breaks: paragraphs ? ParagraphBreaks() : nil)
        // A `<br>` Linear drew for its caret leaves in its own time, and every offset behind it moves then.
        let held = snapshot.flatMap { $0.drawnBreak == nil ? $0 : nil }
        // In `AXValue` offsets a paragraph's end and the next one's start differ, as they do in a command's plan.
        if let held, let breaks = held.breaks, let resolved = breaks.valueRange(start..<start, side: { _ in side }),
           resolved.upperBound <= (held.text?.utf16.count ?? .max) {
            start = resolved.lowerBound
            field = FieldSnapshot(capabilities: profile, text: held.text, selection: resolved, breaks: breaks)
        }
        var context = Context(snapshot: field)
        context.unknown.insert(.length)
        let keys = [.press(.left, count: 1)] + (context.normalizes(start) ? outside : []) + settle(context, profile: profile)
        guard profile.has(.writeSelection) else { return PhysicalPlan(steps: keys) }
        // A folded write plans nothing where the caret is already placed, which a selection there is not.
        context.selection = nil
        let written = write(start..<start, context: context)
        // Where a write needs keys to finish, as at a paragraph's end, ← lands the selection's start itself (LIN-1532).
        return PhysicalPlan(steps: presses(written) ? keys : written)
    }

    /// Takes the drawn cursor off a field focus has left, by a write alone: a key would reach the field focus went to.
    static func releaseCursor(_ cursor: Range<Int>, breaks: ParagraphBreaks?, profile: CapabilityProfile) -> PhysicalPlan? {
        guard profile.has(.writeSelection) else { return nil }
        let context = Context(snapshot: FieldSnapshot(capabilities: profile, breaks: breaks))
        return PhysicalPlan(.setSelection(context.field(cursor.lowerBound..<cursor.lowerBound)))
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

        /// Optional routes that missed at this field's rung, where counting takes over again (LIN-1686).
        var missed: Set<Route> = []

        mutating func queue(_ steps: [PhysicalStep]) {
            for step in steps {
                switch step {
                case .press, .typeText, .clipboardCut, .clipboardCopy, .clipboardInsert: keysQueued = true
                case .settle, .softSettle: keysQueued = false
                default: break
                }
            }
        }

        let webContent: Bool

        /// Everything else is in `AXValue` offsets; ranges leave for the field through these.
        var breaks: ParagraphBreaks?

        /// What the edits so far left settles unable to check.
        var unknown: Set<Unknown> = []

        enum Unknown {
            case selection, length, edge
        }

        /// `text` less `AXValue`, whose length settles check: the empty paragraphs put back, less the lines folded out.
        let valueGap: Int

        /// Emptying or filling a line changes which lines `AXValue` shows beside it.
        let reshapes: Bool

        var textlessLeaves = false

        /// ⇧⌃E may extend a folded write's selection to a line's end.
        let lineEndKey: Bool

        init(snapshot: FieldSnapshot) {
            text = snapshot.text
            lineEndKey = snapshot.capabilities.has(.lineEndKey)
            selection = snapshot.selection
            anchor = snapshot.anchor
            webContent = snapshot.webContent
            breaks = snapshot.breaks
            emptyParagraphCaret = snapshot.caretInEmptyParagraph ? snapshot.selection : nil
            textlessLeaves = snapshot.textlessLeaves
            valueGap = snapshot.valueGap - snapshot.foldedLength
            reshapes = snapshot.holdsEmptyParagraphs || snapshot.foldedLength > 0
            if snapshot.holdsChips || snapshot.holdsDrawnCaret { unknown.insert(.length) }
            drawnBreak = snapshot.drawnBreak
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

        /// The model holds folded text, where Linear lands a write by where the caret came from (LIN-1652).
        var folded: Bool { !(breaks?.hidden.allSatisfy(\.isGap) ?? true) }

        /// A non-empty line's start with nothing folded at or beside it, where a write lands as where nothing is folded.
        func plainStart(_ offset: Int, in model: TextModel) -> Bool {
            // A stop folds no text, so a quote's first line after one takes a write as any paragraph's does.
            let folded = breaks?.hidden.contains { !$0.isGap && (offset - 1...offset + 1).contains($0.at) } ?? false
            return model.lineEnd(of: offset) > offset && !folded
        }

        /// Chromium rich text, where a plain arrow at a Linear code span's edge can stay put (LIN-1683).
        var arrowsSelect: Bool { breaks != nil }

        /// The `<br>` after a caret Linear draws at a paragraph's end, which only a write before the caret moves meets.
        var drawnBreak: Int?

        /// Nothing has pressed or written yet, so the caret is still the snapshot's, wherever it came from.
        var unmoved = true

        /// `range` in field offsets as a write meets them: past that `<br>`, one more while it is there.
        func written(_ range: Range<Int>) -> Range<Int> {
            let written = field(range)
            guard let drawnBreak, let breaks else { return written }
            let end = breaks.valueOffsets(drawnBreak).lowerBound
            return (range.lowerBound > end ? written.lowerBound + 1 : written.lowerBound)
                ..< (range.upperBound > end ? written.upperBound + 1 : written.upperBound)
        }

        /// Model offsets of the chips, which keys cross in one step.
        var atoms: Set<Int> { breaks?.atoms ?? [] }

        /// Starts of lines right after a list, code block or quote's end, where a plain → ↓ from above or ↑ from them stops first.
        var gaps: Set<Int> { breaks?.gaps ?? [] }

        /// Starts of to-dos after a stop, into which ⇧→ does not extend.
        var boxed: Set<Int> { Set(breaks?.hidden.filter { $0.kind == .boxedGap }.map(\.at) ?? []) }

        func isAtom(_ offset: Int) -> Bool { breaks?.isAtom(offset) ?? false }

        /// A register's text for `range`, each chip's label whole.
        func content(_ range: Range<Int>, _ text: String) -> String {
            breaks?.withAtoms(text, at: range) ?? text
        }

        /// The snapshot's caret when it is in an empty paragraph, which `AXValue` can leave out and read beside, so a
        /// key pressed from it can seem to do nothing when it did.
        let emptyParagraphCaret: Range<Int>?

        /// Typing over `range` would drop a break bounding an `<hr>` or a table cell, or a chip: no typed text rebuilds them.
        func retypesStructure(_ range: Range<Int>) -> Bool {
            textlessLeaves && (breaks?.offsets.contains { range.contains($0) } ?? false) || (breaks?.coversAtom(range) ?? false)
        }

        /// A caret here may be inside a code span's start; ←, ⌘← and writes land outside one at a paragraph's start.
        func normalizes(_ offset: Int) -> Bool {
            arrowsSelect && offset > 0 && edge(offset) != .paragraphStart
        }

        /// Which side of a paragraph boundary `offset` is on; nil off a boundary.
        func edge(_ offset: Int) -> Expectation.Edge? {
            guard let breaks else { return nil }
            let candidates = breaks.valueOffsets(breaks.fieldOffset(offset))
            guard candidates.count > 1 else { return nil }
            // Between two breaks is a line Chromium makes for a text-less or uneditable element, past the paragraph's end.
            return offset == candidates.lowerBound ? .paragraphEnd : .paragraphStart
        }

        /// Every settle's expectation: a landing in `AXValue` offsets leaves in the field's, less what is unknown.
        func expectation(
            _ landing: Landing, blame: Expectation.Blame? = nil, selectedText: String? = nil,
            keeps: Int? = nil, within: Range<Int>? = nil, profile: CapabilityProfile
        ) -> Expectation {
            let length = profile.has(.readLength) && !unknown.contains(.length)
                ? text.map { $0.utf16.count - valueGap } : nil
            // Without a landing no selection is read, so its edge and slots would check nothing.
            guard !unknown.contains(.selection) else {
                return Expectation(landing: nil, length: length, blame: blame, selectedText: selectedText)
            }
            let read: Landing
            var side: Expectation.Edge?
            switch landing {
            case .exact(let range):
                read = .exact(field(range))
                side = unknown.contains(.edge) ? nil : edge(range.upperBound)
            case .caretAfter(let o, let strict):
                read = .caretAfter(field(o..<o).lowerBound, strict: strict)
            case .caretBefore(let o, let strict):
                read = .caretBefore(field(o..<o).lowerBound, strict: strict)
            case .between:
                read = landing
            }
            var expectation = Expectation(landing: read, length: length, edge: side, blame: blame, selectedText: selectedText)
            expectation.within = within.map(field)
            expectation.longest = expectation.within?.count
            expectation.keeps = keeps
            return expectation
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
            if reshapes, !replacement.contains("\n"), let before, let after = model {
                let caret = range.lowerBound + replacement.utf16.count
                if before.touchesEmptyLine(range) || after.touchesEmptyLine(range.lowerBound..<caret) {
                    unknown.formUnion([.length, .edge])
                }
            }
            if let current = breaks {
                // Deleting a plain line into a list item leaves the item; otherwise the first line keeps its own.
                let ownRuns = current.hidden.filter { $0.at == range.lowerBound && $0.isStructure }
                let plainLine = replacement.isEmpty && ownRuns.isEmpty && before?.lineStart(of: range.lowerBound) == range.lowerBound
                let ownMarker = ownRuns.contains { !$0.text.isEmpty }
                let coversMarker = current.hidden.contains { range.lowerBound < $0.at && $0.at <= range.upperBound && $0.isMarker }
                breaks = current.replacing(range, with: replacement, keepingCovered: plainLine)
                // A typed `\n` may have made a paragraph or a line break.
                if replacement.contains("\n") { unknown.formUnion([.selection, .edge]) }
                // An item made or merged gains or loses `AXValue` lines, and its list renumbers.
                if current.hidden.contains(where: { !$0.isGap }), replacement.contains("\n") || current.covers(range) {
                    unknown.insert(.length)
                }
                if coversMarker, !plainLine, !ownMarker { unknown.formUnion([.selection, .edge]) }
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
        blame: Expectation.Blame? = nil, selectedText: String? = nil, route: Route? = nil
    ) -> [PhysicalStep] {
        guard profile.has(.readCaret), let selection = context.selection else { return [] }
        var expectation = context.expectation(.exact(selection), blame: blame, selectedText: selectedText, profile: profile)
        expectation.route = route
        return [hard ? .settle(expectation) : .softSettle(expectation)]
    }

    /// Chromium lands a write at a boundary on the next paragraph, so paragraph ends are reached by keys.
    static func write(_ range: Range<Int>, from current: Int? = nil, context: Context) -> [PhysicalStep] {
        if context.folded, let model = context.model {
            return foldedWrite(range, from: current, model: model, context: context)
        }
        let field = context.written(range)
        if !range.isEmpty, landsPast(range.lowerBound, context: context), let model = context.model {
            return [
                .setSelection(field.lowerBound..<field.lowerBound),
                .press(.left, count: 1),
                .press(.selectRight, count: model.graphemes(in: range)),
            ]
        }
        let step = PhysicalStep.setSelection(field)
        guard landsPast(range.upperBound, context: context) else { return [step] }
        return [step] + back(range.isEmpty, context: context)
    }

    /// A paragraph's end, whose write lands on the next paragraph, unless the `<br>` after a drawn caret still ends it.
    static func landsPast(_ offset: Int, context: Context) -> Bool {
        context.edge(offset) == .paragraphEnd && context.field(offset..<offset).lowerBound != context.drawnBreak
    }

    /// From the next paragraph's start to this one's end, as a shifted ← and a collapse where a code span can take a plain ←.
    static func back(_ caret: Bool, context: Context) -> [PhysicalStep] {
        guard caret else { return [.press(.selectLeft, count: 1)] }
        return context.arrowsSelect ? [.press(.selectLeft, count: 1), .press(.left, count: 1)] : [.press(.left, count: 1)]
    }

    /// Linear lands a write at a marker, checkbox or chip by where the caret was, so those boundaries are reached by keys (LIN-1652).
    static func foldedWrite(
        _ range: Range<Int>, from current: Int? = nil, model: TextModel, context: Context
    ) -> [PhysicalStep] {
        guard range.isEmpty else {
            let ends = [range.lowerBound, range.upperBound]
            let needsKeys = { (end: Int) in
                context.isAtom(end) || model.lineEnd(of: end) == end
                    || model.lineStart(of: end) == end && !context.plainStart(end, in: model)
            }
            guard ends.contains(where: needsKeys) else { return [.setSelection(context.written(range))] }
            let placed = foldedWrite(range.lowerBound..<range.lowerBound, model: model, context: context)
            // A caret already at the start needs no write that takes arrows after it.
            return (current == range.lowerBound ? keyed(placed, or: [], context: context) : placed)
                + extending(range, model: model, context: context)
        }
        let caret = range.lowerBound
        let field = context.written(range)
        if context.isAtom(caret) {
            // Past the run of chips it starts, since each chip's end is the next one's start.
            var end = caret
            while context.isAtom(end) { end += 1 }
            let written = context.written(caret..<end).upperBound
            return [.setSelection(written..<written), .press(.left, count: end - caret)]
        }
        if context.breaks?.endsBeforeBreak(caret) ?? false {
            return [.setSelection(field.lowerBound - 1..<field.lowerBound - 1)]
        }
        let start = model.lineStart(of: caret)
        let end = model.lineEnd(of: caret)
        if caret == end, caret < model.length, start < caret {
            let inside = model.advance(caret, byGraphemes: -1)
            // A plain → from a code span's start only steps into it.
            return foldedWrite(inside..<inside, model: model, context: context)
                + run(.right, count: 1, selecting: context.arrowsSelect, normalizing: false)
        }
        // A line's start sharing its offset with the line above's end, as a to-do's does, takes a write from below there.
        if context.edge(caret) == .paragraphStart, field.lowerBound > 0, !context.plainStart(caret, in: model) {
            let inside = model.advance(caret, byGraphemes: 1)
            guard inside < end, !context.isAtom(inside) else {
                if context.caret == caret { return [] }
                if let from = context.caret, from < caret { return [.setSelection(field)] }
                // First above it, at a letter no line boundary shares, where no caret Linear draws brings a `<br>`.
                let above = letterAbove(caret, in: model) ?? 0
                return [.setSelection(context.written(above..<above)), .setSelection(field)]
            }
            // A caret written at a code span's end takes no ← or ⇧← next, and a collapse onto its start may stay inside.
            return [.setSelection(context.written(inside..<inside))]
                + run(.left, count: 1, selecting: context.arrowsSelect, normalizing: context.normalizes(caret))
        }
        guard landsPast(caret, context: context) else { return [.setSelection(field)] }
        return [.setSelection(field)] + back(true, context: context)
    }

    /// From a caret at `range`'s start to all of it, by ⇧⌃E over each line's rest it holds whole and ⇧→ elsewhere (LIN-1685).
    static func extending(_ range: Range<Int>, model: TextModel, context: Context) -> [PhysicalStep] {
        guard context.lineEndKey else { return [.press(.selectRight, count: model.graphemes(in: range))] }
        let atoms = context.atoms
        var steps: [PhysicalStep] = []
        func press(_ chord: Chord, _ count: Int) {
            guard count > 0 else { return }
            guard case .press(chord, let earlier)? = steps.last else { return steps.append(.press(chord, count: count)) }
            steps[steps.count - 1] = .press(chord, count: earlier + count)
        }
        var at = range.lowerBound
        while at < range.upperBound {
            let end = model.lineEnd(of: at)
            let stop = min(end, range.upperBound)
            let graphemes = model.graphemes(in: at..<stop)
            // ⇧⌃E stops at a chip (LIN-1652), and over one character saves nothing.
            if stop == end, graphemes > 1, !atoms.contains(where: { (at..<end).contains($0) }) {
                press(Chord.paragraphEnd.shifted, 1)
            } else {
                press(.selectRight, graphemes)
            }
            guard stop < range.upperBound else { break }
            press(.selectRight, 1)
            at = model.advance(stop, byGraphemes: 1)
        }
        return steps
    }

    /// The last letter of the nearest line above `offset`'s with two or more, strictly inside it.
    static func letterAbove(_ offset: Int, in model: TextModel) -> Int? {
        var end = model.lineStart(of: offset) - 1
        while end >= 0 {
            let start = model.lineStart(of: end)
            let last = model.advance(end, byGraphemes: -1)
            if last > start { return last }
            end = start - 1
        }
        return nil
    }

    /// To the caret at `start`, which the context predicts: ← lands a selection's start in every host measured (LIN-1532).
    static func collapse(to start: Int, context: Context, profile: CapabilityProfile) -> [PhysicalStep] {
        let keys = [.press(.left, count: 1)] + (context.normalizes(start) ? outside : [])
        // Settled, so a later AX write cannot overtake the ←; in a write lane `planning` settles before the next write.
        guard profile.has(.writeSelection) else { return keys + settle(context, profile: profile) }
        return keyed(write(start..<start, context: context), or: keys, context: context)
    }

    /// A folded field's write that needs arrows after it gives way to the key lane's `keys` where they press no more (LIN-1685).
    static func keyed(_ written: [PhysicalStep], or keys: [PhysicalStep], context: Context) -> [PhysicalStep] {
        context.folded && presses(written) && pressCount(keys) <= pressCount(written) ? keys : written
    }

    static func presses(_ steps: [PhysicalStep]) -> Bool {
        steps.contains { if case .press = $0 { return true }; return false }
    }

    static func pressCount(_ steps: [PhysicalStep]) -> Int {
        steps.reduce(0) { total, step in
            guard case .press(_, let count) = step else { return total }
            return total + count
        }
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
        // A selection written over a chip collapses past it.
        guard end > gap, gap < model.lineEnd(of: gap), !context.isAtom(gap) else {
            return [.commit(.setCursor(nil))]   // end of line/text: nothing to cover
        }
        context.selection = gap..<end
        return write(gap..<end, from: gap, context: context) + [.commit(.setCursor(gap..<end))]
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
    static func keyPath(from selection: Range<Int>, to: Int, model: TextModel, context: Context) -> [PhysicalStep] {
        let selecting = context.arrowsSelect
        // ← collapses a selection to its start from either end.
        var presses: [PhysicalStep] = selection.isEmpty ? [] : [.press(.left, count: 1)]
        let from = selection.lowerBound
        if !selection.isEmpty, context.normalizes(from) { presses += outside }
        guard from != to else { return presses }
        let fromLine = model.lineStart(of: from)
        let toLine = model.lineStart(of: to)
        if fromLine == toLine {
            let count = model.graphemes(in: min(from, to)..<max(from, to))
            return presses + run(to > from ? .right : .left, count: count, selecting: selecting, normalizing: context.normalizes(to))
        }
        let lines = model.newlineCount(in: min(fromLine, toLine)..<max(fromLine, toLine))
        // ↓ or ↑ across a line that starts right after a list, code block or quote's end stops between the two first.
        let stops = context.gaps.filter { min(fromLine, toLine) < $0 && $0 <= max(fromLine, toLine) }.count
        presses.append(.press(toLine > fromLine ? .down : .up, count: lines + stops))
        presses.append(.press(.lineStart, count: 1))
        if context.normalizes(toLine) { presses += outside }
        let column = model.graphemes(in: toLine..<to)
        if column > 0 {
            presses += run(.right, count: column, selecting: selecting, normalizing: false)
        }
        return presses
    }

    /// `arrows` as presses; a run inside one grapheme presses nothing.
    static func run(_ arrow: Chord, count: Int, selecting: Bool, normalizing: Bool) -> [PhysicalStep] {
        selecting && count > 0 ? counted(arrows(arrow, count: count, selecting: true, normalizing: normalizing))
            : [.press(arrow, count: count)]
    }

    /// `count` arrows, or shifted ones and a collapse no code edge holds up, leftward stepping out of a span it starts.
    static func arrows(_ arrow: Chord, count: Int, selecting: Bool, normalizing: Bool) -> [Chord] {
        guard selecting else { return Array(repeating: arrow, count: count) }
        let run = Array(repeating: arrow.shifted, count: count) + [arrow]
        return arrow == .left && normalizing ? run + [.selectLeft, .right] : run
    }

    /// ⇧← then →, which leaves a caret where it was, outside a code span it starts (LIN-1683).
    static let outside: [PhysicalStep] = [.press(.selectLeft, count: 1), .press(.right, count: 1)]

    /// What goes before ⇧→ or ⇧⌃E from `caret`; at a paragraph's start only ⇧⌃E sticks, and ⌃A or ⇧→ ← lands outside.
    static func outside(before chord: Chord, at caret: Int, context: Context, profile: CapabilityProfile) -> [PhysicalStep]? {
        guard context.arrowsSelect, [.selectRight, Chord.paragraphEnd.shifted].contains(chord) else { return nil }
        guard caret == 0 || context.edge(caret) == .paragraphStart else { return outside }
        guard chord != .selectRight, let model = context.model, model.lineEnd(of: caret) > caret else { return nil }
        return profile.has(.lineStartKey) ? [.press(.paragraphStart, count: 1)]
            : [.press(.selectRight, count: 1), .press(.left, count: 1)]
    }

    /// One press per run of the same chord.
    static func counted(_ chords: [Chord]) -> [PhysicalStep] {
        var steps: [PhysicalStep] = []
        for chord in chords {
            if case .press(chord, let count)? = steps.last {
                steps[steps.count - 1] = .press(chord, count: count + 1)
            } else {
                steps.append(.press(chord, count: 1))
            }
        }
        return steps
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
        let written = profile.has(.writeSelection) ? write(target..<target, context: context) : nil
        let keyed: Lane
        if let written {
            keyed = lineKey(destination, to: target, instead: written, model: model, context: &context, profile: profile)
        } else {
            keyed = nativeMove(destination, to: target, model: model, context: &context, profile: profile).or {
                sameLine(to: target, model: model, context: &context, profile: profile)
            }
        }
        return keyed.or {
            let actuation = written ?? keyPath(from: selection, to: target, model: model, context: context)
            context.selection = target..<target
            context.selectionOpaque = false
            return .steps(actuation + settle(context, profile: profile))
        }
    }

    /// A folded field's write reaches a line's start or end only with arrows after it, where ⌃A or ⌃E may need none (LIN-1685).
    static func lineKey(
        _ destination: LogicalStep.Destination, to target: Int, instead written: [PhysicalStep], model: TextModel,
        context: inout Context, profile: CapabilityProfile
    ) -> Lane {
        switch destination {
        case .motion(.lineStart, _), .motion(.lineEnd, 1): break
        default: return .next
        }
        guard context.folded, presses(written) else { return .next }
        var keyed = context
        guard case .steps(let keys) = nativeMove(destination, to: target, model: model, context: &keyed, profile: profile),
              pressCount(keys) <= pressCount(written) else { return .next }
        context = keyed
        return .steps(keys)
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

    /// Moves by native line and document keys, counting only the column; `next` where lane B counts it all.
    static func nativeMove(
        _ destination: LogicalStep.Destination?, to target: Int, model: TextModel,
        context: inout Context, profile: CapabilityProfile
    ) -> Lane {
        guard let position = context.position else { return .next }
        let line = model.lineStart(of: position)
        let targetLine = model.lineStart(of: target)
        let gaps = context.gaps
        let boxed = context.boxed
        // ⇧→ → crosses a stop, which Dia reads right ~150 ms before → → (LIN-1686); a to-do takes only → →.
        func hops(_ count: Int) -> [[Chord]] {
            let starts = gaps.isEmpty ? [] : lineStarts(after: line, count: count, in: model)
            return starts.map { !gaps.contains($0) ? [.right] : boxed.contains($0) ? [.right, .right] : [.selectRight, .right] }
                + Array(repeating: [.right], count: count - starts.count)
        }
        // The way to the target's line, and for `j`/`k` an optional one to its end; the column is counted from where each lands.
        var way: [KeyGroup]
        var end: (way: [KeyGroup], route: Route)?
        switch destination {
        case .motion(.lineStart, _)?:
            guard profile.has(.lineStartKey) else { return .next }
            way = [([.paragraphStart], .lineStartKey)]
        case .motion(.lineEnd, let count)?:
            guard profile.has(.lineEndKey) else { return .next }
            way = [([.paragraphEnd], .lineEndKey), (hops(count - 1).flatMap { $0 + [.paragraphEnd] }, nil)]
        case .motion(.fileStart, _)?:
            guard profile.has(.documentStartKey) else { return .next }
            way = [([.documentStart], .documentStartKey)]
        case .motion(.fileEnd, _)?:
            guard profile.has(.documentEndKey), profile.has(.lineStartKey) else { return .next }
            way = [([.documentEnd], .documentEndKey), ([.paragraphStart], .lineStartKey)]
        default:
            // `j`/`k` press their key even where the caret stays put, so a settle checks the line they start from.
            var vertical: Direction?
            if case .motion(.line(let direction, _), _)? = destination { vertical = direction }
            guard targetLine != line || vertical != nil else { return .next }
            if targetLine > line || vertical == .down {
                guard profile.has(.lineEndKey) else { return .next }
                let lines = model.newlineCount(in: line..<targetLine)
                let down = hops(lines).enumerated().flatMap { ($0.offset > 0 ? [Chord.paragraphEnd] : []) + $0.element }
                way = [([.paragraphEnd], .lineEndKey), (down, nil)]
                if lines > 0, !context.missed.contains(.lineEnd) {
                    end = ([([.paragraphEnd], .lineEndKey), (down + [.paragraphEnd], nil)], .lineEnd)
                }
            } else {
                guard profile.has(.lineStartKey) else { return .next }
                let lines = model.newlineCount(in: targetLine..<line)
                let up = repeated([.left, .paragraphStart], lines)
                way = [([.paragraphStart], .lineStartKey), (up, nil)]
                // The last ← already lands at the line's end.
                if lines > 0, !context.missed.contains(.lineStart) {
                    end = ([([.paragraphStart], .lineStartKey), (Array(up.dropLast()), nil)], .lineStart)
                }
            }
        }
        let atoms = context.atoms
        let selecting = context.arrowsSelect
        let normalizing = context.normalizes(target)
        // Only the column is counted, in its own settle so the line the field reports decides it.
        func counted(_ way: [KeyGroup]) -> [KeyGroup]? {
            var landing = KeyModel(text: model.text, anchor: position, focus: position, atoms: atoms, gaps: gaps)
            guard way.flatMap(\.chords).allSatisfy({ landing.press($0) }),
                  model.lineStart(of: landing.focus) == targetLine else { return nil }
            let reached = landing.focus
            let column = model.graphemes(in: min(reached, target)..<max(reached, target))
            return way + [(column > 0 ? arrows(target > reached ? .right : .left, count: column, selecting: selecting,
                                               normalizing: normalizing) : [], nil)]
        }
        guard var groups = counted(way) else { return .next }
        var route: Route?
        // From the line's end only where that presses fewer keys, which a walk from the target no longer than them shows.
        let presses = groups.flatMap(\.chords).count
        if let end, model.graphemes(from: target, toLineEnd: true, atMost: presses - end.way.flatMap(\.chords).count - 1) != nil,
           let fromEnd = counted(end.way), fromEnd.flatMap(\.chords).count < presses {
            (groups, route) = (fromEnd, end.route)
        }
        return pressing(groups, to: target..<target, context: &context, profile: profile, route: route)
    }

    /// An optional route: ⌃A or ⌃E, then arrows to a target on the caret's line, where that presses fewer keys than counting.
    static func sameLine(to target: Int, model: TextModel, context: inout Context, profile: CapabilityProfile) -> Lane {
        guard !profile.has(.writeSelection), let position = context.position else { return .next }
        let low = min(position, target), high = max(position, target)
        guard model.newlineCount(in: low..<high) == 0 else { return .next }
        let selecting = context.arrowsSelect
        let normalizing = context.normalizes(target)
        func presses(_ arrow: Chord, _ count: Int) -> Int {
            count > 0 ? count + arrows(arrow, count: 0, selecting: selecting, normalizing: normalizing).count : 0
        }
        let toward: Chord = target > position ? .right : .left
        let counting = presses(toward, model.graphemes(in: low..<high))
            + prefixCount(selecting ? toward.shifted : toward, context: context, profile: profile)
        // The line key and then fewer arrows than counting presses, which bounds the walk from the target.
        let limit = counting - 2
        var best: (key: Chord, route: Route, back: Chord, count: Int)?
        for (key, needs, route, back) in [(Chord.paragraphStart, Capability.lineStartKey, Route.lineStart, Chord.right),
                                          (.paragraphEnd, .lineEndKey, .lineEnd, .left)] {
            guard profile.has(needs), !context.missed.contains(route),
                  let count = model.graphemes(from: target, toLineEnd: back == .left, atMost: limit),
                  presses(back, count) <= limit, best.map({ presses(back, count) < presses($0.back, $0.count) }) ?? true
            else { continue }
            best = (key, route, back, count)
        }
        guard let best else { return .next }
        let run = best.count > 0 ? arrows(best.back, count: best.count, selecting: selecting, normalizing: normalizing) : []
        return pressing([([best.key] + run, nil)], to: target..<target, context: &context, profile: profile, route: best.route)
    }

    /// How many keys `planning` puts before `chord` when it is the plan's first actuation, from the caret the snapshot saw.
    static func prefixCount(_ chord: Chord, context: Context, profile: CapabilityProfile) -> Int {
        guard context.unmoved, let caret = context.caret else { return 0 }
        return outside(before: chord, at: caret, context: context, profile: profile)?.count ?? 0
    }

    /// The starts of the `count` lines after `line`'s, as far as the text goes.
    static func lineStarts(after line: Int, count: Int, in model: TextModel) -> [Int] {
        var starts: [Int] = []
        guard count > 0 else { return starts }
        var end = model.lineEnd(of: line)
        while starts.count < count, end < model.length {
            starts.append(end + 1)
            if starts.count < count { end = model.lineEnd(of: end + 1) }
        }
        return starts
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

    /// Presses the groups from the caret, each then settled, an unblamed one marked for `route`; `next` unless they land on `target`.
    static func pressing(
        _ groups: [KeyGroup], to target: Range<Int>, context original: inout Context, profile: CapabilityProfile,
        route: Route? = nil
    ) -> Lane {
        guard let text = original.text, let position = original.position else { return .next }
        let atoms = Set(groups.compactMap(\.blame))
        guard atoms.allSatisfy(profile.has) else { return .next }
        var context = original
        var steps = collapsing(&context)
        // One model throughout: which end of a selection moves is state the keys build up.
        var model = KeyModel(text: text, anchor: position, focus: position, atoms: original.atoms, gaps: original.gaps)
        for group in groups where !group.chords.isEmpty {
            for chord in group.chords {
                guard model.press(chord) else { return .next }
            }
            steps += keys(group.chords, blaming: group.blame, to: model.selection, context: &context, profile: profile,
                          route: group.blame == nil ? route : nil)
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
        context: inout Context, profile: CapabilityProfile, route: Route? = nil
    ) -> [PhysicalStep] {
        let before = context.selection
        let model = context.model
        context.selection = landing
        context.selectionOpaque = false
        let leavesCaret = chords.allSatisfy { !$0.modifiers.contains(.shift) }
        let blame = atom.flatMap { atom -> Expectation.Blame? in
            guard let before, let model else { return nil }
            let emptyParagraph = before == context.emptyParagraphCaret
            let unmoved = emptyParagraph || mayStayPut(chords, from: before, in: model, atoms: context.atoms, gaps: context.gaps)
                ? [] : [context.field(before)]
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
        return counted(chords) + settle(context, profile: profile, blame: blame, route: route)
    }

    /// Whether the keys may rightly leave the caret where it was: they had nowhere to go from it.
    static func mayStayPut(_ chords: [Chord], from read: Range<Int>, in model: TextModel, atoms: Set<Int>, gaps: Set<Int>) -> Bool {
        guard read.isEmpty else { return true }
        var keys = KeyModel(text: model.text, anchor: read.lowerBound, focus: read.lowerBound, atoms: atoms, gaps: gaps)
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
        return [.press(.left, count: 1)] + (context.normalizes(selection.lowerBound) ? outside : [])
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

    static func appSettle(
        _ landing: Landing, blame: Expectation.Blame?, keeps: Int? = nil, within: Range<Int>? = nil,
        context: Context, profile: CapabilityProfile
    ) -> PhysicalStep {
        .settle(context.expectation(landing, blame: blame, keeps: keeps, within: within, profile: profile))
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

    /// Rejects a selection its keys cannot prove, since vim's words may not be the app's.
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
                let caret = selection.isEmpty ? selection.lowerBound : nil
                return .steps(write(range, from: caret, context: context) + settle(context, profile: profile))
            }
            return lineSelect(range, model: model, context: &context, profile: profile).or {
                let keys = selectKeys(range, from: selection, model: model, context: context)
                context.selection = range
                return .steps(keys.presses + settle(context, profile: profile, route: keys.route))
            }
        }
    }

    /// An optional route: ⇧⌃E or ⇧⌃A from a caret at a range's end on its line, then ⇧ arrows back, where that presses fewer.
    static func lineSelect(_ range: Range<Int>, model: TextModel, context: inout Context, profile: CapabilityProfile) -> Lane {
        guard let caret = context.caret, !range.isEmpty, [range.lowerBound, range.upperBound].contains(caret),
              model.newlineCount(in: range) == 0 else { return .next }
        let forward = caret == range.lowerBound
        let (key, back, needs, route): (Chord, Chord, Capability, Route) = forward
            ? (Chord.paragraphEnd.shifted, .selectLeft, .lineEndKey, .lineEnd)
            : (Chord.paragraphStart.shifted, .selectRight, .lineStartKey, .lineStart)
        let across = model.graphemes(in: range) + prefixCount(forward ? .selectRight : .selectLeft, context: context, profile: profile)
        let limit = across - 2 - prefixCount(key, context: context, profile: profile)
        guard profile.has(needs), !context.missed.contains(route), let count = model.graphemes(
            from: forward ? range.upperBound : range.lowerBound, toLineEnd: forward, atMost: limit
        ) else { return .next }
        return pressing([([key] + Array(repeating: back, count: count), nil)], to: range, context: &context, profile: profile,
                        route: route)
    }

    /// ⇧→ across a range from its start; or, as an optional route, ⇧← across one that ends at the caret on its line.
    static func selectKeys(
        _ range: Range<Int>, from selection: Range<Int>, model: TextModel, context: Context
    ) -> (presses: [PhysicalStep], route: Route?) {
        let count = model.graphemes(in: range)
        if selection.isEmpty, count > 0, selection.lowerBound == range.upperBound, model.newlineCount(in: range) == 0,
           !context.missed.contains(.selectBack) {
            return ([.press(.selectLeft, count: count)], .selectBack)
        }
        return (keyPath(from: selection, to: range.lowerBound, model: model, context: context)
            + (count > 0 ? [.press(.selectRight, count: count)] : []), nil)
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
            let settled = towardStart && context.normalizes(target) ? outside : []
            let keys = [.press(towardStart ? .left : .right, count: 1)] + settled + settle(context, profile: profile)
            guard profile.has(.writeSelection) else { return keys }
            return keyed(write(target..<target, context: context) + settle(context, profile: profile), or: keys, context: context)
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
            let text = model.substring(selection)
            let content = context.content(selection, text)
            var steps = checkSelectedText(text, context: context, profile: profile)
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
            let content = context.content(selection, model.substring(selection))
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
            // Chromium leaves a new empty paragraph out of `AXValue` until it holds text, so later settles stop checking the length.
            if !profile.has(.insertText), context.breaks != nil, replacement.contains("\n") {
                context.unknown.insert(.length)
            }
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
            steps += write(range, from: selection.isEmpty ? selection.lowerBound : nil, context: context)
        } else {
            switch nativeSelect(.lines(count: count, interior: true), range: range,
                                context: &context, profile: profile) {
            case .steps(let keys):
                steps += keys
                settled = true
            case .next:
                steps += keyPath(from: selection, to: range.lowerBound, model: model, context: context)
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
            case .next: steps = keyPath(from: selection, to: target, model: model, context: context)
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
