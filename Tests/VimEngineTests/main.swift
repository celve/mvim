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
    .settle(Expectation(selection: 4..<9, length: 15, selectedText: "hello")),
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
    .settle(Expectation(selection: 4..<9, length: 15, selectedText: "hello")),
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
    .settle(Expectation(selection: 0..<4, length: 9, selectedText: "say ")),
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
    .settle(Expectation(selection: 0..<4, length: 7, selectedText: "one\n")),
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

// A cross-module string contract: `CapabilityConfig` seeds and stored beliefs name the raw value.
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

// MARK: - Native keys (nativeMotions)

func adding(_ extra: Set<Capability>, to profile: CapabilityProfile) -> CapabilityProfile {
    var statuses = profile.statuses
    for capability in extra { statuses[capability] = .available }
    return CapabilityProfile(statuses: statuses)
}
func removing(_ gone: Set<Capability>, from profile: CapabilityProfile) -> CapabilityProfile {
    var statuses = profile.statuses
    for capability in gone { statuses[capability] = .unavailable }
    return CapabilityProfile(statuses: statuses)
}
// The probe claims every native key where the caret reads.
let claimedKeys = Capability.nativeKeys
let lineKeys = claimedKeys.subtracting([.wordKeys, .paragraphKeys])
let nativeRead = adding(claimedKeys.union([.nativeMotions]), to: readProfile)
let nativeAX = adding(claimedKeys.union([.nativeMotions]), to: axProfile)
let nativeBlind = CapabilityProfile(available: [.nativeMotions])
let nativeBlockRead = adding(claimedKeys.union([.nativeMotions]), to: CapabilityProfile(available: [
    .readText, .readLength, .readCaret, .readSelectedText,
]))
func wordBlame(_ p: Int) -> Expectation.Blame { Expectation.Blame(capability: .wordKeys, unmoved: [p..<p]) }
func capped(_ expectation: Expectation, _ longest: Int) -> Expectation {
    var capped = expectation
    capped.longest = longest
    return capped
}
func kept(_ expectation: Expectation, _ slot: Int) -> Expectation {
    var kept = expectation
    kept.keeps = slot
    return kept
}
let spanBlame = Expectation.Blame(capability: .wordKeys, unmoved: [])
func proven(_ within: Range<Int>, length: Int) -> Expectation {
    var proven = capped(Expectation(landing: .between(0, 1), length: length, blame: spanBlame), within.count)
    proven.within = within
    return proven
}
func selectedBack(_ end: Landing, length: Int, within: Range<Int>) -> [PhysicalStep] {
    [.press(.wordRight, count: 1), .settle(kept(Expectation(landing: end, length: length), 1)),
     .press(.selectWordLeft, count: 1), .settle(proven(within, length: length))]
}
func moveBlame(_ atom: Capability, _ p: Int?) -> Expectation.Blame {
    Expectation.Blame(capability: atom, unmoved: p.map { [$0..<$0] } ?? [], leavesCaret: true)
}
func webMoveBlame(_ atom: Capability, _ p: Int?) -> Expectation.Blame {
    Expectation.Blame(capability: atom, unmoved: [], leavesCaret: true,
                      exemptions: p.map { [.init(.webContent, unmoved: [$0..<$0])] } ?? [])
}
let prose = "say hello world"
let nativeParagraphs = "alpha beta\ngamma delta\n\nepsilon zeta"

// With the option off, plans are unchanged.
let nativeCorpus = ["w", "3w", "e", "b", "ge", "W", "ciw", "diw", "yiw", "caw", "d2iw", "ciW", "dw", "d3w", "de",
                    "cw", "db", "yw", "}", "{", "3}", "gj", "gk", "<C-f>", "<C-b>", "d}", "x", "dd", "j", "k", "$"]
for base in [axProfile, readProfile, blindProfile, blockProfile, noInsertProfile] {
    for keys in nativeCorpus {
        precondition(
            physical(keys, text: prose + "\nnext line", caret: 6, profile: adding(claimedKeys, to: base))
                == physical(keys, text: prose + "\nnext line", caret: 6, profile: adding(lineKeys, to: base)),
            "claimed keys without nativeMotions changed \(keys)"
        )
    }
}
for keys in ["}", "{", "gj", "gk", "<C-f>", "<C-b>"] {
    precondition(physical(keys, text: nativeParagraphs, caret: 3, profile: adding(claimedKeys, to: readProfile)).steps == [.bell])
}

precondition(physical("w", text: prose, caret: 6, profile: nativeRead).steps == [
    .press(.wordRight, count: 1),
    .settle(Expectation(landing: .caretAfter(6, strict: true), length: 15, blame: moveBlame(.wordKeys, 6))),
    .commit(.setCursor(nil)),
])
precondition(physical("e", text: prose, caret: 6, profile: nativeRead) == physical("w", text: prose, caret: 6, profile: nativeRead))
precondition(physical("3w", text: prose, caret: 0, profile: nativeRead).steps.first == .press(.wordRight, count: 3))
precondition(physical("b", text: prose, caret: 6, profile: nativeRead).steps == [
    .press(.wordLeft, count: 1),
    .settle(Expectation(landing: .caretBefore(6, strict: true), length: 15, blame: moveBlame(.wordKeys, 6))),
    .commit(.setCursor(nil)),
])
precondition(physical("b", text: prose, caret: 0, profile: nativeRead).steps[1]
    == .settle(Expectation(landing: .caretBefore(0, strict: false), length: 15, blame: moveBlame(.wordKeys, nil))))
precondition(physical("w", text: prose, caret: 15, profile: nativeRead).steps[1]
    == .settle(Expectation(landing: .caretAfter(15, strict: false), length: 15, blame: moveBlame(.wordKeys, nil))))
precondition(physical("w", text: "ab\ncd\nef", caret: 6, profile: nativeRead).steps[1]
    == .settle(Expectation(landing: .caretAfter(6, strict: true), length: 8, blame: moveBlame(.wordKeys, 6))))
// In web content only a selection left behind is blamed.
func webPhysical(
    _ keys: String, text: String, caret: Int, profile: CapabilityProfile, breaks: ParagraphBreaks? = nil
) -> PhysicalPlan {
    PhysicalPlanner.plan(LogicalPlanner.plan(RawCommand(keys), state: .initial),
                         snapshot: FieldSnapshot(capabilities: profile, text: text, selection: caret..<caret, webContent: true,
                                                 breaks: breaks))
}
// In Chromium text content checks leave in field offsets, and a boundary caret names its side.
let chromiumBreak = ParagraphBreaks(offsets: [2])
precondition(webPhysical("w", text: "ab\ncd", caret: 3, profile: nativeRead, breaks: chromiumBreak).steps[1]
    == .settle(Expectation(landing: .caretAfter(2, strict: true), length: 5, blame: webMoveBlame(.wordKeys, 2))))
precondition(webPhysical("w", text: "ab\ncd", caret: 2, profile: nativeRead, breaks: chromiumBreak).steps[1]
    == .settle(Expectation(landing: .caretAfter(2, strict: false), length: 5, blame: moveBlame(.wordKeys, nil))))
let boundaryCiw = webPhysical("ciw", text: "ab\ncd", caret: 2, profile: nativeRead, breaks: chromiumBreak).steps
precondition(boundaryCiw[2] == .settle(kept(Expectation(landing: .exact(2..<2), length: 5, edge: .paragraphStart), 0)))
precondition(boundaryCiw[6] == .settle(kept(Expectation(landing: .exact(2..<2), length: 5, edge: .paragraphEnd), 1)))
precondition(webPhysical("w", text: "ab\ncd\nef", caret: 6, profile: nativeRead).steps[1]
    == .settle(Expectation(landing: .caretAfter(6, strict: true), length: 8, blame: webMoveBlame(.wordKeys, 6))))
precondition(webPhysical("ciw", text: prose, caret: 6, profile: nativeRead).steps.allSatisfy {
    guard case .settle(let expectation) = $0 else { return true }
    return expectation.checkedKey == nil
})
precondition(physical("w", text: "ab\ncd\nef", caret: 5, profile: nativeRead).steps[1]
    == .settle(Expectation(landing: .caretAfter(5, strict: true), length: 8, blame: moveBlame(.wordKeys, 5))))
precondition(physical("w", text: prose, selection: 4..<9, profile: nativeRead).steps.prefix(2)
    == [.press(.left, count: 1), .press(.wordRight, count: 1)])

let nativeCiw = physical("ciw", text: prose, caret: 4, profile: nativeRead)
precondition(nativeCiw.steps == [
    .press(.wordRight, count: 1),
    .press(.wordLeft, count: 1),
    .settle(kept(Expectation(landing: .caretBefore(4, strict: false), length: 15), 0)),
] + selectedBack(.caretAfter(4, strict: true), length: 15, within: 4..<9) + [
    .clipboardCut,
    .commit(.deleted(into: nil, content: .pasteboard, wise: .character)),
    .commit(.setMode(.insert)),
    .commit(.setInsertStart(nil)),
])
precondition(nativeCiw.mutatesText)
precondition(physical("diw", text: prose, caret: 8, profile: nativeRead).steps.suffix(3) == [
    .clipboardCut,
    .commit(.deleted(into: nil, content: .pasteboard, wise: .character)),
    .commit(.setCursor(nil)),
])
precondition(physical("yiw", text: prose, caret: 6, profile: nativeRead).steps.suffix(4) == [
    .clipboardCopy,
    .commit(.yanked(into: nil, content: .pasteboard, wise: .character)),
    .press(.left, count: 1),
    .commit(.setCursor(nil)),
])
precondition(physical("\"_diw", text: prose, caret: 6, profile: nativeRead).steps.suffix(2)
    == [.press(.deleteBack, count: 1), .commit(.setCursor(nil))])
// The character under the caret picks the keys, so no dictionary is needed.
let roundTripKeys: [PhysicalStep] = [.press(.wordRight, count: 1), .press(.wordLeft, count: 1)]
precondition(physical("ciw", text: prose, caret: 6, profile: nativeRead).steps.prefix(7) == roundTripKeys + [
    .settle(kept(Expectation(landing: .caretBefore(6, strict: false), length: 15), 0)),
] + selectedBack(.caretAfter(6, strict: true), length: 15, within: 4..<9))
precondition(physical("ciw", text: prose, caret: 9, profile: nativeRead).steps.prefix(9) == roundTripKeys + [
    .settle(kept(Expectation(landing: .exact(10..<10), length: 15), 0)),
    .press(.wordLeft, count: 1), .settle(kept(Expectation(landing: .caretBefore(9, strict: true), length: 15), 0)),
] + selectedBack(.exact(9..<9), length: 15, within: 4..<9))
precondition(physical("ciw", text: prose, caret: 15, profile: nativeRead).steps.prefix(7) == roundTripKeys + [
    .settle(kept(Expectation(landing: .caretBefore(15, strict: false), length: 15), 0)),
] + selectedBack(.exact(15..<15), length: 15, within: 10..<15))
precondition(physical("ciw", text: "今天天气很好", caret: 2, profile: nativeRead).steps.prefix(7) == roundTripKeys + [
    .settle(kept(Expectation(landing: .caretBefore(2, strict: false), length: 6), 0)),
] + selectedBack(.caretAfter(2, strict: true), length: 6, within: 0..<6))
precondition(physical("ciw", text: "one two\nthree four", caret: 13, profile: nativeRead).steps.prefix(9) == roundTripKeys + [
    .settle(kept(Expectation(landing: .exact(14..<14), length: 18), 0)),
    .press(.wordLeft, count: 1), .settle(kept(Expectation(landing: .caretBefore(13, strict: true), length: 18), 0)),
] + selectedBack(.exact(13..<13), length: 18, within: 8..<13))
for demoted in [Capability.lineStartKey, .lineEndKey] {
    precondition(physical("ciw", text: "abc def\nghi", caret: 7, profile: removing([demoted], from: nativeRead))
        == physical("ciw", text: "abc def\nghi", caret: 7, profile: nativeRead))
}
precondition(physical("ciw", text: "abc\n\ndef", caret: 3, profile: nativeRead).steps.prefix(9) == roundTripKeys + [
    .settle(kept(Expectation(landing: .exact(5..<5), length: 8), 0)),
    .press(.wordLeft, count: 1), .settle(kept(Expectation(landing: .caretBefore(3, strict: true), length: 8), 0)),
] + selectedBack(.exact(3..<3), length: 8, within: 0..<3))
for (text, caret) in [("   ", 1), ("a  b", 2), ("• b", 1), ("a\n\nb", 2)] {
    precondition(physical("ciw", text: text, caret: caret, profile: nativeRead).steps == [.bell], text)
}

precondition(physical("dw", text: prose, caret: 4, profile: nativeRead).steps == [
    .press(.wordRight, count: 1), .settle(kept(Expectation(landing: .caretAfter(4, strict: true), length: 15), 1)),
    .press(.wordLeft, count: 1), .settle(kept(Expectation(landing: .exact(4..<4), length: 15), 0)),
    .press(.selectWordRight, count: 1),
    .settle(proven(4..<9, length: 15)),
    .clipboardCut,
    .commit(.deleted(into: nil, content: .pasteboard, wise: .character)),
    .commit(.setCursor(nil)),
])
precondition(physical("dw", text: prose, caret: 6, profile: nativeRead).steps.prefix(2) == [
    .press(.selectWordRight, count: 1),
    .settle(Expectation(landing: .exact(6..<9), length: 15, blame: wordBlame(6))),
])
precondition(physical("d3w", text: prose, caret: 0, profile: nativeRead).steps.first == .press(.wordRight, count: 3))
precondition(physical("cw", text: prose, caret: 4, profile: nativeRead).steps.prefix(2)
    == physical("dw", text: prose, caret: 4, profile: nativeRead).steps.prefix(2))
precondition(physical("de", text: prose, caret: 4, profile: nativeRead).steps
    == physical("dw", text: prose, caret: 4, profile: nativeRead).steps)
