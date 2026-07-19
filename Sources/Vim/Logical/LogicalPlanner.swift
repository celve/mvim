/// Compiles one completed `RawCommand` against the current `VimState`.
///
/// The planner is **total** — every command yields a plan: unsupported or
/// invalid commands compile to `bell`; prompts in progress, Insert-mode
/// traffic, and stray incompletes compile to the empty plan. It is **pure**
/// — it reads state and never writes it; state changes become effects
/// attached at the physical layer. And it resolves **all** state
/// dependencies: no plan contains an unresolved `;`, `n`, mark, or register
/// read.
///
/// Contract with the interceptor: commands arrive complete (per
/// `RawCommand.isComplete`) with two mode-driven exceptions the interceptor
/// must implement — in Visual mode a bare operator (`d`) is dispatched, it
/// acts on the selection; and `i`/`a` keep buffering, they begin a text
/// object despite parsing as complete mode changes. Stray incompletes
/// reaching the planner compile to the empty plan, never a bell: buffering
/// is the interceptor's contract, and the engine does not punish the user
/// for a harness bug.
public enum LogicalPlanner {
    public static func plan(_ command: RawCommand, state: VimState) -> LogicalPlan {
        let planned: LogicalPlan
        switch state.field.mode {
        case .normal:
            planned = planNormal(
                intent: command.intent,
                count: command.count,
                register: command.register,
                source: command.source,
                state: state
            )
        case .visual(let context):
            planned = planVisual(command, context: context, state: state)
        case .insert, .replace:
            planned = planInsertOrReplace(command)
        }
        return appendingCursorRender(planned, state: state)
    }
}

// MARK: - Cursor rendering

private extension LogicalPlanner {
    /// Normal mode's on-character cursor is part of the mode's semantics:
    /// every plan that ends resident in Normal re-renders it. Empty and
    /// bell-only plans touch nothing — the cursor already on screen stays,
    /// with zero field writes.
    static func appendingCursorRender(_ plan: LogicalPlan, state: VimState) -> LogicalPlan {
        guard !plan.isEmpty, !isBellOnly(plan) else { return plan }
        guard endsInNormalMode(plan, startingFrom: state.field.mode) else { return plan }
        return LogicalPlan(steps: plan.steps + [.renderCursor])
    }

    static func isBellOnly(_ plan: LogicalPlan) -> Bool {
        plan.steps.allSatisfy { step in
            if case .bell = step { return true }
            return false
        }
    }

    /// The last `setMode` wins; a plan without one stays in its starting
    /// residency.
    static func endsInNormalMode(_ plan: LogicalPlan, startingFrom mode: VimState.Mode) -> Bool {
        for step in plan.steps.reversed() {
            if case .setMode(let target) = step {
                if case .normal = target { return true }
                return false
            }
        }
        if case .normal = mode { return true }
        return false
    }
}

// MARK: - Normal mode

private extension LogicalPlanner {
    static func planNormal(
        intent: RawCommand.Intent,
        count: Int?,
        register: Register?,
        source: String,
        state: VimState
    ) -> LogicalPlan {
        let n = count ?? 1
        switch intent {
        case .incomplete:
            return .empty

        case .modeChange(let change):
            return planModeChange(change, state: state)

        case .motion(let motion):
            switch resolveDestination(motion, count: n, state: state) {
            case .value(let destination):
                var steps: [LogicalStep] = [.moveCaret(destination)]
                if let remember = memoryCommit(for: motion) { steps.append(remember) }
                return LogicalPlan(steps: steps)
            case .bell(let reason): return .bell(reason)
            }

        case .search(let search):
            guard search.isSubmitted else { return .empty }
            switch resolveSearch(search, state: state) {
            case .value(let resolved):
                var steps: [LogicalStep] = [.moveCaret(.motion(.search(resolved), count: n))]
                if let remember = memoryCommit(for: .search(search)) { steps.append(remember) }
                return LogicalPlan(steps: steps)
            case .bell(let reason):
                return .bell(reason)
            }

        case .operatorCommand(let operation):
            return planOperator(operation, count: n, register: register, source: source, state: state)

        case .edit(let edit):
            return planEdit(edit, count: n, register: register, source: source, state: state)

        case .history(let action):
            switch action {
            case .undo, .redo: return LogicalPlan(.history(action))
            case .olderTextState, .newerTextState: return .bell(.unsupported(source))
            }

        case .repeat(.lastChange):
            return planDot(count: count, register: register, state: state)

        case .repeat:
            return .bell(.unsupported(source))

        case .mark(.set(let name)):
            return LogicalPlan(.setMark(name))

        case .mark:
            return .bell(.unsupported(source))

        case .commandLine(let line):
            return line.isSubmitted ? .bell(.unsupported(source)) : .empty

        case .macro:
            // Recording and playback need the interceptor's tape payloads.
            return .bell(.unsupported(source))

        case .view, .window, .fold, .custom:
            return .bell(.unsupported(source))
        }
    }

