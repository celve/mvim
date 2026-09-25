private func expect(
    _ source: String,
    _ expected: RawCommand.Intent,
    file: StaticString = #file,
    line: UInt = #line
) {
    let command = RawCommand(source)
    precondition(command.intent == expected, "Unexpected intent for \(source): \(command.intent)", file: file, line: line)
}

expect("i", .modeChange(.insert(.beforeCursor)))
expect("V", .modeChange(.visual(.line)))
expect("w", .motion(.word(.forward, end: false, bigWord: false)))
expect("<Left>", .motion(.character(.left)))
expect("dd", .operatorCommand(.init(kind: .delete, target: .line)))
expect("g~~", .operatorCommand(.init(kind: .swapCase, target: .line)))
expect("g~g~", .operatorCommand(.init(kind: .swapCase, target: .line)))
expect("gUgU", .operatorCommand(.init(kind: .uppercase, target: .line)))
expect("guu", .operatorCommand(.init(kind: .lowercase, target: .line)))
expect(
    "diw",
    .operatorCommand(.init(
        kind: .delete,
        target: .textObject(.init(scope: .inner, kind: .word(bigWord: false)))
    ))
)
expect(
    "zf}",
    .operatorCommand(.init(
        kind: .createFold,
        target: .motion(.paragraph(.forward))
    ))
)
expect("/needle<CR>", .search(.init(direction: .forward, pattern: "needle", isSubmitted: true)))
expect(":write<CR>", .commandLine(.init(command: "write", isSubmitted: true)))
expect("r", .incomplete(.characterArgument(prefix: "r")))
expect("df", .incomplete(.operatorTarget(.delete)))
expect("@:", .repeat(.lastExCommand))
expect("z=", .custom(keys: "z="))
expect("<Plug>(Surround)", .custom(keys: "<Plug>(Surround)"))

let counted = RawCommand("\"a2d3w")
precondition(counted.register == .init("a"))
precondition(counted.count == 2)
precondition(
    counted.intent == .operatorCommand(.init(
        kind: .delete,
        targetCount: 3,
        target: .motion(.word(.forward, end: false, bigWord: false))
    ))
)

let interleaved = RawCommand("2\"a3dd")
precondition(interleaved.register == .init("a"))
precondition(interleaved.count == 6)
precondition(interleaved.intent == .operatorCommand(.init(kind: .delete, target: .line)))

// MARK: - VimState

var state = VimState.initial
precondition(state.field.mode == .normal)
precondition(state.session.register("\"") == nil)
precondition(state.session.register("a") == nil)

state.session.registers.named["a"] = RegisterContent(text: "hello", wise: .character)
precondition(state.session.register("a") == .content(RegisterContent(text: "hello", wise: .character)))
precondition(state.session.register("A") == .content(RegisterContent(text: "hello", wise: .character)))

state.session.registers.numbered[1] = RegisterContent(text: "line\n", wise: .line)
precondition(state.session.register("1") == .content(RegisterContent(text: "line\n", wise: .line)))
precondition(state.session.register("2") == nil)

state.session.lastSearch = VimState.SearchMemory(pattern: "needle", direction: .forward)
precondition(state.session.register("/") == .content(RegisterContent(text: "needle", wise: .character)))

state.session.lastInsert = "typed"
precondition(state.session.register(".") == .content(RegisterContent(text: "typed", wise: .character)))
precondition(state.session.register("_") == nil)
precondition(state.session.register("+") == nil)

state.field.mode = .visual(VimState.VisualContext(kind: .line, anchor: 4))
if case .visual(let context) = state.field.mode {
    precondition(context.kind == .line)
    precondition(context.anchor == 4)
} else {
    preconditionFailure("expected visual mode")
}

// Focus moved: field state resets, session memory survives.
state.field = VimState.Field()
precondition(state.field.mode == .normal)
precondition(state.session.register("a") != nil)

// MARK: - LogicalPlanner

func plan(_ source: String, state: VimState = .initial) -> LogicalPlan {
    LogicalPlanner.plan(RawCommand(source), state: state)
}

// ciw: select the word, delete it, enter Insert.
precondition(plan("ciw").steps == [
    .select(.textObject(TextObject(scope: .inner, kind: .word(bigWord: false)), count: 1)),
    .deleteSelection(into: nil),
    .setMode(.insert)
])

// dd takes whole lines; cc keeps the line it empties.
precondition(plan("dd").steps == [
    .select(.lines(count: 1, interior: false)),
    .deleteSelection(into: nil),
    .renderCursor
])
precondition(plan("cc").steps == [
    .select(.lines(count: 1, interior: true)),
    .deleteSelection(into: nil),
    .setMode(.insert)
])

// Counts multiply across operator and target; registers ride through.
precondition(plan("\"a2d3w").steps == [
    .select(.span(to: .motion(.word(.forward, end: false, bigWord: false), count: 6), inclusive: false)),
    .deleteSelection(into: Register("a")),
    .renderCursor
])

// Motion lore: dw exclusive, de inclusive, dj linewise, cw rewrites to ce.
precondition(plan("de").steps.first ==
    .select(.span(to: .motion(.word(.forward, end: true, bigWord: false), count: 1), inclusive: true)))
precondition(plan("dj").steps.first ==
    .select(.lineSpan(to: .motion(.line(.down, firstNonBlank: false), count: 1), interior: false)))
precondition(plan("cw").steps.first ==
    .select(.span(to: .motion(.word(.forward, end: true, bigWord: false), count: 1), inclusive: true)))

// Edits and insert entries decompose into primitives.
precondition(plan("3x").steps == [
    .select(.span(to: .motion(.character(.right), count: 3), inclusive: false)),
    .deleteSelection(into: nil),
    .renderCursor
])
precondition(plan("A").steps == [.moveCaret(.motion(.lineEnd, count: 1)), .setMode(.insert)])
precondition(plan("o").steps == [
    .moveCaret(.motion(.lineEnd, count: 1)),
    .insertText("\n"),
    .setMode(.insert)
])
precondition(plan("d").steps.isEmpty)   // incomplete: interceptor keeps buffering

// State resolution: memory-dependent commands resolve or ring.
precondition(plan("n").steps == [.bell(.noPriorSearch)])
var planning = VimState.initial
planning.session.lastSearch = VimState.SearchMemory(pattern: "needle", direction: .backward)
precondition(plan("n", state: planning).steps == [
    .moveCaret(.motion(.search(Search(direction: .backward, pattern: "needle", isSubmitted: true)), count: 1)),
    .renderCursor
])
precondition(plan(";").steps == [.bell(.noPriorFind)])
planning.session.lastFind = VimState.FindMemory(character: "x", direction: .forward, beforeCharacter: false)
precondition(plan(",", state: planning).steps == [
    .moveCaret(.motion(.find(character: "x", direction: .backward, beforeCharacter: false), count: 1)),
    .renderCursor
])
precondition(plan("'m").steps == [.bell(.unsetMark("m"))])

// Put resolves register content at plan time.
precondition(plan("p").steps == [.bell(.emptyRegister("\""))])
planning.session.registers.unnamed = .content(RegisterContent(text: "howdy", wise: .character))
precondition(plan("p", state: planning).steps == [
    .put(.content(RegisterContent(text: "howdy", wise: .character)), PutAction(position: .after), count: 1),
    .renderCursor
])

// A pasteboard marker puts via ⌘V; its wise rides the logical step.
var markedPlanning = VimState.initial
markedPlanning.session.registers.unnamed = .pasteboard(wise: .line)
precondition(plan("p", state: markedPlanning).steps == [
    .put(.pasteboard(wise: .line), PutAction(position: .after), count: 1),
    .renderCursor
])
precondition(plan("\"+p", state: markedPlanning).steps == [
    .put(.pasteboard(wise: .character), PutAction(position: .after), count: 1),
    .renderCursor
])

// Dot recompiles the stored change; its count overrides wholesale.
precondition(plan(".").steps == [.bell(.noPriorChange)])
planning.session.lastChange = VimState.ChangeMemory(body: "x", count: 2)
precondition(plan(".", state: planning).steps == [
    .select(.span(to: .motion(.character(.right), count: 2), inclusive: false)),
    .deleteSelection(into: nil),
    .renderCursor
])
precondition(plan("3.", state: planning).steps.first ==
    .select(.span(to: .motion(.character(.right), count: 3), inclusive: false)))

var dotted = VimState.initial
dotted.session.lastChange = VimState.ChangeMemory(body: "ciw", insert: "bye")
precondition(plan(".", state: dotted).steps == [
    .select(.textObject(TextObject(scope: .inner, kind: .word(bigWord: false)), count: 1)),
    .deleteSelection(into: nil),
    .setMode(.insert),
    .insertText("bye"),
    .moveCaret(.motion(.character(.left), count: 1)),
    .setMode(.normal),
    .renderCursor
])
precondition(plan("3.", state: dotted).steps.first ==
    .select(.textObject(TextObject(scope: .inner, kind: .word(bigWord: false)), count: 3)))
precondition(plan(".", state: dotted).steps.filter { $0 == .insertText("bye") }.count == 1)

dotted.session.lastChange = VimState.ChangeMemory(body: "o", insert: "")
precondition(plan(".", state: dotted).steps == [
    .moveCaret(.motion(.lineEnd, count: 1)),
    .insertText("\n"),
    .setMode(.insert),
    .moveCaret(.motion(.character(.left), count: 1)),
    .setMode(.normal),
    .renderCursor
])

// A replay that rings types nothing.
dotted.session.lastChange = VimState.ChangeMemory(body: "c;", insert: "bye")
precondition(plan(".", state: dotted).steps == [.bell(.noPriorFind)])

dotted.session.lastChange = .unreplayable
precondition(plan(".", state: dotted).steps == [.bell(.unsupported("."))])

// Visual mode: motions extend, bare operators act on the selection,
// text objects keep their spelling, Esc collapses to the head.
var visual = VimState.initial
visual.field.mode = .visual(VimState.VisualContext(kind: .character, anchor: 0))
precondition(plan("w", state: visual).steps == [
    .extendSelection(.motion(.word(.forward, end: false, bigWord: false), count: 1))
])
precondition(plan("d", state: visual).steps == [.deleteSelection(into: nil), .setMode(.normal), .renderCursor])
precondition(plan("iw", state: visual).steps == [
    .select(.textObject(TextObject(scope: .inner, kind: .word(bigWord: false)), count: 1))
])
precondition(plan("<Esc>", state: visual).steps == [.collapseSelection(.head), .setMode(.normal), .renderCursor])

// Insert mode: only Esc concerns the engine.
var inserting = VimState.initial
inserting.field.mode = .insert
precondition(plan("<Esc>", state: inserting).steps == [
    .moveCaret(.motion(.character(.left), count: 1)),
    .setMode(.normal),
    .renderCursor
])
precondition(plan("w", state: inserting).steps.isEmpty)

// Unsupported commands ring with their keys.
precondition(plan("zt").steps == [.bell(.unsupported("zt"))])

// Typed find commands commit memory; repeats never do.
precondition(plan("fx").steps == [
    .moveCaret(.motion(.find(character: "x", direction: .forward, beforeCharacter: false), count: 1)),
    .commit(.found(VimState.FindMemory(character: "x", direction: .forward, beforeCharacter: false))),
    .renderCursor
])

// MARK: - TextModel

let sample = TextModel("say hello world")
precondition(sample.wordForward(from: 0, big: false) == 4)
precondition(sample.wordEnd(from: 4, big: false) == 8)
precondition(sample.wordObject(at: 6, around: false, big: false) == 4..<9)
precondition(sample.wordObject(at: 6, around: true, big: false) == 4..<10)
precondition(sample.findCharacter("w", from: 0, forward: true, before: false, count: 1) == 10)
precondition(TextModel("one\ntwo").verticalMove(from: 1, by: 1, firstNonBlank: false) == 5)
precondition(TextModel("one\ntwo").lines(from: 1, count: 1, includingTerminator: true) == 0..<4)

// MARK: - PhysicalPlanner

let axProfile = CapabilityProfile(available: [
    .readText, .readLength, .readCaret, .readSelectedText, .writeSelection, .insertText,
    .drawCursor, .wholeDocument,
])
let readProfile = CapabilityProfile(available: [
    .readText, .readLength, .readCaret, .readSelectedText, .wholeDocument,
])
let blindProfile = CapabilityProfile(available: [])
/// axProfile minus the standing cursor's permission: writes stay exact,
/// presentation is suppressed.
let noCursorProfile = CapabilityProfile(available: [
    .readText, .readLength, .readCaret, .readSelectedText, .writeSelection, .insertText, .wholeDocument,
])
/// The block-editor shape (Notion): the readable text is one block — exact
/// locally, a lie about the page. Also without drawCursor, mirroring how the
/// two are seeded together.
let blockProfile = CapabilityProfile(available: [
    .readText, .readLength, .readCaret, .readSelectedText, .writeSelection, .insertText,
])
/// The reported ChatGPT config: the user turned OFF Replace text (insertText)
/// only. Selection is still exact (writeSelection), so the SELECT is an AX
/// write (hard settle) and only the DELETE rides the blind lane (soft settle).
let noInsertProfile = CapabilityProfile(available: [
    .readText, .readLength, .readCaret, .readSelectedText, .writeSelection, .wholeDocument,
])

func physical(
    _ keys: String,
    text: String? = nil,
    caret: Int? = nil,
    selection: Range<Int>? = nil,
    profile: CapabilityProfile,
    state: VimState = .initial
) -> PhysicalPlan {
    let logical = LogicalPlanner.plan(RawCommand(keys), state: state)
    let snapshot = FieldSnapshot(capabilities: profile, text: text, selection: selection ?? caret.map { $0..<$0 })
    return PhysicalPlanner.plan(logical, snapshot: snapshot)
}

// ciw in "say hello world" (caret inside "hello") under three profiles.
let ciwA = physical("ciw", text: "say hello world", caret: 6, profile: axProfile)
precondition(ciwA.steps == [
    .setSelection(4..<9),
    .settle(Expectation(selection: 4..<9, length: 15)),
    .replaceSelection(""),
    .settle(Expectation(selection: 4..<4, length: 10)),
    .commit(.deleted(into: nil, content: .literal("hello"), wise: .character)),
    .commit(.setMode(.insert)),
    .commit(.setInsertStart(4)),
])
precondition(ciwA.mutatesText)

let ciwB = physical("ciw", text: "say hello world", caret: 6, profile: readProfile)
precondition(ciwB.steps == [
    .press(.left, count: 2),
    .press(.selectRight, count: 5),
    // Blind SELECT stays a hard settle: if the range mispredicts, aborting is
    // safer than letting the delete hit the wrong text.
    .settle(Expectation(selection: 4..<9, length: 15)),
    .settle(Expectation(selection: 4..<9, length: 15, selectedText: "hello")),
    .press(.deleteBack, count: 1),
    // Blind DELETE is soft: a mismatch here must NOT abort the setMode below —
    // this is the ChatGPT "ciw won't enter insert" bug.
    .softSettle(Expectation(selection: 4..<4, length: 10)),
    .commit(.deleted(into: nil, content: .literal("hello"), wise: .character)),
    .commit(.setMode(.insert)),
    .commit(.setInsertStart(4)),
])

