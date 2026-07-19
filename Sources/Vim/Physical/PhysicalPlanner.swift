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
    public static func plan(_ logical: LogicalPlan, snapshot: FieldSnapshot) -> PhysicalPlan {
        let profile = snapshot.capabilities
        var context = Context(snapshot: snapshot)
        var steps: [PhysicalStep] = []
        // The field shows our block cursor: physically collapse it to its
        // gap before the plan acts, so no step ever operates on the
        // presentation selection. Empty and bell-only plans skip this —
        // they touch nothing and the cursor stays up.
        if let gap = context.cursorCollapse, !logical.steps.isEmpty, !isBellOnly(logical) {
            steps.append(.setSelection(gap..<gap))
        }
        for step in logical.steps {
            guard let lowered = lower(step, context: &context, profile: profile) else {
                return .rejected
            }
            steps.append(contentsOf: lowered)
        }
        return PhysicalPlan(steps: steps)
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

        init(snapshot: FieldSnapshot) {
            text = snapshot.text
            selection = snapshot.selection
            anchor = snapshot.anchor
            if let cursor = snapshot.cursor, !cursor.isEmpty, cursor == snapshot.selection {
                // The engine plans from the collapsed gap, not the block.
                let gap = cursor.lowerBound
                selection = gap..<gap
                cursorCollapse = gap
            }
        }

        var model: TextModel? { text.map(TextModel.init) }
        var position: Int? { selection?.lowerBound }
        var caret: Int? { selection.flatMap { $0.isEmpty ? $0.lowerBound : nil } }

        mutating func takeSlot() -> CaptureSlot {
            defer { nextSlot += 1 }
            return CaptureSlot(id: nextSlot)
        }

        /// Apply a predicted edit: text surgery, caret after the replacement.
        mutating func applyEdit(range: Range<Int>, replacement: String) {
            text = model?.replacing(range, with: replacement)
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
    static func settle(_ context: Context, profile: CapabilityProfile) -> [PhysicalStep] {
        guard profile.has(.readCaret), let selection = context.selection else { return [] }
        let length = profile.has(.readLength) ? context.text.map { $0.utf16.count } : nil
        return [.settle(Expectation(selection: selection, length: length))]
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

    /// Best-effort by design: a cursor that cannot be drawn is a bare
    /// caret, never a bell. No settle — cosmetic divergence must not abort
    /// the plan.
    static func lowerRenderCursor(context: inout Context, profile: CapabilityProfile) -> [PhysicalStep]? {
        guard profile.has(.writeSelection),
              let model = context.model,
              let gap = context.caret else {
            return [.commit(.setCursor(nil))]
        }
        let end = model.advance(gap, byGraphemes: 1)
        guard end > gap, gap < model.lineEnd(of: gap) else {
            return [.commit(.setCursor(nil))]   // end of line/text: nothing to cover
        }
        context.selection = gap..<end
        return [.setSelection(gap..<end), .commit(.setCursor(gap..<end))]
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
    static func keyPath(from: Int, to: Int, model: TextModel) -> [PhysicalStep] {
        guard from != to else { return [] }
        let fromLine = model.lineStart(of: from)
        let toLine = model.lineStart(of: to)
        if fromLine == toLine {
            let count = model.graphemes(in: min(from, to)..<max(from, to))
            return [.press(to > from ? .right : .left, count: count)]
        }
        var presses: [PhysicalStep] = []
        let lines = model.newlineCount(in: min(fromLine, toLine)..<max(fromLine, toLine))
        presses.append(.press(toLine > fromLine ? .down : .up, count: lines))
        presses.append(.press(.lineStart, count: 1))
        let column = model.graphemes(in: toLine..<to)
        if column > 0 {
            presses.append(.press(.right, count: column))
        }
        return presses
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
        if let model = context.model, let position = context.position {
            guard let target = resolve(destination, model: model, from: position) else { return nil }
            let actuation: [PhysicalStep]
            if profile.has(.writeSelection) {
                actuation = [.setSelection(target..<target)]
            } else {
                actuation = keyPath(from: position, to: target, model: model)
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
        case .current:
            return []   // whatever is on screen is the operand
        case .lineSpan, .remembered:
            return nil
        }
    }

    static func lowerSelect(
        _ target: LogicalStep.SelectionTarget,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        if let model = context.model, let position = context.position {
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
                return [.setSelection(range)] + settle(context, profile: profile)
            }
            var presses = keyPath(from: position, to: range.lowerBound, model: model)
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
        guard profile.has(.writeSelection),
              let model = context.model,
              let selection = context.selection,
              let anchor = context.anchor else { return nil }
        let head = selection.lowerBound == anchor ? selection.upperBound : selection.lowerBound
        guard let target = resolve(destination, model: model, from: head) else { return nil }
        let range = min(anchor, target)..<max(anchor, target)
        context.selection = range
        return [.setSelection(range)] + settle(context, profile: profile)
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
                return [.setSelection(target..<target)] + settle(context, profile: profile)
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
            var steps: [PhysicalStep] = profile.has(.insertText)
                ? [.replaceSelection("")]
                : [.press(.deleteBack, count: 1)]
            context.applyEdit(range: selection, replacement: "")
            steps += settle(context, profile: profile)
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
        let slot = context.takeSlot()
        return [
            .clipboardCapture(into: slot, cutting: true),
            .commit(.deleted(into: register, content: .captured(slot), wise: wise)),
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
        let slot = context.takeSlot()
        let capture: PhysicalStep = profile.has(.readSelectedText)
            ? .captureSelectedText(into: slot)
            : .clipboardCapture(into: slot, cutting: false)
        return [capture, .commit(.yanked(into: register, content: .captured(slot), wise: wise))]
    }

    /// `insertText` and `replaceSelection` are the same lowering: AX
    /// replacement replaces whatever is selected, and a caret is an empty
    /// selection; typed text replaces a selection too.
    static func lowerTypeOver(
        _ replacement: String,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        let action: PhysicalStep = profile.has(.insertText)
            ? .replaceSelection(replacement)
            : .typeText(replacement)
        if let selection = context.selection, context.text != nil {
            context.applyEdit(range: selection, replacement: replacement)
            return [action] + settle(context, profile: profile)
        }
        context.invalidate()
        return [action]
    }

    static func lowerTransform(
        _ transform: LogicalStep.SelectionTransform,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep]? {
        guard let model = context.model, let selection = context.selection, !selection.isEmpty else {
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
        context.applyEdit(range: selection, replacement: transformed)
        return [action] + settle(context, profile: profile)
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
        guard let model = context.model, let position = context.position else { return nil }
        let range = model.lines(from: position, count: count, includingTerminator: false)
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
            steps.append(.setSelection(range))
        } else {
            steps += keyPath(from: position, to: range.lowerBound, model: model)
            steps.append(.press(.selectRight, count: model.graphemes(in: range)))
        }
        context.selection = range
        steps.append(profile.has(.insertText) ? .replaceSelection(joined) : .typeText(joined))
        context.applyEdit(range: range, replacement: joined)
        return steps + settle(context, profile: profile)
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
        case .pasteboard:
            var steps: [PhysicalStep] = []
            if action.position == .after {
                steps.append(.press(.right, count: 1))
            }
            steps.append(.clipboardInsert(nil))
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
            var steps = moveSteps(to: target, from: position, context: &context, profile: profile)
            steps += insertSteps(payload, context: &context, profile: profile)
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
        if let model = context.model, let position = context.position {
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
            var steps = moveSteps(to: target, from: position, context: &context, profile: profile)
            steps += insertSteps(insertion, context: &context, profile: profile)
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
        from position: Int,
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep] {
        let steps: [PhysicalStep]
        if profile.has(.writeSelection) {
            steps = [.setSelection(target..<target)]
        } else if let model = context.model {
            steps = keyPath(from: position, to: target, model: model)
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
        context: inout Context,
        profile: CapabilityProfile
    ) -> [PhysicalStep] {
        let action: PhysicalStep = profile.has(.insertText)
            ? .replaceSelection(text)
            : .clipboardInsert(text)
        if let selection = context.selection, context.text != nil {
            context.applyEdit(range: selection, replacement: text)
            return [action] + settle(context, profile: profile)
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