    static func planModeChange(_ change: RawCommand.ModeChange, state: VimState) -> LogicalPlan {
        switch change {
        case .normal:
            return .empty   // Esc in Normal is a no-op

        case .insert(let position):
            return planInsertEntry(position, state: state)

        case .replace:
            return LogicalPlan(.setMode(.replace))

        case .virtualReplace:
            return .bell(.unsupported("gR"))

        case .visual(.character):
            return LogicalPlan(.setMode(.visual(.character)))

        case .visual(.line):
            return LogicalPlan(.setMode(.visual(.line)))

        case .visual(.block):
            return LogicalPlan(.setMode(.visual(.block)))

        case .visual(.previous):
            guard let memory = state.field.lastVisual else { return .bell(.noPriorVisual) }
            return LogicalPlan(.select(.remembered(memory)), .setMode(.visual(memory.kind)))

        case .commandLine:
            return .bell(.unsupported(":"))

        case .ex:
            return .bell(.unsupported("Q"))
        }
    }

    /// Insert entries decompose into caret preludes plus a plain mode set —
    /// the gap-caret convention is what makes `A` and `o` need no special
    /// "append" destination. Counts (`3a`, repeating text on exit) are an
    /// interceptor/effect concern and are ignored here.
    static func planInsertEntry(_ position: RawCommand.InsertPosition, state: VimState) -> LogicalPlan {
        switch position {
        case .beforeCursor:
            return LogicalPlan(.setMode(.insert))

        case .afterCursor:
            return LogicalPlan(.moveCaret(.motion(.character(.right), count: 1)), .setMode(.insert))

        case .firstNonBlank:
            return LogicalPlan(
                .moveCaret(.motion(.lineStart(firstNonBlank: true), count: 1)),
                .setMode(.insert)
            )

        case .endOfLine:
            return LogicalPlan(.moveCaret(.motion(.lineEnd, count: 1)), .setMode(.insert))

        case .newLineBelow:
            return LogicalPlan(
                .moveCaret(.motion(.lineEnd, count: 1)),
                .insertText("\n"),
                .setMode(.insert)
            )

        case .newLineAbove:
            return LogicalPlan(
                .moveCaret(.motion(.lineStart(firstNonBlank: false), count: 1)),
                .insertText("\n"),
                .moveCaret(.motion(.character(.left), count: 1)),
                .setMode(.insert)
            )

        case .lastInsert:
            guard let start = state.field.insertStart else {
                return LogicalPlan(.setMode(.insert))   // vim: gi without memory inserts here
            }
            return LogicalPlan(.moveCaret(.offset(start)), .setMode(.insert))
        }
    }

    static func planOperator(
        _ operation: RawCommand.OperatorCommand,
        count: Int,
        register: Register?,
        source: String,
        state: VimState
    ) -> LogicalPlan {
        let finish: [LogicalStep]
        switch operation.kind {
        case .delete:
            finish = [.deleteSelection(into: register)]
        case .change:
            finish = [.deleteSelection(into: register), .setMode(.insert)]
        case .yank:
            finish = [.yankSelection(into: register), .collapseSelection(.start)]
        case .swapCase:
            finish = [.transformSelection(.toggleCase), .collapseSelection(.start)]
        case .lowercase:
            finish = [.transformSelection(.lowercase), .collapseSelection(.start)]
        case .uppercase:
            finish = [.transformSelection(.uppercase), .collapseSelection(.start)]
        case .shiftRight:
            finish = [.transformSelection(.shiftRight), .collapseSelection(.start)]
        case .shiftLeft:
            finish = [.transformSelection(.shiftLeft), .collapseSelection(.start)]
        case .indent, .filter, .format, .formatKeepCursor, .createFold:
            return .bell(.unsupported(source))
        }

        let isChange = operation.kind == .change
        let total = count * (operation.targetCount ?? 1)   // 2d3w deletes six words

        let target: LogicalStep.SelectionTarget
        var remember: LogicalStep?
        switch operation.target {
        case .pending, .custom:
            return .bell(.unsupported(source))

        case .line:
            target = .lines(count: total, interior: isChange)

        case .textObject(let object):
            target = .textObject(object, count: total)

        case .motion(let motion):
            let effective = isChange ? rewriteForChange(motion) : motion
            switch resolveDestination(effective, count: total, state: state) {
            case .bell(let reason):
                return .bell(reason)
            case .value(let destination):
                if isLinewise(destination) {
                    target = .lineSpan(to: destination, interior: isChange)
                } else {
                    target = .span(to: destination, inclusive: isInclusive(destination))
                }
                remember = memoryCommit(for: motion)
            }
        }

        return LogicalPlan(steps: [.select(target)] + finish + (remember.map { [$0] } ?? []))
    }