let ciwC = physical("ciw", profile: blindProfile)
precondition(ciwC.steps == [
    .press(.wordLeft, count: 1),
    .press(.selectWordRight, count: 1),
    .clipboardCut,
    .commit(.deleted(into: nil, content: .pasteboard, wise: .character)),
    .commit(.setMode(.insert)),
    .commit(.setInsertStart(nil)),
])
precondition(ciwC.mutatesText)

// The reported bug, pinned. Replace text off but selection still exact: the
// SELECT is an AX write (hard settle — a wrong range must abort before the
// delete), the DELETE is blind (soft settle — its mismatch must NOT abort the
// insert). Before the fix the delete's hard settle failed in ChatGPT and took
// setMode(.insert) down with it.
let ciwNoInsert = physical("ciw", text: "say hello world", caret: 6, profile: noInsertProfile)
precondition(ciwNoInsert.steps == [
    .setSelection(4..<9),
    .settle(Expectation(selection: 4..<9, length: 15)),
    .press(.deleteBack, count: 1),
    .softSettle(Expectation(selection: 4..<4, length: 10)),
    .commit(.deleted(into: nil, content: .literal("hello"), wise: .character)),
    .commit(.setMode(.insert)),
    .commit(.setInsertStart(4)),
])
// The whole point: the plan still reaches insert mode on the blind lane, and
// the only settle that can abort (the AX select) is the one that's safe to.
precondition(ciwNoInsert.steps.last == .commit(.setInsertStart(4)))
precondition(ciwNoInsert.steps.contains(.commit(.setMode(.insert))))
precondition(!ciwNoInsert.steps.contains(.settle(Expectation(selection: 4..<4, length: 10))),
             "the blind delete must be a soft settle, never a hard one")

// `o` opens a line and enters insert on the blind lane too: the typed newline
// is a soft settle, so a mismatch cannot swallow the mode change.
let oNoInsert = physical("o", text: "hello", caret: 0, profile: noInsertProfile)
precondition(oNoInsert.steps.contains(.softSettle(Expectation(selection: 6..<6, length: 6))),
             "blind open-line must soft-settle the typed newline")
precondition(oNoInsert.steps.contains(.commit(.setMode(.insert))))

// Contrast: with insertText the delete is an exact AX write, so it stays a HARD
// settle — the fix touches only the blind lane.
let ciwAX = physical("ciw", text: "say hello world", caret: 6, profile: noCursorProfile)
precondition(ciwAX.steps.contains(.replaceSelection("")))
precondition(ciwAX.steps.contains(.settle(Expectation(selection: 4..<4, length: 10))))
precondition(!ciwAX.steps.contains(.softSettle(Expectation(selection: 4..<4, length: 10))),
             "the AX delete path must remain a hard settle")

// Blind delete IS the cut: fire-and-forget, the register holds a marker.
precondition(physical("dd", profile: blindProfile).steps == [
    .press(.lineStart, count: 1),
    .press(.selectDown, count: 1),
    .clipboardCut,
    .commit(.deleted(into: nil, content: .pasteboard, wise: .line)),
    .commit(.setCursor(nil)),
])

// Blind yank copies without mutating; an AX selected-text read is
// preferred when available (real text beats a marker).
let yyBlind = physical("yy", profile: blindProfile)
precondition(yyBlind.steps == [
    .press(.lineStart, count: 1),
    .press(.selectDown, count: 1),
    .clipboardCopy,
    .commit(.yanked(into: nil, content: .pasteboard, wise: .line)),
    .press(.left, count: 1),
    .commit(.setCursor(nil)),
])
precondition(!yyBlind.mutatesText)
// `readSelectedText` must NOT change this lowering. An AX read here is
// synchronous and would beat the still-queued presses that built the
// selection, capturing it as it was before them — the register would come
// back empty or stale. ⌘C rides the same queue as the presses and sees them.
precondition(physical("yy", profile: CapabilityProfile(available: [.readSelectedText])).steps == [
    .press(.lineStart, count: 1),
    .press(.selectDown, count: 1),
    .clipboardCopy,
    .commit(.yanked(into: nil, content: .pasteboard, wise: .line)),
    .press(.left, count: 1),
    .commit(.setCursor(nil)),
])

// fx moves and commits the find memory; `;` repeats without re-committing.
precondition(physical("fl", text: "say hello", caret: 0, profile: axProfile).steps == [
    .setSelection(6..<6),
    .settle(Expectation(selection: 6..<6, length: 9)),
    .commit(.found(VimState.FindMemory(character: "l", direction: .forward, beforeCharacter: false))),
    .setSelection(6..<7),
    .commit(.setCursor(6..<7)),
])

// drawCursor off (the Notion quirk): actuation identical, presentation
// suppressed — the plan ends by clearing the cursor, never drawing it.
precondition(physical("fl", text: "say hello", caret: 0, profile: noCursorProfile).steps == [
    .setSelection(6..<6),
    .settle(Expectation(selection: 6..<6, length: 9)),
    .commit(.found(VimState.FindMemory(character: "l", direction: .forward, beforeCharacter: false))),
    .commit(.setCursor(nil)),
])
var found = VimState.initial
found.session.lastFind = VimState.FindMemory(character: "l", direction: .forward, beforeCharacter: false)
precondition(physical(";", text: "say hello", caret: 0, profile: axProfile, state: found).steps == [
    .setSelection(6..<6),
    .settle(Expectation(selection: 6..<6, length: 9)),
    .setSelection(6..<7),
    .commit(.setCursor(6..<7)),
])

// dw mutates; w does not; undo is a shortcut, not a change.
precondition(physical("dw", text: "say hello", caret: 0, profile: axProfile).steps == [
    .setSelection(0..<4),
    .settle(Expectation(selection: 0..<4, length: 9)),
    .replaceSelection(""),
    .settle(Expectation(selection: 0..<0, length: 5)),
    .commit(.deleted(into: nil, content: .literal("say "), wise: .character)),
    .setSelection(0..<1),
    .commit(.setCursor(0..<1)),
])
precondition(!physical("w", text: "say hello", caret: 0, profile: axProfile).mutatesText)
precondition(physical("u", text: "say hello", caret: 0, profile: axProfile).steps == [
    .press(.undo, count: 1),
    .commit(.setCursor(nil)),
])
precondition(!physical("u", text: "say hello", caret: 0, profile: axProfile).mutatesText)

// dd takes the terminator and commits linewise.
precondition(physical("dd", text: "one\ntwo", caret: 1, profile: axProfile).steps == [
    .setSelection(0..<4),
    .settle(Expectation(selection: 0..<4, length: 7)),
    .replaceSelection(""),
    .settle(Expectation(selection: 0..<0, length: 3)),
    .commit(.deleted(into: nil, content: .literal("one\n"), wise: .line)),
    .setSelection(0..<1),
    .commit(.setCursor(0..<1)),
])

// p resolves register content at logical time and places it physically.
var putState = VimState.initial
putState.session.registers.unnamed = .content(RegisterContent(text: "XY", wise: .character))
precondition(physical("p", text: "abc", caret: 1, profile: axProfile, state: putState).steps == [
    .setSelection(2..<2),
    .replaceSelection("XY"),
    .settle(Expectation(selection: 4..<4, length: 5)),
    .setSelection(4..<5),
    .commit(.setCursor(4..<5)),
])

// Pasteboard-marker puts: ⌘V in every lane; the wise picks the chords.
var markedPut = VimState.initial
markedPut.session.registers.unnamed = .pasteboard(wise: .line)
precondition(physical("p", profile: blindProfile, state: markedPut).steps == [
    .press(.down, count: 1),
    .press(.lineStart, count: 1),
    .clipboardInsert(nil),
    .commit(.setCursor(nil)),
])
precondition(physical("P", profile: blindProfile, state: markedPut).steps == [
    .press(.lineStart, count: 1),
    .clipboardInsert(nil),
    .commit(.setCursor(nil)),
])
var markedChar = VimState.initial
markedChar.session.registers.unnamed = .pasteboard(wise: .character)
precondition(physical("2p", profile: blindProfile, state: markedChar).steps == [
    .press(.right, count: 1),
    .clipboardInsert(nil),
    .clipboardInsert(nil),
    .commit(.setCursor(nil)),
])
precondition(physical("p", text: "abc", caret: 1, profile: axProfile, state: markedChar).steps == [
    .setSelection(2..<2),
    .clipboardInsert(nil),
    .commit(.setCursor(nil)),
])

// Capability changes feasibility: search and marks reject blind.
precondition(physical("/lo<CR>", profile: blindProfile).steps == [.bell])
precondition(physical("ma", profile: blindProfile).steps == [.bell])
precondition(physical("/lo<CR>", text: "say hello", caret: 0, profile: axProfile).steps == [
    .setSelection(7..<7),
    .settle(Expectation(selection: 7..<7, length: 9)),
    .commit(.searched(VimState.SearchMemory(pattern: "lo", direction: .forward))),
    .setSelection(7..<8),
    .commit(.setCursor(7..<8)),
])

// MARK: - Block-scoped fields (wholeDocument denied)

// The atom's raw value is a cross-module string contract: `CapabilityConfig`
// seeds and `LearnedPriors` key on it by literal, because LoomCore cannot see
// this type. Renaming the case silently orphans the Notion seed, so pin it.
precondition(Capability.wholeDocument.rawValue == "wholeDocument")
precondition(Capability.drawCursor.rawValue == "drawCursor")
// Policy atoms are resolved from a parent mechanism, never probed.
precondition(Capability.wholeDocument.species == .policy)
precondition(Capability.wholeDocument.parent == .readText)
precondition(Capability.drawCursor.species == .policy)
precondition(Capability.drawCursor.parent == .writeSelection)
precondition(Capability.allCases.filter { $0.species == .mechanism }.allSatisfy { $0.parent == nil })
// The ungated policy: nothing about a field can moot whether a focus change
// ends a session, so it answers to seeds and the user alone.
precondition(Capability.fieldIsSession.rawValue == "fieldIsSession")
precondition(Capability.fieldIsSession.species == .policy)
precondition(Capability.fieldIsSession.parent == nil)

// The bug this atom exists for: the model says there is no line below, so
// the exact lane resolves `j` to the offset it started at and executes a
// flawless no-op. Denied document scope, `j` reaches the blind chord that
// crosses blocks natively.
precondition(physical("j", text: "one", caret: 0, profile: blockProfile).steps == [
    .press(.down, count: 1),
    .commit(.setCursor(nil)),
])
precondition(physical("3j", text: "one", caret: 0, profile: blockProfile).steps == [
    .press(.down, count: 3),
    .commit(.setCursor(nil)),
])
precondition(physical("gg", text: "one", caret: 0, profile: blockProfile).steps == [
    .press(.documentStart, count: 1),
    .commit(.setCursor(nil)),
])

// A blind vertical move must never write a selection. The app's own column
// memory is the ONLY thing keeping `j` in the same column across blocks, and
// any AX write between presses would reset it. This has to hold even where
// the block cursor is permitted: after a blind press the predicted caret is
// unknown, so `renderCursor` must decline to draw rather than guess.
let blockDrawProfile = CapabilityProfile(available: [
    .readText, .readLength, .readCaret, .readSelectedText, .writeSelection, .insertText, .drawCursor,
])
for keys in ["j", "k", "3j", "gg", "G"] {
    precondition(!physical(keys, text: "one", caret: 0, profile: blockDrawProfile).steps.contains {
        if case .setSelection = $0 { return true }
        return false
    }, "blind vertical move \(keys) must not write a selection — it would clobber the app's column")
}
// …but ONLY while no cursor is drawn. A drawn cursor must still be collapsed
// before the press — it is a real one-character selection, and ↓ with a
// selection active moves from its far end, one column off from where the user
// sees the caret. So correctness wins and the write goes in.
//
// That makes `drawCursor` and column stability mutually exclusive in a block
// editor: permit the cursor and every `j` re-seeds the app's sticky column
// from the current caret, losing it across a short block. Notion is seeded
// with `drawCursor` off, which resolves the tension in favor of the column —
// by luck rather than design, so this pins the coupling before someone
// "fixes" the seed.
let drawnCursorSnapshot = FieldSnapshot(
    capabilities: blockDrawProfile, text: "one", selection: 1..<2, cursor: 1..<2
)
precondition(PhysicalPlanner.plan(
    LogicalPlanner.plan(RawCommand("j"), state: .initial),
    snapshot: drawnCursorSnapshot
).steps == [
    .setSelection(1..<1),   // the collapse — and the column cost of drawing a cursor
    .press(.down, count: 1),
    .commit(.setCursor(nil)),
])

// The gate is profile-driven, not text-driven: the same single-line text
// under a whole-document profile keeps the exact lane.
precondition(physical("j", text: "one\ntwo", caret: 0, profile: axProfile).steps == [
    .setSelection(4..<4),
    .settle(Expectation(selection: 4..<4, length: 7)),
    .setSelection(4..<5),
    .commit(.setCursor(4..<5)),
])

// THE regression guard. `TextModel` classes `\n` as whitespace, so `w`/`b`/`e`
// technically walk lines — but inside a block they are exact and must keep
// the exact lane. A predicate keyed on "crosses a line" instead of on intent
// would demote these and destroy the word motions that work today.
// noCursorProfile is blockProfile + wholeDocument, so this isolates exactly
// the one variable.
for keys in ["w", "b", "e", "ciw", "daw", "fl", "x", "$", "dd", "cc"] {
    precondition(
        physical(keys, text: "say hello world", caret: 6, profile: blockProfile).steps ==
        physical(keys, text: "say hello world", caret: 6, profile: noCursorProfile).steps,
        "block scope must not disturb line-local command \(keys)"
    )
}

// No blind spelling ⇒ ring, never a silent wrong jump. `J`'s whitespace rules
// are the whole point of the function; `/` cannot search a page it cannot
// read; `gi` carries an absolute offset with no staleness witness, and a
// wrong-block jump followed by Insert is the worst failure available.
precondition(physical("J", text: "one", caret: 0, profile: blockProfile).steps == [.bell])
precondition(physical("/lo<CR>", text: "say hello", caret: 0, profile: blockProfile).steps == [.bell])
var resumed = VimState.initial
resumed.field.insertStart = 2
precondition(physical("gi", text: "one", caret: 0, profile: blockProfile, state: resumed).steps == [.bell])