precondition(physical("db", text: prose, caret: 9, profile: nativeRead).steps.prefix(6) == [
    .press(.wordLeft, count: 1), .settle(kept(Expectation(landing: .caretBefore(9, strict: true), length: 15), 0)),
    .press(.wordRight, count: 1), .settle(kept(Expectation(landing: .exact(9..<9), length: 15), 1)),
    .press(.selectWordLeft, count: 1),
    .settle(proven(4..<9, length: 15)),
])
precondition(physical("db", text: prose, caret: 8, profile: nativeRead).steps.first == .press(.selectWordLeft, count: 1))
precondition(physical("yw", text: prose, caret: 4, profile: nativeRead).steps.contains(.clipboardCopy))
precondition(physical("dw", text: "今天天气很好", caret: 2, profile: nativeRead).steps.prefix(6) == [
    .press(.wordRight, count: 1), .settle(kept(Expectation(landing: .caretAfter(2, strict: true), length: 6), 1)),
    .press(.wordLeft, count: 1), .settle(kept(Expectation(landing: .exact(2..<2), length: 6), 0)),
    .press(.selectWordRight, count: 1),
    .settle(proven(2..<6, length: 6)),
])
precondition(physical("db", text: "今天天气很好", caret: 4, profile: nativeRead).steps.prefix(6) == [
    .press(.wordLeft, count: 1), .settle(kept(Expectation(landing: .caretBefore(4, strict: true), length: 6), 0)),
    .press(.wordRight, count: 1), .settle(kept(Expectation(landing: .exact(4..<4), length: 6), 1)),
    .press(.selectWordLeft, count: 1),
    .settle(proven(0..<4, length: 6)),
])

for keys in ["caw", "d2iw", "ciW", "W", "dW", "ge", "x", "dd", "$", "dj", "yk", "+", "-"] {
    precondition(physical(keys, text: prose, caret: 6, profile: nativeRead)
        == physical(keys, text: prose, caret: 6, profile: adding(claimedKeys, to: readProfile)),
        "nativeMotions must leave \(keys) alone")
}
let wordsDemoted = removing([.wordKeys], from: nativeRead)
for keys in ["w", "b", "ciw", "dw", "db"] {
    precondition(physical(keys, text: prose, caret: 6, profile: wordsDemoted)
        == physical(keys, text: prose, caret: 6, profile: removing([.nativeMotions], from: wordsDemoted)),
        "demoted wordKeys must count \(keys)")
}
precondition(physical("}", text: nativeParagraphs, caret: 3, profile: removing([.paragraphKeys], from: nativeRead)).steps
    == [.bell])

precondition(physical("}", text: nativeParagraphs, caret: 3, profile: nativeRead).steps == [
    .press(.paragraphForward, count: 1),
    .settle(Expectation(
        landing: .caretAfter(3, strict: true), length: 36,
        blame: moveBlame(.paragraphKeys, 3)
    )),
    .commit(.setCursor(nil)),
])
precondition(physical("3{", text: nativeParagraphs, caret: 14, profile: nativeRead).steps.first
    == .press(.paragraphBackward, count: 3))
precondition(physical("}", text: nativeParagraphs, caret: 36, profile: nativeRead).steps[1]
    == .settle(Expectation(landing: .caretAfter(36, strict: false), length: 36, blame: moveBlame(.paragraphKeys, nil))))
precondition(physical("gj", text: nativeParagraphs, caret: 3, profile: nativeRead).steps == [
    .press(.down, count: 1),
    .settle(Expectation(landing: .caretAfter(3, strict: true), length: 36)),
    .commit(.setCursor(nil)),
])
precondition(physical("gk", text: nativeParagraphs, caret: 14, profile: nativeRead).steps[0...1] == [
    .press(.up, count: 1), .settle(Expectation(landing: .caretBefore(14, strict: true), length: 36)),
])
precondition(physical("<C-f>", text: nativeParagraphs, caret: 3, profile: nativeRead).steps[0...1] == [
    .press(.pageForward, count: 1), .settle(Expectation(landing: .caretAfter(3, strict: true), length: 36)),
])
precondition(physical("2<C-b>", text: nativeParagraphs, caret: 14, profile: nativeRead).steps.first
    == .press(.pageBackward, count: 2))
// `j`/`k` press ↓/↑ only once ⌃E/⌃A are demoted.
for keys in ["j", "3j", "k", "2k"] {
    precondition(physical(keys, text: nativeParagraphs, caret: 14, profile: nativeRead)
        == physical(keys, text: nativeParagraphs, caret: 14, profile: removing([.nativeMotions], from: nativeRead)), keys)
}
precondition(physical("j", text: nativeParagraphs, caret: 3, profile: removing([.lineEndKey], from: nativeRead)).steps == [
    .press(.down, count: 1),
    .settle(Expectation(landing: .caretAfter(3, strict: true), length: 36)),
    .commit(.setCursor(nil)),
])
precondition(physical("3k", text: nativeParagraphs, caret: 30, profile: removing([.lineStartKey], from: nativeRead)).steps[0...1] == [
    .press(.up, count: 3), .settle(Expectation(landing: .caretBefore(30, strict: true), length: 36)),
])
precondition(physical("k", text: nativeParagraphs, caret: 30, profile: removing([.lineEndKey], from: nativeRead))
    == physical("k", text: nativeParagraphs, caret: 30, profile: removing([.lineEndKey, .nativeMotions], from: nativeRead)))
precondition(physical("j", text: "one block", caret: 2, profile: nativeBlockRead)
    == physical("j", text: "one block", caret: 2, profile: removing([.nativeMotions], from: nativeBlockRead)))
// ⇧⌥↓ lands elsewhere than ⌥↓ (measured), so operators and Visual ring.
for keys in ["d}", "y{", "dgj", "d<C-f>"] {
    precondition(physical(keys, text: nativeParagraphs, caret: 3, profile: nativeRead).steps == [.bell], keys)
}
var nativeVisual = VimState.initial
nativeVisual.field.mode = .visual(VimState.VisualContext(kind: .character, anchor: 3))
precondition(PhysicalPlanner.plan(
    LogicalPlanner.plan(RawCommand("}"), state: nativeVisual),
    snapshot: FieldSnapshot(capabilities: nativeRead, text: nativeParagraphs, selection: 3..<4, anchor: 3)
).steps == [.bell])

for keys in ["w", "b", "e", "ciw", "dw", "db", "j", "k"] {
    precondition(physical(keys, text: prose, caret: 6, profile: nativeAX)
        == physical(keys, text: prose, caret: 6, profile: adding(claimedKeys, to: axProfile)), keys)
}
precondition(PhysicalPlanner.plan(
    LogicalPlanner.plan(RawCommand("}"), state: .initial),
    snapshot: FieldSnapshot(capabilities: nativeAX, text: nativeParagraphs, selection: 3..<4, cursor: 3..<4)
).steps == [
    .setSelection(3..<3),
    .press(.paragraphForward, count: 1),
    .settle(Expectation(
        landing: .caretAfter(3, strict: true), length: 36,
        blame: moveBlame(.paragraphKeys, 3)
    )),
    .commit(.setCursor(nil)),
])

precondition(physical("ciw", profile: nativeBlind).steps == [
    .press(.wordRight, count: 1),
    .press(.wordLeft, count: 1),
    .press(.selectWordRight, count: 1),
    .clipboardCut,
    .commit(.deleted(into: nil, content: .pasteboard, wise: .character)),
    .commit(.setMode(.insert)),
    .commit(.setInsertStart(nil)),
])
for keys in ["w", "b", "e", "dw", "db", "yw", "3j", "k"] {
    precondition(physical(keys, profile: nativeBlind) == physical(keys, profile: blindProfile), keys)
}
precondition(physical("}", profile: nativeBlind).steps == [.press(.paragraphForward, count: 1), .commit(.setCursor(nil))])
precondition(physical("3gj", profile: nativeBlind).steps == [.press(.down, count: 3), .commit(.setCursor(nil))])
precondition(physical("<C-b>", profile: nativeBlind).steps == [.press(.pageBackward, count: 1), .commit(.setCursor(nil))])

precondition(physical("}", text: "one block", caret: 2, profile: nativeBlockRead).steps
    == [.press(.paragraphForward, count: 1), .commit(.setCursor(nil))])
precondition(physical("w", text: "one block", caret: 0, profile: nativeBlockRead).steps[1]
    == .settle(Expectation(landing: .caretAfter(0, strict: true), length: 9, blame: moveBlame(.wordKeys, 0))))
precondition(physical("}", text: "one block", caret: 2, profile: adding(claimedKeys.union([.nativeMotions]), to: blockProfile)).steps
    == [.press(.paragraphForward, count: 1), .commit(.setCursor(nil))])

precondition(KeyNotation.token(keyCode: 3, chord: [.control], characters: controlCharacter("f"), profile: nativeRead) == "<C-f>")
precondition(KeyNotation.token(keyCode: 11, chord: [.control], characters: controlCharacter("b"), profile: nativeBlind) == "<C-b>")
precondition(KeyNotation.token(keyCode: 3, chord: [.control], characters: controlCharacter("f"), profile: readProfile) == nil)
precondition(KeyNotation.token(keyCode: 3, chord: [.control], characters: controlCharacter("f")) == nil)
precondition(KeyNotation.token(keyCode: 2, chord: [.control], characters: controlCharacter("d"), profile: nativeRead) == nil)

// `chromium`: reads fall short by one per paragraph break.
func keyedSim(_ text: String, caret: Int, profile: CapabilityProfile = nativeRead, chromium: Bool = false) -> Sim {
    var keyed = Sim(text: text, caret: caret, profile: profile)
    keyed.emulatesKeys = true
    keyed.reads = chromium ? omitsBreaks : nil
    return keyed
}
let nativeThreeParagraphs = "one two\nthree four\nfive six"
for (doc, word, carets) in [
    (prose, 4..<9, [4, 6, 8, 9]), ("abc def\nghi", 4..<7, [7]), ("\nx\ny", 1..<2, [1]),
    (nativeThreeParagraphs, 8..<13, [8, 10, 12, 13]), (nativeThreeParagraphs, 19..<23, [19, 21, 23]), (nativeThreeParagraphs, 14..<18, [18]),
] {
    for caret in carets {
        var keyed = keyedSim(doc, caret: caret)
        keyed.type("ciwX")
        keyed.feed("<Esc>")
        let context = "ciw at \(caret) in \(doc.debugDescription): \(keyed.text.debugDescription)"
        precondition(keyed.text == TextModel(doc).replacing(word, with: "X"), context)
        precondition(keyed.pasteboard == TextModel(doc).substring(word), context)
        precondition(keyed.settleFailures == 0 && keyed.unsupportedSteps == 0 && keyed.state.field.mode == .normal, context)
    }
    // Uncorrected Chromium reads: these carets get their word or nothing.
    for caret in carets {
        var misread = keyedSim(doc, caret: caret, chromium: true)
        misread.type("ciw")
        precondition(misread.pasteboard == nil ? misread.text == doc : misread.pasteboard == TextModel(doc).substring(word),
                     "ciw at \(caret) in \(doc.debugDescription) under Chromium's reads")
    }
}

for chromium in [false, true] {
    for (keys, caret, landing) in [("w", 10, 13), ("e", 10, 13), ("3w", 0, 13), ("b", 10, 8), ("}", 10, 18), ("{", 10, 8),
                                   ("2}", 1, 18), ("b", 8, 4)] {
        var keyed = keyedSim(nativeThreeParagraphs, caret: caret, chromium: chromium)
        keyed.type(keys)
        precondition(keyed.caret == landing && keyed.settleFailures == 0 && keyed.unsupportedSteps == 0,
                     "\(keys) from \(caret), chromium=\(chromium) landed \(keyed.caret)")
    }
}
var dwKeyed = keyedSim(prose, caret: 4)
dwKeyed.type("dw")
precondition(dwKeyed.text == "say  world" && dwKeyed.pasteboard == "hello" && dwKeyed.settleFailures == 0)
var dbKeyed = keyedSim(prose, caret: 9)
dbKeyed.type("db")
precondition(dbKeyed.text == "say  world" && dbKeyed.pasteboard == "hello")
var cwKeyed = keyedSim(nativeThreeParagraphs, caret: 8)
cwKeyed.type("cwX")
cwKeyed.feed("<Esc>")
precondition(cwKeyed.text == "one two\nX four\nfive six" && cwKeyed.settleFailures == 0)
var emptyLineKeyed = keyedSim("a\n\nb", caret: 2)
emptyLineKeyed.type("ciw")
precondition(emptyLineKeyed.text == "a\n\nb" && emptyLineKeyed.selection.isEmpty && emptyLineKeyed.bells == 1)

let wrappedProse = "alpha beta gamma delta\nnext line"
var rowKeyed = keyedSim(wrappedProse, caret: 3)
rowKeyed.wrapWidth = 8
rowKeyed.type("gj")
precondition(rowKeyed.caret == 11 && rowKeyed.settleFailures == 0)
rowKeyed.type("gk")
precondition(rowKeyed.caret == 3 && rowKeyed.settleFailures == 0)
let longText = (1...30).map { "line \($0)" }.joined(separator: "\n")
var pageKeyed = keyedSim(longText, caret: 0)
pageKeyed.type("\u{06}")
precondition(pageKeyed.caret == TextModel(longText).verticalMove(from: 0, by: 10, firstNonBlank: false)
             && pageKeyed.settleFailures == 0)
pageKeyed.type("\u{02}")
precondition(pageKeyed.caret == 0 && pageKeyed.settleFailures == 0)

var hopKeyed = keyedSim(wrappedProse, caret: 3)
hopKeyed.wrapWidth = 8
hopKeyed.type("j")
precondition(hopKeyed.caret == 26 && hopKeyed.settleFailures == 0)
var rowFallback = keyedSim(wrappedProse, caret: 3, profile: removing([.lineEndKey], from: nativeRead))
rowFallback.wrapWidth = 8
rowFallback.type("j")
precondition(rowFallback.caret == 11 && rowFallback.settleFailures == 0)