    /// `cw`/`cW` act like `ce`/`cE` — the trailing blanks survive the
    /// change. (Vim only applies this with the caret on a non-blank; that
    /// refinement needs text and can move to the physical layer later.)
    static func rewriteForChange(_ motion: Motion) -> Motion {
        if case .word(.forward, false, let bigWord) = motion {
            return .word(.forward, end: true, bigWord: bigWord)
        }
        return motion
    }

    static func planEdit(
        _ edit: RawCommand.Edit,
        count: Int,
        register: Register?,
        source: String,
        state: VimState
    ) -> LogicalPlan {
        switch edit {
        case .deleteCharacter(let direction):
            let side: Direction = direction == .backward ? .left : .right
            return LogicalPlan(
                .select(.span(to: .motion(.character(side), count: count), inclusive: false)),
                .deleteSelection(into: register)
            )

        case .substituteCharacter:
            return LogicalPlan(
                .select(.span(to: .motion(.character(.right), count: count), inclusive: false)),
                .deleteSelection(into: register),
                .setMode(.insert)
            )

        case .substituteLine:
            return LogicalPlan(
                .select(.lines(count: count, interior: true)),
                .deleteSelection(into: register),
                .setMode(.insert)
            )

        case .changeToLineEnd:
            return LogicalPlan(
                .select(.toLineEnd),
                .deleteSelection(into: register),
                .setMode(.insert)
            )

        case .deleteToLineEnd:
            return LogicalPlan(.select(.toLineEnd), .deleteSelection(into: register))

        case .yankLine:
            return LogicalPlan(
                .select(.lines(count: count, interior: false)),
                .yankSelection(into: register),
                .collapseSelection(.start)
            )

        case .replaceCharacter(let replacement):
            guard replacement != "\u{1B}" else { return .empty }   // r<Esc> cancels
            return LogicalPlan(
                .select(.span(to: .motion(.character(.right), count: count), inclusive: false)),
                .replaceSelection(String(repeating: String(replacement), count: count))
            )

        case .joinLines(let keepWhitespace):
            // 1J and 2J both join two lines.
            return LogicalPlan(.joinLines(count: max(2, count), keepWhitespace: keepWhitespace))

        case .put(let action):
            return planPut(action, count: count, register: register, state: state)

        case .toggleCase:
            return LogicalPlan(
                .select(.span(to: .motion(.character(.right), count: count), inclusive: false)),
                .transformSelection(.toggleCase),
                .collapseSelection(.end)
            )

        case .increment, .decrement:
            return .bell(.unsupported(source))
        }
    }

    static func planPut(_ action: PutAction, count: Int, register: Register?, state: VimState) -> LogicalPlan {
        let name = register?.name ?? "\""
        switch name {
        case "+", "*":
            return LogicalPlan(.put(.pasteboard, action, count: count))
        case "_":
            return .empty   // the black hole puts nothing
        default:
            guard let content = state.session.register(name) else {
                return .bell(.emptyRegister(name))
            }
            return LogicalPlan(.put(.content(content), action, count: count))
        }
    }

    static func planDot(count: Int?, register: Register?, state: VimState) -> LogicalPlan {
        guard let change = state.session.lastChange else { return .bell(.noPriorChange) }
        let replay = RawCommand(change.body)
        // Bodies carrying an Insert payload ("ciwhello<Esc>") do not parse
        // as one command; they arrive with the interceptor's replay work.
        guard replay.isComplete else { return .bell(.unsupported(".")) }
        if case .repeat = replay.intent { return .bell(.unsupported(".")) }
        return planNormal(
            intent: replay.intent,
            count: count ?? change.count ?? replay.count,
            register: register ?? change.register ?? replay.register,
            source: change.body,
            state: state
        )
    }
}