// Cross-block operators blind-lower rather than silently acting on the wrong
// span. The register degrades to a pasteboard marker — the lane-C bargain.
precondition(physical("dj", text: "one", caret: 0, profile: blockProfile).steps == [
    .press(.lineStart, count: 1),
    .press(.selectDown, count: 2),
    .clipboardCut,
    .commit(.deleted(into: nil, content: .pasteboard, wise: .line)),
    .commit(.setCursor(nil)),
])
precondition(physical("3dd", text: "one", caret: 0, profile: blockProfile).steps == [
    .press(.lineStart, count: 1),
    .press(.selectDown, count: 3),
    .clipboardCut,
    .commit(.deleted(into: nil, content: .pasteboard, wise: .line)),
    .commit(.setCursor(nil)),
])

// Visual extend goes blind too: the app owns the anchor, so the engine's
// stored one is deliberately ignored and the selection becomes opaque.
var blockVisual = VimState.initial
blockVisual.field.mode = .visual(VimState.VisualContext(kind: .character, anchor: 0))
precondition(PhysicalPlanner.plan(
    LogicalPlanner.plan(RawCommand("j"), state: blockVisual),
    snapshot: FieldSnapshot(capabilities: blockProfile, text: "one", selection: 0..<1, anchor: 0)
).steps == [.press(.selectDown, count: 1)])

// A drawn cursor is collapsed before the next command acts.
let cursored = FieldSnapshot(capabilities: axProfile, text: "abc", selection: 0..<1, cursor: 0..<1)
precondition(PhysicalPlanner.plan(
    LogicalPlanner.plan(RawCommand("x"), state: .initial),
    snapshot: cursored
).steps.first == .setSelection(0..<0))

// MARK: - Lane B from a selection

// Dia kept `0..8` here (`e14287.c993`): lane B must collapse a selection before counting.
precondition(physical("<Esc>", text: "abcdefgh", selection: 0..<8, profile: readProfile, state: inserting).steps == [
    .press(.left, count: 1),
    .settle(Expectation(selection: 0..<0, length: 8)),
    .commit(.setMode(.normal)),
    .commit(.setCursor(nil)),
])
precondition(physical("<Esc>", text: "abcdefgh", selection: 3..<8, profile: readProfile, state: inserting).steps == [
    .press(.left, count: 1),
    .press(.left, count: 1),
    .settle(Expectation(selection: 2..<2, length: 8)),
    .commit(.setMode(.normal)),
    .commit(.setCursor(nil)),
])
precondition(physical("<Esc>", text: "ab\ncdefgh", selection: 3..<6, profile: readProfile, state: inserting).steps == [
    .press(.left, count: 1),
    .settle(Expectation(selection: 3..<3, length: 9)),
    .commit(.setMode(.normal)),
    .commit(.setCursor(nil)),
])
precondition(physical("<Esc>", text: "abcdefgh", caret: 0, profile: readProfile, state: inserting).steps == [
    .settle(Expectation(selection: 0..<0, length: 8)),
    .commit(.setMode(.normal)),
    .commit(.setCursor(nil)),
])
precondition(physical("<Esc>", text: "abcdefgh", caret: 8, profile: readProfile, state: inserting).steps == [
    .press(.left, count: 1),
    .settle(Expectation(selection: 7..<7, length: 8)),
    .commit(.setMode(.normal)),
    .commit(.setCursor(nil)),
])
precondition(physical("<Esc>", text: "abcdefgh", selection: 0..<8, profile: axProfile, state: inserting).steps == [
    .setSelection(0..<0),
    .settle(Expectation(selection: 0..<0, length: 8)),
    .commit(.setMode(.normal)),
    .setSelection(0..<1),
    .commit(.setCursor(0..<1)),
])

for (anchor, head, key) in [(0, 8, Chord.right), (8, 0, Chord.left)] {
    var selecting = VimState.initial
    selecting.field.mode = .visual(VimState.VisualContext(kind: .character, anchor: anchor))
    precondition(PhysicalPlanner.plan(
        LogicalPlanner.plan(RawCommand("<Esc>"), state: selecting),
        snapshot: FieldSnapshot(capabilities: readProfile, text: "abcdefgh", selection: 0..<8, anchor: anchor)
    ).steps == [
        .press(key, count: 1),
        .settle(Expectation(selection: head..<head, length: 8)),
        .commit(.setMode(.normal)),
        .commit(.setCursor(nil)),
    ])
}

var stranded = VimState.initial
stranded.session.registers.unnamed = .content(RegisterContent(text: "XY", wise: .character))
for keys in ["h", "l", "a", "x", "ciw", "p", "J"] {
    let steps = physical(keys, text: "say hello\nworld", selection: 5..<9, profile: readProfile, state: stranded).steps
    precondition(steps.first == .press(.left, count: 1), "\(keys) must collapse the selection before counting")
}
precondition(physical("ciw", text: "say hello world", selection: 5..<15, profile: readProfile).steps == [
    .press(.left, count: 1),
    .press(.left, count: 1),
    .press(.selectRight, count: 5),
    .settle(Expectation(selection: 4..<9, length: 15)),
    .settle(Expectation(selection: 4..<9, length: 15, selectedText: "hello")),
    .press(.deleteBack, count: 1),
    .softSettle(Expectation(selection: 4..<4, length: 10)),
    .commit(.deleted(into: nil, content: .literal("hello"), wise: .character)),
    .commit(.setMode(.insert)),
    .commit(.setInsertStart(4)),
])

// Keys settle before an AX write, never before ⌘V.
let insertOnlyProfile = CapabilityProfile(available: [
    .readText, .readLength, .readCaret, .readSelectedText, .insertText, .wholeDocument,
])
precondition(physical("p", text: "say hello\nworld", selection: 5..<9, profile: insertOnlyProfile, state: stranded).steps == [
    .press(.left, count: 1),
    .press(.right, count: 1),
    .settle(Expectation(selection: 6..<6, length: 15)),
    .replaceSelection("XY"),
    .settle(Expectation(selection: 8..<8, length: 17)),
    .commit(.setCursor(nil)),
])
precondition(physical("\"+p", text: "say hello\nworld", selection: 5..<9, profile: insertOnlyProfile).steps == [
    .press(.left, count: 1),
    .press(.right, count: 1),
    .clipboardInsert(nil),
    .commit(.setCursor(nil)),
])
precondition(physical("J", text: "say hello\nworld", selection: 5..<9, profile: insertOnlyProfile).steps == [
    .press(.left, count: 1),
    .press(.left, count: 5),
    .press(.selectRight, count: 15),
    .settle(Expectation(selection: 0..<15, length: 15, selectedText: "say hello\nworld")),
    .replaceSelection("say hello world"),
    .settle(Expectation(selection: 15..<15, length: 15)),
    .commit(.setCursor(nil)),
])
precondition(physical("p", text: "say hello\nworld", selection: 5..<9, profile: readProfile, state: stranded).steps == [
    .press(.left, count: 1),
    .press(.right, count: 1),
    .clipboardInsert("XY"),
    .softSettle(Expectation(selection: 8..<8, length: 17)),
    .commit(.setCursor(nil)),
])

// A re-resolve can drop `writeSelection` while the cursor stays drawn.
precondition(PhysicalPlanner.plan(
    LogicalPlanner.plan(RawCommand("P"), state: stranded),
    snapshot: FieldSnapshot(capabilities: insertOnlyProfile, text: "abc", selection: 1..<2, cursor: 1..<2)
).steps == [
    .press(.left, count: 1),
    .settle(Expectation(selection: 1..<1, length: 3)),
    .replaceSelection("XY"),
    .settle(Expectation(selection: 3..<3, length: 5)),
    .commit(.setCursor(nil)),
])
precondition(PhysicalPlanner.plan(
    LogicalPlanner.plan(RawCommand("x"), state: .initial),
    snapshot: FieldSnapshot(capabilities: readProfile, text: "abc", selection: 1..<2, cursor: 1..<2)
).steps == [
    .press(.left, count: 1),
    .settle(Expectation(selection: 1..<1, length: 3)),
    .press(.selectRight, count: 1),
    .settle(Expectation(selection: 1..<2, length: 3)),
    .settle(Expectation(selection: 1..<2, length: 3, selectedText: "b")),
    .press(.deleteBack, count: 1),
    .softSettle(Expectation(selection: 1..<1, length: 2)),
    .commit(.deleted(into: nil, content: .literal("b"), wise: .character)),
    .commit(.setCursor(nil)),
])

// MARK: - Paragraph breaks (Chromium rich text)

let paras = ParagraphBreaks(value: "ab\ncd\nef", fieldText: "abcdef")!
precondition(paras.offsets == [2, 5])
precondition(paras.fieldOffset(2) == 2 && paras.fieldOffset(3) == 2 && paras.fieldOffset(7) == 5)
precondition(paras.fieldRange(1..<7) == 1..<5)
precondition(paras.valueOffsets(2) == 2...3, "a paragraph's end and the next one's start")
precondition(paras.valueOffsets(1) == 1...1)
precondition(paras.valueOffsets(3) == 4...4)
precondition(paras.valueOffsets(4) == 5...6)
precondition(ParagraphBreaks(value: "a\nb", fieldText: "a\nb")!.offsets == [], "<br> lines are in both")
precondition(ParagraphBreaks(value: "• ab\n• cd", fieldText: "• ab• cd")!.offsets == [4], "so are list markers")
precondition(ParagraphBreaks(value: "ab\n\ncd", fieldText: "ab\ncd")!.offsets == [2], "the break leads the text's own newline")
precondition(ParagraphBreaks(value: "", fieldText: "")!.offsets == [])
precondition(ParagraphBreaks(value: "ab\ncd", fieldText: "abxcd") == nil)
precondition(ParagraphBreaks(value: "ab", fieldText: "ab ") == nil)
precondition(ParagraphBreaks(value: "a\nb", fieldText: "a\n\nb") == nil)

precondition(paras.valueRange(2..<2) { _ in .start(skipping: 0) } == 3..<3)
precondition(paras.valueRange(2..<2) { _ in .end } == 2..<2)
precondition(paras.valueRange(2..<2) { _ in nil } == nil, "a boundary nothing resolves is unknown")
precondition(paras.valueRange(1..<3) { _ in preconditionFailure("unambiguous") } == 1..<4)
precondition(paras.valueRange(2..<2) { $0 == .upper ? .start(skipping: 0) : .end } == 2..<3, "the break alone")
precondition(paras.valueRange(2..<2) { $0 == .lower ? .start(skipping: 0) : .end } == 2..<3, "the break alone, selected backward")
let listItems = ParagraphBreaks(value: "• ab\n• cd", fieldText: "• ab• cd")!
precondition(listItems.valueRange(4..<4) { _ in .start(skipping: 2) } == 7..<7, "a caret between items sits past the next marker")
precondition(listItems.valueRange(0..<0) { _ in .start(skipping: 2) } == 2..<2, "and so does one before the first item")
precondition(listItems.valueRange(0..<0) { _ in nil } == nil, "a field's start nothing resolves is unknown too")
precondition(listItems.valueRange(0..<4) { $0 == .lower ? .start(skipping: 2) : .end } == 2..<4)

precondition(paras.replacing(1..<4, with: "") == ParagraphBreaks(offsets: [2]))
precondition(paras.replacing(0..<0, with: "x\n") == ParagraphBreaks(offsets: [1, 4, 7]))
precondition(paras.replacing(5..<6, with: " ") == ParagraphBreaks(offsets: [2]), "J joins the paragraphs")

// MARK: - Marker text (Chromium's U+FFFC for text-less leaves)

precondition(MarkerText.plain("See \u{FFFC}LIN-1234") == "See LIN-1234")
precondition(MarkerText.plainLength("\u{FFFC}\u{FFFC}Problem") == 7)
precondition(MarkerText.plainLength("a😀\u{FFFC}") == 3, "UTF-16 units, as the offsets are")
precondition(MarkerText.plain("") == "" && MarkerText.plainLength("") == 0)

/// `AXValue` and marker text Chrome 153 gave for a field with one text-less leaf (LIN-1573), and the plain caret past it.
let leafShapes: [(name: String, value: String, markers: String, caret: Int, valueCaret: Int)] = [
    ("icon chip",
     "Heading one\nFirst paragraph with some words.\nSee \n\nLIN-1234\n here\n• item alpha\n• item beta\nHeading two\nLast paragraph here.",
     "Heading oneFirst paragraph with some words.See \u{FFFC}LIN-1234 here• item alpha• item betaHeading twoLast paragraph here.",
     95, 104),
    ("hr",
     "Heading one\nFirst paragraph with some words.\n\n• item alpha\n• item beta\nHeading two\nLast paragraph here.",
     "Heading oneFirst paragraph with some words.\u{FFFC}• item alpha• item betaHeading twoLast paragraph here.",
     78, 84),
    ("checkbox",
     "Heading one\nFirst paragraph with some words.\n• \ntask one\n• item alpha\n• item beta\nHeading two\nLast paragraph here.",
     "Heading oneFirst paragraph with some words.• \u{FFFC}task one• item alpha• item betaHeading twoLast paragraph here.",
     88, 95),
]
for shape in leafShapes {
    precondition(ParagraphBreaks(value: shape.value, fieldText: shape.markers) == nil, "\(shape.name): U+FFFC is no break")
    let breaks = ParagraphBreaks(value: shape.value, fieldText: MarkerText.plain(shape.markers))!
    precondition(breaks.valueRange(shape.caret..<shape.caret) { _ in preconditionFailure("unambiguous") }
        == shape.valueCaret..<shape.valueCaret, shape.name)
}
let linearHeading = ParagraphBreaks(value: "\n\nProblem\nWhen", fieldText: MarkerText.plain("\u{FFFC}\u{FFFC}ProblemWhen"))!
precondition(linearHeading.offsets == [0, 1, 9], "the heading widget's two lines are breaks")
precondition(linearHeading.valueRange(0..<0) { _ in .start(skipping: 0) } == 2..<2, "a caret on the heading sits past them")

precondition(Expectation(selection: 5..<7, length: 11, edge: .paragraphEnd).traceFields == "sel=5..7 len=11 edge=end")

/// A Chromium `<p>` editor: every `\n` is a generated paragraph break.
func paragraphPlanning(
    _ keys: String, text: String, caret: Int, profile: CapabilityProfile, state: VimState = .initial
) -> PhysicalPlanner.Planning {
    let breaks = ParagraphBreaks(offsets: text.utf16.enumerated().filter { $0.element == 10 }.map(\.offset))
    let snapshot = FieldSnapshot(capabilities: profile, text: text, selection: caret..<caret, breaks: breaks)
    return PhysicalPlanner.planning(LogicalPlanner.plan(RawCommand(keys), state: state), snapshot: snapshot)
}