for (doc, caret, keys, ignored, atom) in [
    (nativeThreeParagraphs, 10, "w", Chord.wordRight, Capability.wordKeys), (prose, 4, "ciw", .selectWordLeft, .wordKeys),
    (nativeThreeParagraphs, 10, "}", .paragraphForward, .paragraphKeys),
] {
    var ignoring = keyedSim(doc, caret: caret)
    ignoring.ignoredChords = [ignored]
    ignoring.type(keys)
    precondition(ignoring.blamed == [atom] && ignoring.text == doc, "\(keys) ignoring \(ignored)")
}
var rebound = keyedSim(nativeThreeParagraphs, caret: 10)
rebound.reboundChords = [.wordRight: .selectAll]
rebound.type("w")
precondition(rebound.blamed == [.wordKeys] && rebound.text == nativeThreeParagraphs)
for (keys, caret) in [("ciw", 0), ("diw", 10), ("yiw", 14), ("dw", 0), ("db", 13)] {
    var grabbing = keyedSim(nativeThreeParagraphs, caret: caret)
    grabbing.reboundChords = [.selectWordRight: .selectAll, .selectWordLeft: .selectAll]
    grabbing.type(keys)
    precondition(grabbing.text == nativeThreeParagraphs && grabbing.pasteboard == nil && grabbing.selection.isEmpty
                 && (grabbing.blamed == [.wordKeys] || !keys.hasSuffix("iw")), keys)
}
// ← collapses a failed check's selection before typing.
var strandedKeyed = keyedSim(prose, caret: 4)
strandedKeyed.reboundChords = [.selectWordLeft: .selectAll]
strandedKeyed.type("ciwX")
precondition(strandedKeyed.text == "X" + prose && strandedKeyed.pasteboard == nil, strandedKeyed.text)
// Mid-word in a joined run a span rings; from a word's end it is proven.
precondition(physical("dw", text: "foo,bar", caret: 1, profile: nativeRead).steps == [.bell])
precondition(physical("db", text: "foo,bar", caret: 6, profile: nativeRead).steps == [.bell])
precondition(physical("dw", text: "foo,bar", caret: 3, profile: nativeRead).steps.prefix(6) == [
    .press(.wordRight, count: 1), .settle(kept(Expectation(landing: .caretAfter(3, strict: true), length: 7), 1)),
    .press(.wordLeft, count: 2), .press(.wordRight, count: 1),
    .settle(kept(Expectation(landing: .exact(3..<3), length: 7), 0)),
    .press(.selectWordRight, count: 1),
])
for (keys, caret) in [("dw", 3), ("dw", 4), ("db", 3), ("db", 4), ("ciw", 1), ("dw", 1)] {
    var reaching = keyedSim("foo,bar baz", caret: caret)
    reaching.reboundChords = [.selectWordRight: .selectLineEnd, .selectWordLeft: .selectAll]
    reaching.type(keys)
    precondition(reaching.text == "foo,bar baz" && reaching.pasteboard == nil && reaching.selection.isEmpty, "\(keys) at \(caret)")
}
var honestSpan = keyedSim("foo,bar", caret: 3)
honestSpan.type("dw")
precondition(honestSpan.text == "foo" && honestSpan.pasteboard == ",bar" && honestSpan.settleFailures == 0, honestSpan.text)
for (keys, caret) in [("ciw", 0), ("diw", 5), ("ciw", 7), ("dw", 0), ("db", 7)] {
    var grabbing = keyedSim("foo.bar", caret: caret)
    grabbing.reboundChords = [.selectWordRight: .selectAll, .selectWordLeft: .selectAll]
    grabbing.type(keys)
    precondition(grabbing.text == "foo.bar" && grabbing.pasteboard == nil && grabbing.selection.isEmpty, "\(keys) at \(caret) in one run")
}
// Raw reads may show a move into an empty paragraph as unmoved: it rings, unblamed.
for (keys, caret) in [("}", 2), ("gj", 2), ("gj", 3), ("{", 4), ("gk", 4)] {
    var empty = keyedSim("ab\n\ncd", caret: caret, chromium: true)
    empty.type(keys)
    precondition(empty.blamed.isEmpty, "\(keys) from \(caret) across an empty paragraph")
}
var gjIgnored = keyedSim(nativeThreeParagraphs, caret: 10)
gjIgnored.ignoredChords = [.down]
gjIgnored.type("gj")
precondition(gjIgnored.blamed.isEmpty && gjIgnored.settleFailures == 1)

// App `w` stops at a word's end, hence `ww` before `.`.
var dotKeyed = keyedSim("ab cd ef", caret: 0)
dotKeyed.type("ciwX")
dotKeyed.feed("<Esc>")
dotKeyed.type("ww.")
precondition(dotKeyed.text == "X X ef" && dotKeyed.settleFailures == 0, dotKeyed.text)

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

precondition(MarkerText.plain("See \u{FFFC}LIN-1234") == "See LIN-1234")
precondition(MarkerText.plainLength("\u{FFFC}\u{FFFC}Problem") == 7)
precondition(MarkerText.plainLength("a😀\u{FFFC}") == 3, "UTF-16 units, as the offsets are")
precondition(MarkerText.plain("") == "" && MarkerText.plainLength("") == 0)

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
    .settle(Expectation(selection: 5..<7, length: 11, edge: .paragraphEnd, selectedText: "ef")),
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
    .settle(Expectation(selection: 2..<4, length: 11, selectedText: "cd")),
    .replaceSelection(""),
    .settle(Expectation(selection: 2..<2, length: 8)),
    .commit(.deleted(into: nil, content: .literal("\ncd"), wise: .character)),
])
precondition(checkedTexts(paragraphPlanning("dd", text: threeParagraphs, caret: 4, profile: readProfile).plan) == ["cd ef"])
let pastPhantom = Expectation(selection: 0..<2, length: 6, edge: .paragraphStart, selectedText: "ab")
precondition(paragraphPlanning("dd", text: "ab\n\ncd", caret: 0, profile: readProfile).plan.steps.contains(.settle(pastPhantom)),
             "keys that stop before the break read the paragraph's end and fail it")

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
for edit in laneBEdits {
    for profile in [axProfile, noCursorProfile, noInsertProfile, blockProfile] {
        let plan = physical(edit.keys, text: twoLines, caret: edit.caret, profile: profile)
        precondition(plan == .rejected || checkedTexts(plan) == edit.text, "lane A must check the text \(edit.keys) replaces")
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
    escapeEngages: Bool = false,
    file: StaticString = #file,
    line: UInt = #line
) {
    let token = KeyNotation.token(keyCode: keyCode, chord: chord, characters: characters, escapeEngages: escapeEngages)
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
expectToken(53, [], "\u{1B}", nil)       // physical Esc is the app's unless chosen
expectToken(38, [.command], "j", nil)

expectToken(53, [], "\u{1B}", "<Esc>", escapeEngages: true)
expectToken(53, [.shift], "\u{1B}", "<Esc>", escapeEngages: true)
expectToken(53, [.option], "\u{1B}", nil, escapeEngages: true)
expectToken(53, [.command], "\u{1B}", nil, escapeEngages: true)
expectToken(53, [.control], "\u{1B}", "<C-[>")
expectToken(33, [.control], "\u{1B}", "<C-[>", escapeEngages: true)
expectToken(38, [], "j", "j", escapeEngages: true)

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
func gateAdmits(_ profile: CapabilityProfile) -> Set<Character> {
    Set(alphabet.filter {
        KeyNotation.token(keyCode: 0, chord: [.control], characters: controlCharacter($0), profile: profile) != nil
    })
}
func engineExecutes(_ profile: CapabilityProfile) -> Set<Character> {
    Set(alphabet.filter { letter in
        let command = RawCommand("<C-\(letter)>")
        guard command.isComplete else { return false }   // <C-w> never completes alone
        let plan = PhysicalPlanner.plan(
            LogicalPlanner.plan(command, state: .initial),
            snapshot: FieldSnapshot(capabilities: profile, text: "alpha beta\nsecond line\n", selection: 3..<3)
        )
        return plan.steps != [.bell]
    })
}
let everything = CapabilityProfile(available: Set(Capability.allCases))
let everythingButNative = CapabilityProfile(available: Set(Capability.allCases).subtracting([.nativeMotions]))
for profile in [everything, everythingButNative, blindProfile, CapabilityProfile(available: [.nativeMotions])] {
    precondition(
        gateAdmits(profile) == engineExecutes(profile),
        "⌃-allowlist drifted from what the engine executes: gate \(gateAdmits(profile).sorted()) vs engine \(engineExecutes(profile).sorted())"
    )
}
precondition(gateAdmits(everythingButNative) == Set("rv"), "expected ⌃r and ⌃v: \(gateAdmits(everythingButNative).sorted())")
precondition(gateAdmits(everything) == Set("rvfb"), "nativeMotions pages with ⌃f and ⌃b: \(gateAdmits(everything).sorted())")

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

// Esc cancels a pending command; idle, it is the app's in Normal and leaves Visual.
precondition(monitor.feed("d", mode: .normal) == .pending)
precondition(monitor.feed("<Esc>", mode: .normal) == .cancelled)
precondition(monitor.feed("<Esc>", mode: .normal) == .passthrough)
precondition(monitor.feed("/", mode: .normal) == .pending)
precondition(monitor.feed("<Esc>", mode: .normal) == .cancelled)
precondition(monitor.feed("i", mode: .visual) == .pending)
precondition(monitor.feed("<Esc>", mode: .visual) == .cancelled)
precondition(monitor.feed("<Esc>", mode: .visual) ==
    .command(RawMonitor.Completed(command: RawCommand("<Esc>"))))
precondition(monitor.feed("\u{1B}", mode: .normal) ==
    .command(RawMonitor.Completed(command: RawCommand("\u{1B}"))))

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

// <C-[> must complete insert, cancel pending, and dispatch alone, even idle in Normal.
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

var esc = Sim(text: "say hello world", caret: 4, profile: axProfile)
esc.type("vl")
esc.feed("<Esc>")
precondition(esc.state.field.mode == .normal && esc.selection == 5..<6)
esc.type("d")
esc.feed("<Esc>")
esc.type("x")
precondition(esc.text == "say hllo world")
esc.feed("<Esc>")
precondition(esc.text == "say hllo world" && esc.selection == 5..<6 && esc.state.field.mode == .normal)
precondition(esc.settleFailures == 0 && esc.bells == 0 && esc.unsupportedSteps == 0)

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
    let reachable = rung == Surface.everywhere
        || (rung.hasPrefix("web:")
            ? Surface(bundleID: "any", origin: String(rung.dropFirst(4))).rungs.contains(rung)
            : Surface(bundleID: rung).rungs.contains(rung))
    precondition(reachable, "no surface can ever produce seed rung \(rung)")
}

precondition(SurfaceLadder.seedEntry("nativeMotions", rungs: diaPageField.rungs, seeds: CapabilitySeeds.denied)
             == Surface.everywhere)
precondition(SurfaceLadder.seedEntry("nativeMotions", rungs: [], seeds: CapabilitySeeds.denied)
             == Surface.everywhere)
precondition(SurfaceLadder.seedEntry("wholeDocument", rungs: diaPageField.rungs, seeds: CapabilitySeeds.denied)
             == "web:notion.so")
precondition(SurfaceLadder.seedEntry("wholeDocument", rungs: diaChrome.rungs, seeds: CapabilitySeeds.denied) == nil)
precondition(!diaPageField.rungs.contains(Surface.everywhere))
precondition(!diaPageField.writableScopes.contains { $0.rung == Surface.everywhere })
precondition(Capability.nativeMotions.species == .policy && Capability.nativeMotions.parent == nil)

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

// One strike commits; `true` asks to persist and re-resolve.
let learnVersions = Versions(app: "1.49.1")
func committing(_ store: inout BeliefStore, _ capability: Capability, at rung: String = learnRung,
                under offsets: OffsetsAnswer = .value, versions: Versions = learnVersions) -> Bool {
    store.commit(broken: capability, at: rung, judgedUnder: offsets, versions: versions, provenance: Provenance(tag: "e1.c1"))
}
var trials = BeliefStore()
precondition(committing(&trials, .insertText))
precondition(!committing(&trials, .insertText) && !committing(&trials, .insertText))
func broken(_ store: BeliefStore, rung: String = learnRung, versions: Versions = learnVersions) -> Set<Capability> {
    store.resolve(rungs: [rung], rung: rung, versions: versions, chromium: false, children: true, userPinsOffsets: false).broken
}
precondition(broken(trials) == [.insertText])

var passed = RunAttribution()
passed.record(.replaceSelection(""))
passed.record(.settle(Expectation(selection: 4..<4)), passed: true, selection: 4..<4)
precondition(passed.evidence == [Evidence(.write(.insertText), .supports(nil), why: .settled, seen: .settle(1))])
for start in [BeliefStore(), trials] {
    var store = start
    let lesson = Learning.learn(
        store: &store, rung: learnRung, versions: learnVersions, model: ReadModel(answer: .value),
        observed: Learning.Observation(before: .value, source: .start), run: passed.evidence, overridden: { _ in false },
        provenance: Provenance(), tally: Tally()
    )
    precondition(store == start && !lesson.republish && lesson.committed == nil)
}

var perRung = BeliefStore()
precondition(committing(&perRung, .insertText) && committing(&perRung, .writeSelection) && committing(&perRung, .insertText, at: otherRung))
precondition(!committing(&perRung, .insertText) && !committing(&perRung, .insertText, at: otherRung))
precondition(broken(perRung) == [.insertText, .writeSelection] && broken(perRung, rung: otherRung) == [.insertText])

precondition(broken(perRung, versions: Versions(app: "1.50")).isEmpty)
precondition(committing(&perRung, .writeSelection, versions: Versions(app: "1.50")))
precondition(!perRung.beliefs.contains { $0.rung == learnRung && $0.appVersion == "1.49.1" })
precondition(perRung.beliefs.contains { $0.rung == otherRung }, "other rungs keep theirs")

var struck = RunAttribution()
struck.record(.setSelection(4..<9))
struck.record(.settle(Expectation(selection: 4..<9)), passed: false, selection: 0..<0)
precondition(struck.evidence == [Evidence(.write(.writeSelection), .refutes, why: .moved, seen: .settle(1))])
for overridden in [true, false] {
    var store = BeliefStore()
    let lesson = Learning.learn(
        store: &store, rung: learnRung, versions: learnVersions, model: ReadModel(answer: .value),
        observed: Learning.Observation(before: .value, source: .start), run: struck.evidence, overridden: { _ in overridden },
        provenance: Provenance(), tally: Tally()
    )
    precondition(overridden ? lesson.skip == .userOverride && store.beliefs.isEmpty
                 : lesson.committed == .writeSelection && lesson.republish && broken(store) == [.writeSelection])
}


// MARK: - The recorder's renderers

func traced(
    _ keys: String, text: String? = nil, caret: Int? = nil, profile: CapabilityProfile
) -> PhysicalPlanner.Planning {
    PhysicalPlanner.planning(
        LogicalPlanner.plan(RawCommand(keys), state: .initial),
        snapshot: FieldSnapshot(capabilities: profile, text: text, selection: caret.map { $0..<$0 })
    )
}

precondition(ciwA.traceShape == "W!!R!CCC")
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
]).traceGrid == "RT+p RL?? RC?? RS?? WS-l IT?? DC?? WD?? FS?? KA?? KE?? KT?? KB?? NM?? WK?? PK??")

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