// MARK: - Visual mode

private extension LogicalPlanner {
    static func planVisual(_ command: RawCommand, context: VimState.VisualContext, state: VimState) -> LogicalPlan {
        let n = command.effectiveCount
        switch command.intent {
        case .motion(let motion):
            switch resolveDestination(motion, count: n, state: state) {
            case .value(let destination):
                var steps: [LogicalStep] = [.extendSelection(destination)]
                if let remember = memoryCommit(for: motion) { steps.append(remember) }
                return LogicalPlan(steps: steps)
            case .bell(let reason): return .bell(reason)
            }

        case .search(let search):
            guard search.isSubmitted else { return .empty }
            switch resolveSearch(search, state: state) {
            case .value(let resolved):
                var steps: [LogicalStep] = [.extendSelection(.motion(.search(resolved), count: n))]
                if let remember = memoryCommit(for: .search(search)) { steps.append(remember) }
                return LogicalPlan(steps: steps)
            case .bell(let reason):
                return .bell(reason)
            }

        // A bare operator is syntactically incomplete but semantically
        // complete here: it acts on the selection.
        case .incomplete(.operatorTarget(let kind)):
            return planVisualOperator(kind, register: command.register, source: command.source)

        case .incomplete:
            return .empty

        case .modeChange(.normal):
            return LogicalPlan(.collapseSelection(.head), .setMode(.normal))

        case .modeChange(.visual(.previous)):
            return .empty

        case .modeChange(.visual(let selection)):
            let kind: VisualKind = selection == .line ? .line : (selection == .block ? .block : .character)
            if kind == context.kind {
                // Re-pressing the current kind exits Visual.
                return LogicalPlan(.collapseSelection(.head), .setMode(.normal))
            }
            return LogicalPlan(.setMode(.visual(kind)))

        case .modeChange(.insert(.newLineBelow)):
            return LogicalPlan(.swapSelectionEnds)   // `o` swaps the ends here

        case .modeChange:
            // `i`/`a` begin a text object in Visual — the interceptor keeps
            // buffering; anything else stray is ignored.
            return .empty

        case .edit(.deleteCharacter):
            return planVisualOperator(.delete, register: command.register, source: command.source)

        case .edit(.substituteCharacter):
            return planVisualOperator(.change, register: command.register, source: command.source)

        case .edit(.yankLine):
            return planVisualOperator(.yank, register: command.register, source: command.source)

        case .edit(.toggleCase):
            return planVisualOperator(.swapCase, register: command.register, source: command.source)

        case .history(.undo):
            return planVisualOperator(.lowercase, register: nil, source: command.source)   // visual u

        case .custom(let keys):
            if keys == "U" {
                return planVisualOperator(.uppercase, register: nil, source: keys)   // visual U
            }
            if let object = TextObject(keys: keys) {
                return LogicalPlan(.select(.textObject(object, count: n)))
            }
            return .bell(.unsupported(keys))

        default:
            return .bell(.unsupported(command.source))
        }
    }

    static func planVisualOperator(_ kind: RawCommand.OperatorKind, register: Register?, source: String) -> LogicalPlan {
        switch kind {
        case .delete:
            return LogicalPlan(.deleteSelection(into: register), .setMode(.normal))
        case .change:
            return LogicalPlan(.deleteSelection(into: register), .setMode(.insert))
        case .yank:
            return LogicalPlan(
                .yankSelection(into: register),
                .collapseSelection(.start),
                .setMode(.normal)
            )
        case .swapCase:
            return LogicalPlan(
                .transformSelection(.toggleCase),
                .collapseSelection(.start),
                .setMode(.normal)
            )
        case .lowercase:
            return LogicalPlan(
                .transformSelection(.lowercase),
                .collapseSelection(.start),
                .setMode(.normal)
            )
        case .uppercase:
            return LogicalPlan(
                .transformSelection(.uppercase),
                .collapseSelection(.start),
                .setMode(.normal)
            )
        case .shiftRight:
            return LogicalPlan(
                .transformSelection(.shiftRight),
                .collapseSelection(.start),
                .setMode(.normal)
            )
        case .shiftLeft:
            return LogicalPlan(
                .transformSelection(.shiftLeft),
                .collapseSelection(.start),
                .setMode(.normal)
            )
        case .indent, .filter, .format, .formatKeepCursor, .createFold:
            return .bell(.unsupported(source))
        }
    }
}