// "ab\ncd ef\ngh" reads to the field as "abcd efgh".
let threeParagraphs = "ab\ncd ef\ngh"
precondition(paragraphPlanning("j", text: threeParagraphs, caret: 1, profile: noCursorProfile).plan.steps == [
    .setSelection(3..<3),
    .settle(Expectation(selection: 3..<3, length: 11)),
    .commit(.setCursor(nil)),
])
precondition(paragraphPlanning("j", text: threeParagraphs, caret: 0, profile: noCursorProfile).plan.steps == [
    .setSelection(2..<2),
    .settle(Expectation(selection: 2..<2, length: 11, edge: .paragraphStart)),
    .commit(.setCursor(nil)),
])
precondition(paragraphPlanning("l", text: threeParagraphs, caret: 9, profile: readProfile).plan.steps == [
    .press(.right, count: 1),
    .settle(Expectation(selection: 8..<8, length: 11)),
    .commit(.setCursor(nil)),
])

let lastWordA = paragraphPlanning("ciw", text: threeParagraphs, caret: 7, profile: noCursorProfile)
precondition(lastWordA.plan.steps == [
    .setSelection(5..<7),
    .press(.selectLeft, count: 1),
    .settle(Expectation(selection: 5..<7, length: 11, edge: .paragraphEnd)),
    .replaceSelection(""),
    .settle(Expectation(selection: 5..<5, length: 9, edge: .paragraphEnd)),
    .commit(.deleted(into: nil, content: .literal("ef"), wise: .character)),
    .commit(.setMode(.insert)),
    .commit(.setInsertStart(6)),
])
precondition(lastWordA.operand == 5..<7, "the operand is compared with the field's own read")
precondition(paragraphPlanning("ciw", text: threeParagraphs, caret: 7, profile: readProfile).plan.steps == [
    .press(.left, count: 1),
    .press(.selectRight, count: 2),
    .settle(Expectation(selection: 5..<7, length: 11, edge: .paragraphEnd)),
    .settle(Expectation(selection: 5..<7, length: 11, edge: .paragraphEnd, selectedText: "ef")),
    .press(.deleteBack, count: 1),
    .softSettle(Expectation(selection: 5..<5, length: 9, edge: .paragraphEnd)),
    .commit(.deleted(into: nil, content: .literal("ef"), wise: .character)),
    .commit(.setMode(.insert)),
    .commit(.setInsertStart(6)),
])
precondition(paragraphPlanning("A", text: threeParagraphs, caret: 0, profile: noCursorProfile).plan.steps == [
    .setSelection(2..<2),
    .press(.left, count: 1),
    .settle(Expectation(selection: 2..<2, length: 11, edge: .paragraphEnd)),
    .commit(.setMode(.insert)),
    .commit(.setInsertStart(2)),
])
let fromParagraphEnd = LogicalPlan(.select(.span(to: .offset(5), inclusive: false)), .deleteSelection(into: nil))
precondition(PhysicalPlanner.planning(fromParagraphEnd, snapshot: FieldSnapshot(
    capabilities: noCursorProfile, text: threeParagraphs, selection: 2..<2, breaks: ParagraphBreaks(offsets: [2, 8])
)).plan.steps == [
    .setSelection(2..<2),
    .press(.left, count: 1),
    .press(.selectRight, count: 3),
    .settle(Expectation(selection: 2..<4, length: 11)),
    .replaceSelection(""),
    .settle(Expectation(selection: 2..<2, length: 8)),
    .commit(.deleted(into: nil, content: .literal("\ncd"), wise: .character)),
])
precondition(checkedTexts(paragraphPlanning("dd", text: threeParagraphs, caret: 4, profile: readProfile).plan) == ["cd ef"])
// "ab\n\ncd": the empty line is one Chromium makes for a text-less leaf, so no caret stops there.
let pastPhantom = Expectation(selection: 0..<2, length: 6, edge: .paragraphStart, selectedText: "ab")
precondition(paragraphPlanning("dd", text: "ab\n\ncd", caret: 0, profile: readProfile).plan.steps.contains(.settle(pastPhantom)),
             "keys that stop before the break read the paragraph's end and fail it")

/// `threeParagraphs` in a field whose text hides an element somewhere, as a Linear heading's widget does.
func leafyPlanning(_ keys: String, caret: Int) -> PhysicalPlanner.Planning {
    let snapshot = FieldSnapshot(capabilities: readProfile, text: threeParagraphs, selection: caret..<caret,
                                 breaks: ParagraphBreaks(offsets: [2, 8]), textlessLeaves: true)
    return PhysicalPlanner.planning(LogicalPlanner.plan(RawCommand(keys), state: .initial), snapshot: snapshot)
}
precondition(leafyPlanning("J", caret: 4).rejection != nil, "typing over a break could drop an <hr> or a table cell")
precondition(leafyPlanning("gUj", caret: 4).rejection != nil, "and so could retyping two lines")
precondition(leafyPlanning("gUiw", caret: 4).rejection == nil, "one line's text is safe to retype")
precondition(leafyPlanning("dd", caret: 4).rejection == nil, "a delete retypes nothing")
precondition(paragraphPlanning("J", text: threeParagraphs, caret: 4, profile: readProfile).rejection == nil)
precondition(paragraphPlanning("gUj", text: threeParagraphs, caret: 4, profile: readProfile).rejection == nil)
precondition(ParagraphBreaks(offsets: [2, 8]).fieldText("cd ef\n", at: 3..<9) == "cd ef")
precondition(ParagraphBreaks(offsets: [2, 8]).fieldText("b\ncd", at: 1..<5) == "bcd")
precondition(paragraphPlanning("o", text: threeParagraphs, caret: 0, profile: noCursorProfile).plan.steps.contains(
    .settle(Expectation(selection: nil, length: 12))
))
// MARK: - The selected-text check

/// For each step that deletes or types, the text the settle right before it checks.
func checkedTexts(_ plan: PhysicalPlan) -> [String?] {
    var texts: [String?] = []
    for (index, step) in plan.steps.enumerated() {
        switch step {
        case .press(.deleteBack, _), .typeText, .replaceSelection:
            if index > 0, case .settle(let expectation) = plan.steps[index - 1] {
                texts.append(expectation.selectedText)
            } else {
                texts.append(nil)
            }
        default:
            break
        }
    }
    return texts
}

let twoLines = "say hello world\nnext line"
let laneBEdits: [(keys: String, caret: Int, text: [String?])] = [
    ("ciw", 6, ["hello"]), ("diw", 6, ["hello"]), ("x", 6, ["l"]), ("3x", 6, ["llo"]), ("X", 6, ["e"]),
    ("dw", 4, ["hello "]), ("de", 4, ["hello"]), ("cw", 4, ["hello"]), ("D", 4, ["hello world"]),
    ("C", 4, ["hello world"]), ("s", 4, ["h"]), ("S", 4, ["say hello world"]), ("cc", 4, ["say hello world"]),
    ("dd", 4, ["say hello world\n"]), ("rZ", 4, ["h"]), ("3rZ", 4, ["hel"]), ("~", 4, ["h"]),
    ("g~iw", 4, ["hello"]), ("gUiw", 4, ["hello"]), (">>", 4, ["say hello world\n"]),
    ("J", 4, ["say hello world\nnext line"]),
]
for edit in laneBEdits {
    for profile in [readProfile, insertOnlyProfile] {
        precondition(checkedTexts(physical(edit.keys, text: twoLines, caret: edit.caret, profile: profile)) == edit.text,
                     "lane B must check the text \(edit.keys) replaces")
    }
}
var visualWord = VimState.initial
visualWord.field.mode = .visual(VimState.VisualContext(kind: .character, anchor: 4))
for keys in ["d", "x", "c", "s", "~", "u"] {
    let steps = PhysicalPlanner.plan(
        LogicalPlanner.plan(RawCommand(keys), state: visualWord),
        snapshot: FieldSnapshot(capabilities: readProfile, text: twoLines, selection: 4..<9, anchor: 4)
    )
    precondition(checkedTexts(steps) == ["hello"], "Visual \(keys) must check the selection it replaces")
}

func checksText(_ plan: PhysicalPlan) -> Bool {
    plan.steps.contains {
        if case .settle(let expectation) = $0 { return expectation.selectedText != nil }
        return false
    }
}
// An AX write made the selection, so lane A is exactly as it was.
for edit in laneBEdits {
    for profile in [axProfile, noCursorProfile, noInsertProfile, blockProfile] {
        precondition(!checksText(physical(edit.keys, text: twoLines, caret: edit.caret, profile: profile)),
                     "lane A must not check the text \(edit.keys) replaces")
    }
}
let readNothingSelected = CapabilityProfile(available: [.readText, .readLength, .readCaret, .wholeDocument])
for edit in laneBEdits {
    precondition(!checksText(physical(edit.keys, text: twoLines, caret: edit.caret, profile: readNothingSelected)))
}
precondition(physical("ciw", text: "say hello world", caret: 6, profile: readNothingSelected).traceShape == "P2P5!P?CCC")
var yankable = VimState.initial
yankable.session.registers.unnamed = .content(RegisterContent(text: "XY", wise: .character))
for keys in ["yiw", "yy", "w", "p", "P", "o", "O", "A", "i", "u"] {
    precondition(!checksText(physical(keys, text: twoLines, caret: 6, profile: readProfile, state: yankable)),
                 "\(keys) replaces no selection")
}

let checkedCiw = traced("ciw", text: "say hello world", caret: 6, profile: readProfile)
precondition(checkedCiw.plan.traceShape == "P2P5!!P?CCC")
precondition(!checkedCiw.abortedAtTextCheck(nil) && !checkedCiw.abortedAtTextCheck(2))
precondition(checkedCiw.abortedAtTextCheck(3))

// MARK: - KeyNotation

/// The gate between hardware and the engine. nil means the app keeps the key;
/// a token means vim CONSUMES it, because Normal/Visual has no passthrough
/// exit. So every nil below is a shortcut that still works while vim is
/// engaged, and every token is a promise the engine can act on it.
private func expectToken(
    _ keyCode: Int,
    _ chord: KeyNotation.Chord,
    _ characters: String,
    _ expected: String?,
    file: StaticString = #file,
    line: UInt = #line
) {
    let token = KeyNotation.token(keyCode: keyCode, chord: chord, characters: characters)
    precondition(
        token == expected,
        "Unexpected token for keyCode \(keyCode) chord \(chord.rawValue): \(token ?? "nil")",
        file: file, line: line
    )
}

/// The control character a ⌃-letter arrives as: ⌃a is U+0001.
private func controlCharacter(_ letter: Character) -> String {
    String(UnicodeScalar(letter.asciiValue! - 96))
}

// Bare keys are vim's; the tap resolves shift into `characters`.
expectToken(38, [], "j", "j")
expectToken(38, [.shift], "J", "J")
expectToken(123, [], "", "<Left>")
expectToken(36, [], "\r", "<CR>")
expectToken(48, [], "\t", "\t")          // bare Tab stays vim's — deliberate scope
expectToken(53, [], "\u{1B}", nil)       // physical Esc is never vim's
expectToken(38, [.command], "j", nil)

// ⇧ is transparent on the navigation cluster…
expectToken(123, [.shift], "", "<Left>")
// …but not on Tab: ⇧⇥ reverses focus and inserts nothing, so the app keeps it.
expectToken(48, [.shift], "\t", nil)

// The keycode table used to run before any modifier check, so a chorded
// navigation key laundered into a bare vim token — irrecoverably, since the
// modifier was gone by the time the monitor saw `<Up>`.
expectToken(126, [.control], "", nil)        // ⌃↑ Mission Control
expectToken(125, [.control], "", nil)        // ⌃↓ App Exposé
expectToken(123, [.option], "", nil)         // ⌥← word-left
expectToken(51, [.option], "\u{7F}", nil)    // ⌥⌫ delete-word-back
expectToken(48, [.control], "\t", nil)       // ⌃⇥ next tab

// ⌃ on a key with no character identity used to fall into the ⌃-letter
// branch and be read as a letter: Home is U+0001, every F-key is U+0010.
expectToken(115, [.control], controlCharacter("a"), nil)   // ⌃Home, was <C-a>
expectToken(119, [.control], controlCharacter("d"), nil)   // ⌃End,  was <C-d>
expectToken(120, [.control], controlCharacter("p"), nil)   // ⌃F2,   was <C-p>

// Bare F-keys and document keys passed only by accident (no character, so the
// `< 0x20` guard dropped them). Now explicit.
expectToken(122, [], "", nil)   // F1
expectToken(90, [], "", nil)    // F20
expectToken(115, [], "", nil)   // Home
expectToken(121, [], "", nil)   // PgDn

// ⌥ and Globe never reach the engine: ⌥j resolves to "∆", and 🌐E arrives as
// a bare "e" — the fn bit is all that separates it from the word-end motion.
expectToken(38, [.option], "∆", nil)
expectToken(14, [.fn], "e", nil)             // 🌐E emoji picker

// The engage key survives every one of those rejections, including ⌥: on
// layouts where `[` itself needs Option, ⌃[ IS a ⌃⌥ chord, and losing it
// would strand Normal mode. The keycode route is the layout-independent one.
expectToken(33, [.control], "\u{1B}", "<C-[>")
expectToken(33, [.control, .option], "\u{1B}", "<C-[>")
expectToken(33, [.control], "ü", "<C-[>")    // German: keycode 33 prints ü

// The ⌃-letters the gate admits must be exactly the ones the engine can
// EXECUTE — not the ones the parser merely recognizes. The parser binds
// eleven; nine plan to a bare bell, and admitting those would steal ⌃a
// (beginning-of-line), ⌃e (end-of-line) and friends to play a beep.
//
// Both sides are derived, so this fails the day someone implements the page
// motions — which is exactly when the gate needs to change to match.
let alphabet = "abcdefghijklmnopqrstuvwxyz"
let gateAdmits = Set(alphabet.filter {
    KeyNotation.token(keyCode: 0, chord: [.control], characters: controlCharacter($0)) != nil
})
let engineExecutes = Set(alphabet.filter { letter in
    let command = RawCommand("<C-\(letter)>")
    guard command.isComplete else { return false }   // <C-w> never completes alone
    let plan = PhysicalPlanner.plan(
        LogicalPlanner.plan(command, state: .initial),
        snapshot: FieldSnapshot(
            capabilities: CapabilityProfile(available: Set(Capability.allCases)),
            text: "alpha beta\nsecond line\n",
            selection: 3..<3
        )
    )
    return plan.steps != [.bell]
})
precondition(
    gateAdmits == engineExecutes,
    "⌃-allowlist drifted from what the engine executes: gate \(gateAdmits.sorted()) vs engine \(engineExecutes.sorted())"
)
precondition(gateAdmits == Set("rv"), "expected ⌃r and ⌃v: \(gateAdmits.sorted())")

// MARK: - RawMonitor

var monitor = RawMonitor()