// A rejection carries no reason, so the failing step's type is it.
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





// MARK: - Native keys in lane B

let keyProfile = CapabilityProfile(available: [
    .readText, .readLength, .readCaret, .readSelectedText, .wholeDocument,
    .lineStartKey, .lineEndKey, .documentStartKey, .documentEndKey,
])
precondition(Capability.nativeKeys.allSatisfy { $0.species == .mechanism && $0.parent == nil })
precondition(Capability.lineStartKey.rawValue == "lineStartKey")

func chords(_ plan: PhysicalPlan) -> [Chord] {
    plan.steps.flatMap { step -> [Chord] in
        switch step {
        case .press(let chord, let count): return Array(repeating: chord, count: count)
        default: return []
        }
    }
}

let keyedDD = physical("dd", text: "one\ntwo\nthree", caret: 5, profile: keyProfile)
precondition(keyedDD.traceShape == "P!P!P!!P?CC")
precondition(Array(keyedDD.steps[0...6]) == [
    .press(.paragraphStart, count: 1),
    .settle(Expectation(
        landing: .exact(4..<4), length: 13,
        blame: .init(capability: .lineStartKey, unmoved: [5..<5], leavesCaret: true, offTarget: true)
    )),
    .press(Chord.paragraphEnd.shifted, count: 1),
    .settle(Expectation(
        landing: .exact(4..<7), length: 13, blame: .init(capability: .lineEndKey, unmoved: [4..<4], offTarget: true)
    )),
    .press(.selectRight, count: 1),
    .settle(Expectation(selection: 4..<8, length: 13)),
    .settle(Expectation(selection: 4..<8, length: 13, selectedText: "two\n")),
])
// A delete checks the text the field selected; a yank within a line takes it, since Chromium's leaves out breaks.
precondition(keyedDD.steps.contains(.commit(.deleted(into: nil, content: .literal("two\n"), wise: .line))))
precondition(physical("y$", text: "one\ntwo", caret: 5, profile: keyProfile).steps
             .contains(.commit(.yanked(into: nil, content: .captured(CaptureSlot(id: 0)), wise: .character))))
precondition(physical("yy", text: "one\ntwo\nthree", caret: 5, profile: keyProfile).steps
             .contains(.commit(.yanked(into: nil, content: .literal("two\n"), wise: .line))))

let oneLine = "one two"
precondition(chords(physical("0", text: oneLine, caret: 5, profile: keyProfile)) == [.paragraphStart])
precondition(chords(physical("$", text: oneLine, caret: 1, profile: keyProfile)) == [.paragraphEnd])
precondition(chords(physical("D", text: oneLine, caret: 2, profile: keyProfile)) == [Chord.paragraphEnd.shifted, .deleteBack])
precondition(chords(physical("d0", text: oneLine, caret: 4, profile: keyProfile)) == [Chord.paragraphStart.shifted, .deleteBack])
precondition(chords(physical("cc", text: oneLine, caret: 2, profile: keyProfile))
             == [.paragraphStart, Chord.paragraphEnd.shifted, .deleteBack])
precondition(chords(physical("yy", text: oneLine, caret: 2, profile: keyProfile))
             == [.paragraphStart, Chord.paragraphEnd.shifted, .selectRight, .left])
precondition(chords(physical("gg", text: "one\ntwo", caret: 5, profile: keyProfile)) == [.documentStart])
precondition(chords(physical("G", text: "one\ntwo", caret: 1, profile: keyProfile)) == [.documentEnd, .paragraphStart])
precondition(chords(physical("j", text: "one\ntwo", caret: 1, profile: keyProfile)) == [.paragraphEnd, .right, .right])
precondition(chords(physical("dG", text: "one\ntwo", caret: 1, profile: keyProfile))
             == [.paragraphStart, Chord.documentEnd.shifted, .deleteBack])
let keyedO = physical("o", text: oneLine, caret: 2, profile: keyProfile)
precondition(chords(keyedO) == [.paragraphEnd] && keyedO.steps.contains(.typeText("\n")))
precondition(chords(physical("O", text: oneLine, caret: 2, profile: keyProfile))
             == [.paragraphStart, .paragraphStart, .left, .paragraphStart])
let webO = webPhysical("o", text: oneLine, caret: 2, profile: keyProfile)
precondition(chords(webO) == [.paragraphEnd] && webO.steps.contains(.clipboardInsert("\n"))
             && !webO.steps.contains(.typeText("\n")))
let webAbove = webPhysical("O", text: "ab\ncd", caret: 4, profile: keyProfile, breaks: ParagraphBreaks(offsets: [2])).steps
let pasted = webAbove.firstIndex(of: .clipboardInsert("\n"))!
precondition(chords(PhysicalPlan(steps: webAbove)) == [.paragraphStart, .paragraphStart, .left, .paragraphStart])
precondition(webAbove[pasted + 1] == .softSettle(Expectation(selection: nil, length: 6)))
precondition(webAbove[(pasted + 2)...].allSatisfy {
    guard case .settle(let expectation) = $0 else { return true }
    return expectation.length == nil && expectation.selection == nil
})
for (keys, text) in [("oZ", "ab\nZ\ncd"), ("OZ", "Z\nab\ncd")] {
    var sim = Sim(text: "ab\ncd", caret: 1, profile: keyProfile)
    sim.webContent = true
    sim.emulatesKeys = true
    sim.type(keys)
    precondition(sim.text == text && sim.state.session.register("\"") == nil, "\(keys) in web content")
}
precondition(webPhysical("g~j", text: "ab\ncd", caret: 0, profile: readProfile).steps.contains {
    guard case .clipboardInsert(let text?) = $0 else { return false }
    return text.contains("\n")
})
// `x` and `X` keep their checked select-then-delete: ⌦ or ⌫ would delete before any check, and join lines at an end.
precondition(chords(physical("x", text: oneLine, caret: 2, profile: keyProfile)) == [.selectRight, .deleteBack])
let longLine = "a\n" + String(repeating: "word ", count: 16) + "\ne"
precondition(chords(physical("dd", text: longLine, caret: 42, profile: keyProfile)).count == 4)
precondition(chords(physical("dd", text: longLine, caret: 42, profile: readProfile)).count == 122)

// A key the field lacks falls back to counting, exactly as before.
for keys in ["dd", "0", "$", "gg", "G", "j", "k", "D", "o", "O"] {
    for (missing, text) in [(Capability.lineStartKey, "one\ntwo"), (.lineEndKey, "one\ntwo"), (.documentEndKey, "one\ntwo")] {
        var profile = keyProfile
        profile.statuses[missing] = .unavailable
        let plan = physical(keys, text: text, caret: 5, profile: profile)
        let needs: [Capability: [Chord]] = [
            .lineStartKey: [.paragraphStart, Chord.paragraphStart.shifted],
            .lineEndKey: [.paragraphEnd, Chord.paragraphEnd.shifted],
            .documentEndKey: [.documentEnd, Chord.documentEnd.shifted],
        ]
        precondition(!chords(plan).contains { needs[missing]!.contains($0) }, "\(keys) pressed an unavailable key")
    }
}
// Counting presses what it always did; only the register now comes from the field.
precondition(chords(physical("dd", text: "one\ntwo", caret: 5, profile: readProfile))
             == chords(physical("dd", text: "one\ntwo", caret: 5, profile: CapabilityProfile(available: [
                 .readText, .readLength, .readCaret, .readSelectedText, .wholeDocument, .documentStartKey,
             ]))))

// Lane A keeps its exact writes.
for keys in ["dd", "yy", "cc", "D", "0", "$", "gg", "G", "o", "O", "x", "j", "k", "dj", "J", "p"] {
    var full = axProfile
    for key in Capability.nativeKeys { full.statuses[key] = .available }
    let plan = physical(keys, text: "one\ntwo\nthree", caret: 5, profile: full, state: putState)
    precondition(plan == physical(keys, text: "one\ntwo\nthree", caret: 5, profile: axProfile, state: putState), keys)
}

// The logical fixes the keys rely on, in every lane.
sim = Sim(text: "a\nb", caret: 2, profile: axProfile)
sim.type("O")
precondition(sim.text == "a\n\nb" && sim.caret == 2 && sim.state.field.mode == .insert)
sim = Sim(text: "abc\ndef", caret: 1, profile: axProfile)
sim.type("d$")
precondition(sim.text == "a\ndef")
precondition(sim.state.session.register("-") == .content(RegisterContent(text: "bc", wise: .character)))

// End to end against lane A: reading exact offsets, every run does what lane A did; reading Chromium's, which
// lane B cannot correct yet (LIN-1564), a run either does too, stops, or changes no text, and writes nothing else.
let keyedCommands: [[String]] = ["dd", "yy", "cc", "S", "D", "C", "d$", "c$", "y$", "d0", "c0", "0", "^", "$", "A",
    "I", "gg", "G", "o", "O", "j", "k", "+", "-", "2dd", "3dd", "2yy", "dj", "dk", "yk", "cj", "ck", "dG", "dgg", "J",
    "3J", "2j", "3k", "2$", "d2$", "x", "X", "3x"].map { [$0] } + [["yy", "p"], ["yy", "P"], ["dd", "p"], ["dd", "P"]]
for doc in ["alpha one\nbeta two\ngamma three\n\ndelta four\nepsilon", "  indented\n\tx y\nlast", "single line", "a\n",
            "  indented\nx\n\n\nlast", "\nb\n\nc"] {
    for caret in 0...doc.utf16.count {
        for commands in keyedCommands {
            var reference = Sim(text: doc, caret: caret, profile: axProfile)
            var passedThrough = [doc]
            for command in commands {
                reference.type(command)
                passedThrough.append(reference.text)
            }
            for chromium in [false, true] {
                var keyed = Sim(text: doc, caret: caret, profile: keyProfile)
                keyed.emulatesKeys = true
                keyed.reads = chromium ? omitsBreaks : nil
                commands.forEach { keyed.type($0) }
                let keys = commands.joined()
                let context = "\(keys) at \(caret) in \(doc.debugDescription), chromium=\(chromium)"
                precondition(keyed.unsupportedSteps == 0, context)
                let register = keyed.state.session.register("\"")
                let same = keyed.text == reference.text && keyed.caret == reference.caret
                    && keyed.state.field.mode == reference.state.field.mode
                    && register == reference.state.session.register("\"") && keyed.bells == reference.bells
                precondition(same || chromium, context)
                // Counted edits plan from lane B's own reading of the caret, as on `main`; where the characters
                // happen to agree, the text check passes them too.
                if same || ["x", "X", "3x"].contains(keys) { continue }
                precondition(passedThrough.contains(keyed.text), context)
                precondition([nil, reference.state.session.register("\"")].contains(register), context)
                precondition(keyed.settleFailures > 0 || keyed.text == doc && register == nil, context)
            }
        }
    }
}

// Where a misread passes every offset settle, the selected text stops the edit: Chromium reads 4 as 1 (`b`), and
// 10 as 8 (`g`).
for (text, caret, keys, planned) in [("\nb\n\nc", 4, "cc", "b"), ("ab\ncdef\nghij", 10, "x", "g")] {
    sim = Sim(text: text, caret: caret, profile: keyProfile)
    sim.emulatesKeys = true
    sim.reads = omitsBreaks
    sim.type(keys)
    precondition(sim.text == text && sim.state.field.mode == .normal && checkedText(sim.abortedStep) == planned, keys)
}
// A register without its newline (the last line, `cc`) still puts whole lines, in every lane.
for profile in [axProfile, keyProfile] {
    sim = Sim(text: "alpha\nbeta", caret: 7, profile: profile)
    sim.emulatesKeys = true
    sim.type("yy")
    sim.type("2p")
    precondition(sim.text == "alpha\nbeta\nbeta\nbeta")
}

// Past paragraph 1 Chromium's raw reads are one low per break, and the first key's settle stops `j`.
sim = Sim(text: "ab\ncdef\nghij", caret: 5, profile: keyProfile)
sim.emulatesKeys = true
sim.reads = omitsBreaks
sim.type("j")
precondition(sim.settleFailures == 1 && sim.text == "ab\ncdef\nghij")

// Wrapped paragraphs: ↓ and ⌘← move by visual row; ⌃E→ by logical line.
let wrapped = "alpha beta gamma delta\nnext line"
sim = Sim(text: wrapped, caret: 3, profile: keyProfile)
sim.emulatesKeys = true
sim.wrapWidth = 8
sim.type("j")
precondition(sim.caret == 26 && sim.settleFailures == 0)
sim = Sim(text: wrapped, caret: 3, profile: readProfile)
sim.emulatesKeys = true
sim.wrapWidth = 8
sim.type("j")
precondition(sim.settleFailures == 1 && TextModel(wrapped).lineStart(of: sim.caret) == 0)