// MARK: - Insert and Replace modes

private extension LogicalPlanner {
    /// Insert traffic belongs to the app; only Esc concerns the engine. The
    /// insert-session commits (lastInsert, mark `^`, the dot body) are
    /// effects and arrive with the physical layer.
    static func planInsertOrReplace(_ command: RawCommand) -> LogicalPlan {
        if case .modeChange(.normal) = command.intent {
            // Vim nudges the caret one left on exit (clamped at line start —
            // physical arithmetic).
            return LogicalPlan(.moveCaret(.motion(.character(.left), count: 1)), .setMode(.normal))
        }
        return .empty
    }
}

// MARK: - State resolution

private extension LogicalPlanner {
    enum Resolution<Value> {
        case value(Value)
        case bell(LogicalStep.BellReason)
    }

    static func resolveDestination(_ motion: Motion, count: Int, state: VimState) -> Resolution<LogicalStep.Destination> {
        switch motion {
        case .repeatFind(let oppositeDirection):
            guard let find = state.session.lastFind else { return .bell(.noPriorFind) }
            let direction = oppositeDirection ? flip(find.direction) : find.direction
            return .value(.motion(
                .find(character: find.character, direction: direction, beforeCharacter: find.beforeCharacter),
                count: count
            ))

        case .search(let search):
            switch resolveSearch(search, state: state) {
            case .value(let resolved): return .value(.motion(.search(resolved), count: count))
            case .bell(let reason): return .bell(reason)
            }

        case .mark(let name, let lineWise):
            guard let point = state.field.marks[name] else { return .bell(.unsetMark(name)) }
            return .value(.mark(point, lineWise: lineWise))

        default:
            return .value(.motion(motion, count: count))
        }
    }

    /// `n`/`N` repeat *relative to the original direction*: after `?foo`,
    /// `n` keeps going backward and `N` flips forward.
    static func resolveSearch(_ search: Search, state: VimState) -> Resolution<Search> {
        if search.wordUnderCursor != nil { return .value(search) }   // physical extracts the word
        if let pattern = search.pattern, !pattern.isEmpty { return .value(search) }
        guard let last = state.session.lastSearch else { return .bell(.noPriorSearch) }
        let direction = search.direction == .forward ? last.direction : flip(last.direction)
        return .value(Search(direction: direction, pattern: last.pattern, isSubmitted: true))
    }

    static func flip(_ direction: Direction) -> Direction {
        direction == .forward ? .backward : .forward
    }

    /// Motions that write session memory when *typed*: `f`/`F`/`t`/`T` set
    /// the find memory, a pattern search sets the search memory. Called with
    /// the raw motion, so resolved repeats (`;`, `,`, `n`, `N`) — which
    /// arrive here as `.repeatFind` or a patternless `.search` — never
    /// re-commit, and `,` can never store its flipped direction.
    static func memoryCommit(for motion: Motion) -> LogicalStep? {
        switch motion {
        case .find(let character, let direction, let beforeCharacter):
            return .commit(.found(VimState.FindMemory(
                character: character,
                direction: direction,
                beforeCharacter: beforeCharacter
            )))
        case .search(let search):
            guard let pattern = search.pattern, !pattern.isEmpty else { return nil }
            return .commit(.searched(VimState.SearchMemory(pattern: pattern, direction: search.direction)))
        default:
            return nil
        }
    }

    /// Vim's operator lore: which motions make an operator act linewise.
    static func isLinewise(_ destination: LogicalStep.Destination) -> Bool {
        switch destination {
        case .mark(_, let lineWise):
            return lineWise
        case .offset:
            return false
        case .motion(let motion, _):
            switch motion {
            case .line, .fileStart, .fileEnd, .screenLine: return true
            default: return false
            }
        }
    }

    /// Which motions cover their endpoint when used as an operator target.
    static func isInclusive(_ destination: LogicalStep.Destination) -> Bool {
        switch destination {
        case .mark, .offset:
            return false
        case .motion(let motion, _):
            switch motion {
            case .word(_, true, _), .find, .matchingItem, .lineEnd, .lastNonBlank:
                return true
            default:
                return false
            }
        }
    }
}