// Multi-key assembly; single keys dispatch immediately.
precondition(monitor.feed("d", mode: .normal) == .pending)
precondition(monitor.feed("i", mode: .normal) == .pending)
precondition(monitor.feed("w", mode: .normal) ==
    .command(RawMonitor.Completed(command: RawCommand("diw"))))
precondition(monitor.pendingKeys.isEmpty)
precondition(monitor.feed("j", mode: .normal) ==
    .command(RawMonitor.Completed(command: RawCommand("j"))))

// Counts and registers assemble in any interleaving.
precondition(monitor.feed("2", mode: .normal) == .pending)
precondition(monitor.feed("\"", mode: .normal) == .pending)
precondition(monitor.feed("a", mode: .normal) == .pending)
precondition(monitor.feed("3", mode: .normal) == .pending)
precondition(monitor.feed("d", mode: .normal) == .pending)
precondition(monitor.feed("d", mode: .normal) ==
    .command(RawMonitor.Completed(command: RawCommand("2\"a3dd"))))

// A key the gate handed to the app drops the half-typed command: the app may
// have moved the caret, so completing `d` later would delete somewhere the
// user never aimed. The Insert-mode typed log is deliberately untouched.
precondition(monitor.feed("d", mode: .normal) == .pending)
monitor.cancelPending()
precondition(monitor.pendingKeys.isEmpty)
precondition(monitor.feed("d", mode: .normal) == .pending)   // not `dd`

monitor.reset()
precondition(monitor.feed("h", mode: .insert) == .passthrough)
monitor.cancelPending()
precondition(monitor.feed("<Esc>", mode: .insert) ==
    .command(RawMonitor.Completed(command: RawCommand("<Esc>"), insertPayload: "h")))

// Esc cancels a pending command; on an idle buffer it dispatches.
precondition(monitor.feed("d", mode: .normal) == .pending)
precondition(monitor.feed("<Esc>", mode: .normal) == .cancelled)
precondition(monitor.feed("<Esc>", mode: .normal) ==
    .command(RawMonitor.Completed(command: RawCommand("<Esc>"))))

// Visual: bare operators fire on the selection; i/a await their object.
precondition(monitor.feed("d", mode: .visual) ==
    .command(RawMonitor.Completed(command: RawCommand("d"))))
precondition(monitor.feed("i", mode: .visual) == .pending)
precondition(monitor.feed("w", mode: .visual) ==
    .command(RawMonitor.Completed(command: RawCommand("iw"))))

// Prompts stay open until submitted; backspace edits, then cancels.
precondition(monitor.feed("/", mode: .normal) == .pending)
precondition(monitor.feed("n", mode: .normal) == .pending)
precondition(monitor.feed("e", mode: .normal) == .pending)
precondition(monitor.feed("<CR>", mode: .normal) ==
    .command(RawMonitor.Completed(command: RawCommand("/ne<CR>"))))
precondition(monitor.feed("/", mode: .normal) == .pending)
precondition(monitor.feed("n", mode: .normal) == .pending)
precondition(monitor.feed("<BS>", mode: .normal) == .pending)
precondition(monitor.feed("<BS>", mode: .normal) == .cancelled)

// Insert: passthrough with a typed log, handed over once at Esc; an arrow makes it lossy.
precondition(monitor.feed("h", mode: .insert) == .passthrough)
precondition(monitor.feed("i", mode: .insert) == .passthrough)
precondition(monitor.feed("<Left>", mode: .insert) == .passthrough)
precondition(monitor.feed("<Esc>", mode: .insert) == .command(RawMonitor.Completed(
    command: RawCommand("<Esc>"), insertPayload: "hi", insertPayloadIsLossless: false
)))
precondition(monitor.feed("<Esc>", mode: .insert) ==
    .command(RawMonitor.Completed(command: RawCommand("<Esc>"), insertPayload: "")))

for token in ["h", "e", "l", "o", "<BS>", "l", "o", "<CR>", "x"] {
    precondition(monitor.feed(token, mode: .insert) == .passthrough)
}
precondition(monitor.feed("<Esc>", mode: .insert) ==
    .command(RawMonitor.Completed(command: RawCommand("<Esc>"), insertPayload: "hello\nx")))

// Backspace past the typed text is lossy.
precondition(monitor.feed("a", mode: .insert) == .passthrough)
precondition(monitor.feed("<BS>", mode: .insert) == .passthrough)
precondition(monitor.feed("<BS>", mode: .insert) == .passthrough)
precondition(monitor.feed("<Esc>", mode: .insert) == .command(RawMonitor.Completed(
    command: RawCommand("<Esc>"), insertPayload: "", insertPayloadIsLossless: false
)))

precondition(monitor.feed("a", mode: .insert) == .passthrough)
monitor.markInsertLogLossy()
precondition(monitor.feed("<Esc>", mode: .insert) == .command(RawMonitor.Completed(
    command: RawCommand("<Esc>"), insertPayload: "a", insertPayloadIsLossless: false
)))
precondition(monitor.feed("b", mode: .insert) == .passthrough)
precondition(monitor.feed("<Esc>", mode: .insert) ==
    .command(RawMonitor.Completed(command: RawCommand("<Esc>"), insertPayload: "b")))
monitor.markInsertLogLossy()
monitor.reset()
precondition(monitor.feed("<Esc>", mode: .insert) ==
    .command(RawMonitor.Completed(command: RawCommand("<Esc>"), insertPayload: "")))

// <C-[> is the runtime's engage key (physical Esc never reaches the
// monitor): it must complete insert, cancel pending, and dispatch alone.
precondition(monitor.feed("h", mode: .insert) == .passthrough)
precondition(monitor.feed("<C-[>", mode: .insert) ==
    .command(RawMonitor.Completed(command: RawCommand("<Esc>"), insertPayload: "h")))
precondition(monitor.feed("d", mode: .normal) == .pending)
precondition(monitor.feed("<C-[>", mode: .normal) == .cancelled)
precondition(monitor.feed("<C-[>", mode: .normal) ==
    .command(RawMonitor.Completed(command: RawCommand("<C-[>"))))

// MARK: - VimEffect

// Residency is the user's; every other effect claims something about the field.
precondition(VimEffect.setMode(.normal).survivesAbort)
precondition(VimEffect.setMode(.insert).survivesAbort)
precondition(VimEffect.setMode(.replace).survivesAbort)
precondition(!VimEffect.setMode(.visual(VimState.VisualContext(kind: .character, anchor: 0))).survivesAbort)
precondition(!VimEffect.setInsertStart(4).survivesAbort)
precondition(!VimEffect.setCursor(3..<4).survivesAbort)
precondition(!VimEffect.setMark("a", MarkPoint(offset: 1, textLength: 5, context: "abc")).survivesAbort)
precondition(!VimEffect.deleted(into: nil, content: .literal("x"), wise: .character).survivesAbort)
precondition(!VimEffect.yanked(into: nil, content: .literal("x"), wise: .character).survivesAbort)
precondition(!VimEffect.searched(VimState.SearchMemory(pattern: "x", direction: .right)).survivesAbort)
precondition(!VimEffect.found(VimState.FindMemory(character: "x", direction: .right, beforeCharacter: false)).survivesAbort)
precondition(!VimEffect.setLastInsert("x").survivesAbort)
precondition(!VimEffect.setLastChange(VimState.ChangeMemory(body: "x")).survivesAbort)
precondition(!VimEffect.setLastVisual(VisualMemory(kind: .character, range: 0..<1)).survivesAbort)

// MARK: - VimReducer

var reduced = VimState.initial
reduced = VimReducer.reduce(reduced, .yanked(into: nil, content: .literal("one\n"), wise: .line))
precondition(reduced.session.register("\"") == .content(RegisterContent(text: "one\n", wise: .line)))
precondition(reduced.session.register("0") == .content(RegisterContent(text: "one\n", wise: .line)))

// Linewise deletes shift the ring; the yank slot is untouched.
reduced = VimReducer.reduce(reduced, .deleted(into: nil, content: .literal("a\n"), wise: .line))
reduced = VimReducer.reduce(reduced, .deleted(into: nil, content: .literal("b\n"), wise: .line))
precondition(reduced.session.register("1") == .content(RegisterContent(text: "b\n", wise: .line)))
precondition(reduced.session.register("2") == .content(RegisterContent(text: "a\n", wise: .line)))
precondition(reduced.session.register("0") == .content(RegisterContent(text: "one\n", wise: .line)))

// Sub-line deletes go to the small-delete register, not the ring.
reduced = VimReducer.reduce(reduced, .deleted(into: nil, content: .literal("ch"), wise: .character))
precondition(reduced.session.register("-") == .content(RegisterContent(text: "ch", wise: .character)))
precondition(reduced.session.register("1") == .content(RegisterContent(text: "b\n", wise: .line)))

// Named writes mirror to unnamed; uppercase appends; the black hole swallows.
reduced = VimReducer.reduce(reduced, .yanked(into: Register("a"), content: .literal("hi"), wise: .character))
reduced = VimReducer.reduce(reduced, .yanked(into: Register("A"), content: .literal("!"), wise: .character))
precondition(reduced.session.register("a") == .content(RegisterContent(text: "hi!", wise: .character)))
precondition(reduced.session.register("\"") == .content(RegisterContent(text: "hi!", wise: .character)))
reduced = VimReducer.reduce(reduced, .deleted(into: Register("_"), content: .literal("gone"), wise: .character))
precondition(reduced.session.register("\"") == .content(RegisterContent(text: "hi!", wise: .character)))

// An unfilled capture skips the write rather than inventing content.
reduced = VimReducer.reduce(reduced, .deleted(into: nil, content: .captured(CaptureSlot(id: 9)), wise: .character))
precondition(reduced.session.register("\"") == .content(RegisterContent(text: "hi!", wise: .character)))

// Pasteboard markers route to unnamed ONLY — ring, 0, -, named untouched;
// the register name is ignored; uppercase append skips; real content
// overwrites a marker (fresher).
reduced = VimReducer.reduce(reduced, .deleted(into: nil, content: .pasteboard, wise: .line))
precondition(reduced.session.register("\"") == .pasteboard(wise: .line))
precondition(reduced.session.register("1") == .content(RegisterContent(text: "b\n", wise: .line)))
precondition(reduced.session.register("0") == .content(RegisterContent(text: "one\n", wise: .line)))
precondition(reduced.session.register("-") == .content(RegisterContent(text: "ch", wise: .character)))
reduced = VimReducer.reduce(reduced, .deleted(into: Register("a"), content: .pasteboard, wise: .character))
precondition(reduced.session.register("a") == .content(RegisterContent(text: "hi!", wise: .character)))
precondition(reduced.session.register("\"") == .pasteboard(wise: .character))
reduced = VimReducer.reduce(reduced, .yanked(into: Register("A"), content: .pasteboard, wise: .line))
precondition(reduced.session.register("a") == .content(RegisterContent(text: "hi!", wise: .character)))
reduced = VimReducer.reduce(reduced, .deleted(into: Register("_"), content: .pasteboard, wise: .character))
precondition(reduced.session.register("\"") == .pasteboard(wise: .line))   // blackhole swallowed the marker too
reduced = VimReducer.reduce(reduced, .yanked(into: nil, content: .literal("fresh"), wise: .character))
precondition(reduced.session.register("\"") == .content(RegisterContent(text: "fresh", wise: .character)))

// Cursor state: set by renderCursor's commit, cleared on leaving Normal.
reduced = VimReducer.reduce(reduced, .setCursor(3..<4))
precondition(reduced.field.cursor == 3..<4)
reduced = VimReducer.reduce(reduced, .setMode(.insert))
precondition(reduced.field.cursor == nil)

// Only opening a session forgets where the last one began.
reduced = VimReducer.reduce(reduced, .setInsertStart(7))
precondition(reduced.field.insertStart == 7)
reduced = VimReducer.reduce(reduced, .setMode(.normal))
precondition(reduced.field.insertStart == 7)   // `gi` still needs it after Insert ends
reduced = VimReducer.reduce(reduced, .setMode(.visual(VimState.VisualContext(kind: .character, anchor: 2))))
precondition(reduced.field.insertStart == 7)   // and across a Visual excursion
reduced = VimReducer.reduce(reduced, .setMode(.insert))
precondition(reduced.field.insertStart == nil)

// MARK: - Sim goldens: (text, caret, keys) → (text′, caret′, state′)

var sim = Sim(text: "say hello world", caret: 6, profile: axProfile)
sim.type("x")
precondition(sim.text == "say helo world")
precondition(sim.caret == 6)
precondition(sim.selection == 6..<7)                       // the block cursor, on 'o'
precondition(sim.state.field.cursor == 6..<7)
precondition(sim.state.session.register("-") == .content(RegisterContent(text: "l", wise: .character)))

sim = Sim(text: "abcdef", caret: 0, profile: axProfile)
sim.type("3x")
precondition(sim.text == "def")
precondition(sim.state.session.register("\"") == .content(RegisterContent(text: "abc", wise: .character)))

sim = Sim(text: "say hello", caret: 0, profile: axProfile)
sim.type("dw")
precondition(sim.text == "hello")
precondition(sim.state.session.register("-") == .content(RegisterContent(text: "say ", wise: .character)))

sim = Sim(text: "a\nb\nc", caret: 0, profile: axProfile)
sim.type("dddd")
precondition(sim.text == "c")
precondition(sim.state.session.register("1") == .content(RegisterContent(text: "b\n", wise: .line)))
precondition(sim.state.session.register("2") == .content(RegisterContent(text: "a\n", wise: .line)))

sim = Sim(text: "one\ntwo", caret: 0, profile: axProfile)
sim.type("yyp")
precondition(sim.text == "one\none\ntwo")
precondition(sim.state.session.register("0") == .content(RegisterContent(text: "one\n", wise: .line)))

// The flagship: change-inner-word, type, escape — full loop.
sim = Sim(text: "say hello world", caret: 6, profile: axProfile)
sim.type("ciwbye")
sim.feed("<Esc>")
precondition(sim.text == "say bye world")
precondition(sim.caret == 6)
precondition(sim.state.field.cursor == 6..<7)              // redrawn on insert exit
precondition(sim.state.field.mode == .normal)
precondition(sim.state.session.lastInsert == "bye")
precondition(sim.state.session.register(".") == .content(RegisterContent(text: "bye", wise: .character)))
precondition(sim.state.session.lastChange == VimState.ChangeMemory(body: "ciw", insert: "bye"))
precondition(sim.settleFailures == 0 && sim.bells == 0 && sim.unsupportedSteps == 0)

// Insert entry via A opens a dot body even though entry itself mutated nothing.
sim = Sim(text: "hi", caret: 0, profile: axProfile)
sim.type("A!")
sim.feed("<Esc>")
precondition(sim.text == "hi!")
precondition(sim.caret == 2)
precondition(sim.state.session.lastChange == VimState.ChangeMemory(body: "A", insert: "!"))