// A key that does nothing is blamed, and so is one that lands elsewhere.
for (ignored, blamed) in [(Chord.paragraphStart, Capability.lineStartKey), (Chord.paragraphEnd.shifted, .lineEndKey)] {
    sim = Sim(text: "one\ntwo", caret: 5, profile: keyProfile)
    sim.emulatesKeys = true
    sim.ignoredChords = [ignored]
    sim.type("dd")
    precondition(sim.blamed == [blamed] && sim.text == "one\ntwo")
}
sim = Sim(text: "one\ntwo", caret: 5, profile: keyProfile)
sim.emulatesKeys = true
sim.reboundChords = [.paragraphStart: .selectAll]
sim.type("dd")
precondition(sim.blamed == [.lineStartKey] && sim.text == "one\ntwo")
for web in [false, true] {
    sim = Sim(text: "the cat", caret: 4, profile: keyProfile)
    sim.emulatesKeys = true
    sim.webContent = web
    sim.reboundChords = [.paragraphStart: .paragraphEnd]
    sim.type("0")
    precondition(sim.blamed == [.lineStartKey] && sim.caret == 7, "a ⌃A that acts as ⌃E, web \(web)")
}
// In web content a key that did nothing is blamed where the reads are exact, as in a textarea.
sim = Sim(text: "the cat", caret: 4, profile: keyProfile)
sim.emulatesKeys = true
sim.webContent = true
sim.ignoredChords = [.paragraphStart]
sim.type("0")
precondition(sim.settleFailures == 1 && sim.blamed == [.lineStartKey] && sim.text == "the cat")
func webBlame(_ keys: String, caret: Int, breaks: ParagraphBreaks) -> Expectation.Blame? {
    webPhysical(keys, text: "ab\ncdef", caret: caret, profile: keyProfile, breaks: breaks).steps.lazy.compactMap {
        guard case .settle(let expectation) = $0 else { return nil }
        return expectation.blame
    }.first
}
// With paragraph reads too, beside a `<br>` as well, except from a caret in an empty paragraph, which `AXValue` can
// leave out and read beside.
precondition(webBlame("0", caret: 5, breaks: ParagraphBreaks(offsets: [2]))?.unmoved == [4..<4])
precondition(webBlame("0", caret: 5, breaks: ParagraphBreaks(offsets: []))?.unmoved == [5..<5])
precondition(webBlame("0", caret: 2, breaks: ParagraphBreaks(offsets: []))?.unmoved == [2..<2])
precondition(webBlame("$", caret: 3, breaks: ParagraphBreaks(offsets: []))?.unmoved == [3..<3])
let fromEmptyParagraph = PhysicalPlanner.plan(LogicalPlanner.plan(RawCommand("0"), state: .initial), snapshot: FieldSnapshot(
    capabilities: keyProfile, text: "ab\ncdef", selection: 2..<2, webContent: true, breaks: ParagraphBreaks(offsets: []),
    caretInEmptyParagraph: true
))
precondition(fromEmptyParagraph.steps.contains {
    guard case .settle(let expectation) = $0 else { return false }
    return expectation.blame?.unmoved == [] && expectation.blame?.leavesCaret == true
})
// A landing that is right with a length that is not blames nothing: the key did its part.
precondition(Expectation(landing: .exact(0..<0), length: 7, blame: .init(capability: .lineStartKey, unmoved: [4..<4],
    leavesCaret: true, offTarget: true)).blamed(observed: 0..<0) == nil)
// Rich text is where a working key lands off the model's line, so only there a landing elsewhere teaches nothing.
precondition(webBlame("0", caret: 5, breaks: ParagraphBreaks(offsets: [2]))?.offTarget == false)
precondition(webPhysical("0", text: "the cat", caret: 4, profile: keyProfile).steps.contains {
    guard case .settle(let expectation) = $0 else { return false }
    return expectation.blame?.offTarget == true
})
sim = Sim(text: "one\ntwo", caret: 5, profile: keyProfile)
sim.emulatesKeys = true
sim.webContent = true
sim.reboundChords = [.paragraphStart: .selectAll]
sim.type("dd")
precondition(sim.blamed == [.lineStartKey] && sim.text == "one\ntwo")
// Elsewhere reads are exact: a key that did nothing is blamed wherever it had somewhere to go.
for (text, caret, keys, ignored, blamed) in [
    ("one\ntwo", 5, "$", Chord.paragraphEnd, Capability.lineEndKey), ("one\ntwo", 4, "$", .paragraphEnd, .lineEndKey),
    ("the cat", 4, "0", .paragraphStart, .lineStartKey), ("ab\ncdef\nghij", 6, "0", .paragraphStart, .lineStartKey),
] {
    sim = Sim(text: text, caret: caret, profile: keyProfile)
    sim.emulatesKeys = true
    sim.ignoredChords = [ignored]
    sim.type(keys)
    precondition(sim.blamed == [blamed], "\(keys) at \(caret) in \(text.debugDescription)")
}
sim = Sim(text: "one\ntwo", caret: 4, profile: keyProfile)
sim.emulatesKeys = true
sim.ignoredChords = [.paragraphStart]
sim.type("0")
precondition(sim.blamed.isEmpty && sim.settleFailures == 0, "⌃A at a line start has nowhere to go")

// Relational landings, for keys whose landing the app decides.
precondition(Landing.caretAfter(4, strict: true).matches(5..<5) && !Landing.caretAfter(4, strict: true).matches(4..<4))
precondition(Landing.caretBefore(4, strict: false).matches(4..<4) && !Landing.caretBefore(4, strict: false).matches(2..<3))
precondition(Expectation(landing: .caretAfter(2, strict: true)).traceFields == "sel=>2 len=nil")

// MARK: - The belief model

let supportsValue = Evidence.offsets(.supports(.value), .plainIsValue)
let supportsTextContent = Evidence.offsets(.supports(.textContent), .plainIsTextContent)
for answer in OffsetsAnswer.allCases {
    for newEngine in [false, true] {
        precondition(answer.next(.neutral, newEngine: newEngine) == answer)
        precondition(answer.next(.refutes, newEngine: newEngine) == .untrusted)
        precondition(answer.next(supportsTextContent.outcome, newEngine: newEngine) == .textContent, "textContent fits again from \(answer)")
    }
    precondition(answer.next(supportsValue.outcome, newEngine: true) == .value)
}
precondition(OffsetsAnswer.value.next(supportsValue.outcome, newEngine: false) == .value)
precondition(OffsetsAnswer.textContent.next(supportsValue.outcome, newEngine: false) == .untrusted, "value needs a new engine")
precondition(OffsetsAnswer.untrusted.next(supportsValue.outcome, newEngine: false) == .untrusted)

// In "ab\ncd" a caret before `d` is 4 in `AXValue` and 3 without the break.
let beforeD = MarkerReads(breaks: ParagraphBreaks(offsets: [2]), value: 4..<4)
precondition(FieldReads(text: "ab\ncd", plain: 3..<3, markers: beforeD).evidence(current: .value) == supportsTextContent)
precondition(FieldReads(text: "ab\ncd", plain: 4..<4, markers: beforeD).evidence(current: .textContent) == supportsValue)
precondition(FieldReads(text: "ab\ncd", plain: 0..<0, markers: beforeD).evidence(current: .textContent) == .offsets(.neutral, .boundarySnap))
precondition(FieldReads(text: "ab\ncd", plain: 1..<1, markers: MarkerReads(breaks: ParagraphBreaks(offsets: [2]), value: 1..<1))
    .evidence(current: .value) == .offsets(.neutral, .noBreaks))
precondition(FieldReads(text: "ab\ncd", plain: 3..<3).evidence(current: .value) == nil, "a caret without markers compares nothing")
precondition(FieldReads(text: "ab\ncd", plain: 3..<3, markers: MarkerReads(breaks: nil, value: nil)).evidence(current: .textContent) == nil)
// A list marker the side read skips is no break.
let listItem = ParagraphBreaks(value: "• ab\n• cd", fieldText: "• ab• cd")!
precondition(FieldReads(text: "• ab\n• cd", plain: 6..<6, markers: MarkerReads(breaks: listItem, value: 7..<7))
    .evidence(current: .textContent) == supportsTextContent)

let cd = MarkerReads(breaks: ParagraphBreaks(offsets: [2]), value: 3..<5)
precondition(FieldReads(text: "ab\ncd", plain: 2..<4, selectedText: "cd", markers: cd).evidence(current: .value) == supportsTextContent)
precondition(FieldReads(text: "ab\ncd", plain: 2..<4, selectedText: "cd").selectedTextEvidence(current: .value) == .offsets(.refutes, .selectedText),
             "with value the only candidate, a mismatch fits nothing")
precondition(FieldReads(text: "ab\ncd", plain: 2..<4, selectedText: "cd").selectedTextEvidence(current: .textContent) == .offsets(.neutral, .unaligned))
precondition(FieldReads(text: "ab\ncd", plain: 3..<5, selectedText: "cd").selectedTextEvidence(current: .value) == .offsets(.neutral, .textAgrees))
precondition(FieldReads(text: "ab\ncd", plain: 3..<5, selectedText: "c\u{FFFC}d").selectedTextEvidence(current: .value) == .offsets(.neutral, .textAgrees),
             "Chromium's U+FFFC for a leaf with no text is no disagreement")
precondition(FieldReads(text: "ab\nab", plain: 2..<4, selectedText: "\na", markers: MarkerReads(breaks: ParagraphBreaks(offsets: [2]), value: 3..<5))
    .evidence(current: .textContent) == .offsets(.refutes, .readsDisagree))
precondition(FieldReads(text: "ab\ncd", plain: 2..<4, selectedText: "zz", markers: cd).evidence(current: .textContent) == .offsets(.refutes, .selectedText),
             "a selected-text misfit outranks the offsets")
precondition(FieldReads(text: "ab", plain: 0..<1, selectedText: "a", markers: MarkerReads(breaks: nil, value: nil))
    .interpreted(under: .textContent) == (nil, ParagraphBreaks(), false, false))
precondition(FieldReads(text: "ab", plain: 0..<1).interpreted(under: .untrusted) == (nil, nil, false, false))

var sampling = OffsetsSampling()
precondition(!sampling.samples(text: "ab", plain: 1..<1) && !sampling.samples(text: "ab\ncd", plain: nil))
precondition(!sampling.samples(text: "ab\ncd", plain: 1..<1), "a plain read before the first newline is paragraph 1's under any count")
precondition(sampling.samples(text: "ab\ncd", plain: 2..<2) && sampling.samples(text: "ab\ncd", plain: 0..<2))
sampling.sampled(markers: true, evidence: .offsets(.neutral, .noBreaks), text: "ab\ncd", plain: 0..<2)
precondition(sampling.remaining == OffsetsSampling.budget, "a silence at paragraph 1's end costs nothing")
for _ in 1..<OffsetsSampling.budget {
    sampling.sampled(markers: true, evidence: .offsets(.neutral, .noBreaks), text: "ab\ncd", plain: 3..<3)
    precondition(sampling.samples(text: "ab\ncd", plain: 3..<3))
}
sampling.sampled(markers: true, evidence: nil, text: "ab\ncd", plain: 4..<4)
precondition(!sampling.samples(text: "ab\ncd", plain: 3..<3))
var informed = OffsetsSampling()
informed.sampled(markers: true, evidence: supportsValue, text: nil, plain: nil)
var markerless = OffsetsSampling()
markerless.sampled(markers: false, evidence: nil, text: nil, plain: nil)
precondition(!informed.samples(text: "ab\ncd", plain: 3..<3) && !markerless.samples(text: "ab\ncd", plain: 3..<3))

func resolving(_ store: BeliefStore, starting: OffsetsAnswer = .value, versions: Versions = learnVersions,
               pins: Bool = false, children: Bool = true) -> ResolvedBeliefs {
    store.resolve(rungs: diaPageField.rungs, rung: learnRung, versions: versions, chromium: starting == .textContent,
                  children: children, userPinsOffsets: pins)
}
var dependent = BeliefStore()
precondition(committing(&dependent, .writeSelection))
precondition(resolving(dependent).broken == [.writeSelection] && resolving(dependent).reopened.isEmpty)
let reopenedAtStart = resolving(dependent, starting: .textContent)
precondition(reopenedAtStart.broken.isEmpty && reopenedAtStart.reopened.map(\.question) == [.write(.writeSelection)])
precondition(dependent.record(offsets: .textContent, at: learnRung, versions: learnVersions, provenance: Provenance(), tally: Tally()))
let learnedTextContent = resolving(dependent)
precondition(learnedTextContent.readModel.answer == .textContent && learnedTextContent.readModel.source == .learned)
precondition(learnedTextContent.broken.isEmpty, "a verdict judged under value reopens when its rung learns textContent")
precondition(committing(&dependent, .writeSelection, under: .textContent), "a new strike re-judges it under the answer in force")
precondition(resolving(dependent).broken == [.writeSelection])
precondition(dependent.record(offsets: .untrusted, at: learnRung, versions: learnVersions, provenance: Provenance(), tally: Tally()))
precondition(resolving(dependent).broken.isEmpty && resolving(dependent).reopened.map(\.question) == [.write(.writeSelection)],
             "any change of the offsets answer reopens what the old one judged")
var judgedUntrusted = dependent
precondition(committing(&judgedUntrusted, .writeSelection, under: .untrusted) && resolving(judgedUntrusted).broken == [.writeSelection])
precondition(!dependent.record(offsets: .untrusted, at: learnRung, versions: learnVersions, provenance: Provenance(tag: "e9.c9"), tally: Tally()))
precondition(dependent.offsetsBelief(at: learnRung)?.provenance.tag == nil, "a read model that stood is not rewritten")

let upgraded = resolving(dependent, versions: Versions(app: learnVersions.app, engine: "42"))
precondition(upgraded.readModel.answer == .value && upgraded.readModel.source == .start && upgraded.readModel.newEngine)
let pinned = resolving(dependent, starting: .textContent, pins: true)
precondition(pinned.readModel.answer == .textContent && pinned.readModel.source == .user)
precondition(dependent.forget(.offsets, at: learnRung) && resolving(dependent).readModel.source == .start)

var anchored = BeliefStore()
precondition(anchored.record(offsets: .textContent, at: learnRung, anchor: true, versions: learnVersions, provenance: Provenance(), tally: Tally()))
precondition(resolving(anchored).readModel == ReadModel(answer: .value, belief: anchored.offsetsBelief(at: learnRung)))
precondition(resolving(anchored, starting: .textContent).readModel.answer == .textContent)
precondition(resolving(anchored, versions: Versions(app: "1.50")).readModel.newEngine)

var richSibling = BeliefStore()
precondition(richSibling.record(offsets: .untrusted, at: learnRung, versions: learnVersions, provenance: Provenance(), tally: Tally()))
let textareaBeside = resolving(richSibling, children: false)
precondition(textareaBeside.readModel.answer == .value && textareaBeside.readModel.source == .plain
             && textareaBeside.readModel.learned == .untrusted)