// Dot replays the last change and must not overwrite it.
sim = Sim(text: "aabb", caret: 0, profile: axProfile)
sim.type("x.")
precondition(sim.text == "bb")
precondition(sim.state.session.lastChange == VimState.ChangeMemory(body: "x"))

sim = Sim(text: "say hello world", caret: 6, profile: axProfile)
sim.type("ciwbye")
sim.feed("<Esc>")
sim.type("w.")
precondition(sim.text == "say bye bye")
precondition(sim.selection == 10..<11)
precondition(sim.state.field.mode == .normal)
precondition(sim.state.session.lastChange == VimState.ChangeMemory(body: "ciw", insert: "bye"))
precondition(sim.settleFailures == 0 && sim.bells == 0 && sim.unsupportedSteps == 0)

/// Types `change`, ends it with ⌃[, then types `then`.
func replayed(_ text: String, caret: Int = 0, _ change: String, then keys: String) -> Sim {
    var replay = Sim(text: text, caret: caret, profile: axProfile)
    replay.type(change)
    replay.feed("<C-[>")
    replay.type(keys)
    precondition(replay.settleFailures == 0 && replay.bells == 0 && replay.unsupportedSteps == 0)
    return replay
}
precondition(replayed("one two three", "cwX", then: "w.").text == "X X three")
precondition(replayed("a\nb", "ccX", then: "j.").text == "X\nX")
precondition(replayed("abc", "sX", then: "l.").text == "XXc")
precondition(replayed("one\ntwo", "A!", then: "j.").text == "one!\ntwo!")
let reopened = replayed("a", "ofoo", then: ".")
precondition(reopened.text == "a\nfoo\nfoo")
precondition(reopened.selection == 8..<9)

var typo = Sim(text: "say hello world", caret: 6, profile: axProfile)
typo.type("ciwhelo")
typo.feed("<BS>")
typo.type("lo")
typo.feed("<C-[>")
precondition(typo.text == "say hello world")
precondition(typo.state.session.lastInsert == "hello")
typo.type("w.")
precondition(typo.text == "say hello hello")
var lines = Sim(text: "a", profile: axProfile)
lines.type("otwo")
lines.feed("<CR>")
lines.type("three")
lines.feed("<C-[>")
lines.type(".")
precondition(lines.text == "a\ntwo\nthree\ntwo\nthree")
precondition(lines.state.session.lastChange == VimState.ChangeMemory(body: "o", insert: "two\nthree"))

var lost = Sim(text: "say hello world", caret: 6, profile: axProfile)
lost.type("ciwfoo")
lost.feed("<Left>")
lost.type("bar")
lost.feed("<C-[>")
precondition(lost.state.session.lastChange == .unreplayable)
let beforeDot = lost.text
lost.type("w.")
precondition(lost.text == beforeDot)
precondition(lost.bells == 1)

// An empty session closes its body: `ciw` records, `i` does not, nothing strands.
var empty = Sim(text: "say hello world", caret: 6, profile: axProfile)
empty.type("ciw")
empty.feed("<C-[>")
precondition(empty.state.session.lastChange == VimState.ChangeMemory(body: "ciw", insert: ""))
empty.type("w.")
precondition(empty.text == "say  ")
empty.type("A!")
empty.feed("<C-[>")
precondition(empty.state.session.lastChange == VimState.ChangeMemory(body: "A", insert: "!"))
empty.type("i")
empty.feed("<C-[>")
precondition(empty.state.session.lastChange == VimState.ChangeMemory(body: "A", insert: "!"))
precondition(empty.state.session.lastInsert == "!")
precondition(replayed("a", "o", then: ".").text == "a\n\n")

// Visual changes ring on `.` instead of replaying as Normal `s`, or `u` (undo).
var visualChange = Sim(text: "say hello world", caret: 4, profile: axProfile)
visualChange.type("viwsbye")
visualChange.feed("<C-[>")
precondition(visualChange.text == "say bye world")
precondition(visualChange.state.session.lastChange == .unreplayable)
visualChange.type("w.")
precondition(visualChange.text == "say bye world")
precondition(visualChange.bells == 1)
var visualCase = Sim(text: "AAA BBB", caret: 0, profile: axProfile)
visualCase.type("viwu")
precondition(visualCase.text == "aaa BBB")
visualCase.type("w.")
precondition(visualCase.text == "aaa BBB")
precondition(visualCase.bells == 1 && visualCase.unsupportedSteps == 0)

var refused = replayed("say hello world", caret: 6, "ciwbye", then: "w")
refused.swallowsReplace = true
refused.type(".")
precondition(refused.settleFailures == 1)
precondition(refused.text == "say bye world")
precondition(refused.state.field.mode == .normal)
precondition(refused.selection.isEmpty)

var dotState = VimState.initial
dotState.session.lastChange = VimState.ChangeMemory(body: "ciw", insert: "bye")
let dotB = physical(".", text: "say hello world", caret: 6, profile: readProfile, state: dotState)
precondition(dotB.traceShape == "P2P5!!P?CCCT?P!CC")
precondition(dotB.steps.contains(.typeText("bye")))
let dotC = physical(".", profile: blindProfile, state: dotState)
precondition(dotC.traceShape == "PPXCCCTPCC")
precondition(dotC.steps.contains(.typeText("bye")))

// Find commits its memory; `;` repeats from it.
sim = Sim(text: "abcabc", caret: 0, profile: axProfile)
sim.type("fc;")
precondition(sim.caret == 5)
precondition(sim.state.session.lastFind ==
    VimState.FindMemory(character: "c", direction: .forward, beforeCharacter: false))
precondition(sim.settleFailures == 0 && sim.bells == 0)

// Block cursor: drawn after commands, walks with the caret, and collapses
// on insert entry so typing inserts instead of overwriting.
sim = Sim(text: "abc", caret: 0, profile: axProfile)
sim.type("l")
precondition(sim.selection == 1..<2)                       // block on 'b'
precondition(sim.state.field.cursor == 1..<2)
sim.type("iZ")
sim.feed("<Esc>")
precondition(sim.text == "aZbc")                           // inserted, not overwritten
precondition(sim.state.field.cursor == 1..<2)              // redrawn after Esc
precondition(sim.settleFailures == 0 && sim.bells == 0)

// At end of line the cursor has nothing to cover: bare caret.
sim = Sim(text: "hi", caret: 0, profile: axProfile)
sim.type("$")
precondition(sim.selection == 2..<2)
precondition(sim.state.field.cursor == nil)

// drawCursor suppressed (the Notion shape): identical edits and exact
// offsets, but no standing selection — the caret stays bare after every
// command.
sim = Sim(text: "say hello world", caret: 6, profile: noCursorProfile)
sim.type("ciwbye")
sim.feed("<Esc>")
precondition(sim.text == "say bye world")
precondition(sim.caret == 6)
precondition(sim.selection == 6..<6)                       // bare caret, no block
precondition(sim.state.field.cursor == nil)
precondition(sim.settleFailures == 0 && sim.bells == 0 && sim.unsupportedSteps == 0)

// A field that accepts the AX write and does nothing — measured in Linear.
sim = Sim(text: "say hello world", caret: 6, profile: axProfile)
sim.swallowsReplace = true
sim.type("ciw")
precondition(sim.text == "say hello world")            // nothing was deleted
precondition(sim.settleFailures == 1)
precondition(sim.state.field.mode == .insert)
precondition(sim.state.field.insertStart == nil)       // the paired commit died with the plan
precondition(sim.state.session.register("-") == nil)   // and no register claims the delete
precondition(sim.selection == 4..<9)                   // the word is still the operand
sim.type("bye")
sim.feed("<Esc>")
precondition(sim.text == "say bye world")              // the app's own editor finished it
precondition(sim.caret == 6)
precondition(sim.state.field.mode == .normal)
precondition(sim.state.session.lastInsert == "bye")
precondition(sim.state.session.lastChange == VimState.ChangeMemory(body: "ciw", insert: "bye"))

// An aborted plan that stayed in Normal mutated nothing, so `.` must not learn it.
sim = Sim(text: "say hello", caret: 0, profile: axProfile)
sim.swallowsReplace = true
sim.type("dw")
precondition(sim.text == "say hello")
precondition(sim.state.session.lastChange == nil)

// Esc's nudge can fail too, and the drained payload has no second chance.
sim = Sim(text: "hi", caret: 0, profile: axProfile)
sim.type("iZ")
precondition(sim.state.field.mode == .insert)
sim.swallowsSelect = true
sim.feed("<Esc>")
precondition(sim.settleFailures == 1)
precondition(sim.state.field.mode == .normal)
precondition(sim.state.session.lastInsert == "Z")
precondition(sim.state.session.lastChange == VimState.ChangeMemory(body: "i", insert: "Z"))

// Visual `c` has no settle to verify its selection; the planner names it.
sim = Sim(text: "say hello world", caret: 4, profile: axProfile)
sim.swallowsReplace = true
sim.type("viw")
precondition(sim.selection == 4..<9)
sim.type("c")
precondition(sim.state.field.mode == .insert)
precondition(sim.selection == 4..<9)                   // kept, not collapsed
sim.type("bye")
sim.feed("<Esc>")
precondition(sim.text == "say bye world")

// The other half: Visual `d` ends in Normal, so nobody types over it.
sim = Sim(text: "say hello world", caret: 4, profile: axProfile)
sim.swallowsReplace = true
sim.type("viwd")
precondition(sim.text == "say hello world")            // nothing deleted
precondition(sim.state.field.mode == .normal)          // and Visual is left regardless
precondition(sim.selection.isEmpty)                    // the stranded selection is collapsed
precondition(sim.state.session.register("\"") == nil)

// A swallowed *replace* leaves a bare caret, so entering Insert is safe.
sim = Sim(text: "say hello world", caret: 4, profile: axProfile)
sim.swallowsReplace = true
sim.type("o")
precondition(sim.state.field.mode == .insert)
precondition(sim.selection.isEmpty)

// A swallowed *select* strands a range no write of ours can collapse.
sim = Sim(text: "say hello world", caret: 4, profile: axProfile)
sim.perform([.setSelection(4..<9)])
sim.swallowsSelect = true
sim.type("o")
precondition(sim.settleFailures == 1)
precondition(sim.state.field.mode == .normal)
precondition(sim.selection == 4..<9)
precondition(sim.text == "say hello world")

// Answering no selection at all: residency must not ride on a failed read.
sim = Sim(text: "say hello world", caret: 6, profile: axProfile)
sim.unreadableSelection = true
sim.type("ciw")
precondition(sim.settleFailures == 1)
precondition(sim.state.field.mode == .normal)
precondition(sim.text == "say hello world")

// Standing down never revives Visual, whose anchor names an unreadable selection.
sim = Sim(text: "say hello world", caret: 4, profile: axProfile)
sim.type("viw")
precondition(sim.selection == 4..<9)
sim.swallowsReplace = true
sim.unreadableSelection = true
sim.type("c")
precondition(sim.settleFailures == 1)
precondition(sim.state.field.mode == .normal)
precondition(sim.text == "say hello world")

// The pasteboard IS the register (clipboard=unnamed): cut writes it, a
// marker commit remembers only the wise, and a nil insert pastes it back.
// Step-level: blind plans carry .press moves the Sim can't emulate.
sim = Sim(text: "one two", caret: 0, profile: blindProfile)
precondition(sim.perform([
    .setSelection(0..<3),
    .clipboardCut,
    .commit(.deleted(into: nil, content: .pasteboard, wise: .character)),
    .clipboardInsert(nil),
]))
precondition(sim.pasteboard == "one")
precondition(sim.text == "one two")                        // cut, then pasted back
precondition(sim.caret == 3)
precondition(sim.state.session.register("\"") == .pasteboard(wise: .character))

// A copy overwrites the modeled pasteboard without mutating the field.
precondition(sim.perform([.setSelection(4..<7), .clipboardCopy]))
precondition(sim.pasteboard == "two")
precondition(sim.text == "one two")

// MARK: - Lane B end to end, and hosts that misread the caret

func typed(_ keys: String, text: String, caret: Int, profile: CapabilityProfile) -> Sim {
    var host = Sim(text: text, caret: caret, profile: profile)
    host.type(keys)
    return host
}
for edit in laneBEdits {
    let laneB = typed(edit.keys, text: twoLines, caret: edit.caret, profile: readProfile)
    precondition(laneB.text == typed(edit.keys, text: twoLines, caret: edit.caret, profile: axProfile).text,
                 "lane B must edit what lane A edits: \(edit.keys)")
    precondition(laneB.settleFailures == 0 && laneB.unsupportedSteps == 0, edit.keys)
}
sim = Sim(text: "say hello world", caret: 6, profile: readProfile)
sim.type("ciwbye")
sim.feed("<Esc>")
precondition(sim.text == "say bye world")
precondition(sim.caret == 6)
precondition(sim.state.field.mode == .normal)
precondition(sim.state.session.lastChange == VimState.ChangeMemory(body: "ciw", insert: "bye"))
precondition(sim.settleFailures == 0 && sim.unsupportedSteps == 0)
sim = typed("viwd", text: "say hello world", caret: 6, profile: readProfile)
precondition(sim.text == "say  world" && sim.settleFailures == 0)

/// Chromium's rule 1 (LIN-1533): the read leaves out the breaks before the caret.
func omitsBreaks(_ offset: Int, _ text: String) -> Int {
    offset - TextModel(text).newlineCount(in: 0..<offset)
}
func checkedText(_ step: PhysicalStep?) -> String? {
    guard case .settle(let expectation)? = step else { return nil }
    return expectation.selectedText
}
let paragraphs = "alpha beta gamma\ndelta epsilon zeta\neta theta iota"

var misread = Sim(text: paragraphs, caret: 7, profile: readProfile)
misread.reads = omitsBreaks
misread.type("ciwX")
misread.feed("<C-[>")
precondition(misread.text == "alpha X gamma\ndelta epsilon zeta\neta theta iota")
precondition(misread.state.field.mode == .normal && misread.settleFailures == 0)

// Paragraph 2: the keys select "psilon " while every offset reads as "epsilon".
misread = Sim(text: paragraphs, caret: 24, profile: readProfile)
misread.reads = omitsBreaks
misread.type("ciw")
precondition(misread.text == paragraphs && misread.settleFailures == 1)
precondition(checkedText(misread.abortedStep) == "epsilon", "the offsets settle passes and the text check rings")
precondition(misread.selection == 24..<24, "a failed check collapses what the keys selected")
precondition(misread.state.field.mode == .normal, "the operand's offsets must not keep Insert over other text")
precondition(misread.state.session.register("-") == nil && misread.state.session.lastChange == nil)

var unchecked = Sim(text: paragraphs, caret: 24, profile: readNothingSelected)
unchecked.reads = omitsBreaks
unchecked.type("ciwX")
unchecked.feed("<C-[>")
precondition(unchecked.text == "alpha beta gamma\ndelta eXzeta\neta theta iota")
precondition(unchecked.settleFailures == 0)

for keys in ["x", "3x", "X", "dw", "de", "diw", "D", "C", "s", "S", "cc", "dd", "rZ", "~", "g~iw", "J", "viwd", "viwc"] {
    misread = Sim(text: paragraphs, caret: 24, profile: readProfile)
    misread.reads = omitsBreaks
    misread.type(keys)
    precondition(misread.text == paragraphs && misread.settleFailures == 1, "\(keys) must ring, not edit, in paragraph 2")
    precondition(!misread.state.field.mode.isInserting, keys)
}

// Rule 2: a caret at an element boundary reads as its paragraph's start, in read offsets (as measured).
let fromBlockStart: [(keys: String, check: String?)] = [("ciw", "\n"), ("dw", "\n"), ("x", nil), ("dd", nil), ("~", nil)]
for edit in fromBlockStart {
    misread = Sim(text: paragraphs, caret: 24, profile: readProfile)
    misread.reads = { offset, text in offset == 24 ? 16 : omitsBreaks(offset, text) }
    misread.type(edit.keys)
    precondition(misread.text == paragraphs, "\(edit.keys) must not edit from a caret read as its block's start")
    precondition(checkedText(misread.abortedStep) == edit.check, edit.keys)
}

// Chromium's AXSelectedText leaves paragraph breaks out, so no edit across one passes, in paragraph 1 too.
misread = Sim(text: paragraphs, caret: 7, profile: readProfile)
misread.reads = omitsBreaks
misread.type("J")
precondition(misread.text == paragraphs && checkedText(misread.abortedStep) != nil)
var acrossBreak = VimState.initial
acrossBreak.field.mode = .visual(VimState.VisualContext(kind: .character, anchor: 10))
misread = Sim(text: paragraphs, caret: 10, state: acrossBreak, profile: readProfile)
misread.reads = omitsBreaks
misread.perform([.setSelection(10..<20)])
misread.type("d")
precondition(misread.text == paragraphs && checkedText(misread.abortedStep) == " gamma\nde")

// MARK: - Focus transitions

// The entry policy as a value — pinned nowhere until now.
precondition(VimState.Field.entry.mode == .insert)

// A fully-populated field, to prove exactly what each edge keeps.
let populated = VimState.Field(
    mode: .normal,
    insertStart: 3,
    marks: ["a": MarkPoint(offset: 2, textLength: 9, context: "he")],
    lastVisual: VisualMemory(kind: .character, range: 1..<4),
    cursor: 2..<3
)

// sameElement: nothing moved, so nothing is stale.
precondition(populated.carried(across: .sameElement) == populated)

// sameDocument: residency survives; every offset-bearing member does not.
let crossed = populated.carried(across: .sameDocument)
precondition(crossed.mode == .normal)
precondition(crossed.insertStart == nil)
precondition(crossed.marks.isEmpty)
precondition(crossed.lastVisual == nil)
precondition(crossed.cursor == nil)

// Visual carries verbatim — dropping to Normal would break `v j j d`.
let visualContext = VimState.VisualContext(kind: .character, anchor: 0)
precondition(
    VimState.Field(mode: .visual(visualContext)).carried(across: .sameDocument).mode
        == .visual(visualContext)
)

// newSession: the entry policy, whatever the old field held.
precondition(populated.carried(across: .newSession) == VimState.Field.entry)

// Keys-in-flight and the dot body move as one unit, and only a new session
// drops them.
precondition(FocusTransition.newSession.clearsChangeInFlight)
precondition(!FocusTransition.sameDocument.clearsChangeInFlight)
precondition(!FocusTransition.sameElement.clearsChangeInFlight)
precondition(FocusTransition.sameElement.preservesDrawnCursor)
precondition(!FocusTransition.sameDocument.preservesDrawnCursor)

// End-to-end through the Sim: engaging Normal then crossing a block keeps
// Normal — the bug this exists for — while a genuinely new field opens in
// Insert.
var refocused = Sim(text: "one", state: .initial, profile: blockProfile)
refocused.feed("<C-[>")
precondition(refocused.state.field.mode == .normal)
refocused.refocus(.sameDocument, text: "two")
precondition(refocused.state.field.mode == .normal, "a block crossing must not end the session")
refocused.refocus(.newSession, text: "three")
precondition(refocused.state.field.mode == .insert)

// The dot body survives a crossing the user's own ⏎ caused: `ciw` opens the
// body, the new block arrives mid-Insert, and Esc must still close it.
var carriedChange = Sim(text: "say hello", caret: 4, profile: axProfile)
carriedChange.feed("<C-[>")
carriedChange.type("ciwfoo")
carriedChange.refocus(.sameDocument, text: "bar")
carriedChange.feed("<Esc>")
precondition(carriedChange.state.session.lastChange == VimState.ChangeMemory(body: "ciw", insert: "foo"),
             "sameDocument must not half-clear the dot body")

// An opaque selection is press-built and lives in the queued channel, so the
// yank must ride the same queue (⌘C). `blockProfile` HAS readSelectedText —
// the tempting synchronous AX read — and must still not use it here: it would
// beat the queued presses and capture the selection as it was before them.
let opaqueYank = physical("yj", text: "one", caret: 0, profile: blockProfile).steps
precondition(opaqueYank.contains(.clipboardCopy), "opaque yank must stay in the queued channel")
precondition(!opaqueYank.contains(where: {
    if case .captureSelectedText = $0 { return true }
    return false
}), "a synchronous AX read would beat the queued presses")

// MARK: - Surface rungs and the precedence walks

// The whole point: one app, two engines. Dia's own search box is native; the
// <input> in the page it is showing is not; both are AXTextField.
let diaChrome = Surface(bundleID: "com.dia.app", role: "AXTextField", identifier: "address-bar")
let diaPage = Surface(bundleID: "com.dia.app", origin: "notion.so", role: "AXTextField")
let diaPageField = Surface(
    bundleID: "com.dia.app", origin: "notion.so", role: "AXTextField", identifier: "search-input"
)

// Narrowest first, and both element rungs coexist so an identified field still
// inherits from "all text fields on this site".
precondition(diaPageField.rungs == [
    "com.dia.app|notion.so|id:search-input",
    "com.dia.app|notion.so|role:AXTextField",
    "com.dia.app|notion.so",
    "web:notion.so",
    "com.dia.app",
])
// No identifier: the id rung simply drops out.
precondition(diaPage.rungs == [
    "com.dia.app|notion.so|role:AXTextField",
    "com.dia.app|notion.so",
    "web:notion.so",
    "com.dia.app",
])
// Native: no origin, so no site rung and no web: rung. The element rungs hang
// off the app instead.
precondition(diaChrome.rungs == [
    "com.dia.app|id:address-bar",
    "com.dia.app|role:AXTextField",
    "com.dia.app",
])
// The bare bundle ID is still the last rung, which is what makes every override
// written before surfaces existed keep resolving.
precondition(Surface(bundleID: "notion.id").rungs == ["notion.id"])
precondition(Surface().rungs.isEmpty)

// Host normalization: case-folded, `www.` dropped, unusable hosts refused.
precondition(Surface.normalizedHost("WWW.Notion.SO") == "notion.so")
precondition(Surface.normalizedHost("docs.google.com") == "docs.google.com")
precondition(Surface.normalizedHost("") == nil)
precondition(Surface.normalizedHost(nil) == nil)
// Subdomains are kept: these are genuinely different editors.
precondition(Surface.normalizedHost("mail.google.com") != Surface.normalizedHost("docs.google.com"))

// A `|` in a DOM id must not forge a rung boundary.
precondition(Surface(bundleID: "a", role: "R", identifier: "x|y").rungs.first == "a|id:x%7Cy")

// The menu never offers the app-independent web: rung — that is curation's
// claim, not one a user makes standing in one app.
precondition(diaPageField.writableScopes.map(\.scope) == [
    .field(identifier: "search-input"), .fieldsOfRole("AXTextField"), .site("notion.so"), .app,
])
precondition(diaChrome.writableScopes.map(\.scope) == [
    .field(identifier: "address-bar"), .fieldsOfRole("AXTextField"), .app,
])
precondition(!diaPageField.writableScopes.contains { $0.rung == "web:notion.so" })

// `site` drops the element half. transition() compares THIS: every Notion block
// is a different element, so comparing whole surfaces would end the session on
// every line move — the exact failure fieldIsSession exists to prevent.
precondition(diaPage.site == diaPageField.site)
precondition(diaPage != diaPageField)

// --- The two walks -------------------------------------------------------

let seeds: SurfaceLadder.Seeds = [
    "web:notion.so": ["wholeDocument", "drawCursor"],
    "com.dia.app": ["fieldIsSession"],
]

// Seeds resolve at whichever rung names them, narrowest first.
precondition(SurfaceLadder.seedEntry("wholeDocument", rungs: diaPageField.rungs, seeds: seeds)
             == "web:notion.so")
precondition(SurfaceLadder.seedEntry("fieldIsSession", rungs: diaPageField.rungs, seeds: seeds)
             == "com.dia.app")
precondition(SurfaceLadder.seedEntry("readText", rungs: diaPageField.rungs, seeds: seeds) == nil)
// A native field in the same app never sees the site's seed.
precondition(SurfaceLadder.seedEntry("wholeDocument", rungs: diaChrome.rungs, seeds: seeds) == nil)

// The narrowest user entry wins over wider ones.
let layered: SurfaceLadder.UserStore = [
    "com.dia.app": ["insertText": "off"],
    "com.dia.app|notion.so": ["insertText": "on"],
]
precondition(SurfaceLadder.userEntry("insertText", rungs: diaPageField.rungs, store: layered)?.rung
             == "com.dia.app|notion.so")
// ...and the app-level entry is what a native field in the same app still sees.
precondition(SurfaceLadder.userEntry("insertText", rungs: diaChrome.rungs, store: layered)?.rung
             == "com.dia.app")
precondition(SurfaceLadder.userEntry("readText", rungs: diaChrome.rungs, store: layered) == nil)

// THE law a single merged walk would have broken: a user's `.on` at the app
// rung must still un-seed curation at the narrower web: rung. The walks stay
// separate precisely so the existing precedence table can see both and apply
// "`.on` un-seeds" itself.
let unseeding: SurfaceLadder.UserStore = ["com.dia.app": ["wholeDocument": "on"]]
precondition(SurfaceLadder.seedEntry("wholeDocument", rungs: diaPageField.rungs, seeds: seeds)
             == "web:notion.so")
precondition(SurfaceLadder.userEntry("wholeDocument", rungs: diaPageField.rungs, store: unseeding)?.value
             == "on")

// --- The write rule ------------------------------------------------------

// "The picker must never show a lie": writing at a rung clears the same atom at
// every narrower one, so the choice just made is the choice that resolves.
let conflicted: SurfaceLadder.UserStore = [
    "com.dia.app|notion.so|id:search-input": ["insertText": "on"],
    "com.dia.app|notion.so": ["insertText": "on"],
]
let widened = SurfaceLadder.setting(
    "off", "insertText", at: "com.dia.app", rungs: diaPageField.rungs, store: conflicted
)
precondition(SurfaceLadder.userEntry("insertText", rungs: diaPageField.rungs, store: widened)?.value
             == "off", "a wider write must not be shadowed by the narrow entries it replaces")
precondition(widened["com.dia.app|notion.so|id:search-input"] == nil)
precondition(widened["com.dia.app|notion.so"] == nil)

// Writing narrow leaves wider rungs alone — nothing below them to clear.
let narrowed = SurfaceLadder.setting(
    "off", "insertText", at: "com.dia.app|notion.so", rungs: diaPageField.rungs, store: layered
)
precondition(narrowed["com.dia.app"]?["insertText"] == "off")
precondition(narrowed["com.dia.app|notion.so"]?["insertText"] == "off")

// The Dia shape, end to end: denying the page must leave the chrome untouched.
let scoped = SurfaceLadder.setting(
    "off", "insertText", at: "com.dia.app|notion.so|role:AXTextField",
    rungs: diaPage.rungs, store: [:]
)
precondition(SurfaceLadder.userEntry("insertText", rungs: diaPage.rungs, store: scoped)?.value == "off")
precondition(SurfaceLadder.userEntry("insertText", rungs: diaChrome.rungs, store: scoped) == nil,
             "denying the page must not reach the app's own search box")

// Auto clears the atom at every rung, and touches nothing else.
let mixed: SurfaceLadder.UserStore = [
    "com.dia.app|notion.so": ["insertText": "off", "drawCursor": "off"],
    "com.dia.app": ["insertText": "on"],
]
let autoed = SurfaceLadder.setting(
    nil, "insertText", at: nil, rungs: diaPageField.rungs, store: mixed
)
precondition(SurfaceLadder.userEntry("insertText", rungs: diaPageField.rungs, store: autoed) == nil)
precondition(autoed["com.dia.app|notion.so"]?["drawCursor"] == "off", "Auto must be per-atom")

// Emptied rungs are pruned, so `defaults read` shows exactly what was chosen.
precondition(SurfaceLadder.setting(
    nil, "insertText", at: nil, rungs: diaChrome.rungs,
    store: ["com.dia.app": ["insertText": "off"]]
).isEmpty)

// The clear actions wipe a scope and everything narrower than it.
let cleared = SurfaceLadder.clearing(
    atAndBelow: "com.dia.app|notion.so", rungs: diaPageField.rungs, store: conflicted
)
precondition(cleared.isEmpty)
// ...but never a wider one.
precondition(SurfaceLadder.clearing(
    atAndBelow: "com.dia.app|notion.so", rungs: diaPageField.rungs, store: layered
)["com.dia.app"]?["insertText"] == "off")

// Every capability the shipped seeds name must still exist, and the rungs they
// are keyed by must be rungs some surface can actually produce. A renamed atom
// or a malformed seed key orphans curation silently.
for (rung, capabilities) in CapabilitySeeds.denied {
    for raw in capabilities {
        precondition(Capability(rawValue: raw) != nil, "seed names unknown capability \(raw)")
    }
    let reachable = rung.hasPrefix("web:")
        ? Surface(bundleID: "any", origin: String(rung.dropFirst(4))).rungs.contains(rung)
        : Surface(bundleID: rung).rungs.contains(rung)
    precondition(reachable, "no surface can ever produce seed rung \(rung)")
}

// MARK: - The web-area walk

// Fake AX tree: element n's parent is n + 1 unless overridden.
func walked(_ tree: [Int: WebAreaWalk.Reading<Int>]) -> WebAreaWalk.Result {
    WebAreaWalk.walk(from: 0, clock: { 0 }) { node in
        tree[node] ?? WebAreaWalk.Reading(role: "AXGroup", parent: node + 1)
    }
}
func page(_ scheme: String?, _ host: String?, at depth: Int) -> [Int: WebAreaWalk.Reading<Int>] {
    [depth: WebAreaWalk.Reading(
        role: "AXWebArea", address: WebAreaWalk.Address(scheme: scheme, host: host), parent: depth + 1
    )]
}