precondition(textareaBeside.traceLines.last?.hasSuffix(" not-this-field") == true)
precondition(CapabilityResolver.resolve(probed: axProfile, config: [:], beliefs: textareaBeside).profile.has(.readCaret))
precondition(ReadModel(answer: .value, learned: .textContent).reading(chromium: true, children: false) == (.value, .plain))
precondition(ReadModel(answer: .value, learned: .textContent).reading(chromium: false, children: true) == (.textContent, .learned))
precondition(ReadModel(answer: .value, pinned: true).reading(chromium: true, children: true) == (.textContent, .user))

let migrated = BeliefStore(demotions: [(learnRung, "1.49.1", "writeSelection"), (learnRung, "1.49.1", "noSuchAtom")])
precondition(migrated.beliefs.count == 1 && migrated.beliefs[0].judgedUnder == .value && migrated.beliefs[0].provenance.tag == "migrated")
precondition(resolving(migrated).broken == [.writeSelection] && resolving(migrated, starting: .textContent).broken.isEmpty)

func lesson(_ store: inout BeliefStore, model: ReadModel, snapshot: (OffsetsAnswer, Evidence?, OffsetsAnswer),
            source: OffsetsSource = .start, run: [Evidence] = []) -> Learning.Lesson {
    let observed = Learning.Observation(before: snapshot.0, source: source, evidence: snapshot.1, after: snapshot.2)
    return Learning.learn(store: &store, rung: learnRung, versions: learnVersions, model: model, observed: observed, run: run,
                          overridden: { _ in false }, provenance: Provenance(tag: "e2.c5"), tally: Tally())
}
var observed = BeliefStore()
let moved = lesson(&observed, model: ReadModel(answer: .value), snapshot: (.value, supportsTextContent, .textContent))
precondition(moved.move == Learning.Move(from: .value, to: .textContent, why: .plainIsTextContent) && moved.recorded && moved.republish)
precondition(observed.offsetsBelief(at: learnRung)?.provenance.tag == "e2.c5")
var confirming = BeliefStore()
let dated = lesson(&confirming, model: ReadModel(answer: .textContent), snapshot: (.textContent, supportsTextContent, .textContent))
precondition(dated.move == nil && dated.recorded && dated.republish && confirming.offsetsBelief(at: learnRung)?.anchor == true)
let againDated = lesson(&confirming, model: ReadModel(answer: .textContent, belief: confirming.offsetsBelief(at: learnRung)),
                        snapshot: (.textContent, supportsTextContent, .textContent))
precondition(!againDated.recorded && !againDated.republish)
var valueConfirmed = BeliefStore()
precondition(!lesson(&valueConfirmed, model: ReadModel(answer: .value), snapshot: (.value, supportsValue, .value)).recorded
             && valueConfirmed.beliefs.isEmpty, "value needs no date")
var textChecked = RunAttribution()
textChecked.record(.setSelection(0..<4))
textChecked.record(.settle(Expectation(selection: 0..<4, length: 7, selectedText: "one\n")), passed: false,
                   selection: 0..<4, length: 7, selectedText: "two\n")
precondition(textChecked.evidence == [.offsets(.refutes, .textCheck, seen: .settle(1))], "the offsets answer for a text mismatch, not the write")
var mismatched = BeliefStore()
let charged = lesson(&mismatched, model: ReadModel(answer: .value), snapshot: (.value, nil, .value), run: textChecked.evidence)
precondition(charged.move == Learning.Move(from: .value, to: .untrusted, why: .textCheck) && charged.committed == nil)
var userPinned = BeliefStore()
precondition(lesson(&userPinned, model: ReadModel(answer: .value, source: .user, pinned: true), snapshot: (.value, nil, .value),
                    source: .user, run: textChecked.evidence).move == nil && userPinned.beliefs.isEmpty, "a user override pins the answer")
var plainField = BeliefStore()
precondition(lesson(&plainField, model: ReadModel(answer: .value, source: .plain), snapshot: (.value, nil, .value),
                    source: .plain, run: textChecked.evidence).move == nil && plainField.beliefs.isEmpty,
             "a field with no children has no breaks to learn about")
var wrongRange = RunAttribution()
wrongRange.record(.setSelection(0..<4))
wrongRange.record(.settle(Expectation(selection: 0..<4, length: 7, selectedText: "one\n")), passed: false,
                  selection: 1..<5, length: 7, selectedText: "ne\nt")
precondition(wrongRange.evidence == [Evidence(.write(.writeSelection), .refutes, why: .moved, seen: .settle(1))])
var unanswered = RunAttribution()
unanswered.record(.setSelection(0..<4))
unanswered.record(.settle(Expectation(selection: 0..<4, length: 7, selectedText: "one\n")), passed: false,
                  selection: 0..<4, length: 7, selectedText: nil)
precondition(unanswered.evidence.isEmpty)
var sideOnly = RunAttribution()
sideOnly.record(.settle(Expectation(selection: 0..<4, length: 7, edge: .paragraphEnd, selectedText: "one")), passed: false,
                selection: 0..<4, length: 7, selectedText: "one")
precondition(sideOnly.evidence.isEmpty)

let offLine = Expectation(landing: .exact(4..<4), blame: Expectation.Blame(
    capability: .lineStartKey, unmoved: [], leavesCaret: true, exemptions: [.init(.paragraphLines, offTarget: true)]))
func judged(_ expectation: Expectation, _ observed: Range<Int>) -> Evidence? {
    var run = RunAttribution()
    run.record(.settle(expectation), passed: false, selection: observed)
    return run.evidence.first
}
func key(_ capability: Capability, _ outcome: Evidence.Outcome, _ why: Evidence.Why) -> Evidence {
    Evidence(.key(capability), outcome, why: why, seen: .settle(0))
}
precondition(judged(offLine, 2..<2) == key(.lineStartKey, .neutral, .paragraphLines) && offLine.blamed(observed: 2..<2) == nil)
precondition(judged(offLine, 2..<5) == key(.lineStartKey, .refutes, .leftSelection), "a selection left behind is still blamed")
precondition(judged(offLine, 4..<4) == nil)
let fromEmpty = Expectation(landing: .exact(7..<7), blame: Expectation.Blame(
    capability: .lineEndKey, unmoved: [], exemptions: [.init(.emptyParagraph, unmoved: [5..<5])]))
precondition(judged(fromEmpty, 5..<5) == key(.lineEndKey, .neutral, .emptyParagraph) && judged(fromEmpty, 6..<6) == nil)
var webWord = Expectation(landing: .exact(0..<3), blame: Expectation.Blame(
    capability: .wordKeys, unmoved: [0..<0], exemptions: [.init(.webContent, all: true)]))
webWord.longest = 3
precondition(webWord.blamed(observed: 0..<0) == nil && webWord.checkedKey == nil)
precondition(judged(webWord, 0..<5) == key(.wordKeys, .neutral, .webContent) && judged(webWord, 1..<2) == nil)
var neutralRun = RunAttribution()
neutralRun.record(.press(.paragraphStart, count: 1))
neutralRun.record(.settle(offLine), passed: false, selection: 2..<2)
precondition(neutralRun.evidence == [Evidence(.key(.lineStartKey), .neutral, why: .paragraphLines, seen: .settle(1))])
let chipLine = webPhysical("0", text: "ab\ncd", caret: 4, profile: keyProfile, breaks: chromiumBreak)
precondition(chipLine.steps.contains {
    guard case .settle(let expectation) = $0 else { return false }
    return judged(expectation, 5..<5) == key(.lineStartKey, .neutral, .paragraphLines)
}, "an off-target line key in Chromium rich text is neutral")
func writeStrike(_ expectation: Expectation, selection: Range<Int>?, length: Int?) -> Evidence.Why? {
    var run = RunAttribution()
    run.record(.replaceSelection("x"))
    run.record(.settle(expectation), passed: false, selection: selection, length: length)
    return run.evidence.first?.why
}
let afterX = Expectation(selection: 5..<5, length: 11)
precondition(writeStrike(afterX, selection: nil, length: 11) == .unanswered && writeStrike(afterX, selection: 5..<5, length: nil) == .unanswered)
precondition(writeStrike(afterX, selection: 4..<4, length: 10) == .length, "unchanged text outranks where the caret read")
precondition(writeStrike(afterX, selection: 4..<4, length: 11) == .moved)
precondition(writeStrike(Expectation(selection: 5..<5, length: 11, edge: .paragraphEnd), selection: 5..<5, length: 11) == .edge)
let stuckWord = Expectation(landing: .caretAfter(3, strict: true), blame: Expectation.Blame(capability: .wordKeys, unmoved: [3..<3]))
precondition(judged(stuckWord, 3..<3) == key(.wordKeys, .refutes, .unmoved))
var wideWord = Expectation(landing: .exact(0..<3), blame: Expectation.Blame(capability: .wordKeys, unmoved: []))
wideWord.longest = 3
precondition(judged(wideWord, 0..<5) == key(.wordKeys, .refutes, .tooLong))
let aimedEnd = Expectation(landing: .exact(4..<4), blame: Expectation.Blame(capability: .lineEndKey, unmoved: [], offTarget: true))
precondition(judged(aimedEnd, 6..<6) == key(.lineEndKey, .refutes, .offTarget) && aimedEnd.blamed(observed: 6..<6) == .lineEndKey)
precondition(Learning.teaches(supportsValue) && Learning.teaches(textChecked.evidence[0]) && !Learning.teaches(.offsets(.neutral, .noBreaks)))
precondition(Learning.teaches(struck.evidence[0]) && !Learning.teaches(passed.evidence[0]) && !Learning.teaches(neutralRun.evidence[0]))

for capability in Capability.allCases {
    let question = Question(capability)
    precondition(question.rawValue == capability.rawValue && Question(rawValue: capability.rawValue) == question)
    precondition(question == (Capability.nativeKeys.contains(capability) ? .key(capability) : .write(capability)))
}
precondition(Question(rawValue: "offsets") == .offsets && Question.offsets.rawValue == "offsets")
precondition(Question(rawValue: "offset") == .unknown("offset") && Question.unknown("offset").rawValue == "offset")
var laterBuild = BeliefStore(beliefs: [Belief(rung: learnRung, question: Question(rawValue: "offset"), answer: Belief.broken,
                                              versions: learnVersions)])
precondition(committing(&laterBuild, .writeSelection) && laterBuild.beliefs.count == 2 && broken(laterBuild) == [.writeSelection],
             "a question this build does not know is kept and ignored")

// The resolver's table before beliefs, which it must still match.
func previousTable(probed: CapabilityProfile, config: [Capability: ConfigChoice], learned: Set<Capability>)
    -> [Capability: CapabilityReport.Entry] {
    var entries: [Capability: CapabilityReport.Entry] = [:]
    for capability in Capability.allCases where capability.species == .mechanism {
        let choice = config[capability]?.override
        if probed.has(capability), choice == .off {
            entries[capability] = .init(status: .unavailable, source: .user)
        } else if probed.has(capability), learned.contains(capability), choice != .on {
            entries[capability] = .init(status: .unavailable, source: .learned)
        } else {
            entries[capability] = .init(status: probed.has(capability) ? .available : .unavailable, source: .probed)
        }
    }
    for capability in Capability.allCases where capability.species == .policy {
        let mechanism = capability.parent.map { entries[$0] ?? .init(status: .unavailable, source: .probed) }
        let choice = config[capability] ?? ConfigChoice()
        if let mechanism, mechanism.status != .available {
            entries[capability] = .init(status: .unavailable, source: mechanism.source)
        } else if choice.override == .off {
            entries[capability] = .init(status: .unavailable, source: .user)
        } else if choice.seededOff, choice.override != .on {
            entries[capability] = .init(status: .unavailable, source: .seeded)
        } else {
            entries[capability] = .init(status: .available, source: choice.override == .on ? .user : .probed)
        }
    }
    return entries
}
var draw: UInt64 = 0x9E37_79B9_7F4A_7C15
func coin(_ sides: UInt64) -> UInt64 {
    draw ^= draw << 13
    draw ^= draw >> 7
    draw ^= draw << 17
    return draw % sides
}
for _ in 0..<400 {
    var probed: Set<Capability> = []
    var config: [Capability: ConfigChoice] = [:]
    var demoted: Set<Capability> = []
    var store = BeliefStore()
    for capability in Capability.allCases {
        if coin(2) == 0 { probed.insert(capability) }
        let override: ConfigChoice.Override? = [nil, .on, .off][Int(coin(3))]
        config[capability] = ConfigChoice(override: override, seededOff: coin(3) == 0)
        if capability.species == .mechanism, coin(3) == 0 {
            demoted.insert(capability)
            _ = committing(&store, capability)
        }
    }
    let profile = CapabilityProfile(available: probed)
    let resolved = CapabilityResolver.resolve(probed: profile, config: config, beliefs: resolving(store))
    precondition(resolved.report.entries == previousTable(probed: profile, config: config, learned: demoted))
    precondition(resolved.profile.statuses == previousTable(probed: profile, config: config, learned: demoted).mapValues(\.status))
}
var withheld = BeliefStore()
_ = withheld.record(offsets: .untrusted, at: learnRung, versions: learnVersions, provenance: Provenance(), tally: Tally())
let untrustedReport = CapabilityResolver.resolve(probed: axProfile, config: [:], beliefs: resolving(withheld)).report
precondition(untrustedReport.entries[.readCaret] == .init(status: .unavailable, source: .learned))
precondition(CapabilityResolver.resolve(probed: axProfile, config: [.readCaret: ConfigChoice(override: .on)], beliefs: resolving(withheld))
    .profile.has(.readCaret))

let judgedBelief = Belief(
    rung: learnRung, question: .write(.writeSelection), answer: Belief.broken, judgedUnder: .value, versions: Versions(app: "1.49.1"),
    provenance: Provenance(build: "1.0.0 (812)", learnedAt: "2026-09-24T10:00:00Z", tag: "e3.c7")
)
precondition(judgedBelief.traceFields
    == "q=writeSelection a=broken judged=value ver=1.49.1 build=1.0.0(812) at=2026-09-24T10:00:00Z tag=e3.c7")