// The old 16-hop cap keyed this editor at the app rung.
let deepEditor = walked(page("https", "WWW.Linear.app", at: 40))
precondition(deepEditor.origin == "linear.app")
precondition(deepEditor.stop == .webArea(WebAreaWalk.Address(scheme: "https", host: "WWW.Linear.app")))
precondition(deepEditor.hops == 40)
precondition(deepEditor.traceFields == "stop=site@40 ms=0")
precondition(walked(page("https", "linear.app", at: 3)).origin == "linear.app")
precondition(walked(page("https", "linear.app", at: WebAreaWalk.maxHops - 1)).origin == "linear.app")

let pastCap = walked(page("https", "linear.app", at: WebAreaWalk.maxHops))
precondition(pastCap.origin == nil && pastCap.stop == .hopCap)
precondition(pastCap.traceFields == "stop=hopCap@64 ms=0")

let localPage = walked(page("file", nil, at: 4))
precondition(localPage.origin == nil)
precondition(localPage.traceFields == "stop=hostless@4 scheme=file ms=0")
precondition(walked(page("about", nil, at: 2)).traceFields == "stop=hostless@2 scheme=about ms=0")
precondition(walked(page("https", "", at: 2)).origin == nil)

let noURL = walked([4: WebAreaWalk.Reading(role: "AXWebArea", parent: 5)])
precondition(noURL.origin == nil && noURL.traceFields == "stop=noURL@4 ms=0")
precondition(walked([5: WebAreaWalk.Reading(role: "AXWindow", parent: 6)]).traceFields == "stop=window@5 ms=0")
precondition(walked([1: WebAreaWalk.Reading(role: "AXApplication", parent: nil)]).traceFields
    == "stop=application@1 ms=0")

let timedOut = walked([2: WebAreaWalk.Reading(role: "AXGroup", parent: nil, parentError: -25204)])
precondition(timedOut.stop == .orphan(axError: -25204) && timedOut.origin == nil)
precondition(timedOut.traceFields == "stop=orphan@2 axerror=-25204 ms=0")
precondition(walked([0: WebAreaWalk.Reading(role: "AXTextArea", parent: nil)]).traceFields
    == "stop=orphan@0 axerror=nil ms=0")

var walkClock = 0.0
var walkReads = 0
let stalled = WebAreaWalk.walk(from: 0, clock: { walkClock += 0.3; return walkClock }) { node -> WebAreaWalk.Reading<Int> in
    walkReads += 1
    return WebAreaWalk.Reading(role: "AXGroup", parent: node + 1)
}
precondition(stalled.stop == .budget && walkReads == 2)
precondition(stalled.traceFields == "stop=budget@2 ms=900")
walkReads = 0
let spent = WebAreaWalk.walk(from: 0, clock: { walkClock += 1; return walkClock }) { node -> WebAreaWalk.Reading<Int> in
    walkReads += 1
    return WebAreaWalk.Reading(role: "AXGroup", parent: node + 1)
}
precondition(spent.stop == .budget && spent.hops == 1 && walkReads == 1, "the field itself is always read")

// MARK: - The learner's commit rule

// The learner writes at the ROLE learnRung, never the identifier rung: a key per
// individual field would scatter the evidence so thinly two consecutive strikes
// would never land.
precondition(diaPageField.roleRung == "com.dia.app|notion.so|role:AXTextField")
precondition(diaPageField.roleRung != diaPageField.rungs.first,
             "the learner must not write at the identifier learnRung")
precondition(diaChrome.roleRung == "com.dia.app|role:AXTextField")
precondition(Surface(bundleID: "com.dia.app").roleRung == nil)   // no role: nothing to learn against
precondition(Surface(role: "AXTextField").roleRung == nil)       // no app: likewise
// The role learnRung is always a learnRung the ladder actually produces, or a demotion
// would be written where no lookup could ever find it.
precondition(diaPageField.rungs.contains(diaPageField.roleRung!))
precondition(diaChrome.rungs.contains(diaChrome.roleRung!))

let learnRung = "com.dia.app|notion.so|role:AXTextField"
let otherRung = "com.other.app|role:AXTextField"

// One strike commits. The fields this catches no-op the write on every single
// command, so a second reading buys no certainty and costs another dead command
// on every new surface. `true` means "persist this and re-resolve the binding".
var learnerLedger = StrikeLedger()
precondition(learnerLedger.strike(rung: learnRung, capability: "insertText") == true)

// ...and says so exactly once. A demoted capability stops being exercised, but a
// stray strike (a stale cursor collapse, a queued command) must not re-fire the
// republish a commit triggers.
precondition(learnerLedger.strike(rung: learnRung, capability: "insertText") == false)
precondition(learnerLedger.strike(rung: learnRung, capability: "insertText") == false)

// A success never un-commits. Once demoted the capability is not exercised, so
// it generates no evidence either way — only the version TTL re-opens the trial.
learnerLedger.clear(rung: learnRung, capability: "insertText")
precondition(learnerLedger.strike(rung: learnRung, capability: "insertText") == false,
             "a cleared tally must not resurrect a committed demotion")

// Clearing something that never struck is a no-op — the honest-app path, which
// runs on essentially every command.
var learnerHonest = StrikeLedger()
learnerHonest.clear(rung: learnRung, capability: "insertText")
precondition(learnerHonest.pending(rung: learnRung, capability: "insertText") == 0)

// Commits are independent per capability and per rung: a lying insertText must
// not drag writeSelection down with it, nor one site another.
var learnerMixed = StrikeLedger()
precondition(learnerMixed.strike(rung: learnRung, capability: "insertText") == true)
precondition(learnerMixed.strike(rung: learnRung, capability: "writeSelection") == true)
precondition(learnerMixed.strike(rung: otherRung, capability: "insertText") == true)
// Each of those is its own conclusion, so none of them re-fires.
precondition(learnerMixed.strike(rung: learnRung, capability: "insertText") == false)
precondition(learnerMixed.strike(rung: otherRung, capability: "insertText") == false)

// The threshold is the single knob: raising it restores the forgiving behaviour
// (a success clearing a pending tally) without touching anything else.
precondition(StrikeLedger.strikesToCommit == 1)


// MARK: - The recorder's renderers

func traced(
    _ keys: String, text: String? = nil, caret: Int? = nil, profile: CapabilityProfile
) -> PhysicalPlanner.Planning {
    PhysicalPlanner.planning(
        LogicalPlanner.plan(RawCommand(keys), state: .initial),
        snapshot: FieldSnapshot(capabilities: profile, text: text, selection: caret.map { $0..<$0 })
    )
}

precondition(ciwA.traceShape == "W!R!CCC")
precondition(physical("ciw", text: "say hello world", caret: 6, profile: readProfile).traceShape
             == "P2P5!!P?CCC")
precondition(physical("ciw", text: "say hello world", caret: 6, profile: blindProfile).traceShape
             == "P2P5PCCC")

// A hard settle behind a press can name no capability, so it rings and teaches nothing.
func settleFollowsPress(_ plan: PhysicalPlan) -> Bool {
    for (index, step) in plan.steps.enumerated() where index > 0 {
        guard case .settle = step, case .press = plan.steps[index - 1] else { continue }
        return true
    }
    return false
}
precondition(settleFollowsPress(physical("ciw", text: "say hello world", caret: 6, profile: readProfile)))
precondition(!settleFollowsPress(ciwA))
precondition(!physical("ciw", text: "say hello world", caret: 6, profile: blindProfile).traceShape
             .contains("!"))

precondition(physical("3w", text: "say hello world", caret: 0, profile: readProfile).traceShape == "P15!C")

precondition(CapabilityReport(entries: [
    .readText: .init(status: .available, source: .probed),
    .writeSelection: .init(status: .unavailable, source: .learned),
]).traceGrid == "RT+p RL?? RC?? RS?? WS-l IT?? DC?? WD?? FS??")

// MARK: - The redaction rule

let secret = "hunter2"
let leaky: [LogicalStep] = [
    .insertText(secret),
    .replaceSelection(secret),
    .setMark("h"),
    .bell(.unsupported(secret)),
    .bell(.emptyRegister("h")),
    .bell(.unsetMark("h")),
]
for step in leaky {
    precondition(!step.traceName.contains(secret), "traceName leaked a text payload")
}
precondition(LogicalStep.insertText(secret).traceName == "insertText(7)")

let leakySteps = PhysicalPlan(steps: [
    .replaceSelection(secret), .typeText(secret), .clipboardInsert(secret),
    .commit(.setLastInsert(secret)),
])
precondition(!leakySteps.traceShape.contains(secret), "traceShape leaked a text payload")
precondition(leakySteps.traceShape == "RTVC")

// `Z` and `hunter2` are the operands; no case name `shape` emits holds either.
for leak in ["/hunter2<CR>", "d/hunter2<CR>", "d?hunter2<CR>", "y/hunter2<CR>",
             ":s/hunter2/x<CR>", "rZ", "dfZ", "ctZ", "\"ZY", "mZ", "`Z", "ciZ", "qZ"] {
    let rendered = RawCommand(leak).traceKeys
    precondition(!rendered.contains("Z") && !rendered.contains("hunter2"),
                 "traceKeys leaked an operand: " + leak + " -> " + rendered)
}

// The `.incomplete` forms are why the check scans `source`: the parse discards a count.
for digits in ["4111111111111111w", "d4111111111111111w", "4155551234x", "41111",
               "3dd", "12j", "2yy", "d3w",
               "d4111111111111111", "d4111111111111111f", "y4155551234"] {
    let rendered = RawCommand(digits).traceKeys
    precondition(rendered != digits, "a counted command reached the log verbatim: " + digits)
    let shape = String(rendered.split(separator: "…").first ?? "")
    precondition(!shape.contains(where: \.isNumber),
                 "traceKeys leaked a count digit: " + digits + " -> " + rendered)
}
precondition(RawCommand("3dd").traceKeys == "op(delete,line)…(3)")
precondition(RawCommand("4111111111111111w").traceKeys == "motion(word)…(17)")
precondition(RawCommand("d4111111111111111w").traceKeys == "op(delete,word)…(18)")
precondition(RawCommand("d4111111111111111").traceKeys == "incomplete…(17)")
precondition(RawCommand("y4155551234").traceKeys == "incomplete…(11)")
precondition(RawCommand("0").traceKeys == "motion(lineStart)…(1)")
precondition(RawCommand("d/hunter2<CR>").traceKeys == "op(delete,search)…(13)")
precondition(RawCommand("rS").traceKeys == "edit(replaceCharacter)…(2)")
precondition(RawCommand("dfS").traceKeys == "op(delete,find)…(3)")
precondition(RawCommand("mS").traceKeys == "mark…(2)")
precondition(RawCommand("`S").traceKeys == "motion(mark)…(2)")
precondition(RawCommand("\"aY").traceKeys == "edit(yankLine)…(3)")
precondition(RawCommand("/hunter2<CR>").traceKeys == "search…(12)")
precondition(RawCommand(":s/x/y<CR>").traceKeys == "cmdline…(10)")

for plain in ["ciw", "w", "b", "dd", "x", "p", "gg", "A", "S", "gU", "diw", "yy", "u"] {
    precondition(RawCommand(plain).traceKeys == plain, "needlessly redacted: " + plain)
}

// MARK: - Rejections and the reason that already existed

// 26 of the 27 rejection sites carry no reason, so the failing step's type is it.
let joinReject = traced("J", text: "a\nb", caret: 0, profile: blockProfile)
precondition(joinReject.plan == .rejected)
precondition(joinReject.rejection?.index == 0)
precondition(joinReject.rejection!.step.traceName == "joinLines(2)")

let markReject = traced("ma", profile: blindProfile)
precondition(markReject.plan == .rejected)
precondition(markReject.rejection!.step.traceName == "setMark")

precondition(traced("ciw", text: "say hello world", caret: 6, profile: axProfile).rejection == nil)
precondition(traced("ciw", text: "say hello world", caret: 6, profile: axProfile).plan == ciwA)

// The 27th: the lowering drops `BellReason`, but the logical plan still holds it.
func bellReason(_ keys: String) -> String? {
    for step in LogicalPlanner.plan(RawCommand(keys), state: .initial).steps {
        if case .bell(let reason) = step { return reason.traceName }
    }
    return nil
}
precondition(bellReason("gv") == "noPriorVisual")
precondition(bellReason("g-") == "unsupported")
precondition(bellReason("\"ap") == "emptyRegister")
precondition(bellReason("'a") == "unsetMark")
precondition(bellReason("ciw") == nil)

// MARK: - The settle's comparison

precondition(Expectation(selection: 4..<9, length: 15).traceFields == "sel=4..9 len=15")
precondition(Expectation().traceFields == "sel=nil len=nil")
// The settle line used to assemble these four fragments by hand; pinned so the one
// restructured line in `Diag` stays byte-identical.
precondition(
    " want \(Expectation(selection: 4..<9, length: 15).traceFields)"
        + " got \(Expectation(selection: 0..<0, length: 15).traceFields)"
        == " want sel=4..9 len=15 got sel=0..0 len=15"
)

precondition(Expectation().matches(selection: nil, length: nil), "a prediction of nothing is already met")
precondition(Expectation().matches(selection: 3..<4, length: 99), "unpredicted fields are not checked")
precondition(Expectation(selection: 4..<9).matches(selection: 4..<9, length: nil))
precondition(!Expectation(selection: 4..<9).matches(selection: 0..<0, length: nil), "disagreed")
precondition(!Expectation(selection: 4..<9).matches(selection: nil, length: nil), "no answer")
precondition(!Expectation(length: 15).matches(selection: nil, length: nil), "no answer")
precondition(Expectation(selection: 4..<9, length: 15).matches(selection: 4..<9, length: 15))
precondition(!Expectation(selection: 4..<9, length: 15).matches(selection: 4..<9, length: 14))

let checkedWord = Expectation(selection: 4..<9, length: 15, selectedText: "hello")
precondition(checkedWord.matches(selection: 4..<9, length: 15, selectedText: "hello"))
precondition(!checkedWord.matches(selection: 4..<9, length: 15, selectedText: "mber "), "offsets agree, text does not")
precondition(!checkedWord.matches(selection: 4..<9, length: 15), "no answer")
precondition(Expectation(selection: 4..<9).matches(selection: 4..<9, length: nil, selectedText: "mber "))
precondition(!Expectation(selectedText: "a\u{FFFC}b").matches(selection: nil, length: nil, selectedText: "ab"), "an attachment counts")
precondition(checkedWord.traceFields == "sel=4..9 len=15 text=(5)")
precondition(!Expectation(selectedText: secret).traceFields.contains(secret), "traceFields leaked the selected text")





print("Vim engine tests passed")