var tallied = Tally()
tallied.count(supportsTextContent)
tallied.count(.offsets(.neutral, .noBreaks))
let offsetsBelief = Belief(rung: learnRung, question: .offsets, answer: "textContent",
                           versions: Versions(app: "1.32.4", engine: "41.3.0"), tally: tallied, anchor: true)
precondition(offsetsBelief.traceFields == "q=offsets a=textContent ver=1.32.4 engine=41.3.0 tally=v0,tc1,misfit0,neutral1 anchor")
precondition(ReadModel(answer: .textContent).traceName == "textContent/start")
precondition(ReadModel(answer: .value, newEngine: true).traceName == "value/start new-engine")
var shown = BeliefStore(beliefs: [judgedBelief])
_ = shown.record(offsets: .textContent, at: learnRung, versions: Versions(app: "1.49.1"), provenance: Provenance(tag: "e4.c1"), tally: Tally())
precondition(resolving(shown, versions: Versions(app: "1.49.1")).traceLines == [
    "belief q=writeSelection a=broken judged=value ver=1.49.1 build=1.0.0(812) at=2026-09-24T10:00:00Z tag=e3.c7 reopened offsets=textContent",
    "belief q=offsets a=textContent ver=1.49.1 tag=e4.c1 tally=v0,tc0,misfit0,neutral0 in-force",
])
precondition(supportsTextContent.traceFields == "q=offsets supports=textContent why=plain=textContent seen=snapshot")
precondition(textChecked.evidence[0].traceFields == "q=offsets refutes why=text-check seen=settle@1")
precondition(neutralRun.evidence[0].traceFields == "q=lineStartKey neutral why=paragraph-lines seen=settle@1")
precondition(struck.evidence[0].traceFields == "q=writeSelection refutes why=moved seen=settle@1")
precondition(passed.evidence[0].traceFields == "q=insertText supports why=settled seen=settle@1")
precondition(moved.traceLines(rung: learnRung, versions: learnVersions)
    == ["offsets value→textContent why=plain=textContent rung=\(learnRung) engine=1.49.1 → republish"])
let lengthStrike = Evidence(.write(.insertText), .refutes, why: .length, seen: .settle(3))
precondition(Learning.Lesson(refuted: lengthStrike, republish: true).traceLines(rung: learnRung, versions: learnVersions)
    == ["commit q=insertText why=length rung=\(learnRung) ver=1.49.1 → republish"])
precondition(Learning.Lesson(refuted: lengthStrike, skip: .alreadyCommitted).traceLines(rung: learnRung, versions: learnVersions)
    == ["skip=already-committed q=insertText why=length"])
precondition(Expectation(selection: 10..<15, length: 21, selectedText: "hello").traceFields(text: true)
    == "sel=10..15 len=21 text=\"hello\"")
precondition(Expectation(selection: 10..<15, length: 21, selectedText: "hello").traceFields == "sel=10..15 len=21 text=(5)")
precondition(Expectation(selectedText: "ab").matches(selection: nil, length: nil, selectedText: "a\u{FFFC}b"),
             "Chromium's leaf with no text is not a different selection")

let withheldCaret = removing([.readCaret], from: axProfile)
precondition(physical("rX", text: "say hello", profile: withheldCaret).steps.prefix(2)
    == [.press(.selectRight, count: 1), .typeText("X")], "an AX write would overtake the queued ⇧→")
precondition(physical("o", text: "say hello", profile: withheldCaret).steps.prefix(2)
    == [.press(.lineEnd, count: 1), .typeText("\n")])
precondition(physical("rX", text: "say hello", profile: withheldCaret).steps.allSatisfy {
    if case .replaceSelection = $0 { return false }
    return true
})
var replayInsert = VimState.initial
replayInsert.session.lastChange = VimState.ChangeMemory(body: "i", insert: "abc")
precondition(physical(".", text: "say hello", profile: withheldCaret, state: replayInsert).steps.contains(.replaceSelection("abc")),
             "with nothing queued the AX write stays")

// MARK: - Lessons the menu may forget

let probedAll = CapabilityProfile(available: Set(Capability.allCases))
func taught(_ store: BeliefStore, starting: OffsetsAnswer = .value, probed: CapabilityProfile = probedAll,
            config: [Capability: ConfigChoice] = [:]) -> [ResolvedBeliefs.Lesson] {
    let beliefs = resolving(store, starting: starting, pins: config[.readCaret]?.override != nil)
    let report = CapabilityResolver.resolve(probed: probed, config: config, beliefs: beliefs).report
    return beliefs.lessons(report: report, overridden: Set(config.filter { $0.value.override != nil }.keys))
}
var twoWrites = BeliefStore()
precondition(committing(&twoWrites, .writeSelection) && committing(&twoWrites, .insertText))
let inForceLessons = taught(twoWrites)
precondition(inForceLessons.map(\.capability) == [.writeSelection, .insertText] && inForceLessons.allSatisfy { $0.state == .inForce })
precondition(inForceLessons[1].beliefs.map(\.question) == [.write(.insertText)])
precondition(taught(twoWrites, starting: .textContent).map(\.state) == [.reopened, .reopened])
precondition(taught(twoWrites, starting: .textContent, config: [.insertText: ConfigChoice(override: .on)]).map(\.capability)
             == [.writeSelection], "an On decides a reopened verdict")
precondition(taught(twoWrites, config: [.insertText: ConfigChoice(override: .off)]).map(\.capability) == [.writeSelection])
precondition(taught(twoWrites, probed: removing([.insertText], from: probedAll)).map(\.capability) == [.writeSelection])
var forgotten = twoWrites
for belief in inForceLessons[0].beliefs { forgotten.forget(belief.question, at: belief.rung) }
precondition(taught(forgotten).map(\.capability) == [.insertText])

var untrustedCaret = BeliefStore()
precondition(untrustedCaret.record(offsets: .untrusted, at: learnRung, versions: learnVersions, provenance: Provenance(), tally: Tally()))
let withheldLessons = taught(untrustedCaret, starting: .textContent)
precondition(withheldLessons.map(\.capability) == [.readCaret] && withheldLessons[0].beliefs == [untrustedCaret.offsetsBelief(at: learnRung)!])
var learnedValue = BeliefStore()
precondition(learnedValue.record(offsets: .value, at: learnRung, versions: learnVersions, provenance: Provenance(), tally: Tally()))
precondition(resolving(learnedValue, starting: .textContent).readModel.source == .learned)
precondition(taught(learnedValue, starting: .textContent).isEmpty, "forgetting it would restart the field at textContent")
var learnedMarkers = BeliefStore()
precondition(learnedMarkers.record(offsets: .textContent, at: learnRung, versions: learnVersions, provenance: Provenance(), tally: Tally()))
precondition(taught(learnedMarkers).isEmpty)
var brokenCaret = learnedMarkers
precondition(committing(&brokenCaret, .readCaret, under: .textContent))
let brokenCaretLessons = taught(brokenCaret)
precondition(brokenCaretLessons.map(\.capability) == [.readCaret] && brokenCaretLessons[0].beliefs.map(\.question) == [.write(.readCaret)])
var brokenUntrusted = untrustedCaret
precondition(committing(&brokenUntrusted, .readCaret, under: .untrusted))
precondition(taught(brokenUntrusted, starting: .textContent).first?.beliefs.map(\.question) == [.offsets, .write(.readCaret)])

var policyVerdict = BeliefStore()
precondition(committing(&policyVerdict, .drawCursor))
precondition(taught(policyVerdict).isEmpty, "the resolver applies no verdict to a policy")
var twoRungs = BeliefStore()
precondition(committing(&twoRungs, .insertText) && committing(&twoRungs, .insertText, at: "com.dia.app"))
precondition(taught(twoRungs).first?.beliefs.map(\.rung) == [learnRung, "com.dia.app"])
var mixedRungs = BeliefStore()
precondition(committing(&mixedRungs, .insertText) && committing(&mixedRungs, .insertText, at: "com.dia.app", under: .textContent))
precondition(taught(mixedRungs).first?.beliefs.count == 2, "Try Again leaves no reopened verdict behind")

// MARK: - Beliefs end to end (the Sim's Chromium read fault)

func chromiumSim(_ text: String, caret: Int, profile: CapabilityProfile, markers: Bool, chromium: Bool = false,
                 store: BeliefStore = BeliefStore()) -> Sim {
    var host = Sim(text: text, caret: caret, profile: profile)
    host.reads = omitsBreaks
    host.writesInReadOffsets = true
    host.markers = markers
    host.emulatesKeys = true
    host.learn(with: Sim.Learner(store: store, chromium: chromium, probed: profile))
    return host
}
// LIN-1590's worked example: the caret on the `w` of `world` is 16 in `AXValue` and 11 to Chromium.
let workedExample = "a\nb\nc\nd\ne\nhello world"

var firstParagraph = chromiumSim(workedExample, caret: 0, profile: axProfile, markers: true)
firstParagraph.type("l")
precondition(firstParagraph.learner!.model.answer == .value && firstParagraph.learner!.evidence.isEmpty,
             "a caret in paragraph 1 reads no markers")
var discovered = chromiumSim(workedExample, caret: 16, profile: axProfile, markers: true)
discovered.type("ciwthere")
discovered.feed("<Esc>")
precondition(discovered.learner!.evidence.first == supportsTextContent)
precondition(discovered.learner!.lessons.first?.move == Learning.Move(from: .value, to: .textContent, why: .plainIsTextContent))
precondition(discovered.learner!.model.answer == .textContent && discovered.learner!.model.source == .learned)
precondition(discovered.text == "a\nb\nc\nd\ne\nhello there" && discovered.settleFailures == 0, "the move takes effect on its own snapshot")

var misreadWord = chromiumSim(workedExample, caret: 16, profile: axProfile, markers: false)
misreadWord.type("ciw")
precondition(misreadWord.text == workedExample && misreadWord.settleFailures == 1, "ciw deletes nothing")
precondition(checkedText(misreadWord.abortedStep) == "hello", "the range reads back as planned while ` worl` is selected")
precondition(misreadWord.learner!.lessons.last?.move == Learning.Move(from: .value, to: .untrusted, why: .textCheck))
precondition(misreadWord.learner!.model.answer == .untrusted && !misreadWord.profile.has(.readCaret))
precondition(misreadWord.learner!.store.offsetsBelief(at: "sim|role:AXTextArea")?.tally?.misfit == 1, "the text check is tallied")
precondition(misreadWord.state.field.mode == .normal && misreadWord.selection.isEmpty)
misreadWord.type("ciw")
precondition(misreadWord.settleFailures == 1 && misreadWord.text == "a\nb\nc\nd\ne\n world" && misreadWord.pasteboard == "hello",
             "the next ciw lets the field choose the word, from where the check left the caret")
var misreadKeys = chromiumSim(paragraphs, caret: 24, profile: readProfile, markers: false)
misreadKeys.type("ciw")
precondition(misreadKeys.text == paragraphs && misreadKeys.learner!.model.answer == .untrusted)

var sameEngine = discovered
sameEngine.reads = nil
sameEngine.writesInReadOffsets = false
sameEngine.type("h")
precondition(sameEngine.learner!.lessons.last?.move == Learning.Move(from: .textContent, to: .untrusted, why: .plainIsValue))
var newEngine = discovered
newEngine.reads = nil
newEngine.writesInReadOffsets = false
newEngine.update(to: Versions(app: "2"))
newEngine.type("h")
precondition(newEngine.learner!.model.answer == .value && newEngine.learner!.evidence.last == supportsValue)
var fixedChromium = chromiumSim(workedExample, caret: 16, profile: axProfile, markers: true, chromium: true,
                                store: discovered.learner!.store)
fixedChromium.reads = nil
fixedChromium.writesInReadOffsets = false
fixedChromium.update(to: Versions(app: "2"))
fixedChromium.type("h")
precondition(fixedChromium.learner!.lessons.last?.move == Learning.Move(from: .textContent, to: .value, why: .plainIsValue),
             "a detected Chromium field moves back to value on a new engine")

var preFix = BeliefStore()
_ = preFix.commit(broken: .writeSelection, at: "sim|role:AXTextArea", judgedUnder: .value, versions: Versions(app: "1"),
                  provenance: Provenance(tag: "e3.c7"))
var reopening = chromiumSim(workedExample, caret: 16, profile: axProfile, markers: true, store: preFix)
precondition(!reopening.profile.has(.writeSelection), "in force while plain reads stand")
reopening.type("l")
precondition(reopening.learner!.model.answer == .textContent && reopening.profile.has(.writeSelection))
precondition(reopening.learner!.resolved!.reopened.map(\.question) == [.write(.writeSelection)])
reopening.type("ciwthere")
precondition(reopening.text == "a\nb\nc\nd\ne\nhello there" && reopening.settleFailures == 0)

var firstThenLater = chromiumSim("alpha beta gamma\nb\nc\nd\ne\nhello world", caret: 2, profile: axProfile, markers: true)
firstThenLater.type("llll")
precondition(firstThenLater.caret == 6 && firstThenLater.learner!.model.answer == .value)
precondition(firstThenLater.learner!.sampling.remaining == OffsetsSampling.budget, "paragraph 1 spends no samples")
firstThenLater.type("5jl")
precondition(firstThenLater.learner!.model.answer == .textContent && firstThenLater.learner!.evidence.last == supportsTextContent)

var untrustedRung = BeliefStore()
_ = untrustedRung.record(offsets: .untrusted, at: "sim|role:AXTextArea", versions: Versions(app: "1"), provenance: Provenance(),
                         tally: Tally())
var textarea = Sim(text: "say hello world", caret: 6, profile: axProfile)
textarea.hasChildren = false
textarea.learn(with: Sim.Learner(store: untrustedRung, probed: axProfile))
precondition(textarea.profile.has(.readCaret) && textarea.learner!.model.source == .plain)
textarea.type("ciwbye")
textarea.feed("<Esc>")
precondition(textarea.text == "say bye world" && textarea.settleFailures == 0)
precondition(textarea.learner!.store == untrustedRung && textarea.learner!.evidence.isEmpty)

var ignored = Sim(text: "say hello world", caret: 6, profile: axProfile)
ignored.swallowsReplace = true
ignored.learn(with: Sim.Learner(probed: axProfile))
ignored.type("ciw")
precondition(ignored.learner!.lessons.last?.committed == .insertText && !ignored.profile.has(.insertText))
precondition(ignored.learner!.store.beliefs.map(\.judgedUnder) == [.value])
var chipKey = chromiumSim("ab\ncd", caret: 4, profile: keyProfile, markers: true, chromium: true)
chipKey.reboundChords = [.paragraphStart: .paragraphEnd]
chipKey.type("0")
precondition(chipKey.settleFailures == 1 && chipKey.blamed.isEmpty)
precondition(chipKey.attribution.evidence.contains { $0.question == .key(.lineStartKey) && $0.outcome == .neutral && $0.why == .paragraphLines })
precondition(chipKey.learner!.lessons.last?.committed == nil && chipKey.profile.has(.lineStartKey))

// MARK: - Empty paragraphs (LIN-1612)

// Chrome 153's own strings (softlash/LIN-1612 scripts/empty-shapes): a blank line under the first paragraph.
let blankParagraphs = ["Heading one", "First paragraph with some words.", "", "Second paragraph.", "\u{2022} item alpha",
                       "\u{2022} item beta", "Last paragraph here."]
let blankValue = "Heading one\nFirst paragraph with some words.\nSecond paragraph.\n\u{2022} item alpha\n\u{2022} item beta\n"
    + "Last paragraph here."
let blankMarkers = "Heading oneFirst paragraph with some words.\nSecond paragraph.\u{2022} item alpha\u{2022} item beta"
    + "Last paragraph here."
let blankAligned = ParagraphBreaks(value: blankValue, fieldText: blankMarkers)!
precondition(blankAligned.offsets == [11, 62, 75, 87], "the blank line's <br> pairs with AXValue's separator")
let blankModel = EmptyParagraphs.restore(value: blankValue, fieldText: blankMarkers, aligned: blankAligned, found: [43])!
precondition(blankModel.text == blankParagraphs.joined(separator: "\n"))
precondition(blankModel.gap == 1)
precondition(blankModel.breaks.valueRange(43..<43) { _ in .start(skipping: 0) } == 45..<45, "a caret in it reads as its own line")
precondition(blankModel.breaks.valueRange(43..<43) { _ in .end } == 44..<44)
precondition(blankModel.breaks.valueRange(44..<44) { _ in .start(skipping: 0) } == 46..<46)
precondition(EmptyParagraphs.chromium(blankParagraphs) == (blankValue, blankMarkers, [43]))

// Each placement Chrome 153 was measured in, round-tripped through every caret.
for paragraphs in [["L", "", "N"], ["L", "", "", "N"], ["L", "", "", "", "N"], ["", "L"], ["", "", "L"], ["L", ""], ["L", "", ""],
                   [""], ["", ""], ["L", "N"], ["a", "", "bc", "", "", "d", ""]] {
    let truth = paragraphs.joined(separator: "\n")
    let shown = EmptyParagraphs.chromium(paragraphs)
    let aligned = ParagraphBreaks(value: shown.value, fieldText: shown.markers)!
    let restored = EmptyParagraphs.restore(value: shown.value, fieldText: shown.markers, aligned: aligned, found: shown.found)
    precondition(restored?.text == truth && restored?.gap == truth.utf16.count - shown.value.utf16.count, "\(paragraphs)")
    let host = ChromiumParagraphs(text: truth)
    for caret in 0...truth.utf16.count {
        let field = host.field(caret)
        let read = restored?.breaks.valueRange(field..<field) { _ in host.side(caret) }
        precondition(read == caret..<caret, "\(paragraphs) at \(caret)")
    }
}
precondition(EmptyParagraphs.restore(value: "L\nN", fieldText: "L\nN", aligned: ParagraphBreaks(offsets: []), found: [0]) == nil,
             "a found offset must be a <br>")
precondition(EmptyParagraphs.restore(value: "L\n\nN", fieldText: "L\n\nN", aligned: ParagraphBreaks(offsets: []), found: [2, 1]) == nil)
precondition(EmptyParagraphs.restore(value: "a\nb", fieldText: "a\nb", aligned: ParagraphBreaks(offsets: []), found: [])
             == EmptyParagraphs.Model(text: "a\nb", breaks: ParagraphBreaks(offsets: []), gap: 0), "no blank line, no change")

// macbook14's e78: L is field 203..<210, the blank line's <br> is at 210.
let e78Paragraphs = [String(repeating: "a", count: 121), String(repeating: "b", count: 82), "ccccccc", "", "ddddd"]
let e78Shown = EmptyParagraphs.chromium(e78Paragraphs)
precondition(e78Shown.value.utf16.count == 218 && e78Shown.markers.utf16.count == 216 && e78Shown.found == [210])
let e78Aligned = ParagraphBreaks(value: e78Shown.value, fieldText: e78Shown.markers)!
let e78Model = EmptyParagraphs.restore(value: e78Shown.value, fieldText: e78Shown.markers, aligned: e78Aligned, found: [210])!
precondition(e78Model.breaks.offsets == [121, 204, 212] && e78Model.gap == 1)

func e78Planning(_ keys: String, caret: Int) -> PhysicalPlanner.Planning {
    PhysicalPlanner.planning(LogicalPlanner.plan(RawCommand(keys), state: .initial), snapshot: FieldSnapshot(
        capabilities: keyProfile, text: e78Model.text, selection: caret..<caret, webContent: true, breaks: e78Model.breaks,
        valueGap: e78Model.gap, holdsEmptyParagraphs: true
    ))
}
func settleTraces(_ plan: PhysicalPlan) -> [String] {
    plan.steps.compactMap { step in
        switch step {
        case .settle(let expectation): return expectation.traceFields
        case .softSettle(let expectation): return "soft " + expectation.traceFields
        default: return nil
        }
    }
}
let e78k = e78Planning("k", caret: 213).plan
precondition(e78k.traceShape == "P!PP!C")
precondition(settleTraces(e78k) == ["sel=210..210 len=218 edge=start", "sel=203..203 len=218 edge=start"], "c61 leaves the blank line")
let e78j = e78Planning("j", caret: 205).plan
precondition(e78j.traceShape == "P!P!C")
precondition(settleTraces(e78j) == ["sel=210..210 len=218 edge=end", "sel=210..210 len=218 edge=start"], "c60: j stops on it")
let e78dd = e78Planning("dd", caret: 205).plan
precondition(e78dd.traceShape == "P!P!P!!P?CC")
precondition(settleTraces(e78dd)[2] == "sel=203..210 len=218 edge=start", "c49: ⇧→ ends in the blank line")
precondition(settleTraces(e78dd).last == "soft sel=203..203 len=nil", "and what AXValue shows after is a guess")

func blankSim(_ paragraphs: [String], caret: Int, profile: CapabilityProfile = keyProfile) -> Sim {
    var host = Sim(text: paragraphs.joined(separator: "\n"), caret: caret, profile: profile)
    host.emptyParagraphs = true
    host.emulatesKeys = true
    host.readModel = .textContent
    return host
}
var e78Keys = blankSim(e78Paragraphs, caret: 205)
e78Keys.type("j")
precondition(e78Keys.caret == 213 && e78Keys.settleFailures == 0, "j from the line above lands in the blank line")
e78Keys.type("k")
precondition(e78Keys.caret == 205 && e78Keys.settleFailures == 0)
e78Keys.type("jj")
precondition(e78Keys.caret == 214)
e78Keys.type("kk")
precondition(e78Keys.caret == 205 && e78Keys.settleFailures == 0 && e78Keys.bells == 0)
var e78Above = blankSim(e78Paragraphs, caret: 205)
e78Above.type("dd")
precondition(e78Above.text == [e78Paragraphs[0], e78Paragraphs[1], "", "ddddd"].joined(separator: "\n"))
precondition(e78Above.settleFailures == 0)
var e78Blank = blankSim(e78Paragraphs, caret: 213)
e78Blank.type("dd")
precondition(e78Blank.text == [e78Paragraphs[0], e78Paragraphs[1], "ccccccc", "ddddd"].joined(separator: "\n"))
precondition(e78Blank.settleFailures == 0 && e78Blank.caret == 213)
for keys in ["h", "j", "k", "l", "0", "$", "w", "b", "e", "x", "D", "gg", "G", "yy", "ma`a"] {
    var fromBlank = blankSim(e78Paragraphs, caret: 213)
    fromBlank.type(keys)
    precondition(fromBlank.settleFailures == 0 && fromBlank.unsupportedSteps == 0, "\(keys) from the blank line")
}
var blankInsert = blankSim(e78Paragraphs, caret: 213)
blankInsert.type("I")
blankInsert.feed("<C-[>")
precondition(blankInsert.caret == 213 && blankInsert.settleFailures == 0 && blankInsert.state.field.mode == .normal)
var blankVisual = blankSim(e78Paragraphs, caret: 213)
blankVisual.type("v")
precondition(blankVisual.state.field.mode == .visual(VimState.VisualContext(kind: .character, anchor: 213)))

// Without discovery the field keeps AXValue's lines, and e78 happens as logged.
var e78Logged = blankSim(e78Paragraphs, caret: 205)
e78Logged.findsEmptyParagraphs = false
e78Logged.type("j")
precondition(e78Logged.settleFailures == 1 && e78Logged.caret == 213, "c60")
e78Logged.type("k")
precondition(e78Logged.settleFailures == 2 && e78Logged.caret == 213, "c61: the caret stays in the blank line")
precondition(e78Logged.attribution.evidence.contains { $0.question == .key(.lineStartKey) && $0.why == .emptyParagraph })

// Two in a row, and at either end.
var twoBlank = blankSim(["alpha", "", "", "omega"], caret: 0)
twoBlank.type("jjj")
precondition(twoBlank.caret == 8 && twoBlank.settleFailures == 0)
twoBlank.type("kk")
precondition(twoBlank.caret == 6 && twoBlank.settleFailures == 0)
var edgesBlank = blankSim(["", "alpha", ""], caret: 1)
edgesBlank.type("k")
precondition(edgesBlank.caret == 0 && edgesBlank.settleFailures == 0)
edgesBlank.type("G")
precondition(edgesBlank.caret == 7 && edgesBlank.settleFailures == 0)

// Lane A: writes land on the blank line too.
let writeKeys = CapabilityProfile(available: [
    .readText, .readLength, .readCaret, .readSelectedText, .writeSelection, .insertText, .wholeDocument,
    .lineStartKey, .lineEndKey, .documentStartKey, .documentEndKey,
])
var e78Writes = blankSim(e78Paragraphs, caret: 205, profile: writeKeys)
e78Writes.type("j")
precondition(e78Writes.caret == 213 && e78Writes.settleFailures == 0)
e78Writes.type("k")
precondition(e78Writes.caret == 205 && e78Writes.settleFailures == 0)

// Beside a line put back, emptying one changes which empty paragraphs AXValue hides, so no length is checked after it.
var emptied = blankSim(e78Paragraphs, caret: 214, profile: writeKeys)
emptied.type("cc")
precondition(emptied.text == [e78Paragraphs[0], e78Paragraphs[1], "ccccccc", "", ""].joined(separator: "\n"))
precondition(emptied.settleFailures == 0 && emptied.state.field.mode == .insert)
precondition(settleTraces(e78Planning("x", caret: 205).plan).last == "soft sel=203..203 len=217 edge=start",
             "a line that stays non-empty keeps its length")

// The scan over a fake tree: role, subrole, children and plain offsets as Chromium's would read.
final class FakeNode {
    let role: String
    let subrole: String?
    let start: Int
    let end: Int
    let children: [FakeNode]
    var fails = false

    init(_ role: String, _ subrole: String? = nil, _ start: Int, _ end: Int, _ children: [FakeNode] = []) {
        self.role = role
        self.subrole = subrole
        self.start = start
        self.end = end
        self.children = children
    }
}
func text(_ start: Int, _ end: Int) -> FakeNode { FakeNode("AXStaticText", nil, start, end) }
func paragraph(_ start: Int, _ end: Int) -> FakeNode { FakeNode("AXGroup", nil, start, end, [text(start, end)]) }
func blank(_ at: Int) -> FakeNode { FakeNode("AXGroup", "AXEmptyGroup", at, at + 1) }
func scanned(_ blocks: [FakeNode], _ plain: String, budget: Int = EmptyParagraphs.readBudget) -> [Int]? {
    var scan = EmptyBlockScan<FakeNode>(budget: budget, block: { node in
        node.fails ? nil : EmptyBlockScan.Block(role: node.role, subrole: node.subrole, children: node.children)
    }, offset: { node, end in end ? node.end : node.start })
    return scan.run(blocks: blocks, plain: Array(plain.utf16))
}
let middleBlank = blank(1)
precondition(scanned([paragraph(0, 1), middleBlank, paragraph(2, 3)], "L\nN") == [1])
middleBlank.fails = true
precondition(scanned([paragraph(0, 1), middleBlank, paragraph(2, 3)], "L\nN") == nil, "a failed read fails the scan")
precondition(scanned([FakeNode("AXGroup", nil, 0, 3, [text(0, 1), text(1, 2), text(2, 3)])], "a\nb") == [],
             "a soft break is a paragraph's own text")
let quote = FakeNode("AXGroup", nil, 1, 4, [paragraph(1, 2), blank(2), paragraph(3, 4)])
precondition(scanned([paragraph(0, 1), quote, paragraph(4, 5)], "Lq\nmN") == [2], "one nested in a quote")
quote.children[0].fails = true
precondition(scanned([paragraph(0, 1), quote, paragraph(4, 5)], "Lq\nmN") == nil, "and a failed read on the way down")
let item = FakeNode("AXGroup", nil, 0, 3, [FakeNode("AXListMarker", nil, 0, 2), blank(2)])
precondition(scanned([FakeNode("AXList", "AXContentList", 0, 3, [item])], "\u{2022} \n") == [],
             "an empty list item's line is its marker's")
precondition(scanned((0..<300).map { paragraph($0, $0 + 1) }, String(repeating: "x", count: 299) + "\n") == nil,
             "a field past the budget keeps AXValue's lines")

// A trailing blank line nets no gap, but emptying the line beside it still changes what AXValue shows.
var trailingBlank = blankSim(["a", ""], caret: 0, profile: writeKeys)
trailingBlank.type("x")
precondition(trailingBlank.text == "\n" && trailingBlank.settleFailures == 0)

print("Vim engine tests passed")
