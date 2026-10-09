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
// Policy atoms are decided, against a parent mechanism.
precondition(Capability.wholeDocument.species == .policy)
precondition(Capability.wholeDocument.parent == .readText)
precondition(Capability.drawCursor.species == .policy)
precondition(Capability.drawCursor.parent == .writeSelection)
precondition(Capability.allCases.filter { $0.species == .mechanism }.allSatisfy { $0.parent == nil })
// The ungated policy: no mechanism can moot whether a focus change ends a
// session.
precondition(Capability.fieldIsSession.rawValue == "fieldIsSession")
precondition(Capability.fieldIsSession.species == .policy)
precondition(Capability.fieldIsSession.parent == nil)

// A field that names a bigger editable field around itself is one block of it, with no seed (LIN-1855).
precondition(Capability.blockScoped == [.drawCursor, .wholeDocument, .fieldIsSession])
let shippedSeeds: [Capability: ConfigChoice] = [.nativeMotions: ConfigChoice(seededOff: true)]
let enclosedField = CapabilityResolver.resolve(probed: axProfile, enclosed: true, config: shippedSeeds, learned: [])
for capability in Capability.blockScoped {
    precondition(enclosedField.report.entries[capability] == .init(status: .unavailable, source: .probed))
}
precondition(enclosedField.report.traceGrid.contains("WS+p IT+p DC-p WD-p FS-p"))
precondition(physical("j", text: "one", caret: 0, profile: enclosedField.profile).steps == [
    .press(.down, count: 1),
    .commit(.setCursor(nil)),
])
for keys in ["j", "k", "3j", "gg", "G", "l", "w", "x", "ciw", "dd", "dj", "yj", "J"] {
    precondition(physical(keys, text: "say hello world", caret: 6, profile: enclosedField.profile).steps
        == physical(keys, text: "say hello world", caret: 6, profile: blockProfile).steps, "\(keys) plans as in Notion's seeded block")
}
precondition(physical("j", text: "one", caret: 0, profile: CapabilityResolver.resolve(probed: axProfile, config: shippedSeeds, learned: []).profile)
    .steps.contains(.setSelection(0..<0)), "without the read the caret is written where it is")
let enclosedChoices = Dictionary(uniqueKeysWithValues: Capability.blockScoped.map { ($0, ConfigChoice(override: .on)) })
let userOverPage = CapabilityResolver.resolve(probed: axProfile, enclosed: true, config: enclosedChoices, learned: []).report
for capability in Capability.blockScoped {
    precondition(userOverPage.entries[capability] == .init(status: .available, source: .user))
}
let seededEnclosed = CapabilityResolver.resolve(
    probed: axProfile, enclosed: true, config: [.fieldIsSession: ConfigChoice(seededOff: true)], learned: []
).report
precondition(seededEnclosed.entries[.fieldIsSession] == .init(status: .unavailable, source: .seeded), "a seeded surface reports as it did")
let parentsOff = CapabilityResolver.resolve(
    probed: axProfile, enclosed: true,
    config: [.readText: ConfigChoice(override: .off), .writeSelection: ConfigChoice(override: .off)], learned: []
).report
precondition(parentsOff.entries[.wholeDocument] == .init(status: .unavailable, source: .user)
    && parentsOff.entries[.drawCursor] == .init(status: .unavailable, source: .user), "a missing parent still answers first")

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
var strandedIgnored = keyedSim(prose, caret: 4)
strandedIgnored.reboundChords = [.selectWordLeft: .selectAll]
strandedIgnored.ignoredChords = [.left]
strandedIgnored.type("ciw")
precondition(strandedIgnored.state.field.mode == .normal && strandedIgnored.selection == 0..<15)
precondition(strandedIgnored.settleFailures == 2, "the repair's own settle fails where the field ignores ←")
var strandedPlain = Sim(text: prose, caret: 4, profile: readProfile)
strandedPlain.reboundChords = [.selectRight: .selectAll]
strandedPlain.type("x")
precondition(strandedPlain.selection == 0..<0 && strandedPlain.settleFailures == 1)
strandedPlain.reboundChords = [:]
strandedPlain.type("iX")
precondition(strandedPlain.text == "X" + prose, "i types beside a stranded selection, not over it")
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

precondition(PhysicalPlanner.collapse(4..<9, profile: axProfile) == PhysicalPlan(.setSelection(4..<4)))
for profile in [nativeRead, readProfile] {
    precondition(PhysicalPlanner.collapse(4..<9, profile: profile)
                 == PhysicalPlan(.press(.left, count: 1), .settle(Expectation(selection: 4..<4))))
}
precondition(PhysicalPlanner.collapse(4..<9, profile: blindProfile) == PhysicalPlan(.press(.left, count: 1)))
for profile in [axProfile, nativeRead, readProfile, blindProfile] {
    precondition(PhysicalPlanner.collapse(4..<9, misread: true, profile: profile) == PhysicalPlan(.press(.left, count: 1)))
}
precondition(PhysicalPlanner.releaseCursor(6..<7, breaks: ParagraphBreaks(offsets: [3]), profile: axProfile)
             == PhysicalPlan(.setSelection(5..<5)))
precondition(PhysicalPlanner.releaseCursor(2..<3, breaks: ParagraphBreaks(offsets: [2]), profile: axProfile)
             == PhysicalPlan(.setSelection(2..<2)), "no key steps back to a paragraph's end once focus has left")
precondition(PhysicalPlanner.releaseCursor(6..<7, breaks: nil, profile: readProfile) == nil)

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

// LIN-1643: a stranded selection's start resolves through its side, and ← collapses it where a write would need keys.
func strandedPlan(
    _ selection: Range<Int>, _ side: ParagraphBreaks.Side?, text: String = "ab\ncd\nef", breaks: ParagraphBreaks = paras,
    profile: CapabilityProfile
) -> PhysicalPlan {
    PhysicalPlanner.collapse(
        selection, side: side, paragraphs: true, snapshot: FieldSnapshot(capabilities: profile, text: text, breaks: breaks),
        profile: profile
    )
}
let collapsedToEnd = PhysicalPlan(
    .press(.left, count: 1), .press(.selectLeft, count: 1), .press(.right, count: 1),
    .settle(Expectation(selection: 2..<2, edge: .paragraphEnd))
)
for profile in [axProfile, readProfile] {
    precondition(strandedPlan(2..<4, .end, profile: profile) == collapsedToEnd,
                 "a write there lands on the next paragraph, so ← collapses the selection in a write lane too")
}
precondition(strandedPlan(2..<4, .start(skipping: 0), profile: axProfile) == PhysicalPlan(.setSelection(2..<2)))
precondition(strandedPlan(2..<2, .end, profile: axProfile) == collapsedToEnd, "a selected break alone starts at the end too")
precondition(strandedPlan(1..<4, .end, profile: axProfile) == PhysicalPlan(.setSelection(1..<1)), "off a boundary the side says nothing")
let drawnAhead = FieldSnapshot(capabilities: axProfile, text: "ab\ncd\nef", breaks: paras, drawnBreak: 4)
for (profile, asRead) in [
    (axProfile, PhysicalPlan(.setSelection(2..<2))),
    (readProfile, PhysicalPlan(
        .press(.left, count: 1), .press(.selectLeft, count: 1), .press(.right, count: 1), .settle(Expectation(selection: 2..<2))
    )),
] {
    for unplaced in [
        strandedPlan(2..<4, nil, profile: profile),
        PhysicalPlanner.collapse(2..<4, side: .end, paragraphs: true, profile: profile),
        strandedPlan(2..<4, .end, text: "a", profile: profile),
        PhysicalPlanner.collapse(2..<4, side: .end, paragraphs: true, snapshot: drawnAhead, profile: profile),
    ] {
        precondition(unplaced == asRead,
                     "a side says nothing without breaks that place it: a code span's end inside a paragraph is an end too")
    }
}
precondition(strandedPlan(2..<4, .start(skipping: 0), profile: readProfile) == PhysicalPlan(
    .press(.left, count: 1), .settle(Expectation(selection: 2..<2, edge: .paragraphStart))
), "no ⇧← → crosses the break above a paragraph's start")
precondition(strandedPlan(4..<6, .start(skipping: 2), text: "• ab\n• cd", breaks: listItems, profile: axProfile)
             == PhysicalPlan(.setSelection(6..<6)), "a list item's start is written past its marker")
precondition(strandedPlan(0..<2, .start(skipping: 2), text: "• ab\n• cd", breaks: listItems, profile: axProfile)
             == PhysicalPlan(.setSelection(2..<2)))
precondition(strandedPlan(4..<6, .end, text: "• ab\n• cd", breaks: listItems, profile: axProfile) == PhysicalPlan(
    .press(.left, count: 1), .press(.selectLeft, count: 1), .press(.right, count: 1),
    .settle(Expectation(selection: 4..<4, edge: .paragraphEnd))
))

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
    .press(.selectRight, count: 1),
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
    .press(.selectLeft, count: 1),
    .press(.left, count: 1),
    .press(.selectLeft, count: 1),
    .press(.right, count: 1),
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
    .press(.selectLeft, count: 1),
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
sim = Sim(text: "say hello world", caret: 4, profile: nativeAX)
sim.perform([.setSelection(4..<9)])
sim.swallowsSelect = true
sim.type("o")
precondition(sim.state.field.mode == .normal && sim.selection == 4..<9, "a field that takes writes is not repaired by ←")

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

var unreadCaret = Sim(text: "say hello world", caret: 6, profile: CapabilityProfile(available: [
    .readText, .readLength, .readSelectedText, .writeSelection, .insertText, .wholeDocument,
]))
unreadCaret.type("dd")
precondition(unreadCaret.text == "say hello world" && unreadCaret.unsupportedSteps == 1, "a caret the field cannot read goes blind")

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
var misreadIgnoresLeft = Sim(text: paragraphs, caret: 24, profile: readProfile)
misreadIgnoresLeft.reads = omitsBreaks
misreadIgnoresLeft.ignoredChords = [.left]
misreadIgnoresLeft.type("ciw")
precondition(checkedText(misreadIgnoresLeft.abortedStep) == "epsilon" && misreadIgnoresLeft.selection == 24..<31)
precondition(misreadIgnoresLeft.state.field.mode == .normal)

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
    precondition(misread.selection.isEmpty, "\(keys) leaves no selection to type over")
    precondition(checkedText(misread.abortedStep) == nil || !misread.state.field.mode.isInserting, keys)
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

// Visual carries, since dropping to Normal would break `v j j d`, but not its anchor: an offset in the field focus left.
let visualContext = VimState.VisualContext(kind: .character, anchor: 0)
precondition(
    VimState.Field(mode: .visual(visualContext)).carried(across: .sameDocument).mode
        == .visual(VimState.VisualContext(kind: .character, anchor: nil))
)
precondition(VimState.Field(mode: .visual(visualContext)).carried(across: .sameElement).mode == .visual(visualContext))

// newSession: the entry policy, whatever the old field held.
precondition(populated.carried(across: .newSession) == VimState.Field.entry)

// Keys-in-flight and the dot body move as one unit, and only a new session
// drops them.
precondition(FocusTransition.newSession.clearsChangeInFlight)
precondition(!FocusTransition.sameDocument.clearsChangeInFlight)
precondition(!FocusTransition.sameElement.clearsChangeInFlight)
precondition(FocusTransition.sameElement.preservesDrawnCursor)
precondition(!FocusTransition.sameDocument.preservesDrawnCursor)

// The rule itself (LIN-1855): elements are numbers here, 100 and 200 two pages, and a site is its role.
typealias Focus = FocusTransition.Focus<Int, String>
let offByPage = CapabilityReport.Entry(status: .unavailable, source: .probed)
let offBySeed = CapabilityReport.Entry(status: .unavailable, source: .seeded)
let offByUser = CapabilityReport.Entry(status: .unavailable, source: .user)
let onByDefault = CapabilityReport.Entry(status: .available, source: .probed)
let onByUser = CapabilityReport.Entry(status: .available, source: .user)
func field(
    _ element: Int, in page: Int? = nil, _ session: CapabilityReport.Entry = onByDefault, role: String = "AXTextArea", pid: Int32 = 1,
    window: Int? = nil
) -> Focus {
    Focus(element: element, pid: pid, site: role, session: session, enclosing: page, window: window)
}
func edge(_ old: Focus?, _ new: Focus?) -> FocusTransition { FocusTransition.between(old, new) }
precondition(edge(nil, field(1)) == .newSession && edge(field(1), nil) == .newSession)
precondition(edge(field(1, in: 100, offByPage), field(1, in: 100, offByPage)) == .sameElement)
precondition(edge(field(1, in: 100, offByPage), field(2, in: 100, offByPage)) == .sameDocument)
precondition(edge(field(1, in: 100, offByPage), field(2, in: 200, offByPage)) == .newSession)
precondition(edge(field(1, in: 100, offByPage), field(2, in: 100, offByPage, role: "AXTextField")) == .sameDocument)
precondition(edge(field(1, in: 100, offByPage), field(100)) == .sameDocument && edge(field(100), field(1, in: 100, offByPage)) == .sameDocument,
             "a block and the page it names are one document")
precondition(edge(field(1), field(2)) == .newSession)
precondition(edge(field(1, in: 100, onByUser), field(2, in: 100, offByPage)) == .newSession)
precondition(edge(field(1, in: 100, offByPage), field(100, onByUser)) == .newSession, "the user's On keeps a field a session")
precondition(edge(field(1, offBySeed, window: 7), field(2, offByUser, window: 7)) == .sameDocument)
precondition(edge(field(1, offBySeed, window: 7), field(2, offBySeed, window: 8)) == .newSession)
precondition(edge(field(1, offBySeed, window: 7), field(2, offBySeed, role: "AXTextField", window: 7)) == .newSession)
precondition(edge(field(1, offBySeed, window: 7), field(2, offBySeed, pid: 2, window: 7)) == .newSession)
precondition(edge(field(1, offBySeed), field(2, offBySeed)) == .newSession, "an unread window fails closed")
precondition(edge(field(1, in: 100, offByPage, window: 7), field(2, in: 200, offByPage, window: 7)) == .newSession,
             "the page's own answer never makes the window the document")
precondition(edge(field(1, in: 100, offBySeed, window: 7), field(2, in: 200, offBySeed, window: 7)) == .sameDocument)
precondition(edge(field(1, in: 100, offBySeed, window: 7), field(2, offBySeed, window: 7)) == .sameDocument)
precondition(edge(field(1, in: 100, offBySeed, window: 7), field(2, in: 100, offBySeed, window: 8)) == .sameDocument)
precondition(FocusTransition.windowIsDocument(offBySeed) && FocusTransition.windowIsDocument(offByUser))
precondition(!FocusTransition.windowIsDocument(offByPage) && !FocusTransition.windowIsDocument(onByUser)
    && !FocusTransition.windowIsDocument(onByDefault) && !FocusTransition.windowIsDocument(nil))
let forcedApp = Focus(element: 0, pid: 1, site: "", forcedWindow: 7)
precondition(edge(forcedApp, forcedApp) == .sameElement)
precondition(edge(forcedApp, Focus(element: 0, pid: 1, site: "", forcedWindow: 8)) == .newSession)
precondition(edge(forcedApp, Focus(element: 0, pid: 2, site: "", forcedWindow: 7)) == .newSession)
precondition(edge(forcedApp, field(0)) == .newSession && edge(field(0), forcedApp) == .newSession)

// End-to-end: `v` at 1 in a block, then focus takes the rule's own edge into its page or another block (LIN-1855).
func crossedInVisual(_ crossing: FocusTransition, to text: String, caret: Int, profile: CapabilityProfile, _ keys: String...) -> Sim {
    var sim = Sim(text: "abc", caret: 1, profile: enclosedField.profile)
    sim.emulatesKeys = true
    sim.type("v")
    sim.refocus(crossing, text: text, caret: caret)
    sim.profile = profile
    for key in keys {
        if key.hasPrefix("<") { sim.feed(key) } else { sim.type(key) }
    }
    return sim
}
let blockToPage = edge(field(1, in: 100, offByPage), field(100))
let blockToBlock = edge(field(1, in: 100, offByPage), field(2, in: 100, offByPage))
let pageProfile = CapabilityResolver.resolve(probed: axProfile, config: shippedSeeds, learned: []).profile
let pageText = "header\nabcdefghij\nfooter"
let intoPage = crossedInVisual(blockToPage, to: pageText, caret: 10, profile: pageProfile, "j", "d")
precondition(intoPage.text == "header\nabcter" && intoPage.bells == 0, "the block's anchor must not select in the page")
precondition(crossedInVisual(blockToPage, to: pageText, caret: 10, profile: pageProfile, "l", "l", "d").text == "header\nabcfghij\nfooter")
precondition(crossedInVisual(blockToBlock, to: "second block", caret: 7, profile: enclosedField.profile, "l", "d").text == "second lock",
             "nor in another block, where `l` is planned in the block's own text")
let leftVisual = crossedInVisual(blockToPage, to: pageText, caret: 10, profile: pageProfile, "j", "<Esc>")
precondition(leftVisual.state.field.mode == .normal && leftVisual.text == pageText && leftVisual.bells == 0, "Esc still leaves Visual")

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

var leaving = Sim(text: "abc", caret: 0, profile: axProfile)
leaving.type("l")
precondition(leaving.selection == 1..<2 && leaving.state.field.cursor == 1..<2)
leaving.refocus(.sameElement)
precondition(leaving.selection == 1..<2)
var unwritable = leaving
leaving.refocus(.newSession)
precondition(leaving.selection == 1..<1 && leaving.state.field.cursor == nil)
unwritable.profile = readProfile
unwritable.refocus(.newSession)
precondition(unwritable.selection == 1..<2, "without a write the drawn cursor stays: a key would reach the new focus")

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

// MARK: - The typing target (LIN-1742)

final class FakeElement: Equatable {
    let role: String?
    let parent: FakeElement?
    var owns: [FakeElement] = []
    var chromium = true
    var hasChildren = false

    init(_ role: String?, in parent: FakeElement? = nil) {
        self.role = role
        self.parent = parent
    }

    static func == (a: FakeElement, b: FakeElement) -> Bool { a === b }
}
func nested(_ role: String, _ depth: Int, in parent: FakeElement) -> FakeElement {
    (0..<depth).reduce(parent) { node, _ in FakeElement(role, in: node) }
}
var typingReads = 0
var caretReads = 0
func typingTarget(of reported: FakeElement, caretOn node: FakeElement?) -> FakeElement? {
    typingReads = 0
    caretReads = 0
    return TypingTarget.field(for: reported, read: { node in
        typingReads += 1
        return TypingTarget.Reading(role: node.role, parent: node.parent, owns: node.owns, isChromium: node.chromium)
    }, caret: { _ in
        caretReads += 1
        return node
    }, hasChildren: { $0.hasChildren })
}

let menuPage = FakeElement("AXWebArea")
let menuInput = FakeElement("AXComboBox", in: menuPage)
let menuList = FakeElement("AXList", in: menuPage)
let menuRow = FakeElement("AXStaticText", in: menuList)
menuInput.owns = [menuList]
precondition(typingTarget(of: menuRow, caretOn: menuInput) == menuInput && typingReads == 2)
precondition(typingTarget(of: menuList, caretOn: menuInput) == menuInput, "the owned container itself")
precondition(typingTarget(of: menuRow, caretOn: nil) == nil && typingReads == 1, "no caret in the page")
precondition(typingTarget(of: menuInput, caretOn: menuInput) == nil && typingReads == 1 && caretReads == 0,
             "a text field stands for itself")
menuRow.chromium = false
precondition(typingTarget(of: menuRow, caretOn: menuInput) == nil && typingReads == 1 && caretReads == 0,
             "only Chromium defines AXOwns this way")
menuRow.chromium = true
precondition(typingTarget(of: FakeElement(nil, in: menuList), caretOn: menuInput) == nil && caretReads == 0, "a failed read")
precondition(typingTarget(of: menuPage, caretOn: menuInput) == nil && typingReads == 1 && caretReads == 0, "the page itself")

let groupedRow = FakeElement("AXStaticText", in: FakeElement("AXGroup", in: menuList))
precondition(typingTarget(of: groupedRow, caretOn: menuInput) == menuInput && typingReads == 3, "a row in a group, as Linear's")
precondition(typingTarget(of: nested("AXRow", TypingTarget.ownerHops, in: menuList), caretOn: menuInput) == menuInput)
precondition(typingTarget(of: nested("AXRow", TypingTarget.ownerHops + 1, in: menuList), caretOn: menuInput) == nil)
let framed = FakeElement("AXStaticText", in: FakeElement("AXWebArea", in: menuList))
precondition(typingTarget(of: framed, caretOn: menuInput) == nil, "a frame's row is not the outer field's")

let textArea = FakeElement("AXTextArea", in: menuPage)
textArea.owns = [menuList]
precondition(typingTarget(of: menuRow, caretOn: textArea) == textArea)
textArea.hasChildren = true
precondition(typingTarget(of: menuRow, caretOn: textArea) == nil, "a rich editor's caret does not say whether it has the focus")
let unread = FakeElement(nil, in: menuPage)
unread.owns = [menuList]
precondition(typingTarget(of: menuRow, caretOn: unread) == nil, "a failed read of the field")
let owningGroup = FakeElement("AXGroup", in: menuPage)
owningGroup.owns = [menuList]
precondition(typingTarget(of: menuRow, caretOn: owningGroup) == nil, "the caret's node is no text field")

// Focus really elsewhere: Chromium leaves the caret on the text inside the field it left.
let leftBehind = FakeElement("AXStaticText", in: FakeElement("AXGroup", in: menuInput))
let pageButton = FakeElement("AXButton", in: menuPage)
precondition(typingTarget(of: pageButton, caretOn: leftBehind) == nil && typingReads == 1 && caretReads == 0)
precondition(typingTarget(of: FakeElement("AXStaticText", in: menuList), caretOn: leftBehind) == nil && typingReads == 2,
             "a row of the field's own list with the real focus")
precondition(typingTarget(of: FakeElement("AXCell", in: menuList), caretOn: FakeElement("AXGroup", in: menuInput)) == nil,
             "and an empty field's left-behind caret")
for role in ["AXButton", "AXLink"] {
    precondition(typingTarget(of: FakeElement(role, in: menuList), caretOn: menuInput) == nil && caretReads == 0,
                 "a button or a link is never a highlighted row")
}
let checkbox = FakeElement("AXCheckBox", in: menuPage)
precondition(typingTarget(of: checkbox, caretOn: menuInput) == nil && typingReads == 3, "the field's list does not hold it")
let plainInput = FakeElement("AXTextField", in: menuPage)
precondition(typingTarget(of: checkbox, caretOn: plainInput) == nil && typingReads == 2, "a field that owns nothing")
precondition(typingTarget(of: FakeElement("AXStaticText", in: FakeElement("AXList", in: menuPage)), caretOn: menuPage) == nil,
             "a list no field owns")

// A row destroyed mid-read misses once; a bound field is looked up again on a fresh focus read.
var targetLookups = 0
func target(of reported: FakeElement, bound: FakeElement?, refocus: FakeElement?) -> FakeElement {
    targetLookups = 0
    return TypingTarget.target(of: reported, bound: bound, field: { node in
        targetLookups += 1
        return typingTarget(of: node, caretOn: menuInput)
    }, refocus: { refocus })
}
let deadRow = FakeElement(nil, in: menuList)
precondition(target(of: menuInput, bound: menuInput, refocus: nil) == menuInput && targetLookups == 0)
precondition(target(of: menuRow, bound: nil, refocus: nil) == menuInput && targetLookups == 1)
precondition(target(of: menuRow, bound: menuInput, refocus: nil) == menuInput && targetLookups == 1)
precondition(target(of: deadRow, bound: nil, refocus: menuRow) == deadRow && targetLookups == 1, "nothing bound to keep")
precondition(target(of: deadRow, bound: menuInput, refocus: menuRow) == menuInput && targetLookups == 2)
precondition(target(of: deadRow, bound: menuInput, refocus: menuInput) == menuInput && targetLookups == 1)
precondition(target(of: deadRow, bound: menuInput, refocus: deadRow) == deadRow && targetLookups == 1, "focus did not move")
precondition(target(of: deadRow, bound: menuInput, refocus: nil) == deadRow)
precondition(target(of: pageButton, bound: menuInput, refocus: pageButton) == pageButton && targetLookups == 1)
precondition(target(of: deadRow, bound: plainInput, refocus: menuRow) == deadRow && targetLookups == 2, "another field's row")

// MARK: - The learner's commit rule

// The learner writes at the ROLE learnRung, never the identifier rung: a key per
// individual field would scatter the evidence so thinly its strikes in a row
// would never add up.
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

// The store commits at once; `true` asks to persist and re-resolve.
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
func learned(_ store: inout BeliefStore, _ strikes: inout Strikes, _ run: [Evidence], under offsets: OffsetsAnswer = .value,
             versions: Versions = learnVersions, overridden: Bool = false) -> Learning.Lesson {
    Learning.learn(
        store: &store, strikes: &strikes, rung: learnRung, versions: versions, model: ReadModel(answer: offsets),
        observed: Learning.Observation(before: offsets, source: .start), run: run, overridden: { _ in overridden },
        provenance: Provenance(), tally: Tally()
    )
}
for start in [BeliefStore(), trials] {
    var store = start
    var strikes = Strikes()
    let lesson = learned(&store, &strikes, passed.evidence)
    precondition(store == start && !lesson.republish && lesson.committed == nil && strikes.isEmpty)
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
var overruled = BeliefStore()
var overruledStrikes = Strikes()
precondition(learned(&overruled, &overruledStrikes, struck.evidence, overridden: true).skip == .userOverride
             && overruled.beliefs.isEmpty && overruledStrikes.isEmpty)

// LIN-1685: one refuted write leaves writes on; the third refuted run in a row switches them off.
var struckStore = BeliefStore()
var strikes = Strikes()
for count in 1..<Strikes.limit {
    let lesson = learned(&struckStore, &strikes, struck.evidence)
    precondition(lesson.skip == .strike && lesson.strikes == count && lesson.committed == nil && !lesson.republish)
    precondition(struckStore.beliefs.isEmpty && strikes.runs(.writeSelection) == count)
}
let third = learned(&struckStore, &strikes, struck.evidence)
precondition(third.committed == .writeSelection && third.strikes == Strikes.limit && third.republish)
precondition(broken(struckStore) == [.writeSelection] && strikes.isEmpty)

var wrote = RunAttribution()
wrote.record(.setSelection(4..<9))
wrote.record(.settle(Expectation(selection: 4..<9)), passed: true, selection: 4..<9)
func strikesAfter(_ runs: [(run: [Evidence], under: OffsetsAnswer, app: String)]) -> (Strikes, BeliefStore) {
    var store = BeliefStore()
    var strikes = Strikes()
    for item in runs { _ = learned(&store, &strikes, item.run, under: item.under, versions: Versions(app: item.app)) }
    return (strikes, store)
}
let miss = (run: struck.evidence, under: OffsetsAnswer.value, app: "1.49.1")
let landedBetween = strikesAfter([miss, miss, (wrote.evidence, .value, "1.49.1"), miss])
precondition(landedBetween.0.runs(.writeSelection) == 1 && landedBetween.1.beliefs.isEmpty, "a write that lands starts the count over")
let otherPass = strikesAfter([miss, miss, (passed.evidence, .value, "1.49.1"), miss])
precondition(otherPass.0.isEmpty && broken(otherPass.1) == [.writeSelection], "another write's pass does not")
let reread = strikesAfter([miss, miss, (struck.evidence, .textContent, "1.49.1")])
precondition(reread.0.runs(.writeSelection) == 1 && reread.1.beliefs.isEmpty, "a new offsets answer starts it over")
let updated = strikesAfter([miss, miss, (struck.evidence, .value, "1.50")])
precondition(updated.0.runs(.writeSelection) == 1 && updated.1.beliefs.isEmpty, "so does an app update")
var appKeyStore = BeliefStore()
var appKeyStrikes = Strikes()
let appKeyMiss = Evidence(.key(.wordKeys), .refutes, why: .unmoved, seen: .settle(1))
precondition(learned(&appKeyStore, &appKeyStrikes, [appKeyMiss]).committed == .wordKeys && Strikes.limit(for: .lineEndKey) == 3,
             "the opt-in app keys keep the one-miss rule")


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

let paragraphEnd = Expectation(selection: 2..<2, length: 5, edge: .paragraphEnd)
precondition(paragraphEnd.converged(selection: 2..<2, length: 5, selectedText: nil, side: .end))
precondition(!paragraphEnd.converged(selection: 2..<2, length: 5, selectedText: nil, side: .start(skipping: 0)), "the other side")
precondition(!paragraphEnd.converged(selection: 2..<2, length: 5, selectedText: nil, side: nil), "no marker read")
precondition(!paragraphEnd.converged(selection: 3..<3, length: 5, selectedText: nil, side: .end), "offsets still decide")
precondition(Expectation(selection: 2..<2, edge: .paragraphStart)
    .converged(selection: 2..<2, length: nil, selectedText: nil, side: .start(skipping: 2)), "past a list marker")
precondition(Expectation(selection: 4..<9).converged(selection: 4..<9, length: nil, selectedText: nil, side: nil))





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
precondition(chords(physical("O", text: oneLine, caret: 2, profile: keyProfile)) == [.paragraphStart, .paragraphStart, .left])
let webO = webPhysical("o", text: oneLine, caret: 2, profile: keyProfile)
precondition(chords(webO) == [.paragraphEnd] && webO.steps.contains(.clipboardInsert("\n"))
             && !webO.steps.contains(.typeText("\n")))
let webAbove = webPhysical("O", text: "ab\ncd", caret: 4, profile: keyProfile, breaks: ParagraphBreaks(offsets: [2])).steps
let pasted = webAbove.firstIndex(of: .clipboardInsert("\n"))!
precondition(chords(PhysicalPlan(steps: webAbove)) == [.paragraphStart, .paragraphStart, .left])
precondition(webAbove[pasted + 1] == .softSettle(Expectation(selection: nil, length: 6)))
precondition(webAbove[(pasted + 2)...].allSatisfy {
    guard case .settle(let expectation) = $0 else { return true }
    return expectation.length == nil && expectation.selection == nil
})
let rowKeys = adding([.nativeMotions], to: removing([.lineStartKey], from: keyProfile))
let rowAbove = webPhysical("O", text: "ab\ncd", caret: 4, profile: rowKeys, breaks: ParagraphBreaks(offsets: [2])).steps
precondition(chords(PhysicalPlan(steps: rowAbove)) == [.selectLeft, .left, .up])
precondition(rowAbove[rowAbove.firstIndex(of: .press(.up, count: 1))! + 1] == .settle(Expectation(landing: nil)),
             "↑ past a pasted newline settles as blind as ⌃A does")
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
    var strikes = Strikes()
    return Learning.learn(store: &store, strikes: &strikes, rung: learnRung, versions: learnVersions, model: model,
                          observed: observed, run: run, overridden: { _ in false }, provenance: Provenance(tag: "e2.c5"),
                          tally: Tally())
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
    let enclosed = CapabilityResolver.resolve(probed: profile, enclosed: true, config: config, beliefs: resolving(store)).report.entries
    for (capability, entry) in resolved.report.entries {
        let read = Capability.blockScoped.contains(capability) && entry == .init(status: .available, source: .probed)
        precondition(enclosed[capability] == (read ? .init(status: .unavailable, source: .probed) : entry),
                     "an enclosing field turns off only what nothing else decided")
    }
}

// The focus rule before enclosing fields, which it must still match where no field names one.
func previousEdge(_ old: Focus?, _ new: Focus?) -> FocusTransition {
    guard let old, let new else { return .newSession }
    if old.forcedWindow != nil || new.forcedWindow != nil {
        return old.forcedWindow != nil && new.forcedWindow != nil && old.pid == new.pid && old.forcedWindow == new.forcedWindow
            ? .sameElement
            : .newSession
    }
    if old.element == new.element { return .sameElement }
    guard old.session?.status == .unavailable, new.session?.status == .unavailable, old.pid == new.pid, old.site == new.site,
          let oldWindow = old.window, let newWindow = new.window, oldWindow == newWindow else { return .newSession }
    return .sameDocument
}
func randomFocus(enclosing: Bool) -> Focus? {
    if coin(12) == 0 { return nil }
    let pid = Int32(coin(2))
    if coin(6) == 0 { return Focus(element: 0, pid: pid, site: "", forcedWindow: UInt32(coin(2))) }
    let page: Int? = enclosing && coin(2) == 0 ? 100 + Int(coin(2)) : nil
    // `main` denied `fieldIsSession` by a seed or the user only; the page's answer is new.
    let session = [onByDefault, onByUser, offBySeed, offByUser, offByPage][Int(coin(enclosing ? 5 : 4))]
    let window: Int? = FocusTransition.windowIsDocument(session) && coin(4) != 0 ? 7 + Int(coin(2)) : nil
    return Focus(
        element: coin(3) == 0 ? 100 + Int(coin(2)) : Int(coin(4)), pid: pid, site: ["AXTextArea", "AXTextField"][Int(coin(2))],
        session: session, enclosing: page, window: window
    )
}
var addedEdges = 0
for _ in 0..<4000 {
    let (old, new) = (randomFocus(enclosing: false), randomFocus(enclosing: false))
    precondition(edge(old, new) == previousEdge(old, new), "no field names another, so the rule is the one before")
    let (block, other) = (randomFocus(enclosing: true), randomFocus(enclosing: true))
    if edge(block, other) != previousEdge(block, other) {
        precondition(previousEdge(block, other) == .newSession && edge(block, other) == .sameDocument, "enclosing fields only join")
        addedEdges += 1
    }
}
precondition(addedEdges > 100)
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
precondition(Learning.Lesson(refuted: lengthStrike, skip: .strike, strikes: 2).traceLines(rung: learnRung, versions: learnVersions)
    == ["strike 2/3 q=insertText why=length rung=\(learnRung)"])
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
var leftDiscovered = discovered
precondition(leftDiscovered.selection == 20..<21)
leftDiscovered.refocus(.newSession)
precondition(leftDiscovered.selection == 20..<20, "the release writes the drawn cursor in field offsets")

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
for count in 1...Strikes.limit {
    ignored.type("ciw")
    precondition(ignored.learner!.lessons.last?.strikes == count)
    precondition(ignored.profile.has(.insertText) == (count < Strikes.limit), "one swallowed replace leaves the write on")
    ignored.feed("<Esc>")
}
precondition(ignored.learner!.lessons.contains { $0.committed == .insertText })
var swallowedWrites = Sim(text: "say hello world", caret: 6, profile: axProfile)
swallowedWrites.swallowsSelect = true
swallowedWrites.learn(with: Sim.Learner(probed: axProfile))
for count in 1...Strikes.limit {
    swallowedWrites.type("l")
    precondition(swallowedWrites.caret == 6 && swallowedWrites.learner!.lessons.last?.strikes == count)
    precondition(swallowedWrites.profile.has(.writeSelection) == (count < Strikes.limit), "one lost write leaves writes on")
}
swallowedWrites.type("l")
precondition(swallowedWrites.caret == 7, "then keys move the caret")
precondition(ignored.learner!.store.beliefs.map(\.judgedUnder) == [.value])
var chipKey = chromiumSim("ab\ncd", caret: 4, profile: keyProfile, markers: true, chromium: true)
chipKey.reboundChords = [.paragraphStart: .paragraphEnd]
chipKey.type("0")
precondition(chipKey.settleFailures == 1 && chipKey.blamed.isEmpty)
precondition(chipKey.attribution.evidence.contains { $0.question == .key(.lineStartKey) && $0.outcome == .neutral && $0.why == .paragraphLines })
precondition(chipKey.learner!.lessons.last?.committed == nil && chipKey.profile.has(.lineStartKey))

// MARK: - Paragraph edges

let chromiumModes: [(name: String, apply: (inout Sim) -> Void)] = [
    ("reads", { $0.reads = omitsBreaks }),
    ("markers", { $0.reads = omitsBreaks; $0.markers = true }),
    ("emptyParagraphs", { $0.emptyParagraphs = true }),
]
for mode in chromiumModes {
    for (edge, settles) in [(Expectation.Edge.paragraphStart, true), (.paragraphEnd, false)] {
        var host = Sim(text: "ab\ncd", caret: 3, profile: readProfile)
        mode.apply(&host)
        precondition(host.perform([.settle(Expectation(selection: 2..<2, edge: edge))]) == settles, "\(mode.name) \(edge)")
    }
}

var appended = Sim(text: "ab\ncd", caret: 1, profile: axProfile)
appended.reads = omitsBreaks
appended.markers = true
appended.writesInReadOffsets = true
appended.readModel = .textContent
var misplaced = appended
misplaced.ignoredChords = [.left, .selectLeft]
appended.type("A")
precondition(appended.caret == 2 && appended.settleFailures == 0 && appended.state.field.mode == .insert)
misplaced.type("A")
precondition(misplaced.caret == 3 && misplaced.settleFailures == 1, "the next paragraph's start reads the same offset")
var strandedMarkers = Sim(text: "ab cd\nef gh", caret: 5, profile: axProfile)
strandedMarkers.reads = omitsBreaks
strandedMarkers.markers = true
strandedMarkers.writesInReadOffsets = true
strandedMarkers.emulatesKeys = true
strandedMarkers.readModel = .textContent
strandedMarkers.reboundChords = [.selectRight: .selectWordRight]
strandedMarkers.type("cw")
strandedMarkers.reboundChords = [:]
strandedMarkers.type("X")
precondition(strandedMarkers.text == "ab cdX\nef gh",
             "LIN-1643: a repair reads its start's side from the markers, and collapses onto that paragraph's end")

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

var blankNeeds: [FieldSnapshot.Need] = []
func blankBuild(
    memo known: EmptyParagraphs.Memo?, unreachable knownUnreachable: UnreachableLines.Memo? = nil
) -> (snapshot: FieldSnapshot, memo: EmptyParagraphs.Memo?, unreachable: UnreachableLines.Memo?) {
    var reads = FieldSnapshot.Reads(
        field: FieldReads(text: blankValue, plain: 43..<43, markers: MarkerReads(
            breaks: blankAligned, value: blankAligned.valueRange(43..<43) { _ in .start(skipping: 0) }
        )),
        length: blankValue.utf16.count, webContent: true, blocks: blankParagraphs.count, marked: 43..<43, markerText: blankMarkers
    )
    var memo = known
    var unreachable = knownUnreachable
    return FieldSnapshot.Step.run(taking: { need in
        blankNeeds.append(need)
        switch need {
        case .side(let end): reads.sides.updateValue(.start(skipping: 0), forKey: end)
        case .emptyParagraph: reads.inEmptyParagraph = true
        case .emptyParagraphs(let value, let markers, _):
            memo = EmptyParagraphs.Memo(value: value, markers: markers, blocks: reads.blocks, found: [43])
        case .unreachable(let value, let markers, _, _):
            unreachable = UnreachableLines.Memo(value: value, markers: markers, blocks: reads.blocks, found: nil)
        }
    }) {
        FieldSnapshot.build(reads, capabilities: readProfile, answer: .textContent, anchor: nil, cursor: nil, memo: memo,
                            unreachable: unreachable)
    }
}
let blankBuilt = blankBuild(memo: nil)
precondition(blankNeeds == [
    .emptyParagraph, .emptyParagraphs(value: blankValue, markers: blankMarkers, why: .first), .side(.lower), .side(.upper),
    .unreachable(value: blankValue, markers: blankMarkers,
                 candidates: UnreachableLines.candidates(text: blankModel.text, breaks: blankModel.breaks), why: .first),
])
precondition(blankBuilt.snapshot.text == blankModel.text && blankBuilt.snapshot.selection == 45..<45 && blankBuilt.snapshot.valueGap == 1)
precondition(blankBuilt.snapshot.holdsEmptyParagraphs && !blankBuilt.snapshot.caretInEmptyParagraph, "its own line holds the caret")
blankNeeds = []
let blankRebuilt = blankBuild(memo: blankBuilt.memo, unreachable: blankBuilt.unreachable)
precondition(blankRebuilt.snapshot == blankBuilt.snapshot && blankRebuilt.memo == blankBuilt.memo)
precondition(blankNeeds == [.emptyParagraph, .side(.lower), .side(.upper)], "a memo that holds spares discovery")

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

// LIN-1643: `cw` whose ⇧→ selects a word fails its check with the selection stranded, and `c` keeps Insert where it collapses.
func strandedChange(
    _ paragraphs: [String], caret: Int, profile: CapabilityProfile, lines: [Sim.ListLine]? = nil, code: [Range<Int>] = [],
    rebound: [Chord: Chord] = [:], ignored: Set<Chord> = []
) -> Sim {
    var host = blankSim(paragraphs, caret: caret, profile: profile)
    host.listLines = lines
    host.codeSpans = code
    host.reboundChords = [.selectRight: .selectWordRight, Chord.paragraphEnd.shifted: .selectWordRight].merging(rebound) { $1 }
    host.ignoredChords = ignored
    host.type("cw")
    host.reboundChords = [:]
    host.type("X")
    return host
}
for profile in [writeKeys, keyProfile] {
    let atEnd = strandedChange(["ab cd", "ef gh"], caret: 5, profile: profile)
    precondition(atEnd.text == "ab cdX\nef gh" && atEnd.settleFailures == 1, "the repair leaves the caret at the paragraph's end")
}
let unstepped = strandedChange(["ab cd", "ef gh"], caret: 5, profile: writeKeys, ignored: [.right])
precondition(unstepped.text == "ab cd\nXef gh" && unstepped.settleFailures == 2,
             "keys the host ignores fail their settle, and a write lane then writes the start as read")
let atStart = strandedChange(["ab cd", "ef gh"], caret: 6, profile: keyProfile, rebound: [.selectLeft: .selectAll])
precondition(atStart.text == "ab cd\nXef gh" && atStart.settleFailures == 1, "and presses no ⇧← above a paragraph's start")
let numbered = [Sim.ListLine(marker: "1."), Sim.ListLine(marker: "2."), Sim.ListLine()]
precondition(strandedChange(["one", "two three", "four"], caret: 3, profile: writeKeys, lines: numbered).text
             == "oneX\ntwo three\nfour", "the snapshot's text tells that a write to a list item's end needs keys, so ← collapses there too")
let atDrawn = strandedChange(["ab x", "cd ef", "gh"], caret: 4, profile: writeKeys, lines: numbered, code: [3..<4])
precondition(atDrawn.text == "ab xX\ncd ef\ngh" && atDrawn.settleFailures == 1,
             "the caret Linear drew at the code span has gone with its <br>, so the repair reads the field again")
var insideSpan = blankSim(["ab x cd ef", "gh"], caret: 4, profile: writeKeys)
insideSpan.listLines = [Sim.ListLine(marker: "1."), Sim.ListLine(marker: "2.")]
insideSpan.codeSpans = [3..<4]
insideSpan.reboundChords = [.selectRight: .selectWordRight, Chord.paragraphEnd.shifted: .selectWordRight]
insideSpan.type("C")
insideSpan.reboundChords = [:]
insideSpan.type("X")
precondition(insideSpan.text == "ab xX cd ef\ngh" && insideSpan.settleFailures == 1,
             "a code span's end inside a paragraph is written as read")
for profile in [writeKeys, keyProfile] {
    let afterChip = strandedChange(["ab \u{2060}", "ef gh"], caret: 4, profile: profile, lines: [Sim.ListLine(), Sim.ListLine()])
    precondition(afterChip.text == "ab \u{2060}X\nef gh" && afterChip.settleFailures == 1,
                 "once the chip's image has changed AXValue, the field read again puts the caret past the chip's <br>")
}
var strandedToDo = blankSim(["one", "", "two"], caret: 4, profile: writeKeys)
strandedToDo.listLines = [Sim.ListLine(), Sim.ListLine(leaves: 2, checkbox: true), Sim.ListLine()]
strandedToDo.swallowsReplace = true
strandedToDo.type("dd")
precondition(strandedToDo.settleFailures == 1 && strandedToDo.selection == 4..<4, "a selection at a to-do's start is no caret placed there")

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
    var classes: [String] = []
    var quoteLevel = 0

    init(_ role: String, _ subrole: String? = nil, _ start: Int, _ end: Int, _ children: [FakeNode] = []) {
        self.role = role
        self.subrole = subrole
        self.start = start
        self.end = end
        self.children = children
    }

    var block: EmptyBlockScan<FakeNode>.Block? {
        fails ? nil : .init(role: role, subrole: subrole, children: children, classes: classes, quoteLevel: quoteLevel)
    }
}
func text(_ start: Int, _ end: Int) -> FakeNode { FakeNode("AXStaticText", nil, start, end) }
func paragraph(_ start: Int, _ end: Int) -> FakeNode { FakeNode("AXGroup", nil, start, end, [text(start, end)]) }
func blank(_ at: Int) -> FakeNode { FakeNode("AXGroup", "AXEmptyGroup", at, at + 1) }
func scanned(_ blocks: [FakeNode], _ plain: String, budget: Int = EmptyParagraphs.readBudget) -> [Int]? {
    var scan = EmptyBlockScan<FakeNode>(budget: budget, block: \.block, offset: { node, end in end ? node.end : node.start })
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

for mode in chromiumModes where mode.name != "reads" {
    for leaf in [false, true] {
        var host = Sim(text: "ab\ncd\nef", caret: 3, profile: keyProfile)
        mode.apply(&host)
        host.readModel = .textContent
        host.emulatesKeys = true
        host.endsInTextlessLeaf = leaf
        host.type("J")
        precondition(host.text == (leaf ? "ab\ncd\nef" : "ab\ncd ef") && host.bells == (leaf ? 1 : 0), "\(mode.name) leaf=\(leaf)")
    }
}

// A trailing blank line nets no gap, but emptying the line beside it still changes what AXValue shows.
var trailingBlank = blankSim(["a", ""], caret: 0, profile: writeKeys)
trailingBlank.type("x")
precondition(trailingBlank.text == "\n" && trailingBlank.settleFailures == 0)

// MARK: - Unreachable lines (LIN-1652)

let hiddenMarker = ParagraphBreaks(offsets: [2], hidden: [.init(at: 3, text: "1.")])
precondition(hiddenMarker.fieldOffset(2) == 2 && hiddenMarker.fieldOffset(3) == 4 && hiddenMarker.fieldOffset(5) == 6)
precondition(hiddenMarker.valueOffsets(2) == 2...2, "a caret at the marker's start is at the line above's end")
precondition(hiddenMarker.valueOffsets(3) == 3...3 && hiddenMarker.valueOffsets(4) == 3...3)
precondition(hiddenMarker.fieldText("ab\ncd", at: 0..<5) == "ab1.cd" && hiddenMarker.fieldText("cd", at: 3..<5) == "cd")
precondition(hiddenMarker.fieldText("b\n", at: 1..<3) == "b1.", "a line's AXSelectedText runs through the next marker")
precondition(hiddenMarker.replacing(3..<4, with: "") == ParagraphBreaks(offsets: [2], hidden: [.init(at: 3, text: "1.")]))
precondition(hiddenMarker.replacing(0..<3, with: "") == ParagraphBreaks(offsets: []))
precondition(hiddenMarker.replacing(0..<3, with: "", keepingCovered: true) == ParagraphBreaks(hidden: [.init(at: 0, text: "1.")]))
precondition(hiddenMarker.covers(1..<3) && !hiddenMarker.covers(3..<5))

// "T[abc]" then "Next": the chip is one model character, and the <br> after it is the model's newline.
let chipBreaks = ParagraphBreaks(offsets: [2], hidden: [
    .init(at: 2, text: "bc", kind: .atom), .init(at: 2, text: "\n", kind: .trailingBreak),
])
precondition((0...7).map(chipBreaks.fieldOffset) == [0, 1, 5, 5, 6, 7, 8, 9])
precondition(chipBreaks.fieldRange(1..<2) == 1..<4 && chipBreaks.fieldRange(1..<3) == 1..<5 && chipBreaks.fieldRange(2..<3) == 4..<5,
             "a caret after the chip reads past its <br>, a selection's end stops before it")
precondition(chipBreaks.fieldText("a", at: 1..<2) == "abc" && chipBreaks.fieldText("a\n", at: 1..<3) == "abc\n")
precondition(chipBreaks.valueRange(5..<5) { _ in .end } == 2..<2 && chipBreaks.valueRange(5..<5) { _ in .start(skipping: 0) } == 3..<3)
precondition(chipBreaks.valueRange(1..<4) { _ in nil } == 1..<2)
precondition(chipBreaks.isAtom(1) && !chipBreaks.isAtom(0) && chipBreaks.atoms == [1])
precondition(chipBreaks.withAtoms("Ta\nN", at: 0..<4) == "Tabc\nN" && chipBreaks.coversAtom(0..<2) && !chipBreaks.coversAtom(2..<4))
precondition(chipBreaks.replacing(1..<2, with: "") == ParagraphBreaks(offsets: [1]), "deleting the chip takes its <br>")

/// `path/role/start/end` per node, roles abbreviated, as softlash/LIN-1652 scripts/list-probe prints a tree; B is one of
/// Linear's `block-node` groups, Q one that is a quote, N a `node-controls` group and R a rule; roots carry Linear's classes,
/// which `linear` false leaves out.
func fakeTree(_ spec: String, linear: Bool = true) -> [FakeNode] {
    let roles: [Character: (String, String?)] = [
        "L": ("AXList", "AXContentList"), "G": ("AXGroup", nil), "T": ("AXStaticText", nil), "H": ("AXHeading", nil),
        "E": ("AXGroup", "AXEmptyGroup"), "A": ("AXGroup", "AXApplicationGroup"), "K": ("AXLink", nil),
        "I": ("AXImage", nil), "C": ("AXCheckBox", nil), "P": ("AXPopUpButton", nil), "M": ("AXListMarker", nil),
        "D": ("AXGroup", "AXCodeStyleGroup"), "S": ("AXGroup", "AXStrongStyleGroup"), "F": ("AXGroup", "AXEmphasisStyleGroup"),
        "B": ("AXGroup", nil), "Q": ("AXGroup", nil), "N": ("AXGroup", nil), "R": ("AXSplitter", nil),
    ]
    var nodes: [[Int]: (code: Character, start: Int, end: Int)] = [:]
    for token in spec.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
        let parts = token.split(separator: "/")
        nodes[parts[0].split(separator: ".").map { Int($0)! }] = (parts[1].first!, Int(parts[2])!, Int(parts[3])!)
    }
    func build(_ path: [Int]) -> FakeNode {
        let node = nodes[path]!
        let children = (0...).prefix { nodes[path + [$0]] != nil }.map { build(path + [$0]) }
        let built = FakeNode(roles[node.code]!.0, roles[node.code]!.1, node.start, node.end, children)
        if linear, "BQ".contains(node.code) { built.classes = [UnreachableLines.blockClass] }
        if linear, node.code == "N" { built.classes = [UnreachableLines.controlsClass] }
        if linear, path.count == 1, let kind = ["G": "text-node", "E": "text-node", "L": "list-node", "H": "heading-node"][node.code] {
            built.classes = [kind]
        }
        if node.code == "Q" { built.quoteLevel = 1 }
        return built
    }
    return (0...).prefix { nodes[[$0]] != nil }.map { build([$0]) }
}
func unreachableScanned(
    _ blocks: [FakeNode], _ candidates: UnreachableLines.Candidates, budget: Int = UnreachableLines.readBudget
) -> UnreachableLines.Found? {
    var scan = UnreachableScan<FakeNode>(budget: budget, block: \.block, offset: { node, end in end ? node.end : node.start })
    return scan.run(blocks: blocks, candidates: candidates)
}
func folded(_ value: String, _ raw: String, _ tree: [FakeNode]) -> UnreachableLines.Model {
    let plain = MarkerText.plain(raw)
    let aligned = ParagraphBreaks(value: value, fieldText: plain)!
    let restored = EmptyParagraphs.restore(value: value, fieldText: plain, aligned: aligned, found: scanned(tree, plain)!)!
    let candidates = UnreachableLines.candidates(text: restored.text, breaks: restored.breaks, raw: raw, proseMirror: true)
    return UnreachableLines.fold(text: restored.text, breaks: restored.breaks, raw: raw,
                                 found: unreachableScanned(tree, candidates)!)
}
func roundTrips(_ model: UnreachableLines.Model) -> Bool {
    let units = Array(model.text.utf16)
    return (0...units.count).allSatisfy { caret in
        let field = model.breaks.fieldOffset(caret)
        let side: ParagraphBreaks.Side = caret == 0 || units[caret - 1] == 10 ? .start(skipping: 0) : .end
        return model.breaks.valueRange(field..<field) { _ in side } == caret..<caret
    }
}

// Dia 1.49.1 on linear.app, probed by softlash/LIN-1652 scripts/list-probe.
let dia1Value = [
    "Top paragraph of the LIN-1652 disposable list probe.", "1.", "Numbered one", "2.", "Numbered two", "a.",
    "Nested numbered one", "b.", "Nested numbered two", "3.", "Numbered three",
    "Middle paragraph after the numbered list.", "\u{2022}", "Bullet one", "\u{25E6}", "Nested bullet one",
    "\u{2022}", "Double nested bullet", "\u{2022}", "Bullet with a mention ",
    "\u{2060}\u{00A0}LIN-1645 Why j/k always beeps in Linear (macbook14 logs)", "\u{2022}", "Bullet two", "", "",
    "Heading two", "", "", "To-do open", "", "", "To-do done", "1.", "Paragraph after a literal one-dot line.",
    "\u{2022}", "9.", "Ninth item", "10.", "Tenth item", "11.", "Eleventh item", "Last paragraph."
].joined(separator: "\n")
let dia1Raw = "Top paragraph of the LIN-1652 disposable list probe.1.Numbered one2.Numbered twoa.Nested numbered o"
    + "neb.Nested numbered two3.Numbered threeMiddle paragraph after the numbered list.\u{2022}Bullet one\u{25E6}"
    + "Nested bullet one\u{2022}Double nested bullet\u{2022}Bullet with a mention \u{2060}\u{00A0}LIN-1645"
    + " Why j/k always beeps in Linear (macbook14 logs)\n\u{2022}Bullet two\u{FFFC}\u{FFFC}Heading two\u{FFFC}"
    + "\u{FFFC}To-do open\u{FFFC}\u{FFFC}To-do done1.Paragraph after a literal one-dot line.\u{2022}9.Nint"
    + "h item10.Tenth item11.Eleventh itemLast paragraph."
let dia1Spec = """
0/G/0/52 0.0/T/0/52 1/L/52/138 1.0/G/52/66 1.0.0/G/52/54 1.0.0.0/T/52/53 1.0.0.1/T/53/54 1.0.1/G/54/66
1.0.1.0/T/54/66 1.1/G/66/122 1.1.0/G/66/68 1.1.0.0/T/66/67 1.1.0.1/T/67/68 1.1.1/G/68/80 1.1.1.0/T/68/80
1.1.2/L/80/122 1.1.2.0/G/80/101 1.1.2.0.0/G/80/82 1.1.2.0.0.0/T/80/81 1.1.2.0.0.1/T/81/82 1.1.2.0.1/G/82/101
1.1.2.0.1.0/T/82/101 1.1.2.1/G/101/122 1.1.2.1.0/G/101/103 1.1.2.1.0.0/T/101/102 1.1.2.1.0.1/T/102/103
1.1.2.1.1/G/103/122 1.1.2.1.1.0/T/103/122 1.2/G/122/138 1.2.0/G/122/124 1.2.0.0/T/122/123 1.2.0.1/T/123/124
1.2.1/G/124/138 1.2.1.0/T/124/138 2/G/138/179 2.0/T/138/179 3/L/179/322 3.0/G/179/229 3.0.0/G/179/180
3.0.0.0/T/179/180 3.0.1/G/180/190 3.0.1.0/T/180/190 3.0.2/L/190/229 3.0.2.0/G/190/229 3.0.2.0.0/G/190/191
3.0.2.0.0.0/T/190/191 3.0.2.0.1/G/191/208 3.0.2.0.1.0/T/191/208 3.0.2.0.2/L/208/229 3.0.2.0.2.0/G/208/229
3.0.2.0.2.0.0/G/208/209 3.0.2.0.2.0.0.0/T/208/209 3.0.2.0.2.0.1/G/209/229 3.0.2.0.2.0.1.0/T/209/229
3.1/G/229/311 3.1.0/G/229/230 3.1.0.0/T/229/230 3.1.1/G/230/311 3.1.1.0/T/230/252 3.1.1.1/A/252/310
3.1.1.1.0/K/252/310 3.1.1.1.0.0/T/252/253 3.1.1.1.0.1/T/253/254 3.1.1.1.0.2/T/254/262 3.1.1.1.0.3/T/262/263
3.1.1.1.0.4/T/263/310 3.2/G/311/322 3.2.0/G/311/312 3.2.0.0/T/311/312 3.2.1/G/312/322 3.2.1.0/T/312/322
4/H/322/333 4.0/G/322/322 4.0.0/G/322/322 4.0.0.0/E/322/322 4.0.0.1/P/322/322 4.1/T/322/333 5/L/333/353
5.0/G/333/343 5.0.0/G/333/333 5.0.0.0/I/333/333 5.0.0.1/C/333/333 5.0.1/G/333/343 5.0.1.0/G/333/343
5.0.1.0.0/T/333/343 5.1/G/343/353 5.1.0/G/343/343 5.1.0.0/I/343/343 5.1.0.1/C/343/343 5.1.1/G/343/353
5.1.1.0/G/343/353 5.1.1.0.0/T/343/353 6/G/353/355 6.0/T/353/355 7/G/355/394 7.0/T/355/394 8/G/394/395
8.0/T/394/395 9/L/395/436 9.0/G/395/407 9.0.0/G/395/397 9.0.0.0/T/395/396 9.0.0.1/T/396/397 9.0.1/G/397/407
9.0.1.0/T/397/407 9.1/G/407/420 9.1.0/G/407/410 9.1.0.0/T/407/409 9.1.0.1/T/409/410 9.1.1/G/410/420
9.1.1.0/T/410/420 9.2/G/420/436 9.2.0/G/420/423 9.2.0.0/T/420/422 9.2.0.1/T/422/423 9.2.1/G/423/436
9.2.1.0/T/423/436 10/G/436/451 10.0/T/436/451
"""
let dia1Tree = fakeTree(dia1Spec)
let dia2Value = [
    "Second probe of LIN-1652 list shapes.", "\u{2022}", "Bullet before empty", "\u{2022}", "\u{2022}",
    "Bullet after empty", "1.", "One", "2.", "3.", "Three", "", "", "To-do before empty", "", "",
    "To-do after empty", "\u{2022}", "Line one of a soft break", "\u{200B}line two of a soft break", "\u{2022}",
    "Para one of a loose item", "Para two of a loose item", "\u{2022}", "Before ",
    "\u{2060}\u{00A0}LIN-1645 Why j/k always beeps in Linear (macbook14 logs)", " after the chip", "\u{2022}", "",
    "\u{2060}\u{00A0}LIN-1641 Build mvim's field snapshots with one pure builder shared by the runtime and the Sim",
    "1.", "Quoted paragraph", "\u{2022}", "Quoted bullet", "", "", "Heading between", "Closing paragraph."
].joined(separator: "\n")
let dia2Raw = "Second probe of LIN-1652 list shapes.\u{2022}Bullet before empty\u{2022}\n\u{2022}Bullet after empt"
    + "y1.One2.\n3.Three\u{FFFC}\u{FFFC}To-do before empty\u{FFFC}\u{FFFC}\n\u{FFFC}\u{FFFC}To-do after em"
    + "pty\u{2022}Line one of a soft break\n\u{200B}line two of a soft break\u{2022}Para one of a loose it"
    + "emPara two of a loose item\u{2022}Before \u{2060}\u{00A0}LIN-1645 Why j/k always beeps in Linear (m"
    + "acbook14 logs) after the chip\u{2022}\u{FFFC}\u{2060}\u{00A0}LIN-1641 Build mvim's field snapshots "
    + "with one pure builder shared by the runtime and the Sim\n1.\nQuoted paragraph\u{2022}Quoted bullet\u{FFFC}"
    + "\u{FFFC}Heading betweenClosing paragraph."
let dia2Tree = fakeTree("""
0/G/0/37 0.0/T/0/37 1/L/37/78 1.0/G/37/57 1.0.0/G/37/38 1.0.0.0/T/37/38 1.0.1/G/38/57 1.0.1.0/T/38/57
1.1/G/57/59 1.1.0/G/57/58 1.1.0.0/T/57/58 1.1.1/E/58/59 1.2/G/59/78 1.2.0/G/59/60 1.2.0.0/T/59/60 1.2.1/G/60/78
1.2.1.0/T/60/78 2/L/78/93 2.0/G/78/83 2.0.0/G/78/80 2.0.0.0/T/78/79 2.0.0.1/T/79/80 2.0.1/G/80/83
2.0.1.0/T/80/83 2.1/G/83/86 2.1.0/G/83/85 2.1.0.0/T/83/84 2.1.0.1/T/84/85 2.1.1/E/85/86 2.2/G/86/93
2.2.0/G/86/88 2.2.0.0/T/86/87 2.2.0.1/T/87/88 2.2.1/G/88/93 2.2.1.0/T/88/93 3/L/93/410 3.0/G/93/111
3.0.0/G/93/93 3.0.0.0/I/93/93 3.0.0.1/C/93/93 3.0.1/G/93/111 3.0.1.0/G/93/111 3.0.1.0.0/T/93/111 3.1/G/111/112
3.1.0/G/111/111 3.1.0.0/I/111/111 3.1.0.1/C/111/111 3.1.1/E/111/112 3.1.1.0/E/111/112 3.2/G/112/129
3.2.0/G/112/112 3.2.0.0/I/112/112 3.2.0.1/C/112/112 3.2.1/G/112/129 3.2.1.0/G/112/129 3.2.1.0.0/T/112/129
3.3/G/129/180 3.3.0/G/129/130 3.3.0.0/T/129/130 3.3.1/G/130/180 3.3.1.0/T/130/154 3.3.1.1/T/155/156
3.3.1.2/T/156/180 3.4/G/180/229 3.4.0/G/180/181 3.4.0.0/T/180/181 3.4.1/G/181/205 3.4.1.0/T/181/205
3.4.2/G/205/229 3.4.2.0/T/205/229 3.5/G/229/310 3.5.0/G/229/230 3.5.0.0/T/229/230 3.5.1/G/230/310
3.5.1.0/T/230/237 3.5.1.1/A/237/295 3.5.1.1.0/K/237/295 3.5.1.1.0.0/T/237/238 3.5.1.1.0.1/T/238/239
3.5.1.1.0.2/T/239/247 3.5.1.1.0.3/T/247/248 3.5.1.1.0.4/T/248/295 3.5.1.2/T/295/310 3.6/G/310/407
3.6.0/G/310/311 3.6.0.0/T/310/311 3.6.1/G/311/407 3.6.1.0/A/311/406 3.6.1.0.0/K/311/406 3.6.1.0.0.0/I/311/311
3.6.1.0.0.1/T/311/312 3.6.1.0.0.2/T/312/313 3.6.1.0.0.3/T/313/321 3.6.1.0.0.4/T/321/322 3.6.1.0.0.5/T/322/406
3.7/G/407/410 3.7.0/L/407/410 3.7.0.0/G/407/410 3.7.0.0.0/G/407/409 3.7.0.0.0.0/T/407/408 3.7.0.0.0.1/T/408/409
3.7.0.0.1/E/409/410 4/G/410/440 4.0/G/410/426 4.0.0/T/410/426 4.1/L/426/440 4.1.0/G/426/440 4.1.0.0/G/426/427
4.1.0.0.0/T/426/427 4.1.0.1/G/427/440 4.1.0.1.0/T/427/440 5/H/440/455 5.0/G/440/440 5.0.0/G/440/440
5.0.0.0/E/440/440 5.0.0.1/P/440/440 5.1/T/440/455 6/G/455/473 6.0/T/455/473
""")
let dia1Plain = MarkerText.plain(dia1Raw)
let dia1Aligned = ParagraphBreaks(value: dia1Value, fieldText: dia1Plain)!
let dia1Candidates = UnreachableLines.candidates(text: dia1Value, breaks: dia1Aligned)
precondition(dia1Candidates.markers.map(\.lowerBound) == [52, 66, 80, 101, 122, 179, 190, 208, 229, 311, 353, 394, 395, 407, 420])
precondition(dia1Candidates.chips == [252..<310])
let dia1Found = unreachableScanned(dia1Tree, dia1Candidates)!
precondition(dia1Found.markers == [52, 66, 80, 101, 122, 179, 190, 208, 229, 311, 395, 407, 420],
             "the paragraphs that only read 1. and • are no list's")
precondition(dia1Found.chips == [UnreachableLines.Chip(range: 252..<310, paragraph: 230..<311)])
let dia1Lines = [
    "Top paragraph of the LIN-1652 disposable list probe.", "Numbered one", "Numbered two", "Nested numbered one",
    "Nested numbered two", "Numbered three", "Middle paragraph after the numbered list.", "Bullet one", "Nested bullet one",
    "Double nested bullet", "Bullet with a mention \u{2060}", "Bullet two", "Heading two", "To-do open", "To-do done", "1.",
    "Paragraph after a literal one-dot line.", "\u{2022}", "Ninth item", "Tenth item", "Eleventh item", "Last paragraph.",
]
let dia1Model = folded(dia1Value, dia1Raw, dia1Tree)
precondition(dia1Model.text == dia1Lines.joined(separator: "\n"), "the lines a caret reaches, as Linear shows them")
precondition(dia1Model.folded == dia1Value.utf16.count - dia1Model.text.utf16.count)
precondition(dia1Model.breaks.fieldText(dia1Model.text, at: 0..<dia1Model.text.utf16.count) == dia1Plain)
precondition(roundTrips(dia1Model))

let dia2Plain = MarkerText.plain(dia2Raw)
precondition(scanned(dia2Tree, dia2Plain) == [58, 85, 111, 409], "each empty item's <br>, the to-do's included")
let dia2Model = folded(dia2Value, dia2Raw, dia2Tree)
precondition(dia2Model.text == [
    "Second probe of LIN-1652 list shapes.", "Bullet before empty", "", "Bullet after empty", "One", "", "Three",
    "To-do before empty", "", "To-do after empty", "Line one of a soft break", "\u{200B}line two of a soft break",
    "Para one of a loose item", "Para two of a loose item", "Before \u{2060} after the chip", "\u{2060}", "",
    "Quoted paragraph", "Quoted bullet", "Heading between", "Closing paragraph.",
].joined(separator: "\n"), "an empty item keeps its line, a chip with an icon is one character, and a quote's list folds too")
precondition(dia2Model.breaks.fieldText(dia2Model.text, at: 0..<dia2Model.text.utf16.count) == dia2Plain)
precondition(roundTrips(dia2Model))

// Chips inside, ending, starting and alone in paragraphs and items.
let dia6Value = [
    "Chip probe opening paragraph.", "Before ",
    "\u{2060}\u{00A0}LIN-1645 Why j/k always beeps in Linear (macbook14 logs)", " after the chip.",
    "Text then a chip ",
    "\u{2060}\u{00A0}LIN-1641 Build mvim's field snapshots with one pure builder shared by the runtime and the Sim",
    "\u{2060}\u{00A0}LIN-1645 Why j/k always beeps in Linear (macbook14 logs)", " chip then text.",
    "\u{2060}\u{00A0}LIN-1641 Build mvim's field snapshots with one pure builder shared by the runtime and the Sim",
    "\u{2022}", "Item before ", "\u{2060}\u{00A0}LIN-1645 Why j/k always beeps in Linear (macbook14 logs)",
    " and after", "\u{2022}", "Plain item", "\u{2022}",
    "\u{2060}\u{00A0}LIN-1641 Build mvim's field snapshots with one pure builder shared by the runtime and the Sim",
    " chip first item", "Closing paragraph of the chip probe."
].joined(separator: "\n")
let dia6Raw = "Chip probe opening paragraph.Before \u{2060}\u{00A0}LIN-1645 Why j/k always beeps in Linear (macboo"
    + "k14 logs) after the chip.Text then a chip \u{2060}\u{00A0}LIN-1641 Build mvim's field snapshots wit"
    + "h one pure builder shared by the runtime and the Sim\n\u{2060}\u{00A0}LIN-1645 Why j/k always beeps"
    + " in Linear (macbook14 logs) chip then text.\u{2060}\u{00A0}LIN-1641 Build mvim's field snapshots wi"
    + "th one pure builder shared by the runtime and the Sim\n\u{2022}Item before \u{2060}\u{00A0}LIN-1645"
    + " Why j/k always beeps in Linear (macbook14 logs) and after\u{2022}Plain item\u{2022}\u{2060}\u{00A0}"
    + "LIN-1641 Build mvim's field snapshots with one pure builder shared by the runtime and the Sim chip "
    + "first itemClosing paragraph of the chip probe."
let dia6Tree = fakeTree("""
0/G/0/29 0.0/T/0/29 1/G/29/110 1.0/T/29/36 1.1/A/36/94 1.1.0/K/36/94 1.1.0.0/T/36/37 1.1.0.1/T/37/38
1.1.0.2/T/38/46 1.1.0.3/T/46/47 1.1.0.4/T/47/94 1.2/T/94/110 2/G/110/223 2.0/T/110/127 2.1/A/127/222
2.1.0/K/127/222 2.1.0.0/T/127/128 2.1.0.1/T/128/129 2.1.0.2/T/129/137 2.1.0.3/T/137/138 2.1.0.4/T/138/222
3/G/223/297 3.0/A/223/281 3.0.0/K/223/281 3.0.0.0/T/223/224 3.0.0.1/T/224/225 3.0.0.2/T/225/233
3.0.0.3/T/233/234 3.0.0.4/T/234/281 3.1/T/281/297 4/G/297/393 4.0/A/297/392 4.0.0/K/297/392 4.0.0.0/T/297/298
4.0.0.1/T/298/299 4.0.0.2/T/299/307 4.0.0.3/T/307/308 4.0.0.4/T/308/392 5/L/393/597 5.0/G/393/474
5.0.0/G/393/394 5.0.0.0/T/393/394 5.0.1/G/394/474 5.0.1.0/T/394/406 5.0.1.1/A/406/464 5.0.1.1.0/K/406/464
5.0.1.1.0.0/T/406/407 5.0.1.1.0.1/T/407/408 5.0.1.1.0.2/T/408/416 5.0.1.1.0.3/T/416/417 5.0.1.1.0.4/T/417/464
5.0.1.2/T/464/474 5.1/G/474/485 5.1.0/G/474/475 5.1.0.0/T/474/475 5.1.1/G/475/485 5.1.1.0/T/475/485
5.2/G/485/597 5.2.0/G/485/486 5.2.0.0/T/485/486 5.2.1/G/486/597 5.2.1.0/A/486/581 5.2.1.0.0/K/486/581
5.2.1.0.0.0/T/486/487 5.2.1.0.0.1/T/487/488 5.2.1.0.0.2/T/488/496 5.2.1.0.0.3/T/496/497 5.2.1.0.0.4/T/497/581
5.2.1.1/T/581/597 6/G/597/633 6.0/T/597/633
""")
let dia6Plain = MarkerText.plain(dia6Raw)
let dia6Candidates = UnreachableLines.candidates(text: dia6Value, breaks: ParagraphBreaks(value: dia6Value, fieldText: dia6Plain)!)
precondition(dia6Candidates.chips.map(\.lowerBound) == [36, 127, 223, 297, 406, 486])
let dia6Found = unreachableScanned(dia6Tree, dia6Candidates)!
precondition(dia6Found.markers == [393, 474, 485])
precondition(dia6Found.chips.map(\.paragraph) == [29..<110, 110..<223, 223..<297, 297..<393, 394..<474, 486..<597])
let dia6Model = folded(dia6Value, dia6Raw, dia6Tree)
precondition(dia6Model.text == [
    "Chip probe opening paragraph.", "Before \u{2060} after the chip.", "Text then a chip \u{2060}", "\u{2060} chip then text.",
    "\u{2060}", "Item before \u{2060} and after", "Plain item", "\u{2060} chip first item", "Closing paragraph of the chip probe.",
].joined(separator: "\n"))
precondition(dia6Model.breaks.fieldText(dia6Model.text, at: 0..<dia6Model.text.utf16.count) == dia6Plain)
precondition(roundTrips(dia6Model))
precondition(dia6Model.breaks.atoms == [37, 72, 74, 92, 106, 129])

// A space after a chip shares the chip's line.
let dia7Value = [
    "Space probe opening paragraph.", "Two chips ",
    "\u{2060}\u{00A0}LIN-1645 Why j/k always beeps in Linear (macbook14 logs) ",
    "\u{2060}\u{00A0}LIN-1641 Build mvim's field snapshots with one pure builder shared by the runtime and the Sim",
    " end.", "Chip then space ", "\u{2060}\u{00A0}LIN-1645 Why j/k always beeps in Linear (macbook14 logs)",
    "\u{2022}", "\u{2060}\u{00A0}LIN-1641 Build mvim's field snapshots with one pure builder shared by the runtime and the Sim",
    "\u{2022}", "\u{2060}\u{00A0}LIN-1645 Why j/k always beeps in Linear (macbook14 logs) ",
    "\u{2060}\u{00A0}LIN-1641 Build mvim's field snapshots with one pure builder shared by the runtime and the Sim",
    "\u{2022}", "Plain item", "Closing paragraph of the space probe.",
].joined(separator: "\n")
let dia7Raw = "Space probe opening paragraph.Two chips \u{2060}\u{00A0}LIN-1645 Why j/k always beeps in Linear "
    + "(macbook14 logs) \u{2060}\u{00A0}LIN-1641 Build mvim's field snapshots with one pure builder sha"
    + "red by the runtime and the Sim end.Chip then space \u{2060}\u{00A0}LIN-1645 Why j/k always beeps"
    + " in Linear (macbook14 logs)\n\u{2022}\u{2060}\u{00A0}LIN-1641 Build mvim's field snapshots with "
    + "one pure builder shared by the runtime and the Sim\n\u{2022}\u{2060}\u{00A0}LIN-1645 Why j/k alw"
    + "ays beeps in Linear (macbook14 logs) \u{2060}\u{00A0}LIN-1641 Build mvim's field snapshots with "
    + "one pure builder shared by the runtime and the Sim\n\u{2022}Plain itemClosing paragraph of the s"
    + "pace probe."
let dia7Spec = """
0/G/0/30 0.0/T/0/30 1/G/30/199 1.0/T/30/40 1.1/A/40/98 1.1.0/K/40/98 1.1.0.0/T/40/41 1.1.0.1/T/41/42
1.1.0.2/T/42/50 1.1.0.3/T/50/51 1.1.0.4/T/51/98 1.2/T/98/99 1.3/A/99/194 1.3.0/K/99/194 1.3.0.0/T/99/100
1.3.0.1/T/100/101 1.3.0.2/T/101/109 1.3.0.3/T/109/110 1.3.0.4/T/110/194 1.4/T/194/199 2/G/199/274 2.0/T/199/215
2.1/A/215/273 2.1.0/K/215/273 2.1.0.0/T/215/216 2.1.0.1/T/216/217 2.1.0.2/T/217/225 2.1.0.3/T/225/226
2.1.0.4/T/226/273 3/L/274/538 3.0/G/274/371 3.0.0/G/274/275 3.0.0.0/T/274/275 3.0.1/G/275/371 3.0.1.0/A/275/370
3.0.1.0.0/K/275/370 3.0.1.0.0.0/T/275/276 3.0.1.0.0.1/T/276/277 3.0.1.0.0.2/T/277/285 3.0.1.0.0.3/T/285/286
3.0.1.0.0.4/T/286/370 3.1/G/371/527 3.1.0/G/371/372 3.1.0.0/T/371/372 3.1.1/G/372/527 3.1.1.0/A/372/430
3.1.1.0.0/K/372/430 3.1.1.0.0.0/T/372/373 3.1.1.0.0.1/T/373/374 3.1.1.0.0.2/T/374/382 3.1.1.0.0.3/T/382/383
3.1.1.0.0.4/T/383/430 3.1.1.1/T/430/431 3.1.1.2/A/431/526 3.1.1.2.0/K/431/526 3.1.1.2.0.0/T/431/432
3.1.1.2.0.1/T/432/433 3.1.1.2.0.2/T/433/441 3.1.1.2.0.3/T/441/442 3.1.1.2.0.4/T/442/526 3.2/G/527/538
3.2.0/G/527/528 3.2.0.0/T/527/528 3.2.1/G/528/538 3.2.1.0/T/528/538 4/G/538/575 4.0/T/538/575
"""
let dia7Tree = fakeTree(dia7Spec)
let dia7Plain = MarkerText.plain(dia7Raw)
let dia7Candidates = UnreachableLines.candidates(text: dia7Value, breaks: ParagraphBreaks(value: dia7Value, fieldText: dia7Plain)!)
let dia7Found = unreachableScanned(dia7Tree, dia7Candidates)!
precondition(dia7Found.chips.map(\.range) == [40..<98, 99..<194, 215..<273, 275..<370, 372..<430, 431..<526])
let dia7Model = folded(dia7Value, dia7Raw, dia7Tree)
precondition(dia7Model.text == [
    "Space probe opening paragraph.", "Two chips \u{2060} \u{2060} end.", "Chip then space \u{2060}", "\u{2060}",
    "\u{2060} \u{2060}", "Plain item", "Closing paragraph of the space probe.",
].joined(separator: "\n"))
precondition(dia7Model.breaks.fieldText(dia7Model.text, at: 0..<dia7Model.text.utf16.count) == dia7Plain)
precondition(roundTrips(dia7Model))
precondition(dia7Model.breaks.atoms == [41, 43, 66, 68, 70, 72])

// Chromium's own lists start each item's line with its marker.
let dia8Value = [
    "Native list probe opening paragraph.", "\u{2022} First bullet item", "\u{2022} Second bullet item",
    "\u{25E6} Nested circle item", "\u{2022} ", "\u{2022} After empty", "Middle paragraph between the lists.",
    "9. Nine", "10. Ten is longer", "i. Roman one", "ii. Roman two", "Closing paragraph.",
].joined(separator: "\n")
let dia8Raw = "Native list probe opening paragraph.\u{2022} First bullet item\u{2022} Second bullet item"
    + "\u{25E6} Nested circle item\u{2022} \n\u{2022} After emptyMiddle paragraph between the lists.9. "
    + "Nine10. Ten is longeri. Roman oneii. Roman twoClosing paragraph."
let dia8Tree = fakeTree("""
0/G/0/36 0.0/T/0/36 1/L/36/111 1.0/G/36/55 1.0.0/M/36/38 1.0.1/T/38/55 1.1/G/55/95 1.1.0/M/55/57 1.1.1/T/57/75
1.1.2/L/75/95 1.1.2.0/G/75/95 1.1.2.0.0/M/75/77 1.1.2.0.1/T/77/95 1.2/G/95/98 1.2.0/M/95/97 1.3/G/98/111
1.3.0/M/98/100 1.3.1/T/100/111 2/G/111/146 2.0/T/111/146 3/L/146/170 3.0/G/146/153 3.0.0/M/146/149
3.0.1/T/149/153 3.1/G/153/170 3.1.0/M/153/157 3.1.1/T/157/170 4/L/170/195 4.0/G/170/182 4.0.0/M/170/173
4.0.1/T/173/182 4.1/G/182/195 4.1.0/M/182/186 4.1.1/T/186/195 5/G/195/213 5.0/T/195/213
""")
let dia8Plain = MarkerText.plain(dia8Raw)
let dia8Candidates = UnreachableLines.candidates(text: dia8Value, breaks: ParagraphBreaks(value: dia8Value, fieldText: dia8Plain)!)
precondition(dia8Candidates.markers == [36..<38, 55..<57, 75..<77, 95..<97, 98..<100, 146..<149, 153..<157, 170..<173, 182..<186])
precondition(unreachableScanned(dia8Tree, dia8Candidates)?.markers == dia8Candidates.markers.map(\.lowerBound))
let dia8Model = folded(dia8Value, dia8Raw, dia8Tree)
precondition(dia8Model.text == [
    "Native list probe opening paragraph.", "First bullet item", "Second bullet item", "Nested circle item", "",
    "After empty", "Middle paragraph between the lists.", "Nine", "Ten is longer", "Roman one", "Roman two",
    "Closing paragraph.",
].joined(separator: "\n"))
precondition(dia8Model.breaks.fieldText(dia8Model.text, at: 0..<dia8Model.text.utf16.count) == dia8Plain)
precondition(roundTrips(dia8Model))
precondition([(36, 2, 37), (55, 2, 55), (95, 2, 93), (98, 2, 94), (146, 3, 142), (153, 4, 147)].allSatisfy { field, skip, model in
    dia8Model.breaks.valueRange(field..<field) { _ in .start(skipping: skip) } == model..<model
}, "a caret read at a marker's start and past it is at its item's start")
precondition(dia8Model.breaks.valueRange(36..<36) { _ in .end } == 36..<36 && dia8Model.breaks.valueRange(95..<95) { _ in .end } == 92..<92)
let dia9Value = "Third list probe top paragraph.\n\u{2022} One\n\u{2022} \nBetween.\n1. Only\n2. \n3. \n"
let dia9Raw = "Third list probe top paragraph.\u{2022} One\u{2022} \nBetween.1. Only2. \n3. \n"
let dia9Tree = fakeTree("""
0/G/0/31 0.0/T/0/31 1/L/31/39 1.0/G/31/36 1.0.0/M/31/33 1.0.1/T/33/36 1.1/G/36/39 1.1.0/M/36/38 2/G/39/47 2.0/T/39/47
3/L/47/62 3.0/G/47/54 3.0.0/M/47/50 3.0.1/T/50/54 3.1/G/54/58 3.1.0/M/54/57 3.2/G/58/62 3.2.0/M/58/61
""")
let dia9Model = folded(dia9Value, dia9Raw, dia9Tree)
precondition(dia9Model.text == "Third list probe top paragraph.\nOne\n\nBetween.\nOnly\n\n", "an empty last item's <br> is no line")
precondition(dia9Model.breaks.fieldOffset(dia9Model.text.utf16.count) == 61 && roundTrips(dia9Model))
precondition(unreachableScanned([FakeNode("AXList", "AXContentList", 0, 7, [paragraph(0, 7)])],
                                UnreachableLines.Candidates(markers: [0..<2], chips: []))?.markers == [])

let noUnreachable = UnreachableLines.Found(markers: [], chips: [])
let dia1Unfound = UnreachableLines.fold(text: dia1Value, breaks: dia1Aligned, raw: dia1Raw, found: noUnreachable)
precondition(dia1Unfound.text.contains("\n1.\nNumbered one") && !dia1Unfound.text.contains("To-do open\n\n"),
             "without discovery markers stay lines, and leaves still fold")
precondition(UnreachableLines.fold(text: "ab\ncd", breaks: ParagraphBreaks(offsets: [2]), raw: "abcd", found: noUnreachable)
             == UnreachableLines.Model(text: "ab\ncd", breaks: ParagraphBreaks(offsets: [2]), folded: 0), "nothing to fold")
let chipLast = UnreachableLines.fold(text: "a\n\u{2022}\nChip\n", breaks: ParagraphBreaks(offsets: [1, 3]), raw: "a\u{2022}Chip\n",
                                     found: UnreachableLines.Found(markers: [1], chips: [.init(range: 2..<6, paragraph: 2..<7)]))
precondition(chipLast.text == "a\nC" && chipLast.breaks.fieldOffset(3) == 7, "a <br> ending the field leaves no line")

let todoOne = FakeNode("AXList", "AXContentList", 0, 2, [FakeNode("AXGroup", nil, 0, 2, [
    FakeNode("AXGroup", nil, 0, 0, [FakeNode("AXCheckBox", nil, 0, 0)]), paragraph(0, 2),
])])
precondition(unreachableScanned([todoOne], UnreachableLines.Candidates(markers: [0..<2], chips: []))?.markers == [],
             "a to-do reading 1. has a checkbox where a marker would be")
precondition(unreachableScanned(dia6Tree, UnreachableLines.Candidates(markers: [], chips: [29..<36]))?.chips == [],
             "text is no chip")
dia1Tree[1].children[0].fails = true
precondition(unreachableScanned(dia1Tree, dia1Candidates) == nil, "a failed read fails the scan")
dia1Tree[1].children[0].fails = false
precondition(unreachableScanned(dia1Tree, dia1Candidates, budget: 60) == nil, "past its budget")
let separated = FakeNode("AXGroup", nil, 2, 11, [FakeNode("AXGroup", "AXApplicationGroup", 2, 10, [text(2, 10)]),
                                                 FakeNode("AXGroup", "AXEmptyGroup", 10, 10)])
precondition(scanned([paragraph(0, 1), FakeNode("AXList", "AXContentList", 1, 11, [FakeNode("AXGroup", nil, 1, 11, [
    FakeNode("AXGroup", nil, 1, 2, [text(1, 2)]), separated,
])])], "a\u{2022}Chip one\n") == [], "the image after a chip is no empty paragraph")

var dia1Needs: [FieldSnapshot.Need] = []
func dia1Build(caret field: Int, side: ParagraphBreaks.Side = .start(skipping: 0), unreachable known: UnreachableLines.Memo?)
    -> (snapshot: FieldSnapshot, memo: EmptyParagraphs.Memo?, unreachable: UnreachableLines.Memo?) {
    var reads = FieldSnapshot.Reads(
        field: FieldReads(text: dia1Value, plain: field..<field, markers: MarkerReads(
            breaks: dia1Aligned, value: dia1Aligned.valueRange(field..<field) { _ in side }
        )),
        length: dia1Value.utf16.count, webContent: true, blocks: dia1Tree.count, marked: field..<field, markerText: dia1Raw
    )
    var memo: EmptyParagraphs.Memo?
    var unreachable = known
    return FieldSnapshot.Step.run(taking: { need in
        dia1Needs.append(need)
        switch need {
        case .side(let end): reads.sides.updateValue(side, forKey: end)
        case .emptyParagraph: reads.inEmptyParagraph = false
        case .emptyParagraphs(let value, let raw, _):
            memo = EmptyParagraphs.Memo(value: value, markers: raw, blocks: reads.blocks, found: scanned(dia1Tree, dia1Plain))
        case .unreachable(let value, let raw, let candidates, _):
            unreachable = UnreachableLines.Memo(value: value, markers: raw, blocks: reads.blocks,
                                                found: unreachableScanned(dia1Tree, candidates))
        }
    }) {
        FieldSnapshot.build(reads, capabilities: keyProfile, answer: .textContent, anchor: nil, cursor: nil, memo: memo,
                            unreachable: unreachable)
    }
}
let dia1Built = dia1Build(caret: 68, unreachable: nil)
precondition(dia1Needs.contains(.unreachable(value: dia1Value, markers: dia1Raw, candidates: dia1Candidates, why: .first)))
precondition(dia1Built.snapshot.text == dia1Model.text && dia1Built.snapshot.breaks == dia1Model.breaks)
precondition(dia1Built.snapshot.selection == 66..<66 && dia1Built.snapshot.foldedLength == dia1Model.folded
             && dia1Built.snapshot.holdsChips, "the caret past 2. is at Numbered two's start")
dia1Needs = []
let dia1Rebuilt = dia1Build(caret: 68, unreachable: dia1Built.unreachable)
precondition(dia1Rebuilt.snapshot == dia1Built.snapshot && !dia1Needs.contains { if case .unreachable = $0 { true } else { false } },
             "a memo that holds spares discovery")
precondition(dia1Build(caret: 66, side: .end, unreachable: dia1Built.unreachable).snapshot.selection == 65..<65,
             "a caret before a marker is at the line above's end")
let dia1Failed = dia1Build(caret: 68, unreachable: UnreachableLines.Memo(
    value: dia1Value, markers: dia1Raw, blocks: dia1Tree.count, found: nil
)).snapshot
precondition(dia1Failed.text == dia1Unfound.text, "failed discovery keeps the markers' lines")

func dia1Planning(_ keys: String, caret: Int, profile: CapabilityProfile = keyProfile) -> PhysicalPlan {
    let snapshot = FieldSnapshot(
        capabilities: profile, text: dia1Model.text, selection: caret..<caret, length: dia1Value.utf16.count, webContent: true,
        breaks: dia1Model.breaks, textlessLeaves: true, foldedLength: dia1Model.folded
    )
    return PhysicalPlanner.plan(LogicalPlanner.plan(RawCommand(keys), state: .initial), snapshot: snapshot)
}
let dia1j = dia1Planning("j", caret: 0)
precondition(dia1j.traceShape == "P!P!C" && settleTraces(dia1j) == ["sel=52..52 len=491", "sel=54..54 len=491"],
             "LIN-1645's j into the first item")
let dia1k = dia1Planning("k", caret: 53)
precondition(dia1k.traceShape == "P!PP!C" && settleTraces(dia1k) == ["sel=54..54 len=491", "sel=0..0 len=491"])
let dia1Count = dia1Planning("3j", caret: 55)
precondition(settleTraces(dia1Count).last == "sel=105..105 len=491", "3j counts the lines Linear shows, keeping column 2")
let dia1dd = dia1Planning("dd", caret: 53)
precondition(checkedTexts(dia1dd) == ["Numbered one2."], "AXSelectedText runs through the next item's marker")
precondition(settleTraces(dia1dd).last == "soft sel=54..54 len=nil", "a list renumbers, so the length goes unchecked")
precondition(dia1Planning("$", caret: 0, profile: removing([.lineEndKey], from: writeKeys)).steps.prefix(3)
             == [.setSelection(51..<51), .press(.selectRight, count: 1), .press(.right, count: 1)],
             "a write at a list marker lands by where the caret was, so the line's end is reached from inside it")
let dia1End = dia1Planning("$", caret: 0, profile: writeKeys)
precondition(dia1End.traceShape == "P!C" && chords(dia1End) == [.paragraphEnd], "where ⌃E lands it alone, no write goes first")
precondition(chords(dia1Planning("A", caret: 4, profile: writeKeys)) == [.paragraphEnd])
func dia1Line(_ index: Int) -> Int { dia1Lines.prefix(index).map { $0.utf16.count + 1 }.reduce(0, +) }
let heading = dia1Line(12)
precondition(chords(dia1Planning("0", caret: heading + 3, profile: writeKeys)) == [.paragraphStart], "the heading's leaves fold there")
precondition(chords(dia1Planning("0", caret: dia1Line(6) + 3, profile: writeKeys)).isEmpty, "a plain paragraph's start takes a write")
precondition(dia1Planning("0", caret: dia1Line(1) + 3, profile: writeKeys).steps.first == .setSelection(54..<54),
             "past a list marker a write lands alone")
precondition(dia1Planning("0", caret: 4, profile: writeKeys).steps.first == .setSelection(0..<0), "a write that lands alone stays")

// LIN-1685: the folded write lane extends to a line's end by ⇧⌃E, which a chip would stop.
let dia1D = dia1Planning("D", caret: 4, profile: writeKeys)
precondition(dia1D.steps.first == .setSelection(4..<4) && chords(dia1D) == [Chord.paragraphEnd.shifted])
precondition(chords(dia1Planning("D", caret: 4, profile: removing([.lineEndKey], from: writeKeys)))
             == Array(repeating: .selectRight, count: 48))
precondition(Set(chords(dia1Planning("D", caret: dia1Line(10) + 7, profile: writeKeys))) == [.selectRight],
             "the mention chip ends that line")
precondition(chords(dia1Planning("cc", caret: 4, profile: writeKeys)) == [Chord.paragraphEnd.shifted])
precondition(chords(dia1Planning("dd", caret: 4, profile: writeKeys)) == [Chord.paragraphEnd.shifted, .selectRight])
precondition(chords(dia1Planning("2dd", caret: 4, profile: writeKeys))
             == [Chord.paragraphEnd.shifted, .selectRight, Chord.paragraphEnd.shifted, .selectRight])

// Where a write at a paragraph's start takes arrows after it, a caret already there is not written again, and a collapse is ←.
func writes(_ plan: PhysicalPlan) -> Bool { plan.steps.contains { if case .setSelection = $0 { true } else { false } } }
let headingYank = dia1Planning("yw", caret: heading, profile: writeKeys)
precondition(!writes(headingYank) && chords(headingYank) == Array(repeating: .selectRight, count: 8) + [.left])
let middle = dia1Line(6)
let middleYank = dia1Planning("yw", caret: middle, profile: writeKeys)
precondition(writes(middleYank) && chords(middleYank).isEmpty, "a plain paragraph's start takes writes alone")
func dia1Cursor(_ keys: String, gap: Int) -> PhysicalPlan {
    let snapshot = FieldSnapshot(
        capabilities: adding([.drawCursor], to: writeKeys), text: dia1Model.text, selection: gap..<(gap + 1),
        length: dia1Value.utf16.count, cursor: gap..<(gap + 1), webContent: true, breaks: dia1Model.breaks,
        textlessLeaves: true, foldedLength: dia1Model.folded
    )
    return PhysicalPlanner.plan(LogicalPlanner.plan(RawCommand(keys), state: .initial), snapshot: snapshot)
}
let cursorX = dia1Cursor("x", gap: heading)
precondition(!writes(cursorX) && cursorX.steps.prefix(2) == [.press(.left, count: 1), .press(.selectRight, count: 1)],
             "the drawn cursor collapses by ←")
precondition(writes(dia1Cursor("x", gap: heading + 2)), "inside a paragraph the write stays")
precondition(chords(dia1Cursor("x", gap: middle)).isEmpty, "at a plain paragraph's start too, and the cursor is drawn by a write")
let cursorJ = dia1Cursor("j", gap: heading)
precondition(cursorJ.steps.first == .press(.left, count: 1) && writes(cursorJ))
if case .settle = cursorJ.steps[1] {} else { preconditionFailure("a write after the ← waits for it to settle") }
precondition(chords(dia1Cursor("$", gap: middle + 2)) == [.paragraphEnd]
             && chords(dia1Cursor("0", gap: heading + 2)) == [.paragraphStart, .selectRight],
             "⌃A and ⌃E land alike from the cursor, which needs no collapse first; ⇧→ draws it again at the start")
precondition(chords(dia1Cursor("0", gap: middle + 2)).isEmpty, "a plain paragraph's start is written, cursor and all")
for history in ["u", "<C-r>"] {
    var nothingToUndo = Sim(text: "alpha\nbeta", caret: 0, profile: adding([.drawCursor], to: writeKeys))
    nothingToUndo.emptyParagraphs = true
    nothingToUndo.listLines = [Sim.ListLine(marker: "\u{2022}"), Sim.ListLine()]
    nothingToUndo.emulatesKeys = true
    nothingToUndo.readModel = .textContent
    nothingToUndo.ignoredChords = [.undo, .redo]
    nothingToUndo.type("l")
    nothingToUndo.feed(history)
    nothingToUndo.type("iQ")
    precondition(nothingToUndo.text == "aQlpha\nbeta", "an undo with nothing to undo leaves no drawn cursor to type over")
}

func dia6Planning(_ keys: String, caret: Int, profile: CapabilityProfile = keyProfile) -> PhysicalPlanner.Planning {
    let snapshot = FieldSnapshot(capabilities: profile, text: dia6Model.text, selection: caret..<caret, webContent: true,
                                 breaks: dia6Model.breaks, foldedLength: dia6Model.folded, holdsChips: true)
    return PhysicalPlanner.planning(LogicalPlanner.plan(RawCommand(keys), state: .initial), snapshot: snapshot)
}
let chipA = "\u{2060}\u{00A0}LIN-1645 Why j/k always beeps in Linear (macbook14 logs)"
let chipB = "\u{2060}\u{00A0}LIN-1641 Build mvim's field snapshots with one pure builder shared by the runtime and the Sim"
precondition(dia6Planning("0", caret: 80, profile: removing([.lineStartKey], from: writeKeys)).plan.steps.prefix(2)
             == [.setSelection(281..<281), .press(.left, count: 1)],
             "a caret written at a chip's start stops the next arrow, so a chip's start is reached from its end")
precondition(chords(dia6Planning("0", caret: 80, profile: writeKeys).plan) == [.paragraphStart], "⌃A crosses the chip")
precondition(dia6Planning("$", caret: 60, profile: writeKeys).plan.steps.first == .setSelection(222..<222),
             "after a chip that ends its paragraph, the write goes before the <br>")
let dia6j = dia6Planning("j", caret: 30, profile: writeKeys).plan
precondition(dia6j.steps.first == .setSelection(110..<110) && chords(dia6j).isEmpty,
             "a plain paragraph's start sharing an offset with the line above's end takes the write, which lands downstream")
precondition(checkedTexts(dia6Planning("x", caret: 37).plan) == [chipA], "x takes the chip whole")
precondition(dia6Planning("yy", caret: 60).plan.steps.contains(
    .commit(.yanked(into: nil, content: .literal("Text then a chip " + chipB + "\n"), wise: .line))
), "a register keeps a chip's label")
precondition(dia6Planning("rx", caret: 37).rejection != nil && dia6Planning("~", caret: 37).rejection != nil,
             "typed text cannot rebuild a chip")
precondition(dia6Planning("~", caret: 36).rejection == nil)

var chipKeys = KeyModel(text: "ab\u{2060}cd", anchor: 0, focus: 0, atoms: [2])
precondition(chipKeys.press(Chord.paragraphEnd.shifted) && chipKeys.selection == 0..<2, "⇧⌃E stops at a chip")
precondition(chipKeys.press(Chord.paragraphEnd.shifted) && chipKeys.selection == 0..<2)
chipKeys = KeyModel(text: "ab\u{2060}cd", anchor: 5, focus: 5, atoms: [2])
precondition(chipKeys.press(Chord.paragraphStart.shifted) && chipKeys.selection == 3..<5, "⇧⌃A stops after one")
precondition(chipKeys.press(.paragraphStart) && chipKeys.selection == 0..<0, "⌃A crosses it")

// A Sim of Linear's editor moves as Vim does over the lines Linear shows, in both lanes.
let linearDoc: [(String, String?, Int, Bool)] = [
    ("Top paragraph", nil, 0, false), ("Numbered one", "1.", 0, false), ("Numbered two", "2.", 0, false),
    ("Nested numbered", "a.", 0, false), ("Numbered three", "3.", 0, false), ("Middle \u{2060} paragraph", nil, 0, false),
    ("Two \u{2060} \u{2060} end", nil, 0, false), ("\u{2060} ", "\u{2022}", 0, false),
    ("Bullet one", "\u{2022}", 0, false), ("Nested bullet", "\u{25E6}", 0, false), ("\u{2060}", "\u{2022}", 1, false),
    ("", "\u{2022}", 0, false), ("Bullet \u{2060} two", "\u{2022}", 0, false), ("\u{2060} first", "\u{2022}", 0, false),
    ("Chores", nil, 2, false), ("A to-do item", nil, 2, true), ("", nil, 2, true), ("Ends in \u{2060}", nil, 0, false),
    ("\u{2060} starts", nil, 0, false), ("\u{2060}", nil, 0, false), ("Last paragraph.", nil, 0, false),
]
func linearSim(_ profile: CapabilityProfile, findsUnreachable: Bool = true) -> Sim {
    var host = Sim(text: linearDoc.map(\.0).joined(separator: "\n"), caret: 0, profile: profile)
    host.emptyParagraphs = true
    host.listLines = linearDoc.map { Sim.ListLine(marker: $0.1, leaves: $0.2, checkbox: $0.3) }
    host.findsUnreachable = findsUnreachable
    host.emulatesKeys = true
    host.readModel = .textContent
    return host
}
for profile in [keyProfile, writeKeys] {
    let down = String(repeating: "j", count: linearDoc.count)
    for keys in [down + String(repeating: "k", count: linearDoc.count), "3j2k4j5j3k", "5ljjjjjjjjjjjjjjjjkkkk",
                 "$jjjjjjjjjjjjjjjjkkkk", "G" + String(repeating: "k", count: linearDoc.count - 1), "jjjjjjjjjjjjjjjjj0jj^",
                 "jjjjjwwwwwwwwwwwbbbbbbb",
                 "jjjjjjjjjjjjjjjjdd", "jjjjjlx"] {
        var linear = linearSim(profile)
        var plain = Sim(text: linear.text, caret: 0, profile: profile)
        plain.emulatesKeys = true
        for key in keys {
            linear.type(String(key))
            plain.type(String(key))
            precondition(linear.caret == plain.caret && linear.text == plain.text, "\(keys) at \(key)")
        }
        precondition(linear.settleFailures == 0 && linear.bells == 0, keys)
    }
}
var chipStart = linearSim(writeKeys)
let firstChip = chipStart.chromium.chips[0].range.lowerBound
chipStart.perform([.setSelection(firstChip..<firstChip), .press(.right, count: 1)])
precondition(chipStart.readSelection == firstChip..<firstChip, "the Sim's caret written at a chip's start stops the next arrow")

let nativeDoc: [(String, String?)] = [
    ("Top paragraph", nil), ("First bullet", "\u{2022} "), ("Second bullet", "\u{2022} "), ("Nested one", "\u{25E6} "),
    ("", "\u{2022} "), ("After empty", "\u{2022} "), ("Middle paragraph", nil), ("Nine", "9. "), ("Ten longer", "10. "),
    ("Last paragraph.", nil),
]
for profile in [keyProfile, writeKeys] {
    let down = String(repeating: "j", count: nativeDoc.count)
    for keys in [down + String(repeating: "k", count: nativeDoc.count), "3j2k4j3j3k", "5ljjjjjjjjkkkk", "$jjjjjjjjkkkkk",
                 "G" + String(repeating: "k", count: nativeDoc.count - 1), "jjjjjjj0jj^k0", "jwwwwwwwwwbbbbbbb", "jjjdd", "jjjjdd",
                 "jjjjjdd", "jjjjjjjdd", "jlx"] {
        var native = Sim(text: nativeDoc.map(\.0).joined(separator: "\n"), caret: 0, profile: profile)
        native.emptyParagraphs = true
        native.listLines = nativeDoc.map { Sim.ListLine(marker: $0.1, inline: true) }
        native.emulatesKeys = true
        native.readModel = .textContent
        var plain = Sim(text: native.text, caret: 0, profile: profile)
        plain.emulatesKeys = true
        for key in keys {
            native.type(String(key))
            plain.type(String(key))
            precondition(native.caret == plain.caret && native.text == plain.text, "\(keys) at \(key)")
        }
        precondition(native.settleFailures == 0 && native.bells == 0, keys)
    }
}

var linearLogged = linearSim(keyProfile, findsUnreachable: false)
linearLogged.type("j")
precondition(linearLogged.settleFailures == 1 && linearLogged.caret == 14, "without discovery, LIN-1645's j into an item")
linearLogged.type("k")
precondition(linearLogged.settleFailures == 2, "and its k out of one")

// MARK: - Discovery carried across typing (LIN-1874)

let typedRun = Discovery.Run(from: "ab\u{FFFC}cd", to: "ab\u{FFFC}cxyd")!
precondition(typedRun.at == 3 && typedRun.earliest == 3 && typedRun.inserted == 2 && typedRun.removed == 0)
precondition([2, 3, 4].map { typedRun.shifted($0) } == [2, nil, 6] && typedRun.shifted(3, lands: .before) == 5
             && typedRun.shifted(3, lands: .after) == 3)
let deletedRun = Discovery.Run(from: "abcdef", to: "abef")!
precondition(deletedRun.at == 2 && deletedRun.removed == 2
             && [1, 2, 3, 4, 5].map { deletedRun.shifted($0) } == [1, nil, nil, 2, 3])
precondition(deletedRun.shifted(2, lands: .after) == 2 && deletedRun.shifted(2, lands: .before) == nil)
for (old, new) in [("abcd", "abxd"), ("abcd", "ab\ncd"), ("abcd", "ab\u{FFFC}cd"), ("abcd", "abcd"), ("abcd", "xabcdy")] {
    precondition(Discovery.Run(from: old, to: new) == nil, "\(new.debugDescription) is no one run of text")
}
let repeatedRun = Discovery.Run(from: "fooBar", to: "fooBBar")!
precondition(repeatedRun.earliest == 3 && repeatedRun.at == 4 && repeatedRun.shifted(3) == nil
             && repeatedRun.shifted(3, lands: .before) == nil && repeatedRun.shifted(4, lands: .before) == 5,
             "a B typed beside a B may be on either side of the paragraph starting at 3")

// A node boundary at the run's offset moves with the leaf the run went into, which only a line break in AXValue shows.
func runLines(_ old: (value: String, markers: String), _ new: (value: String, markers: String)) -> (Discovery.Run, Discovery.Lines) {
    let edit = try! Discovery.run(markers: old.markers, value: old.value, to: new.markers, value: new.value).get()
    return (edit.run, Discovery.Lines(value: old.value, markers: old.markers, shown: edit.shown)!)
}
let (endRun, endLines) = runLines(("ab\ncd", "abcd"), ("abx\ncd", "abxcd"))
let (startRun, startLines) = runLines(("ab\ncd", "abcd"), ("ab\nxcd", "abxcd"))
let (inlineRun, inlineLines) = runLines(("abcd", "abcd"), ("abxcd", "abxcd"))
precondition([1, 2, 3].map { endLines.boundary($0, endRun) } == [1, 3, 4] && startLines.boundary(2, startRun) == 2
             && inlineLines.boundary(2, inlineRun) == nil, "before a break it moves, after one it stays, and with none it is either")
let (cutRun, cutLines) = runLines(("abbc\nd", "abbcd"), ("abc\nd", "abcd"))
precondition([1, 2, 3].map { cutLines.boundary($0, cutRun) } == [1, nil, 2], "a b deleted beside a b leaves the one between")
// A run of newlines holding one of the text's own: which of them Chromium added is a guess, so neither order proves a side.
for typedValue in ["TopX\n\n", "Top\nX\n"] {
    let (seamRun, seamLines) = runLines(("Top\n\n", "Top\u{FFFC}\n\u{FFFC}"), (typedValue, "Top\u{FFFC}X\n\u{FFFC}"))
    precondition(seamLines.boundary(3, seamRun) == nil, typedValue.debugDescription)
}

/// The runtime's walks over a fake tree, keeping what they read.
func emptyWalk(_ value: String, _ raw: String, _ tree: [FakeNode], budget: Int = EmptyParagraphs.readBudget,
               why: Discovery.Rewalk = .first) -> EmptyParagraphs.Memo {
    let recorder = Discovery.Recorder<FakeNode>(budget: budget, block: \.block, offset: { node, end in end ? node.end : node.start })
    var scan = EmptyBlockScan(budget: budget, block: recorder.block, offset: recorder.offset)
    let found = scan.run(blocks: recorder.roots(tree), plain: Array(MarkerText.plain(raw).utf16))
    return EmptyParagraphs.Memo(value: value, markers: raw, blocks: tree.count, found: found, exhausted: scan.exhausted,
                                reads: recorder.reads, origin: .walked(why))
}
func unreachableWalk(_ value: String, _ raw: String, _ tree: [FakeNode], _ candidates: UnreachableLines.Candidates, roots: Int?,
                     budget: Int = UnreachableLines.readBudget, why: Discovery.Rewalk = .first) -> UnreachableLines.Memo {
    let recorder = Discovery.Recorder<FakeNode>(budget: budget, block: \.block, offset: { node, end in end ? node.end : node.start })
    var scan = UnreachableScan(budget: budget, block: recorder.block, offset: recorder.offset)
    let found = scan.run(blocks: recorder.roots(tree), candidates: candidates)
    return UnreachableLines.Memo(value: value, markers: raw, blocks: tree.count, roots: roots, found: found,
                                 exhausted: scan.exhausted, candidates: candidates, reads: recorder.reads, origin: .walked(why))
}
/// `spec` with `count` units typed (or deleted, below zero) into the text node at `path`: it and its ancestors change
/// length, and every node after it moves.
func typed(_ spec: String, _ count: Int, into path: String) -> String {
    let tokens = spec.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { $0.split(separator: "/").map(String.init) }
    let target = tokens.firstIndex { $0[0] == path }!
    return tokens.enumerated().map { index, token in
        let start = Int(token[2])!
        let end = Int(token[3])!
        if index == target || path.hasPrefix(token[0] + ".") { return [token[0], token[1], token[2], String(end + count)] }
        return index > target ? [token[0], token[1], String(start + count), String(end + count)] : token
    }.map { $0.joined(separator: "/") }.joined(separator: " ")
}
/// A Chromium build over a fake tree, walking it where a memo does not carry; `walks` says why each walk ran.
func treeBuild(
    _ value: String, _ raw: String, _ tree: [FakeNode], memo known: EmptyParagraphs.Memo? = nil,
    unreachable knownUnreachable: UnreachableLines.Memo? = nil, caret: Int = 0, proseMirror: Bool = true
) -> (snapshot: FieldSnapshot, memo: EmptyParagraphs.Memo?, unreachable: UnreachableLines.Memo?, walks: [Discovery.Rewalk]) {
    let aligned = ParagraphBreaks(value: value, fieldText: MarkerText.plain(raw))!
    var reads = FieldSnapshot.Reads(
        field: FieldReads(text: value, plain: caret..<caret, markers: MarkerReads(
            breaks: aligned, value: aligned.valueRange(caret..<caret) { _ in .start(skipping: 0) }
        )),
        length: value.utf16.count, webContent: true, blocks: tree.count, marked: caret..<caret, markerText: raw
    )
    reads.proseMirror = proseMirror
    reads.roots = proseMirror ? tree.count : nil
    var memo = known
    var unreachable = knownUnreachable
    var walks: [Discovery.Rewalk] = []
    let built = FieldSnapshot.Step.run(taking: { need in
        switch need {
        case .side(let end): reads.sides.updateValue(.start(skipping: 0), forKey: end)
        case .emptyParagraph: reads.inEmptyParagraph = false
        case .emptyParagraphs(let value, let raw, let why):
            walks.append(why)
            memo = emptyWalk(value, raw, tree, why: why)
        case .unreachable(let value, let raw, let candidates, let why):
            walks.append(why)
            unreachable = unreachableWalk(value, raw, tree, candidates, roots: reads.roots, why: why)
        }
    }) {
        FieldSnapshot.build(reads, capabilities: keyProfile, answer: .textContent, anchor: nil, cursor: nil, memo: memo,
                            unreachable: unreachable)
    }
    return (built.snapshot, built.memo, built.unreachable, walks)
}
func linedCandidates(_ value: String, _ plain: String) -> UnreachableLines.Candidates {
    UnreachableLines.candidates(text: value, breaks: ParagraphBreaks(value: value, fieldText: MarkerText.plain(plain))!, raw: plain)
}
/// Builds a field before and after an edit, carried and walked; nil when they differ.
func carriedEdit(
    _ before: (value: String, raw: String, spec: String), _ after: (value: String, raw: String, spec: String),
    carets: (Int, Int) = (0, 0), proseMirror: Bool = true, linear: Bool = true
) -> [Discovery.Rewalk]? {
    let old = treeBuild(before.value, before.raw, fakeTree(before.spec, linear: linear), caret: carets.0, proseMirror: proseMirror)
    let tree = fakeTree(after.spec, linear: linear)
    let carried = treeBuild(after.value, after.raw, tree, memo: old.memo, unreachable: old.unreachable, caret: carets.1,
                            proseMirror: proseMirror)
    let walked = treeBuild(after.value, after.raw, tree, caret: carets.1, proseMirror: proseMirror)
    guard carried.snapshot == walked.snapshot, carried.memo?.found == walked.memo?.found,
          carried.memo?.exhausted == walked.memo?.exhausted, carried.unreachable?.found == walked.unreachable?.found
    else { return nil }
    return carried.walks
}
func edited(_ value: String, _ raw: String, _ spec: String, _ path: String, _ from: String, _ to: String)
    -> (value: String, raw: String, spec: String) {
    (value.replacing(from, with: to, maxReplacements: 1), raw.replacing(from, with: to, maxReplacements: 1),
     typed(spec, to.utf16.count - from.utf16.count, into: path))
}
for (name, value, raw, spec, path, from, to) in [
    ("the end of a list item, where the next marker starts", dia1Value, dia1Raw, dia1Spec, "1.0.1.0", "Numbered one",
     "Numbered onexy"),
    ("a list marker the page renumbers", dia1Value, dia1Raw, dia1Spec, "9.1.0.0", "10.", "100."),
    ("before a chip", dia7Value, dia7Raw, dia7Spec, "1.0", "Two chips ", "Two chips xy"),
    ("where a chip's paragraph starts", dia7Value, dia7Raw, dia7Spec, "1.0", "Two chips ", "xyTwo chips "),
    ("after a chip", dia7Value, dia7Raw, dia7Spec, "1.4", " end.", "xy end."),
    ("in a paragraph with chips", dia7Value, dia7Raw, dia7Spec, "1.4", " end.", " exynd."),
    ("a chip's title the page changes", dia7Value, dia7Raw, dia7Spec, "1.1.0.4", "LIN-1645 Why", "LIN-1645 xWhy"),
] {
    let after = edited(value, raw, spec, path, from, to)
    precondition(after.value != value && after.raw != raw, name)
    precondition(carriedEdit((value, raw, spec), after) == [], "\(name): the walk replayed builds what a walk does")
}
// A code block's label Linear changes as you type, at its start, its end and inside it.
let codeLabel = (value: "Before\nC\nabc\nAfter", raw: "BeforeCabcAfter",
                 spec: "0/G/0/6 0.0/T/0/6 1/B/6/10 1.0/N/6/7 1.1/D/7/10 1.1.0/T/7/10 2/G/10/15 2.0/T/10/15")
let objectiveC = (value: "Before\nObjective-C\nabc\nAfter", raw: "BeforeObjective-CabcAfter", spec: typed(codeLabel.spec, 10, into: "1.0"))
let cssLabel = (value: "Before\nCSS\nabc\nAfter", raw: "BeforeCSSabcAfter", spec: typed(codeLabel.spec, 2, into: "1.0"))
precondition(carriedEdit(codeLabel, objectiveC) == [] && carriedEdit(codeLabel, cssLabel) == [],
             "LIN-1874 round 1: a code label becoming Objective-C or CSS")
// LIN-1874 round 3: a line the walk did not confirm, a chip over two lines, becomes one when the page deletes the second.
let splitChip = (value: "Top\n\u{2060}\u{00A0}A\nB\nEnd", raw: "Top\u{2060}\u{00A0}ABEnd",
                 spec: "0/G/0/3 0.0/T/0/3 1/G/3/7 1.0/A/3/7 1.0.0/K/3/7 1.0.0.0/T/3/6 1.0.0.1/T/6/7 2/G/7/10 2.0/T/7/10")
let splitObject = (value: "Top\n\u{2060}\u{00A0}A\nB\n\u{2022} Other", raw: "Top\u{2060}\u{00A0}AB\u{FFFC}\u{2022} Other",
                   spec: "0/G/0/3 0.0/T/0/3 1/G/3/7 1.0/A/3/7 1.0.0/G/3/6 1.0.0.0/T/3/6 1.0.1/G/6/7 1.0.1.0/T/6/7 "
                       + "1.0.1.1/I/7/7 2/L/7/14 2.0/G/7/14 2.0.0/M/7/9 2.0.1/T/9/14")
precondition(unreachableScanned(fakeTree(splitChip.spec), linedCandidates(splitChip.value, splitChip.raw))?.chips == [])
// With an object left on the emptied line, that line is a caret's no walk read, so it walks.
for (field, path, walks) in [(splitChip, "1.0.0.1", [Discovery.Rewalk]()), (splitObject, "1.0.1.0", [.unread])] {
    let after = (field.value.replacing("A\nB\n", with: "A\n\n"), field.raw.replacing("AB", with: "A"), typed(field.spec, -1, into: path))
    precondition(carriedEdit(field, after) == walks, "\(after.0.debugDescription): the chip is confirmed")
}
// And a caret the selection makes a candidate where an object already was: the walk never read there, so it walks.
let caretTail = (value: "ab\nnext", raw: "ab\u{FFFC}\nnext", spec: "0/G/0/3 0.0/D/0/2 0.0.0/T/0/2 0.1/E/2/3 1/G/3/7 1.0/T/3/7")
precondition(carriedEdit(caretTail, ("a\nnext", "a\u{FFFC}\nnext", typed(caretTail.spec, -1, into: "0.0.0")), carets: (0, 1))
             == [.unread])
// LIN-1874 round 4: a text newline beside an added line break, typed before, in either order the run of newlines allows.
for (field, path, before, raw) in [
    ((value: "Top\n\n", raw: "Top\u{FFFC}\n\u{FFFC}", spec: "0/G/0/3 0.0/T/0/3 1/E/3/3 2/G/3/4 2.0/T/3/4 3/I/4/4"), "2.0",
     "Top", "Top\u{FFFC}X\n\u{FFFC}"),
    ((value: "Top\n\nabc\nAfter", raw: "Top\nabcAfter",
      spec: "0/G/0/3 0.0/T/0/3 1/B/3/7 1.0/N/3/4 1.0.0/T/3/4 1.1/D/4/7 1.1.0/T/4/7 2/G/7/12 2.0/T/7/12"), "1.0.0", "Top", "TopX\nabcAfter"),
    ((value: "Top\n\n\u{2060}\u{00A0}Chip\nAfter", raw: "Top\n\u{2060}\u{00A0}ChipAfter",
      spec: "0/G/0/3 0.0/T/0/3 1/G/3/10 1.0/T/3/4 1.1/A/4/10 1.1.0/K/4/10 1.1.0.0/T/4/10 2/G/10/15 2.0/T/10/15"), "1.0", "Top",
     "TopX\n\u{2060}\u{00A0}ChipAfter"),
] {
    for typedValue in [field.value.replacing(before + "\n\n", with: before + "X\n\n"),
                       field.value.replacing(before + "\n\n", with: before + "\nX\n")] {
        let walks = carriedEdit(field, (typedValue, raw, typed(field.spec, 1, into: path)), carets: (3, 4))
        precondition(walks?.contains(.boundary) == true, "\(typedValue.debugDescription): \(walks.map { "\($0)" } ?? "differs")")
    }
}

// Chromium's own list: the page makes a paragraph an item with one run of marker text and no new block.
let native = (value: "Top\n\u{2022} First\nMiddle\nPlain", raw: "Top\u{2022} FirstMiddlePlain",
              spec: "0/G/0/3 0.0/T/0/3 1/L/3/10 1.0/G/3/10 1.0.0/M/3/5 1.0.1/T/5/10 2/G/10/16 2.0/T/10/16 3/G/16/21 3.0/T/16/21")
let nativeMemo = unreachableWalk(native.value, native.raw, fakeTree(native.spec, linear: false),
                                 linedCandidates(native.value, native.raw), roots: nil)
precondition(nativeMemo.found?.markers == [3])
for (name, value, plain) in [("listed", "Top\n\u{2022} First\nMiddle\n\u{2022} Plain", "Top\u{2022} FirstMiddle\u{2022} Plain"),
                             ("typed like one", "Top\n\u{2022} First\nMi. ddle\nPlain", "Top\u{2022} FirstMi. ddlePlain")] {
    precondition(nativeMemo.carried(value: value, markers: plain, blocks: 4, candidates: linedCandidates(value, plain))
                 == .failure(.candidates), "a paragraph \(name) gives a walk a line the last one never checked")
}
let typedNumber = unreachableWalk("Top\n1. Buy", "Top1. Buy", fakeTree("0/G/0/3 0.0/T/0/3 1/G/3/9 1.0/T/3/9", linear: false),
                                  linedCandidates("Top\n1. Buy", "Top1. Buy"), roots: nil)
precondition(typedNumber.found?.markers == [] && typedNumber.carried(
    value: "Top\n\u{2022} 1. Buy", markers: "Top\u{2022} 1. Buy", blocks: 2,
    candidates: linedCandidates("Top\n\u{2022} 1. Buy", "Top\u{2022} 1. Buy")
) == .failure(.candidates), "and a line that already looked like an item, listed, is one line with another marker")
precondition(carriedEdit(native, edited(native.value, native.raw, native.spec, "0.0", "Top", "Topx"), proseMirror: false,
                         linear: false) == [], "typing before the list still carries")
let nativeTyped = (value: native.value.replacing("Top", with: "Topx"), raw: native.raw.replacing("Top", with: "Topx"))
precondition(nativeMemo.carried(value: nativeTyped.value, markers: nativeTyped.raw, blocks: 4, proseMirror: true,
                                candidates: linedCandidates(nativeTyped.value, nativeTyped.raw)) == .failure(.roots)
             && UnreachableLines.Memo(value: native.value, markers: native.raw, blocks: nil, found: nativeMemo.found)
                 .carried(value: nativeTyped.value, markers: nativeTyped.raw, blocks: nil,
                          candidates: linedCandidates(nativeTyped.value, nativeTyped.raw)) == .failure(.blocks),
             "a count unread both times, or a ProseMirror field's roots unread both times, prove nothing unchanged")
precondition(UnreachableLines.Memo(value: native.value, markers: native.raw, blocks: 4, found: nativeMemo.found)
                 .carried(value: nativeTyped.value, markers: nativeTyped.raw, blocks: 4,
                          candidates: linedCandidates(nativeTyped.value, nativeTyped.raw)) == .failure(.unread),
             "a result whose reads were not kept, the Sim's, walks")
let twoRoots = unreachableWalk("\u{2022} one\nTwo", "\u{2022} oneTwo",
                               fakeTree("0/L/0/5 0.0/G/0/5 0.0.0/M/0/2 0.0.1/T/2/5 1/G/5/8 1.0/T/5/8", linear: false),
                               linedCandidates("\u{2022} one\nTwo", "\u{2022} oneTwo"), roots: nil)
precondition(UnreachableLines.Memo(value: twoRoots.value, markers: twoRoots.markers, blocks: 1, found: twoRoots.found,
                                   candidates: twoRoots.candidates, reads: twoRoots.reads)
                 .carried(value: "\u{2022} one\nTwox", markers: "\u{2022} oneTwox", blocks: 1,
                          candidates: linedCandidates("\u{2022} one\nTwox", "\u{2022} oneTwox")) == .failure(.unread)
             && twoRoots.carried(value: "\u{2022} one\nTwox", markers: "\u{2022} oneTwox", blocks: 2,
                                 candidates: linedCandidates("\u{2022} one\nTwox", "\u{2022} oneTwox")).map(\.found?.markers)
                 == .success([0]), "reads of a tree with other root blocks than the count")

// Chrome 153's blank line: typing elsewhere replays the walk, and anything else walks again.
func blankTree(_ paragraphs: [String]) -> [FakeNode] {
    var at = 0
    return paragraphs.map { text in
        defer { at += max(text.utf16.count, 1) }
        return text.isEmpty ? blank(at) : paragraph(at, at + text.utf16.count)
    }
}
let blankMemo = emptyWalk(blankValue, blankMarkers, blankTree(blankParagraphs))
func blankCarried(
    _ edit: (inout [String]) -> Void, memo: EmptyParagraphs.Memo = blankMemo
) -> Result<EmptyParagraphs.Memo, Discovery.Rewalk> {
    var paragraphs = blankParagraphs
    edit(&paragraphs)
    let shown = EmptyParagraphs.chromium(paragraphs)
    let carried = memo.carried(value: shown.value, markers: shown.markers, blocks: paragraphs.count)
    if case .success(let kept) = carried {
        let walked = emptyWalk(shown.value, shown.markers, blankTree(paragraphs), budget: memo.reads?.budget ?? 0)
        precondition(kept.found == walked.found && kept.exhausted == walked.exhausted, "\(paragraphs)")
    }
    return carried
}
precondition(blankMemo.found == [43] && blankCarried { _ in } == .success(blankMemo))
let blankShifted = try! blankCarried { $0[0] = "Headingxy one" }.get()
precondition(blankShifted.found == [45] && blankCarried { $0[3] = "Second" }.map(\.found) == .success([43]))
precondition(blankShifted.origin == .shifted(Discovery.Run(from: blankMarkers, to: "Headingxy one" + blankMarkers.dropFirst(11))!))
precondition(blankCarried { $0[1] += "x" } == .failure(.boundary), "typed where its <br> starts")
precondition(blankCarried { $0[2] = "x" } == .failure(.edit) && blankCarried { $0[0] = "Hx"; $0[6] = "Ly" } == .failure(.edit),
             "typed in the blank line, or in two places")
precondition(blankCarried { $0.insert("New", at: 1) } == .failure(.blocks))
precondition(EmptyParagraphs.Memo(value: "ab\nc", markers: "ab\nc", blocks: nil, found: [2])
             .carried(value: "axb\nc", markers: "axb\nc", blocks: nil) == .failure(.blocks))
let failedBlank = EmptyParagraphs.Memo(value: blankValue, markers: blankMarkers, blocks: blankParagraphs.count, found: nil)
precondition(blankCarried({ $0[0] = "Headingxy one" }, memo: failedBlank) == .failure(.failed), "a failed read is read again")
for budget in [3, 8] {
    let exhausted = emptyWalk(blankValue, blankMarkers, blankTree(blankParagraphs), budget: budget)
    precondition(exhausted.found == nil && exhausted.exhausted, "\(budget)")
    precondition(try! blankCarried({ $0[0] = "Headingxy one" }, memo: exhausted).get().exhausted,
                 "a walk past its budget, replayed, runs out again: \(budget)")
}
let blankTypedMarkers = EmptyParagraphs.chromium(blankParagraphs.dropLast() + ["Last paragraph herexy."]).markers
precondition(blankMemo.carried(value: blankValue + "y", markers: blankTypedMarkers, blocks: blankParagraphs.count)
             == .failure(.value))

// Enter in a list adds an item but no root block, and the marker text gains only "•z": AXValue's new lines refuse it.
let dia7Before = treeBuild(dia7Value, dia7Raw, dia7Tree)
let newItemRaw = dia7Raw.replacing("Plain itemClosing", with: "Plain item\u{2022}zClosing")
let newItemValue = dia7Value.replacing("Plain item\nClosing", with: "Plain item\n\u{2022}\nz\nClosing")
precondition(Discovery.Run(from: dia7Raw, to: newItemRaw)?.inserted == 2
             && dia7Before.unreachable?.carried(value: newItemValue, markers: newItemRaw, blocks: dia7Tree.count, roots: dia7Tree.count,
                                                candidates: dia7Before.unreachable!.candidates) == .failure(.value)
             && dia7Before.memo?.carried(value: newItemValue, markers: newItemRaw, blocks: dia7Tree.count) == .failure(.value))

precondition(ChromiumParagraphs(text: "a \u{2060} b\nc \u{2060}\n\u{2060} d", lines: [Sim.ListLine(), Sim.ListLine(), Sim.ListLine()]).shown
             == ("a \n\u{2060}\u{00A0}LIN-1 chip\n b\nc \n\u{2060}\u{00A0}LIN-1 chip\n\u{2060}\u{00A0}LIN-1 chip\n d",
                 "a \u{2060}\u{00A0}LIN-1 chip bc \u{2060}\u{00A0}LIN-1 chip\n\u{2060}\u{00A0}LIN-1 chip d", []),
             "a chip is a line of its own, and one ending its paragraph has a <br> after it")
precondition(ChromiumParagraphs(text: "a \u{2060} \u{2060} b\nc \u{2060} ", lines: [Sim.ListLine(), Sim.ListLine()]).shown.value
             == "a \n\u{2060}\u{00A0}LIN-1 chip \n\u{2060}\u{00A0}LIN-1 chip\n b\nc \n\u{2060}\u{00A0}LIN-1 chip ",
             "spaces after a chip share its line")
for paragraphs in [["L", "", "N"], ["", "L"], ["L", ""], [""], ["a", "", "bc", "", "", "d", ""]] {
    let host = ChromiumParagraphs(text: paragraphs.joined(separator: "\n"), lines: paragraphs.map { _ in Sim.ListLine() })
    precondition(host.shown == EmptyParagraphs.chromium(paragraphs) && host.plainMarkers == host.shown.markers,
                 "without markers or leaves, Linear's lines are Chrome 153's")
}
precondition(ChromiumParagraphs(text: "a\nb", lines: [Sim.ListLine(), Sim.ListLine(marker: "1.", leaves: 1)]).shown
             == ("a\n1.\n\nb", "a1.\u{FFFC}b", []))
let bullet = Sim.ListLine(marker: "\u{2022} ", inline: true)
precondition(ChromiumParagraphs(text: "a\nb\n\nc", lines: [Sim.ListLine(), bullet, bullet, bullet]).shown
             == ("a\n\u{2022} b\n\u{2022} \n\u{2022} c", "a\u{2022} b\u{2022} \n\u{2022} c", []),
             "Chromium's own list keeps each marker on its item's line")

// MARK: - Drawn carets beside code spans (LIN-1683)

// Dia 1.49.1 on linear.app, probed by softlash/LIN-1683 scripts/code-probe: the text, then each caret Linear drew.
let codeValue = [
    "Plain opening paragraph with a few words to move around in.",
    "Marks: a bold word then an italic word then code span then a link text and it is done.",
    "lead starts this paragraph with code and goes on.",
    "This paragraph ends with code tail",
    "Two spans one and two share a line here.",
    "Adjacent boldcode marks and x one letter.",
    "Last plain paragraph is here.",
].joined(separator: "\n")
let codeRaw = "Plain opening paragraph with a few words to move around in.Marks: a bold word then an italic word then code span then a link text and it is done.lead starts this paragraph with code and goes on.This paragraph ends with code tailTwo spans one and two share a line here.Adjacent boldcode marks and x one letter.Last plain paragraph is here."
let codeTree = fakeTree("""
0/G/0/59 0.0/T/0/59 1/G/59/145 1.0/T/59/68 1.1/S/68/77 1.1.0/T/68/77 1.2/T/77/86 1.3/F/86/97 1.3.0/T/86/97
1.4/T/97/103 1.5/D/103/112 1.5.0/T/103/112 1.6/T/112/120 1.7/K/120/129 1.7.0/T/120/129 1.8/T/129/145 2/G/145/194
2.0/D/145/149 2.0.0/T/145/149 2.1/T/149/194 3/G/194/228 3.0/T/194/224 3.1/D/224/228 3.1.0/T/224/228 4/G/228/268
4.0/T/228/238 4.1/D/238/241 4.1.0/T/238/241 4.2/T/241/246 4.3/D/246/249 4.3.0/T/246/249 4.4/T/249/268 5/G/268/309
5.0/T/268/277 5.1/S/277/281 5.1.0/T/277/281 5.2/D/281/285 5.2.0/T/281/285 5.3/T/285/296 5.4/D/296/297
5.4.0/T/296/297 5.5/T/297/309 6/G/309/338 6.0/T/309/338
""")
let midStartOutsideTree = fakeTree("""
0/G/0/59 0.0/T/0/59 1/G/59/145 1.0/T/59/68 1.1/S/68/77 1.1.0/T/68/77 1.2/T/77/86 1.3/F/86/97 1.3.0/T/86/97
1.4/T/97/103 1.5/E/103/103 1.6/D/103/112 1.6.0/T/103/112 1.7/T/112/120 1.8/K/120/129 1.8.0/T/120/129 1.9/T/129/145
2/G/145/194 2.0/D/145/149 2.0.0/T/145/149 2.1/T/149/194 3/G/194/228 3.0/T/194/224 3.1/D/224/228 3.1.0/T/224/228
4/G/228/268 4.0/T/228/238 4.1/D/238/241 4.1.0/T/238/241 4.2/T/241/246 4.3/D/246/249 4.3.0/T/246/249 4.4/T/249/268
5/G/268/309 5.0/T/268/277 5.1/S/277/281 5.1.0/T/277/281 5.2/D/281/285 5.2.0/T/281/285 5.3/T/285/296 5.4/D/296/297
5.4.0/T/296/297 5.5/T/297/309 6/G/309/338 6.0/T/309/338
""")
let midStartInsideTree = fakeTree("""
0/G/0/59 0.0/T/0/59 1/G/59/145 1.0/T/59/68 1.1/S/68/77 1.1.0/T/68/77 1.2/T/77/86 1.3/F/86/97 1.3.0/T/86/97
1.4/T/97/103 1.5/D/103/112 1.5.0/E/103/103 1.5.1/T/103/112 1.6/T/112/120 1.7/K/120/129 1.7.0/T/120/129 1.8/T/129/145
2/G/145/194 2.0/D/145/149 2.0.0/T/145/149 2.1/T/149/194 3/G/194/228 3.0/T/194/224 3.1/D/224/228 3.1.0/T/224/228
4/G/228/268 4.0/T/228/238 4.1/D/238/241 4.1.0/T/238/241 4.2/T/241/246 4.3/D/246/249 4.3.0/T/246/249 4.4/T/249/268
5/G/268/309 5.0/T/268/277 5.1/S/277/281 5.1.0/T/277/281 5.2/D/281/285 5.2.0/T/281/285 5.3/T/285/296 5.4/D/296/297
5.4.0/T/296/297 5.5/T/297/309 6/G/309/338 6.0/T/309/338
""")
let midEndInsideTree = fakeTree("""
0/G/0/59 0.0/T/0/59 1/G/59/145 1.0/T/59/68 1.1/S/68/77 1.1.0/T/68/77 1.2/T/77/86 1.3/F/86/97 1.3.0/T/86/97
1.4/T/97/103 1.5/D/103/112 1.5.0/T/103/112 1.5.1/E/112/112 1.6/T/112/120 1.7/K/120/129 1.7.0/T/120/129 1.8/T/129/145
2/G/145/194 2.0/D/145/149 2.0.0/T/145/149 2.1/T/149/194 3/G/194/228 3.0/T/194/224 3.1/D/224/228 3.1.0/T/224/228
4/G/228/268 4.0/T/228/238 4.1/D/238/241 4.1.0/T/238/241 4.2/T/241/246 4.3/D/246/249 4.3.0/T/246/249 4.4/T/249/268
5/G/268/309 5.0/T/268/277 5.1/S/277/281 5.1.0/T/277/281 5.2/D/281/285 5.2.0/T/281/285 5.3/T/285/296 5.4/D/296/297
5.4.0/T/296/297 5.5/T/297/309 6/G/309/338 6.0/T/309/338
""")
let midEndOutsideTree = fakeTree("""
0/G/0/59 0.0/T/0/59 1/G/59/145 1.0/T/59/68 1.1/S/68/77 1.1.0/T/68/77 1.2/T/77/86 1.3/F/86/97 1.3.0/T/86/97
1.4/T/97/103 1.5/D/103/112 1.5.0/T/103/112 1.6/E/112/112 1.7/T/112/120 1.8/K/120/129 1.8.0/T/120/129 1.9/T/129/145
2/G/145/194 2.0/D/145/149 2.0.0/T/145/149 2.1/T/149/194 3/G/194/228 3.0/T/194/224 3.1/D/224/228 3.1.0/T/224/228
4/G/228/268 4.0/T/228/238 4.1/D/238/241 4.1.0/T/238/241 4.2/T/241/246 4.3/D/246/249 4.3.0/T/246/249 4.4/T/249/268
5/G/268/309 5.0/T/268/277 5.1/S/277/281 5.1.0/T/277/281 5.2/D/281/285 5.2.0/T/281/285 5.3/T/285/296 5.4/D/296/297
5.4.0/T/296/297 5.5/T/297/309 6/G/309/338 6.0/T/309/338
""")
let leadStartTree = fakeTree("""
0/G/0/59 0.0/T/0/59 1/G/59/145 1.0/T/59/68 1.1/S/68/77 1.1.0/T/68/77 1.2/T/77/86 1.3/F/86/97 1.3.0/T/86/97
1.4/T/97/103 1.5/D/103/112 1.5.0/T/103/112 1.6/T/112/120 1.7/K/120/129 1.7.0/T/120/129 1.8/T/129/145 2/G/145/194
2.0/E/145/145 2.1/D/145/149 2.1.0/T/145/149 2.2/T/149/194 3/G/194/228 3.0/T/194/224 3.1/D/224/228 3.1.0/T/224/228
4/G/228/268 4.0/T/228/238 4.1/D/238/241 4.1.0/T/238/241 4.2/T/241/246 4.3/D/246/249 4.3.0/T/246/249 4.4/T/249/268
5/G/268/309 5.0/T/268/277 5.1/S/277/281 5.1.0/T/277/281 5.2/D/281/285 5.2.0/T/281/285 5.3/T/285/296 5.4/D/296/297
5.4.0/T/296/297 5.5/T/297/309 6/G/309/338 6.0/T/309/338
""")
let tailEndOutsideTree = fakeTree("""
0/G/0/59 0.0/T/0/59 1/G/59/145 1.0/T/59/68 1.1/S/68/77 1.1.0/T/68/77 1.2/T/77/86 1.3/F/86/97 1.3.0/T/86/97
1.4/T/97/103 1.5/D/103/112 1.5.0/T/103/112 1.6/T/112/120 1.7/K/120/129 1.7.0/T/120/129 1.8/T/129/145 2/G/145/194
2.0/D/145/149 2.0.0/T/145/149 2.1/T/149/194 3/G/194/229 3.0/T/194/224 3.1/D/224/228 3.1.0/T/224/228 3.2/E/228/228
4/G/229/269 4.0/T/229/239 4.1/D/239/242 4.1.0/T/239/242 4.2/T/242/247 4.3/D/247/250 4.3.0/T/247/250 4.4/T/250/269
5/G/269/310 5.0/T/269/278 5.1/S/278/282 5.1.0/T/278/282 5.2/D/282/286 5.2.0/T/282/286 5.3/T/286/297 5.4/D/297/298
5.4.0/T/297/298 5.5/T/298/310 6/G/310/339 6.0/T/310/339
""")
let tailEndInsideTree = fakeTree("""
0/G/0/59 0.0/T/0/59 1/G/59/145 1.0/T/59/68 1.1/S/68/77 1.1.0/T/68/77 1.2/T/77/86 1.3/F/86/97 1.3.0/T/86/97
1.4/T/97/103 1.5/D/103/112 1.5.0/T/103/112 1.6/T/112/120 1.7/K/120/129 1.7.0/T/120/129 1.8/T/129/145 2/G/145/194
2.0/D/145/149 2.0.0/T/145/149 2.1/T/149/194 3/G/194/229 3.0/T/194/224 3.1/D/224/228 3.1.0/T/224/228 3.1.1/E/228/228
4/G/229/269 4.0/T/229/239 4.1/D/239/242 4.1.0/T/239/242 4.2/T/242/247 4.3/D/247/250 4.3.0/T/247/250 4.4/T/250/269
5/G/269/310 5.0/T/269/278 5.1/S/278/282 5.1.0/T/278/282 5.2/D/282/286 5.2.0/T/282/286 5.3/T/286/297 5.4/D/297/298
5.4.0/T/297/298 5.5/T/298/310 6/G/310/339 6.0/T/310/339
""")

let boldEndTree = fakeTree("""
0/G/0/59 0.0/T/0/59 1/G/59/145 1.0/T/59/68 1.1/S/68/77 1.1.0/T/68/77 1.2/T/77/86 1.3/F/86/97 1.3.0/T/86/97
1.4/T/97/103 1.5/D/103/112 1.5.0/T/103/112 1.6/T/112/120 1.7/K/120/129 1.7.0/T/120/129 1.8/T/129/145 2/G/145/194
2.0/D/145/149 2.0.0/T/145/149 2.1/T/149/194 3/G/194/228 3.0/T/194/224 3.1/D/224/228 3.1.0/T/224/228 4/G/228/268
4.0/T/228/238 4.1/D/238/241 4.1.0/T/238/241 4.2/T/241/246 4.3/D/246/249 4.3.0/T/246/249 4.4/T/249/268 5/G/268/309
5.0/T/268/277 5.1/S/277/281 5.1.0/T/277/281 5.1.1/E/281/281 5.2/D/281/285 5.2.0/T/281/285 5.3/T/285/296
5.4/D/296/297 5.4.0/T/296/297 5.5/T/297/309 6/G/309/338 6.0/T/309/338
""")
func inserting(_ text: String, _ addition: String, at offset: Int) -> String {
    var units = Array(text.utf16)
    units.insert(contentsOf: addition.utf16, at: offset)
    return String(decoding: units, as: UTF16.self)
}
// Each measured state is the text with what the drawn caret added, then the caret's plain offset and model offset.
let midValue = (start: inserting(codeValue, "\n\n", at: 104), end: inserting(codeValue, "\n\n", at: 113))
let midRaw = (start: inserting(codeRaw, "\u{FFFC}", at: 103), end: inserting(codeRaw, "\u{FFFC}", at: 112))
let tailValue = inserting(codeValue, "\n", at: 232)
let tailRaw = inserting(codeRaw, "\u{FFFC}\n", at: 228)
typealias CodeState = (name: String, value: String, raw: String, tree: [FakeNode], caret: Int, model: Int,
                       place: UnreachableLines.Caret.Place)
let codeStates: [CodeState] = [
    ("outside a start", midValue.start, midRaw.start, midStartOutsideTree, 103, 104, .middle),
    ("inside a start", midValue.start, midRaw.start, midStartInsideTree, 103, 104, .middle),
    ("inside an end", midValue.end, midRaw.end, midEndInsideTree, 112, 113, .middle),
    ("outside an end", midValue.end, midRaw.end, midEndOutsideTree, 112, 113, .middle),
    ("a paragraph's start", inserting(codeValue, "\n", at: 147), inserting(codeRaw, "\u{FFFC}", at: 145), leadStartTree, 145, 147, .start),
    ("outside a paragraph's end", tailValue, tailRaw, tailEndOutsideTree, 228, 231, .end),
    ("inside a paragraph's end", tailValue, tailRaw, tailEndInsideTree, 228, 231, .end),
    ("inside bold before code", inserting(codeValue, "\n\n", at: 286), inserting(codeRaw, "\u{FFFC}", at: 281), boldEndTree, 281, 286,
     .middle),
]
let noCaret = UnreachableLines.Found(markers: [], chips: [])
precondition(folded(codeValue, codeRaw, codeTree).text == codeValue, "code spans alone are no lines")
for state in codeStates {
    let plain = MarkerText.plain(state.raw)
    let aligned = ParagraphBreaks(value: state.value, fieldText: plain)!
    let candidates = UnreachableLines.candidates(text: state.value, breaks: aligned, raw: state.raw)
    precondition(candidates.carets == [state.caret], state.name)
    precondition(unreachableScanned(state.tree, candidates)?.carets == [.init(offset: state.caret, place: state.place)], state.name)
    precondition(scanned(state.tree, plain) == [], "\(state.name): the <br> after a drawn caret is no empty paragraph")
    let model = folded(state.value, state.raw, state.tree)
    precondition(model.text == codeValue, "\(state.name): the model is the text without the drawn caret")
    let withoutBreak = model.drawnBreak.map { String(plain.prefix($0)) + String(plain.dropFirst($0 + 1)) } ?? plain
    precondition(model.breaks.fieldText(model.text, at: 0..<model.text.utf16.count) == withoutBreak && roundTrips(model), state.name)
    precondition(model.breaks.fieldOffset(state.model) == state.caret, state.name)
    let unfolded = UnreachableLines.fold(text: state.value, breaks: aligned, raw: state.raw, found: noCaret).text
    precondition(state.place == .start || unfolded != codeValue, "\(state.name): undiscovered, the drawn caret's line stays")
}
let tailModel = folded(tailValue, tailRaw, tailEndOutsideTree)
precondition(tailModel.drawnBreak == 228 && tailModel.breaks.fieldOffset(232) == 228,
             "offsets past the <br> after a caret drawn at a paragraph's end are the field's once the caret leaves")
precondition(unreachableScanned([FakeNode("AXGroup", nil, 0, 4, [text(0, 2), FakeNode("AXGroup", "AXEmptyGroup", 2, 2), text(2, 4)])],
                                UnreachableLines.Candidates(markers: [], chips: [], carets: [2]))?.carets == [],
             "an empty group away from code is no drawn caret")
precondition(unreachableScanned(midStartOutsideTree, UnreachableLines.Candidates(markers: [], chips: [], carets: [103]), budget: 8)
             == nil, "past its budget")
precondition(DrawnCaret.isCaret(parent: "AXCodeStyleGroup", previous: nil, next: nil)
             && DrawnCaret.isCaret(parent: nil, previous: nil, next: "AXCodeStyleGroup")
             && !DrawnCaret.isCaret(parent: "AXStrongStyleGroup", previous: "AXApplicationGroup", next: nil))
precondition(DrawnCaret.isInline(role: "AXLink", subrole: nil) && DrawnCaret.isInline(role: "AXGroup", subrole: "AXStrongStyleGroup")
             && !DrawnCaret.isInline(role: "AXGroup", subrole: nil))
precondition([.middle, .start, .end].map(DrawnCaret.length) == [2, 1, 1], "two lines' worth inside a paragraph, one at its start or end")
precondition(DrawnCaret.side(.start) == .start(skipping: 0) && DrawnCaret.side(.end) == .end)

func codeBuild(_ state: CodeState, side: ParagraphBreaks.Side) -> FieldSnapshot {
    let plain = MarkerText.plain(state.raw)
    let aligned = ParagraphBreaks(value: state.value, fieldText: plain)!
    var reads = FieldSnapshot.Reads(
        field: FieldReads(text: state.value, plain: state.caret..<state.caret, markers: MarkerReads(
            breaks: aligned, value: aligned.valueRange(state.caret..<state.caret) { _ in side }
        )),
        length: state.value.utf16.count, webContent: true, blocks: 7, marked: state.caret..<state.caret, markerText: state.raw
    )
    var memo: EmptyParagraphs.Memo?
    var unreachable: UnreachableLines.Memo?
    return FieldSnapshot.Step.run(taking: { need in
        switch need {
        case .side(let end): reads.sides.updateValue(side, forKey: end)
        case .emptyParagraph: reads.inEmptyParagraph = true
        case .emptyParagraphs(let value, let raw, _):
            memo = EmptyParagraphs.Memo(value: value, markers: raw, blocks: reads.blocks, found: scanned(state.tree, plain))
        case .unreachable(let value, let raw, let candidates, _):
            unreachable = UnreachableLines.Memo(value: value, markers: raw, blocks: reads.blocks,
                                                found: unreachableScanned(state.tree, candidates))
        }
    }) {
        FieldSnapshot.build(reads, capabilities: keyProfile, answer: .textContent, anchor: nil, cursor: nil, memo: memo,
                            unreachable: unreachable)
    }.snapshot
}
var lingering = codeStates[5]
lingering.caret = 229
precondition(codeBuild(lingering, side: .end).selection == 232..<232, "a read past the <br> is the next line's start")
for state in codeStates {
    let snapshot = codeBuild(state, side: DrawnCaret.side(state.place))
    precondition(snapshot.text == codeValue && snapshot.selection == state.model..<state.model, state.name)
    precondition(snapshot.holdsDrawnCaret && !snapshot.caretInEmptyParagraph && snapshot.foldedLength > 0, state.name)
    let x = PhysicalPlanner.plan(LogicalPlanner.plan(RawCommand("x"), state: .initial), snapshot: snapshot)
    precondition(!x.steps.contains(.bell) && settleTraces(x).allSatisfy { $0.contains("len=nil") },
                 "\(state.name): its lines leave with the caret, so no length is checked")
}

let tailSnapshot = codeBuild(codeStates[5], side: .end)
func tailPlan(_ keys: String) -> PhysicalPlan {
    PhysicalPlanner.plan(LogicalPlanner.plan(RawCommand(keys), state: .initial), snapshot: FieldSnapshot(
        capabilities: writeKeys, text: tailSnapshot.text, selection: tailSnapshot.selection, webContent: true,
        breaks: tailSnapshot.breaks, foldedLength: tailSnapshot.foldedLength, holdsDrawnCaret: true, drawnBreak: tailSnapshot.drawnBreak
    ))
}
precondition(tailPlan("j").steps.first == .setSelection(263..<263) && settleTraces(tailPlan("j")).first == "sel=262..262 len=nil",
             "a write while the caret is drawn meets the <br>, which is gone once it lands")
precondition(tailPlan("w").steps.first == .setSelection(229..<229), "the next paragraph's start is past the <br>")
precondition(tailPlan("h").steps.first == .setSelection(227..<227), "and this one's end before it")

// A Sim of Linear's editor with code spans moves and edits as Vim does, in both lanes.
let codeDoc = ["Marks then code span then a link.", "lead starts here", "ends with tail", "x is one letter", "last line"]
func codeSim(_ profile: CapabilityProfile, caret: Int = 0) -> Sim {
    var host = Sim(text: codeDoc.joined(separator: "\n"), caret: caret, profile: profile)
    host.emptyParagraphs = true
    host.listLines = codeDoc.map { _ in Sim.ListLine() }
    host.codeSpans = [11..<20, 34..<38, 61..<65, 66..<67]
    host.emulatesKeys = true
    host.readModel = .textContent
    return host
}
precondition(ChromiumParagraphs(text: "ab cd e\nf", lines: [Sim.ListLine(), Sim.ListLine()], caret: 3, drawn: 3).shown
             == ("ab \n\ncd e\nf", "ab \u{FFFC}cd ef", []), "a caret drawn mid-paragraph is a line of its own")
precondition(ChromiumParagraphs(text: "ab\ncd\nef", lines: [Sim.ListLine(), Sim.ListLine(), Sim.ListLine()], caret: 5, drawn: 5)
             .shown == ("ab\ncd\n\nef", "abcd\u{FFFC}\nef", []), "and at a paragraph's end, one with a <br> after it")
var toggling = codeSim(writeKeys)
toggling.perform([.setSelection(11..<11), .press(.right, count: 1)])
precondition(toggling.readSelection == 11..<11, "a caret written at a code span's start is outside it, and → steps in")
toggling.perform([.press(.right, count: 1), .press(.left, count: 1), .press(.left, count: 1)])
precondition(toggling.readSelection == 11..<11, "then ← steps out")
toggling.perform([.press(.selectRight, count: 1), .press(.right, count: 1)])
precondition(toggling.readSelection == 12..<12, "shifted keys cross the edge")
for profile in [keyProfile, writeKeys] {
    let down = String(repeating: "j", count: codeDoc.count)
    for keys in ["lllllllllllllllllllllllllllllll" + String(repeating: "h", count: 31), down + String(repeating: "k", count: codeDoc.count),
                 "wwwwwwwwwwwwwwwwbbbbbbbbbbbbbbbb", "eeeeeeeeeeee", "5l3lj2lkj$jjk0jjj^", "fsfcfpfk", "jlhjjlh",
                 "jjj$hhlxlx", "wwxwwdwjx", "wwwcwX", "jA", "jjdd", "jwD", "wwwwD", "jjjwD", "llllllllllllhx",
                 "llllllllllllhyw", "llllllllllllhD", "jlhdw", "jjjlhx", "llllllllllllhhlx"] {
        var code = codeSim(profile)
        var plain = Sim(text: code.text, caret: 0, profile: profile)
        plain.emulatesKeys = true
        for key in keys {
            code.type(String(key))
            plain.type(String(key))
            precondition(code.caret == plain.caret && code.text == plain.text, "\(keys) at \(key)")
        }
        code.feed("<Esc>")
        plain.feed("<Esc>")
        precondition(code.caret == plain.caret && code.text == plain.text, "\(keys) then Esc")
        precondition(code.settleFailures == 0 && code.bells == 0 && code.unsupportedSteps == 0, "\(keys): \(code.settleFailures)")
    }
}

// Spans one letter long at the edges of list items, to-dos and lines beside chips, where writes are reached by keys.
let listCodeDoc: [(String, String?, Int, Bool)] = [
    ("Top line ab x", nil, 0, false), ("\u{2060} tail", nil, 0, false), ("x hi", "\u{2022}", 0, false),
    ("item ends y", "\u{2022}", 0, false), ("z", nil, 0, false), ("q to do", nil, 2, true), ("done r", nil, 2, true),
    ("\u{2060}", nil, 0, false), ("w", "1.", 0, false), ("Last code", nil, 0, false),
]
let listCodeStarts = listCodeDoc.indices.map { listCodeDoc.prefix($0).map { $0.0.utf16.count + 1 }.reduce(0, +) }
let listCodeSpans = [(0, 12, 13), (2, 0, 1), (3, 10, 11), (5, 0, 1), (6, 5, 6), (8, 0, 1), (9, 5, 9)].map {
    listCodeStarts[$0.0] + $0.1 ..< listCodeStarts[$0.0] + $0.2
}
func listCodeSim(_ profile: CapabilityProfile, caret: Int, spans: [Range<Int>]) -> Sim {
    var host = Sim(text: listCodeDoc.map(\.0).joined(separator: "\n"), caret: caret, profile: profile)
    host.emptyParagraphs = true
    host.listLines = listCodeDoc.map { Sim.ListLine(marker: $0.1, leaves: $0.2, checkbox: $0.3) }
    host.codeSpans = spans
    host.emulatesKeys = true
    host.readModel = .textContent
    return host
}
for caret in listCodeSpans.flatMap({ [$0.lowerBound, $0.upperBound] }) {
    for keys in ["AQ", "$", "l", "k", "2j", "dd", "yyp", "dw", "Vjd"] {
        var code = listCodeSim(writeKeys, caret: caret, spans: listCodeSpans)
        var plain = listCodeSim(writeKeys, caret: caret, spans: [])
        for key in keys {
            code.type(String(key))
            plain.type(String(key))
        }
        code.feed("<Esc>")
        plain.feed("<Esc>")
        precondition(code.caret == plain.caret && code.text == plain.text && code.bells == plain.bells
                     && code.settleFailures == plain.settleFailures, "\(keys) from \(caret)")
    }
}
for (text, spans, caret, keys) in [
    ("foo code\n\u{2060} text", [4..<8], 4, ["dd"]), ("ab x\n\u{2060} tail", [3..<4], 0, ["AQ"]),
    ("aa\nx hi\n\u{2060} tail", [3..<4], 0, ["j", "x"]), ("ab x\nyyyy\nz\n\u{2060} tail", [3..<4], 4, ["2j"]),
] {
    var code = Sim(text: text, caret: caret, profile: writeKeys)
    code.emptyParagraphs = true
    code.listLines = text.split(separator: "\n", omittingEmptySubsequences: false).map { _ in Sim.ListLine() }
    code.codeSpans = spans
    code.emulatesKeys = true
    code.readModel = .textContent
    var plain = Sim(text: text, caret: caret, profile: writeKeys)
    plain.emulatesKeys = true
    for command in keys {
        code.type(command)
        plain.type(command)
        if code.state.field.mode == .insert { code.feed("<Esc>"); plain.feed("<Esc>") }
    }
    precondition(code.caret == plain.caret && code.text == plain.text && code.settleFailures == 0, "\(text) \(keys)")
}

// A quick command's snapshot can come before Linear draws the caret, and a write beside a line ending in code can draw one.
for (profile, text, spans, kinds, caret, keys) in [
    (keyProfile, "ab code zz", [3..<7], "p", 4, ["yiw", "x"]), (writeKeys, "e\nd\n", [0..<1], "1.,t,p", 4, ["AQ"]),
    (writeKeys, "e\nd\n", [0..<1], "1.,t,p", 4, ["IQ"]), (writeKeys, "ab\ne\nd\n", [3..<4], "p,1.,t,p", 0, ["3j", "AQ"]),
] {
    func sim(_ spans: [Range<Int>]) -> Sim {
        var host = Sim(text: text, caret: caret, profile: profile)
        host.emptyParagraphs = true
        host.listLines = kinds.split(separator: ",").map {
            $0 == "p" ? Sim.ListLine() : $0 == "t" ? Sim.ListLine(leaves: 2, checkbox: true) : Sim.ListLine(marker: String($0))
        }
        host.codeSpans = spans
        host.drawsLate = true
        host.emulatesKeys = true
        host.readModel = .textContent
        return host
    }
    var code = sim(spans)
    var plain = sim([])
    for command in keys {
        code.type(command)
        plain.type(command)
        if code.state.field.mode == .insert { code.feed("<Esc>"); plain.feed("<Esc>") }
    }
    precondition(code.caret == plain.caret && code.text == plain.text && code.settleFailures == plain.settleFailures,
                 "\(text) \(keys)")
}

// A paragraph's first code span: ⇧→ selects from inside it, and only ⇧⌃E needs ⌃A first, the field's start included.
var firstSpan = Sim(text: "aa\ncode x", caret: 3, profile: keyProfile)
firstSpan.emptyParagraphs = true
firstSpan.listLines = [Sim.ListLine(), Sim.ListLine()]
firstSpan.codeSpans = [3..<7]
firstSpan.emulatesKeys = true
firstSpan.readModel = .textContent
precondition(firstSpan.perform([.press(.right, count: 1), .press(.selectRight, count: 1)]) && firstSpan.selection == 3..<4)
precondition(paragraphPlanning("D", text: "code x\nzz", caret: 0, profile: keyProfile).plan.steps.first
             == .press(.paragraphStart, count: 1))
precondition(paragraphPlanning("x", text: "code x\nzz", caret: 0, profile: keyProfile).plan.steps.first
             == .press(.selectRight, count: 1))
let noLineStart = removing([.lineStartKey], from: keyProfile)
for (text, span, caret, left) in [("aa\ncode x", 3..<7, 3, "aa\n"), ("code x\nzz", 0..<4, 0, "\nzz")] {
    for profile in [keyProfile, noLineStart] {
        var host = Sim(text: text, caret: caret, profile: profile)
        host.emptyParagraphs = true
        host.listLines = [Sim.ListLine(), Sim.ListLine()]
        host.codeSpans = [span]
        host.emulatesKeys = true
        host.readModel = .textContent
        precondition(host.perform([.press(.right, count: 1)]))
        host.type("D")
        precondition(host.text == left && host.settleFailures == 0, "\(text) D")
    }
}

// A caret read past the text's end, as stepping inside a field's first code span gives, is no caret to plan from.
let pastEnd = FieldSnapshot.Step.run(taking: { _ in }) {
    FieldSnapshot.build(FieldSnapshot.Reads(field: FieldReads(text: "code x\nzz", plain: 94..<94), length: 9, webContent: true),
                        capabilities: keyProfile, answer: .value, anchor: nil, cursor: nil, memo: nil)
}.snapshot
precondition(pastEnd.selection == nil)
_ = PhysicalPlanner.planning(LogicalPlanner.plan(RawCommand("D"), state: .initial), snapshot: pastEnd)

// No write-lane plan has a counted ← run, whose first ← a caret the last plan wrote at a code span's end can take.
for caret in listCodeSpans.flatMap({ [$0.lowerBound, $0.upperBound] }) + listCodeStarts {
    for keys in ["h", "3h", "b", "2b", "x", "X", "3X", "dw", "db", "d3h", "c2h", "D", "A", "I", "0", "$", "j", "k", "dd",
                 "yy", "p", "J", "~", "v3h", "2h", "vb"] {
        var host = listCodeSim(writeKeys, caret: caret, spans: listCodeSpans)
        var (reads, observed) = host.read()
        var memo: EmptyParagraphs.Memo?
        var unreachable: UnreachableLines.Memo?
        let snapshot = FieldSnapshot.Step.run(taking: { host.take($0, into: &reads, memo: &memo, unreachable: &unreachable) }) {
            FieldSnapshot.build(reads, capabilities: writeKeys, answer: observed.after, anchor: nil, cursor: nil, memo: memo,
                                unreachable: unreachable)
        }.snapshot
        let steps = PhysicalPlanner.plan(LogicalPlanner.plan(RawCommand(keys), state: host.state), snapshot: snapshot).steps
        var written = true
        for step in steps {
            switch step {
            case .setSelection: written = true
            case .press(.selectLeft, let count), .press(.left, let count):
                precondition(!written || count < 2, "\(keys) from \(caret)")
            case .press: written = false
            default: break
            }
        }
    }
}

// MARK: - Cheaper counted arrows (LIN-1686)

let tenTwice = "abcdefghij\nabcdefghij"
precondition(chords(physical("j", text: tenTwice, caret: 2, profile: keyProfile)) == [.paragraphEnd, .right, .right, .right])
precondition(chords(physical("j", text: tenTwice, caret: 8, profile: keyProfile))
             == [.paragraphEnd, .right, .paragraphEnd, .left, .left])
precondition(chords(physical("j", text: tenTwice, caret: 10, profile: keyProfile)) == [.paragraphEnd, .right, .paragraphEnd])
precondition(chords(physical("k", text: tenTwice, caret: 19, profile: keyProfile)) == [.paragraphStart, .left, .left, .left])
precondition(chords(physical("k", text: tenTwice, caret: 13, profile: keyProfile))
             == [.paragraphStart, .left, .paragraphStart, .right, .right])
precondition(chords(physical("j", text: tenTwice, caret: 5, profile: keyProfile)).count == 7, "a tie counts from the start")
let nearEnd = physical("j", text: tenTwice, caret: 8, profile: keyProfile)
precondition(nearEnd.traceShape == "P!PP!P2!C" && nearEnd.steps[1] == .settle(Expectation(
    landing: .exact(10..<10), length: 21,
    blame: .init(capability: .lineEndKey, unmoved: [8..<8], leavesCaret: true, offTarget: true)
)), "the extra ⌃E rides the unblamed hops")
func routes(_ plan: PhysicalPlan) -> [Route?] {
    plan.steps.compactMap { step -> Route?? in
        guard case .settle(let expectation) = step else { return nil }
        return .some(expectation.route)
    }
}
precondition(routes(nearEnd) == [nil, .lineEnd, .lineEnd], "the settles past the extra ⌃E are an optional route's")
precondition(routes(physical("k", text: tenTwice, caret: 19, profile: keyProfile)) == [nil, .lineStart, .lineStart])
precondition(routes(physical("j", text: tenTwice, caret: 2, profile: keyProfile)) == [nil, nil, nil])
func without(_ missed: Set<Route>, _ keys: String, text: String, caret: Int) -> PhysicalPlan {
    PhysicalPlanner.planning(LogicalPlanner.plan(RawCommand(keys), state: .initial),
                             snapshot: FieldSnapshot(capabilities: keyProfile, text: text, selection: caret..<caret), missed: missed).plan
}
precondition(chords(without([.lineEnd], "j", text: tenTwice, caret: 8))
             == [.paragraphEnd, .right] + Array(repeating: .right, count: 8), "a route that missed leaves `j` its start way")
precondition(chords(without([.lineStart], "k", text: tenTwice, caret: 19))
             == [.paragraphStart, .left, .paragraphStart] + Array(repeating: .right, count: 8))
precondition(chords(without([.lineStart, .selectBack], "j", text: tenTwice, caret: 8)).count == 5, "other routes' misses leave this one")
let tenBreak = ParagraphBreaks(offsets: [10])
precondition(chords(webPhysical("j", text: tenTwice, caret: 8, profile: keyProfile, breaks: tenBreak))
             == [.paragraphEnd, .right, .paragraphEnd, .selectLeft, .selectLeft, .left, .selectLeft, .right])
precondition(chords(physical("j", text: tenTwice, caret: 6, profile: keyProfile)).suffix(5) == [.paragraphEnd, .left, .left, .left, .left])
precondition(chords(webPhysical("j", text: tenTwice, caret: 6, profile: keyProfile, breaks: tenBreak))
             == [.paragraphEnd, .right] + Array(repeating: .selectRight, count: 6) + [.right], "where those tip it to the start")

let twenty = String(repeating: "word ", count: 20) + "end."
precondition(chords(physical("fd", text: twenty, caret: 0, profile: keyProfile)) == [.right, .right, .right])
let farFind = physical("t.", text: twenty, caret: 0, profile: keyProfile)
var routedEnd = Expectation(landing: .exact(102..<102), length: 104)
routedEnd.route = .lineEnd
precondition(Array(farFind.steps.prefix(3)) == [.press(.paragraphEnd, count: 1), .press(.left, count: 2), .settle(routedEnd)],
             "one settle, marked as an optional route's")
precondition(routedEnd.traceFields == "sel=102..102 len=104 route=line-end")
precondition(chords(physical("t.", text: twenty, caret: 98, profile: keyProfile)) == [.paragraphEnd, .left, .left])
precondition(chords(physical("t.", text: twenty, caret: 99, profile: keyProfile)) == Array(repeating: .right, count: 3),
             "a tie counts from the caret")
precondition(chords(without([.lineEnd], "t.", text: twenty, caret: 0)) == Array(repeating: .right, count: 102))
precondition(chords(without([.lineStart], "t.", text: twenty, caret: 0)) == [.paragraphEnd, .left, .left])
let wordFirst = "aw" + String(repeating: "x", count: 100)
precondition(chords(physical("Fw", text: wordFirst, caret: 101, profile: keyProfile)) == [.paragraphStart, .right])
precondition(chords(physical("Fw", text: twenty, caret: 99, profile: keyProfile)) == Array(repeating: .left, count: 4))
precondition(chords(physical("Fw", text: twenty, caret: 102, profile: removing([.lineStartKey, .lineEndKey], from: keyProfile)))
             == Array(repeating: .left, count: 7), "without the line keys it counts from the caret")
var fromStart = Sim(text: twenty, caret: 103, profile: keyProfile)
fromStart.emulatesKeys = true
fromStart.type("2Fw")
precondition(fromStart.caret == 90 && fromStart.settleFailures == 0)
fromStart.type("0e")
precondition(fromStart.caret == 3)

precondition(chords(physical("X", text: twenty, caret: 50, profile: keyProfile)) == [.selectLeft, .deleteBack])
precondition(chords(physical("db", text: twenty, caret: 52, profile: keyProfile)) == [.selectLeft, .selectLeft, .deleteBack])
precondition(chords(physical("d^", text: twenty, caret: 60, profile: keyProfile)) == [Chord.paragraphStart.shifted, .deleteBack])
precondition(chords(physical("dt.", text: twenty, caret: 0, profile: keyProfile))
             == [Chord.paragraphEnd.shifted, .selectLeft, .deleteBack])
precondition(chords(physical("x", text: twenty, caret: 3, profile: keyProfile)) == [.selectRight, .deleteBack])
let chipInLine = ParagraphBreaks(hidden: [.init(at: 3, text: "LIN-1 chip", kind: .atom)])
precondition(chords(webPhysical("dt.", text: "ab\u{2060}cd. and more", caret: 0, profile: keyProfile, breaks: chipInLine))
             == Array(repeating: .selectRight, count: 5) + [.deleteBack], "⇧⌃E would stop at the chip")
precondition(chords(without([.lineStart], "d^", text: twenty, caret: 60)) == Array(repeating: .selectLeft, count: 60) + [.deleteBack])
precondition(chords(without([.lineEnd], "dt.", text: twenty, caret: 0)) == Array(repeating: .selectRight, count: 103) + [.deleteBack])
precondition(chords(without([.selectBack], "X", text: twenty, caret: 50)) == [.left, .selectRight, .deleteBack])
precondition(routes(physical("d^", text: twenty, caret: 60, profile: keyProfile)).first == .some(.lineStart)
             && routes(physical("X", text: twenty, caret: 50, profile: keyProfile)).first == .some(.selectBack)
             && routes(physical("x", text: twenty, caret: 3, profile: keyProfile)).first == .some(nil))
for (keys, caret, left) in [("X", 50, String(twenty.prefix(49) + twenty.dropFirst(50))), ("dF ", 99, String(twenty.prefix(95) + twenty.dropFirst(99))),
                            ("d^", 60, String(twenty.dropFirst(60))), ("dt.", 0, ".")] {
    var host = Sim(text: twenty, caret: caret, profile: keyProfile)
    host.emulatesKeys = true
    host.type(keys)
    precondition(host.text == left && host.settleFailures == 0, keys)
}
precondition(chords(webPhysical("de", text: "ab\ncd", caret: 0, profile: removing([.lineStartKey], from: keyProfile),
                                breaks: ParagraphBreaks(offsets: [2])))
             == [.selectRight, .selectRight, .deleteBack], "⇧⌃E's ⇧→ ← at a paragraph's start would cost more")
precondition(chords(webPhysical("de", text: "abcd\ncd", caret: 0, profile: keyProfile, breaks: ParagraphBreaks(offsets: [4])))
             == [.paragraphStart, Chord.paragraphEnd.shifted, .deleteBack])

var strayed = RunAttribution()
strayed.record(.press(.paragraphEnd, count: 1))
strayed.record(.settle(routedEnd), passed: false, selection: 0..<0, length: 104)
precondition(strayed.missedRoute == .lineEnd && strayed.evidence.isEmpty, "a route's miss is no evidence on its key")
var dark = RunAttribution()
dark.record(.settle(routedEnd), passed: false, selection: nil, length: 104)
var landed = RunAttribution()
landed.record(.settle(routedEnd), passed: true, selection: 102..<102, length: 104)
precondition(dark.missedRoute == nil && landed.missedRoute == nil, "a read that went dark is not the route's miss")
var missedRoutes = Strikes()
missedRoutes.miss(.lineEnd, judgedUnder: .value, app: "1")
missedRoutes.pass([Evidence(.key(.lineEndKey), .supports(nil), why: .settled, seen: .settle(0))])
precondition(missedRoutes.missed(judgedUnder: .value, app: "1") == [.lineEnd] && !missedRoutes.isEmpty, "no pass brings it back")
precondition(missedRoutes.missed(judgedUnder: .textContent, app: "1").isEmpty && missedRoutes.missed(judgedUnder: .value, app: "2").isEmpty)

// softlash/LIN-1686 scripts/route-faults runs these against `main`, which counts and never fails them.
for rich in [false, true] {
    for (line, keys, caret, key, opposite, further, left, landing) in [
        (twenty, "t.", 0, Chord.paragraphEnd, Chord.paragraphStart, Chord.documentEnd, twenty, 102),
        (wordFirst, "Fw", 101, .paragraphStart, .paragraphEnd, .documentStart, wordFirst, 1),
        (twenty, "d^", 60, Chord.paragraphStart.shifted, Chord.paragraphEnd.shifted, Chord.documentStart.shifted,
         String(twenty.dropFirst(60)), 0),
        (twenty, "dt.", 0, Chord.paragraphEnd.shifted, Chord.paragraphStart.shifted, Chord.documentEnd.shifted, ".", 0),
    ] {
        for acts in [nil, opposite, further] {
            var host = Sim(text: "prefix\n" + line + "\nnext", caret: caret + 7, profile: keyProfile)
            host.emulatesKeys = true
            if rich {
                host.emptyParagraphs = true
                host.readModel = .textContent
            }
            if let acts { host.reboundChords = [key: acts] } else { host.ignoredChords = [key] }
            host.learn(with: Sim.Learner(chromium: rich, probed: keyProfile))
            let fault = "\(keys) rich \(rich) as \(acts.map { "\($0)" } ?? "nothing")"
            host.type(keys)
            precondition(host.settleFailures == 1 && host.blamed.isEmpty && !host.learner!.strikes.isEmpty, fault)
            for _ in 0..<2 {
                host.refocus(.sameElement, text: "prefix\n" + line + "\nnext", caret: caret + 7)
                host.type(keys)
                precondition(host.settleFailures == 1 && host.text == "prefix\n" + left + "\nnext" && host.caret == landing + 7, fault)
            }
        }
    }
}
var lineEnd = Sim(text: tenTwice, caret: 10, profile: keyProfile)
lineEnd.emulatesKeys = true
lineEnd.ignoredChords = [.paragraphEnd]
lineEnd.learn(with: Sim.Learner(probed: keyProfile))
lineEnd.type("j")
precondition(lineEnd.settleFailures == 1 && lineEnd.caret == 11, "`j`'s way by the line's end misses where ⌃E does nothing")
lineEnd.refocus(.sameElement, text: tenTwice, caret: 10)
lineEnd.type("j")
precondition(lineEnd.settleFailures == 1 && lineEnd.caret == 21)
var noShiftLeft = Sim(text: twenty, caret: 50, profile: keyProfile)
noShiftLeft.emulatesKeys = true
noShiftLeft.ignoredChords = [.selectLeft]
noShiftLeft.learn(with: Sim.Learner(probed: keyProfile))
noShiftLeft.type("X")
precondition(noShiftLeft.settleFailures == 1 && noShiftLeft.text == twenty)
noShiftLeft.type("X")
precondition(noShiftLeft.settleFailures == 1 && noShiftLeft.text == String(twenty.prefix(49) + twenty.dropFirst(50)))

let paste = webPhysical("\"+p", text: "x", caret: 0, profile: keyProfile, breaks: ParagraphBreaks())
precondition(chords(paste) == [.selectRight, .right] && paste.traceShape.hasPrefix("PPV"), "a put's keys go before ⌘V unsettled")
var yankedBack = Sim(text: twenty, caret: 52, profile: keyProfile)
yankedBack.emulatesKeys = true
yankedBack.type("yb")
precondition(yankedBack.caret == 50 && yankedBack.readSelection == 50..<50
             && yankedBack.state.session.register("\"") == .content(RegisterContent(text: "wo", wise: .character)))

// softlash/LIN-1686 scripts/list-boundary (Dia 1.49.1): a plain → or ↓ from a list's last item stops before the next list.
var gapKeys = KeyModel(text: "a\nb\nc", anchor: 1, focus: 1, gaps: [2])
precondition(gapKeys.press(.right) && gapKeys.selection == 1..<1 && gapKeys.inGap)
precondition(gapKeys.press(.paragraphStart) && gapKeys.press(Chord.paragraphEnd.shifted) && gapKeys.inGap, "⌃A and ⇧⌃E stay")
precondition(gapKeys.press(.right) && gapKeys.selection == 2..<2 && !gapKeys.inGap)
gapKeys = KeyModel(text: "a\nb\nc", anchor: 0, focus: 0, gaps: [2])
precondition(gapKeys.press(.down) && gapKeys.inGap && gapKeys.press(.selectRight) && gapKeys.selection == 2..<2)
gapKeys = KeyModel(text: "a\nb\nc", anchor: 1, focus: 1, gaps: [2])
precondition(gapKeys.press(.right) && gapKeys.press(.left) && gapKeys.selection == 1..<1 && !gapKeys.inGap)
precondition(gapKeys.press(.selectRight) && gapKeys.selection == 1..<2, "⇧→ crosses")
gapKeys = KeyModel(text: "a\nb\nc", anchor: 2, focus: 2, gaps: [2])
precondition(gapKeys.press(.left) && gapKeys.selection == 1..<1, "← from the next list skips it")
// softlash/LIN-1726 scripts/block-boundary (Dia 1.51.0): ↑ from the line after a stop enters it, and ↑ again leaves upward.
gapKeys = KeyModel(text: "ab\ncd\nef", anchor: 4, focus: 4, gaps: [3])
precondition(gapKeys.press(.up) && gapKeys.selection == 2..<2 && gapKeys.inGap)
precondition(gapKeys.press(.up) && gapKeys.selection == 0..<0 && !gapKeys.inGap)
gapKeys = KeyModel(text: "ab\ncd\nef", anchor: 7, focus: 7, gaps: [3])
precondition(gapKeys.press(.up) && gapKeys.selection == 4..<4 && !gapKeys.inGap, "no stop above a line that starts no block")

let boundaryValue = "LIN-1686 boundary probe: plain opening paragraph here.\n1.\nNumbered one alpha\n2.\nNumbered two bravo\n\u{2022}\nBullet one charlie\n\u{2022}\nBullet two delta\n1.\nNumbered again echo\n\n\nTodo one foxtrot\n\n\nTodo two golf\n1.\nNumbered after todo hotel\n\u{2022}\nDash bullet india\n\u{2022}\nStar bullet juliet\n\n\nTodo after star kilo\n\u{2022}\nStar after todo lima\nParagraph after list mike.\n\u{2022}\nBullet after paragraph november\n\n\nHeading after list oscar\nPlain closing paragraph papa."
let boundaryRaw = "LIN-1686 boundary probe: plain opening paragraph here.1.Numbered one alpha2.Numbered two bravo\u{2022}Bullet one charlie\u{2022}Bullet two delta1.Numbered again echo\u{FFFC}\u{FFFC}Todo one foxtrot\u{FFFC}\u{FFFC}Todo two golf1.Numbered after todo hotel\u{2022}Dash bullet india\u{2022}Star bullet juliet\u{FFFC}\u{FFFC}Todo after star kilo\u{2022}Star after todo limaParagraph after list mike.\u{2022}Bullet after paragraph november\u{FFFC}\u{FFFC}Heading after list oscarPlain closing paragraph papa."
let boundarySpec = """
0/G/0/54 0.0/T/0/54 1/L/54/94 1.0/G/54/74 1.0.0/G/54/56 1.0.0.0/T/54/55 1.0.0.1/T/55/56 1.0.1/G/56/74 1.0.1.0/T/56/74
1.1/G/74/94 1.1.0/G/74/76 1.1.0.0/T/74/75 1.1.0.1/T/75/76 1.1.1/G/76/94 1.1.1.0/T/76/94 2/L/94/130 2.0/G/94/113 2.0.0/G/94/95
2.0.0.0/T/94/95 2.0.1/G/95/113 2.0.1.0/T/95/113 2.1/G/113/130 2.1.0/G/113/114 2.1.0.0/T/113/114 2.1.1/G/114/130
2.1.1.0/T/114/130 3/L/130/151 3.0/G/130/151 3.0.0/G/130/132 3.0.0.0/T/130/131 3.0.0.1/T/131/132 3.0.1/G/132/151
3.0.1.0/T/132/151 4/L/151/180 4.0/G/151/167 4.0.0/G/151/151 4.0.0.0/I/151/151 4.0.0.1/C/151/151 4.0.1/G/151/167
4.0.1.0/G/151/167 4.0.1.0.0/T/151/167 4.1/G/167/180 4.1.0/G/167/167 4.1.0.0/I/167/167 4.1.0.1/C/167/167 4.1.1/G/167/180
4.1.1.0/G/167/180 4.1.1.0.0/T/167/180 5/L/180/207 5.0/G/180/207 5.0.0/G/180/182 5.0.0.0/T/180/181 5.0.0.1/T/181/182
5.0.1/G/182/207 5.0.1.0/T/182/207 6/L/207/225 6.0/G/207/225 6.0.0/G/207/208 6.0.0.0/T/207/208 6.0.1/G/208/225
6.0.1.0/T/208/225 7/L/225/244 7.0/G/225/244 7.0.0/G/225/226 7.0.0.0/T/225/226 7.0.1/G/226/244 7.0.1.0/T/226/244
8/L/244/264 8.0/G/244/264 8.0.0/G/244/244 8.0.0.0/I/244/244 8.0.0.1/C/244/244 8.0.1/G/244/264 8.0.1.0/G/244/264
8.0.1.0.0/T/244/264 9/L/264/285 9.0/G/264/285 9.0.0/G/264/265 9.0.0.0/T/264/265 9.0.1/G/265/285 9.0.1.0/T/265/285
10/G/285/311 10.0/T/285/311 11/L/311/343 11.0/G/311/343 11.0.0/G/311/312 11.0.0.0/T/311/312 11.0.1/G/312/343
11.0.1.0/T/312/343 12/H/343/367 12.0/G/343/343 12.0.0/G/343/343 12.0.0.0/E/343/343 12.0.0.1/P/343/343 12.1/T/343/367
13/G/367/396 13.0/T/367/396
"""
let boundaryTree = fakeTree(boundarySpec)
let boundaryModel = folded(boundaryValue, boundaryRaw, boundaryTree)
func lineStart(of needle: String, in text: String) -> Int {
    var offset = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix(needle) { return offset }
        offset += line.utf16.count + 1
    }
    preconditionFailure(needle)
}
precondition(boundaryModel.breaks.gaps == Set(["Bullet one charlie", "Numbered again echo", "Todo one foxtrot",
    "Numbered after todo hotel", "Dash bullet india", "Star bullet juliet", "Todo after star kilo", "Star after todo lima",
].map { lineStart(of: $0, in: boundaryModel.text) }), "a stop before every list right after a list, and nowhere else")
precondition(roundTrips(boundaryModel))
let boundaryCandidates = UnreachableLines.candidates(text: boundaryValue, breaks: ParagraphBreaks(value: boundaryValue,
    fieldText: MarkerText.plain(boundaryRaw))!, raw: boundaryRaw)
precondition((1...400).contains { budget in
    guard let found = unreachableScanned(boundaryTree, boundaryCandidates, budget: budget) else { return false }
    return found.joins.isEmpty && found.markers.count == 10
}, "running out of reads on the lists loses only the joins")
precondition(unreachableScanned(boundaryTree, UnreachableLines.Candidates(markers: [], chips: []))?.joins == [],
             "nothing that starts a list and no ProseMirror editor, no joins read")
let otherBoundary = fakeTree(boundarySpec, linear: false)
let markedJoins = unreachableScanned(otherBoundary, boundaryCandidates)?.joins ?? []
precondition(!markedJoins.isEmpty && unreachableScanned(otherBoundary, UnreachableLines.candidates(text: boundaryValue,
    breaks: ParagraphBreaks(value: boundaryValue, fieldText: MarkerText.plain(boundaryRaw))!, raw: boundaryRaw, proseMirror: true))?
    .joins == markedJoins, "another ProseMirror editor's lists join where its text shows a marker, as on main")
let ownLists = fakeTree("0/G/0/3 0.0/T/0/3 1/L/3/6 1.0/G/3/6 1.0.0/M/3/5 1.0.1/T/5/6 2/L/6/10 2.0/G/6/10 2.0.0/M/6/9 2.0.1/T/9/10")
let ownCandidates = UnreachableLines.candidates(text: "Top\n\u{2022} a\n1. b", breaks: ParagraphBreaks(offsets: [3, 7]), raw: "Top\u{2022} a1. b")
precondition(unreachableScanned(ownLists, ownCandidates)?.joins == [6]
             && folded("Top\n\u{2022} a\n1. b", "Top\u{2022} a1. b", ownLists).breaks.gaps.isEmpty, "Chromium's own lists have no stop")
let todosModel = folded("Top\n\n\nTodo a\n\n\nTodo b\nEnd", "Top\u{FFFC}\u{FFFC}Todo a\u{FFFC}\u{FFFC}Todo bEnd", fakeTree("""
0/G/0/3 0.0/T/0/3 1/L/3/9 1.0/G/3/9 1.0.0/G/3/3 1.0.0.0/I/3/3 1.0.0.1/C/3/3 1.0.1/G/3/9 1.0.1.0/T/3/9 2/L/9/15 2.0/G/9/15
2.0.0/G/9/9 2.0.0.0/I/9/9 2.0.0.1/C/9/9 2.0.1/G/9/15 2.0.1.0/T/9/15 3/G/15/18 3.0/T/15/18
"""))
precondition(todosModel.text == "Top\nTodo a\nTodo b\nEnd" && todosModel.breaks.gaps == [11], "two to-do lists alone stop too")
// softlash/LIN-1726 evidence/tree-empty-above-todo.jsonl: below an empty paragraph a to-do's image and checkbox have no lines.
let bareTodo = folded(
    "Corner probe: plain opening paragraph alpha.\nTodo under paragraph bravo\nQuote after todo charlie\nPlain closing paragraph delta.",
    "Corner probe: plain opening paragraph alpha.\n\u{FFFC}\u{FFFC}Todo under paragraph bravoQuote after todo charliePlain closing paragraph delta.",
    fakeTree("""
    0/G/0/44 0.0/T/0/44 1/E/44/45 2/L/45/71 2.0/G/45/71 2.0.0/G/45/45 2.0.0.0/I/45/45 2.0.0.1/C/45/45 2.0.1/G/45/71
    2.0.1.0/G/45/71 2.0.1.0.0/T/45/71 3/Q/71/95 3.0/G/71/95 3.0.0/T/71/95 4/G/95/125 4.0/T/95/125
    """))
precondition(bareTodo.breaks.hidden == [.init(at: lineStart(of: "Quote after todo", in: bareTodo.text), text: "", kind: .gap)]
             && roundTrips(bareTodo), "with no marker and no leaf's line, the stop is read and kept all the same")
// evidence/tree-empty-quote-line.jsonl: the same to-do below a quote's empty last line.
let quotedBareTodo = folded(
    "Corner probe: plain opening paragraph alpha.\nQuote before todo bravo\nTodo after quote charlie\nPlain closing paragraph delta.",
    "Corner probe: plain opening paragraph alpha.Quote before todo bravo\n\u{FFFC}\u{FFFC}Todo after quote charliePlain closing paragraph delta.",
    fakeTree("""
    0/G/0/44 0.0/T/0/44 1/Q/44/68 1.0/G/44/67 1.0.0/T/44/67 1.1/E/67/68 2/L/68/92 2.0/G/68/92 2.0.0/G/68/68
    2.0.0.0/I/68/68 2.0.0.1/C/68/68 2.0.1/G/68/92 2.0.1.0/G/68/92 2.0.1.0.0/T/68/92 3/G/92/122 3.0/T/92/122
    """))
let quotedBareStart = lineStart(of: "Todo after quote", in: quotedBareTodo.text)
precondition(quotedBareTodo.breaks.hidden == [.init(at: quotedBareStart, text: "", kind: .boxedGap)] && roundTrips(quotedBareTodo)
             && chords(webPhysical("j", text: quotedBareTodo.text, caret: quotedBareStart - 1, profile: keyProfile,
                                   breaks: quotedBareTodo.breaks)) == [.paragraphEnd, .right, .right],
             "its stop is a to-do's by the leaves at the list's start, though none has a line")
precondition(!UnreachableLines.candidates(text: "Top\nEnd", breaks: ParagraphBreaks(offsets: [3]), raw: "TopEnd").roots)

let gapBreaks = ParagraphBreaks(offsets: [10], hidden: [
    .init(at: 11, text: ""), .init(at: 11, text: ""), .init(at: 11, text: "", kind: .boxedGap),
])
precondition(chords(webPhysical("j", text: tenTwice, caret: 0, profile: keyProfile, breaks: gapBreaks))
             == [.paragraphEnd, .right, .right], "a to-do, behind its checkbox's leaves, takes → →")
let markedGap = ParagraphBreaks(offsets: [10], hidden: [.init(at: 11, text: "\u{2022}"), .init(at: 11, text: "", kind: .gap)])
precondition(chords(webPhysical("j", text: tenTwice, caret: 0, profile: keyProfile, breaks: markedGap))
             == [.paragraphEnd, .selectRight, .right], "a marked item is crossed into by ⇧→ →, which Dia reads right sooner")
let quoteGap = ParagraphBreaks(offsets: [10], hidden: [.init(at: 11, text: "", kind: .gap)])
precondition(chords(webPhysical("j", text: tenTwice, caret: 0, profile: keyProfile, breaks: quoteGap))
             == [.paragraphEnd, .selectRight, .right], "and so is a quote, where → → reads one past for ~150 ms (LIN-1726)")
precondition(webPhysical("j", text: tenTwice, caret: 0, profile: writeKeys, breaks: quoteGap).steps
             == webPhysical("j", text: tenTwice, caret: 0, profile: writeKeys, breaks: ParagraphBreaks(offsets: [10])).steps
             && webPhysical("dd", text: tenTwice, caret: 0, profile: writeKeys, breaks: quoteGap).steps.first
             == webPhysical("dd", text: tenTwice, caret: 0, profile: writeKeys, breaks: ParagraphBreaks(offsets: [10])).steps.first,
             "a stop folds no text, so a write lane plans a quote's first line as any paragraph's")
let thrice = tenTwice + "\nabcdefghij"
let foldedQuote = ParagraphBreaks(offsets: [10, 21], hidden: [.init(at: 11, text: "", kind: .gap), .init(at: 22, text: "\u{2022}")])
let foldedPlain = ParagraphBreaks(offsets: [10, 21], hidden: [.init(at: 22, text: "\u{2022}")])
precondition([("j", 0), ("k", 22), ("dd", 11), ("d$", 11)].allSatisfy { keys, caret in
    webPhysical(keys, text: thrice, caret: caret, profile: writeKeys, breaks: foldedQuote).steps
        == webPhysical(keys, text: thrice, caret: caret, profile: writeKeys, breaks: foldedPlain).steps
}, "and so it does where the field folds a marker elsewhere")
let bareTodoGap = ParagraphBreaks(offsets: [10], hidden: [.init(at: 11, text: "", kind: .boxedGap)])
precondition(chords(webPhysical("j", text: tenTwice, caret: 0, profile: keyProfile, breaks: bareTodoGap))
             == [.paragraphEnd, .right, .right], "a to-do whose checkbox has no line of its own still takes → →")
precondition(["j", "$", "o", "dd", "J"].allSatisfy { keys in
    webPhysical(keys, text: tenTwice, caret: 0, profile: writeKeys, breaks: bareTodoGap).steps
        == webPhysical(keys, text: tenTwice, caret: 0, profile: writeKeys, breaks: ParagraphBreaks(offsets: [10])).steps
}, "stops alone leave a field unfolded for the write lane, and an edit's length known")
let codeGap = ParagraphBreaks(offsets: [10], hidden: [
    .init(at: 11, text: "CSS"), .init(at: 11, text: ""), .init(at: 11, text: ""), .init(at: 11, text: "", kind: .gap),
])
precondition(chords(webPhysical("j", text: tenTwice, caret: 0, profile: keyProfile, breaks: codeGap))
             == [.paragraphEnd, .selectRight, .right], "and a code block, behind its label and images")
precondition(chords(webPhysical("w", text: tenTwice, caret: 3, profile: keyProfile, breaks: gapBreaks))
             == [.paragraphEnd, .right, .right])
precondition(chords(webPhysical("2$", text: tenTwice, caret: 0, profile: keyProfile, breaks: gapBreaks))
             == [.paragraphEnd, .right, .right, .paragraphEnd])
precondition(chords(webPhysical("k", text: tenTwice, caret: 11, profile: keyProfile, breaks: gapBreaks))
             == [.paragraphStart, .left, .paragraphStart], "← from below never stops")
let noLineKeys = removing([.lineEndKey, .lineStartKey], from: keyProfile)
precondition(chords(webPhysical("j", text: tenTwice, caret: 0, profile: noLineKeys, breaks: gapBreaks))
             == [.down, .down, .lineStart], "lane B's ↓ stops there too")
precondition(chords(webPhysical("k", text: tenTwice, caret: 11, profile: noLineKeys, breaks: gapBreaks))
             == [.up, .up, .lineStart], "and its ↑ from below")

let joinedDoc: [(String, String?, Int, Bool, Bool)] = [
    ("Top paragraph", nil, 0, false, false), ("Numbered one", "1.", 0, false, false), ("Numbered two", "2.", 0, false, false),
    ("Bullet one", "\u{2022}", 0, false, true), ("Bullet two", "\u{2022}", 0, false, false),
    ("A to-do", nil, 2, true, true), ("Numbered again", "1.", 0, false, true), ("Middle paragraph", nil, 0, false, false),
    ("Bullet after", "\u{2022}", 0, false, false), ("Last paragraph.", nil, 0, false, false),
]
func joinedSim(_ profile: CapabilityProfile, caret: Int = 0) -> Sim {
    var host = Sim(text: joinedDoc.map(\.0).joined(separator: "\n"), caret: caret, profile: profile)
    host.emptyParagraphs = true
    host.listLines = joinedDoc.map { Sim.ListLine(marker: $0.1, leaves: $0.2, checkbox: $0.3, stop: $0.4) }
    host.emulatesKeys = true
    host.readModel = .textContent
    return host
}
var afterCode = Sim(text: "ab\ncd ef\ngh", caret: 4, profile: keyProfile)
afterCode.emptyParagraphs = true
afterCode.listLines = [Sim.ListLine(marker: "\u{2022}"), Sim.ListLine(marker: "\u{2022}"),
                       Sim.ListLine(leaves: 2, checkbox: true, stop: true)]
afterCode.codeSpans = [6..<8]
afterCode.emulatesKeys = true
afterCode.readModel = .textContent
afterCode.type("$j")
precondition(afterCode.caret == 11 && afterCode.settleFailures == 0, "the stop holds while a caret drawn at code ends the item above")
var stopped = joinedSim(keyProfile, caret: 27)
stopped.perform([.press(.paragraphEnd, count: 1), .press(.right, count: 1)])
precondition(stopped.caret == 39, "one → from a list's end stops between the lists")
for profile in [keyProfile, writeKeys] {
    let down = String(repeating: "j", count: joinedDoc.count)
    for keys in [down + String(repeating: "k", count: joinedDoc.count), "3j2k4j5j3k", "9jkkkkkkkk", "5ljjjjjjjjjkkkk",
                 "$jjjjjjjjjkkkk", "jjjwwwwwwwwwwbbbbbbbbbb", "jjjjjjeeeee", "jj2$", "jjdd", "jjjj0jj^jj$"] {
        var joined = joinedSim(profile)
        var plain = Sim(text: joined.text, caret: 0, profile: profile)
        plain.emulatesKeys = true
        for key in keys {
            joined.type(String(key))
            plain.type(String(key))
            precondition(joined.caret == plain.caret && joined.text == plain.text, "\(keys) at \(key)")
        }
        precondition(joined.settleFailures == 0 && joined.bells == 0, keys)
    }
}

// softlash/LIN-1726 scripts/block-boundary (Dia 1.51.0): every pair of paragraph, heading, list, code block and quote.
let blocksValue = "Boundary probe: plain opening paragraph alpha.\nMarkdown\n\n\ncode after paragraph bravo\n\nsecond code line charlie\nParagraph after code delta.\nQuote after paragraph echo\nParagraph after quote foxtrot.\n\n\nHeading golf\nCSS\n\n\ncode after heading hotel\n\n\nHeading after code india\nQuote after heading juliet\n\n\nHeading after quote kilo\n\u{2022}\nBullet before code lima\nCSS\n\n\ncode after bullet mike\nQuote after code november\nCSS\n\n\ncode after quote oscar\nCSS\n\n\ncode after code papa\n1.\nNumbered after code quebec\nQuote after numbered romeo\n\n\nTodo after quote sierra\nCSS\n\n\ncode after todo tango\n\n\nTodo after code uniform\nQuote after todo victor\nSecond quote paragraph whiskey\n\u{2022}\nBullet after quote xray\nPlain closing paragraph yankee."
let blocksRaw = "Boundary probe: plain opening paragraph alpha.Markdown\u{FFFC}\u{FFFC}code after paragraph bravo\nsecond code line charlieParagraph after code delta.Quote after paragraph echoParagraph after quote foxtrot.\u{FFFC}\u{FFFC}Heading golfCSS\u{FFFC}\u{FFFC}code after heading hotel\u{FFFC}\u{FFFC}Heading after code indiaQuote after heading juliet\u{FFFC}\u{FFFC}Heading after quote kilo\u{2022}Bullet before code limaCSS\u{FFFC}\u{FFFC}code after bullet mikeQuote after code novemberCSS\u{FFFC}\u{FFFC}code after quote oscarCSS\u{FFFC}\u{FFFC}code after code papa1.Numbered after code quebecQuote after numbered romeo\u{FFFC}\u{FFFC}Todo after quote sierraCSS\u{FFFC}\u{FFFC}code after todo tango\u{FFFC}\u{FFFC}Todo after code uniformQuote after todo victorSecond quote paragraph whiskey\u{2022}Bullet after quote xrayPlain closing paragraph yankee."
let blocksSpec = """
0/G/0/46 0.0/T/0/46 1/B/46/105 1.0/N/46/54 1.1/D/54/105 1.1.0/T/54/81 1.1.1/T/81/105 2/G/105/132 2.0/T/105/132
3/Q/132/158 3.0/G/132/158 3.0.0/T/132/158 4/G/158/188 4.0/T/158/188 5/H/188/200 5.0/G/188/188 5.1/T/188/200
6/B/200/227 6.0/N/200/203 6.1/D/203/227 6.1.0/T/203/207 6.1.1/T/207/227 7/H/227/251 7.0/G/227/227 7.1/T/227/251
8/Q/251/277 8.0/G/251/277 8.0.0/T/251/277 9/H/277/301 9.0/G/277/277 9.1/T/277/301 10/L/301/325 10.0/G/301/325
10.0.0/G/301/302 10.0.0.0/T/301/302 10.0.1/G/302/325 10.0.1.0/T/302/325 11/B/325/350 11.0/N/325/328 11.1/D/328/350
11.1.0/T/328/332 11.1.1/T/332/350 12/Q/350/375 12.0/G/350/375 12.0.0/T/350/375 13/B/375/400 13.0/N/375/378
13.1/D/378/400 13.1.0/T/378/382 13.1.1/T/382/389 13.1.2/T/389/394 13.1.3/T/394/400 14/B/400/423 14.0/N/400/403
14.1/D/403/423 14.1.0/T/403/407 14.1.1/T/407/414 14.1.2/T/414/418 14.1.3/T/418/423 15/L/423/451 15.0/G/423/451
15.0.0/G/423/425 15.0.0.0/T/423/424 15.0.0.1/T/424/425 15.0.1/G/425/451 15.0.1.0/T/425/451 16/Q/451/477 16.0/G/451/477
16.0.0/T/451/477 17/L/477/500 17.0/G/477/500 17.0.0/G/477/477 17.0.0.0/I/477/477 17.0.0.1/C/477/477 17.0.1/G/477/500
17.0.1.0/G/477/500 17.0.1.0.0/T/477/500 18/B/500/524 18.0/N/500/503 18.1/D/503/524 18.1.0/T/503/507 18.1.1/T/507/524
19/L/524/547 19.0/G/524/547 19.0.0/G/524/524 19.0.0.0/I/524/524 19.0.0.1/C/524/524 19.0.1/G/524/547 19.0.1.0/G/524/547
19.0.1.0.0/T/524/547 20/Q/547/600 20.0/G/547/570 20.0.0/T/547/570 20.1/G/570/600 20.1.0/T/570/600 21/L/600/624
21.0/G/600/624 21.0.0/G/600/601 21.0.0.0/T/600/601 21.0.1/G/601/624 21.0.1.0/T/601/624 22/G/624/655 22.0/T/624/655
"""
let blocksBreaks = ParagraphBreaks(value: blocksValue, fieldText: MarkerText.plain(blocksRaw))!
let blocksCandidates = UnreachableLines.candidates(text: blocksValue, breaks: blocksBreaks, raw: blocksRaw, proseMirror: true)
let blocksFound = unreachableScanned(fakeTree(blocksSpec), blocksCandidates)!
precondition(blocksFound.controls == [46..<54, 200..<203, 325..<328, 375..<378, 400..<403, 500..<503], "each code block's label")
precondition(blocksFound.joins == [325, 350, 375, 400, 423, 451, 477, 500, 524, 547, 600])
let blocksModel = folded(blocksValue, blocksRaw, fakeTree(blocksSpec))
let blocksLines = blocksModel.text.split(separator: "\n", omittingEmptySubsequences: false)
precondition(blocksLines.count == 26 && !blocksLines.contains("CSS") && !blocksLines.contains("Markdown"), "a label is no line")
precondition(blocksModel.breaks.gaps == Set(["code after bullet mike", "Quote after code november", "code after quote oscar",
    "code after code papa", "Numbered after code quebec", "Quote after numbered romeo", "Todo after quote sierra",
    "code after todo tango", "Todo after code uniform", "Quote after todo victor", "Bullet after quote xray",
].map { lineStart(of: $0, in: blocksModel.text) }), "a stop between any two of list, code block and quote, and nowhere else")
precondition(roundTrips(blocksModel))
precondition(Set(blocksModel.breaks.hidden.filter { $0.kind == .boxedGap }.map(\.at))
             == Set(["Todo after quote sierra", "Todo after code uniform"].map { lineStart(of: $0, in: blocksModel.text) }),
             "only a to-do's stop is boxed")
precondition(blocksModel.breaks.fieldOffset(lineStart(of: "code after bullet mike", in: blocksModel.text)) == 328)
func crossing(_ line: String, _ keys: String = "j", profile: CapabilityProfile = keyProfile) -> [Chord] {
    chords(webPhysical(keys, text: blocksModel.text, caret: lineStart(of: line, in: blocksModel.text), profile: profile,
                       breaks: blocksModel.breaks))
}
precondition(crossing("Bullet before code lima") == [.paragraphEnd, .selectRight, .right])
precondition(crossing("code after bullet mike") == [.paragraphEnd, .selectRight, .right])
precondition(crossing("Quote after numbered romeo") == [.paragraphEnd, .right, .right], "a to-do after a quote")
precondition(crossing("Boundary probe") == [.paragraphEnd, .right] && crossing("Heading golf") == [.paragraphEnd, .right]
             && crossing("Paragraph after code delta") == [.paragraphEnd, .right], "one → beside a paragraph or heading")
precondition(crossing("code after bullet mike", "k") == [.paragraphStart, .left, .paragraphStart])
precondition(crossing("code after bullet mike", "k", profile: noLineKeys).prefix(3) == [.up, .up, .lineStart]
             && crossing("code after heading hotel", "k", profile: noLineKeys).prefix(2) == [.up, .lineStart])
precondition((1...400).contains { budget in
    guard let found = unreachableScanned(fakeTree(blocksSpec), blocksCandidates, budget: budget) else { return false }
    return found.joins.isEmpty && found.controls.isEmpty && found.markers.count == 3
}, "running out of reads on the roots loses only the stops and labels")
let listsThenBlocks = fakeTree("0/L/0/2 0.0/G/0/2 1/L/2/4 1.0/G/2/4 2/B/4/8 2.0/N/4/6 2.1/D/6/8 3/Q/8/10 3.0/G/8/10")
let rootsOnly = UnreachableLines.Candidates(markers: [], chips: [], roots: true, stops: true)
precondition(unreachableScanned(listsThenBlocks, rootsOnly)
             == UnreachableLines.Found(markers: [], chips: [], joins: [2, 4, 8], controls: [4..<6]))
// The roots and the second list's start are 6 reads, the code block's two children and three more starts 8.
precondition((6...13).allSatisfy { budget in
    unreachableScanned(listsThenBlocks, rootsOnly, budget: budget) == UnreachableLines.Found(markers: [], chips: [], joins: [2])
} && unreachableScanned(listsThenBlocks, rootsOnly, budget: 14)?.joins == [2, 4, 8], "the lists' stops are read first, as on main")
let othersFound = unreachableScanned(fakeTree(blocksSpec, linear: false), blocksCandidates)!
precondition(othersFound.joins.isEmpty && othersFound.controls.isEmpty && othersFound.markers.count == 3,
             "without Linear's class another editor's quote or code gets no stop")
precondition(folded(blocksValue, blocksRaw, fakeTree(blocksSpec, linear: false)).text.contains("\nCSS\n"))
precondition(unreachableScanned(fakeTree(blocksSpec), UnreachableLines.candidates(text: blocksValue, breaks: blocksBreaks, raw: blocksRaw))
             == UnreachableLines.Found(markers: othersFound.markers, chips: []), "nor does an editor that is not ProseMirror's")
// Two quotes show nothing in the text: a ProseMirror editor's roots are read, and Linear's classes make the stop.
let twoQuotesSpec = "0/Q/0/3 0.0/G/0/3 0.0.0/T/0/3 1/Q/3/6 1.0/G/3/6 1.0.0/T/3/6"
let twoQuotes = fakeTree(twoQuotesSpec)
let quoteCandidates = UnreachableLines.candidates(text: "one\ntwo", breaks: ParagraphBreaks(offsets: [3]), raw: "onetwo", proseMirror: true)
precondition(!quoteCandidates.roots && quoteCandidates.stops && !quoteCandidates.isEmpty
             && UnreachableLines.candidates(text: "one\ntwo", breaks: ParagraphBreaks(offsets: [3]), raw: "onetwo").isEmpty
             && UnreachableLines.candidates(text: "one", breaks: ParagraphBreaks(), raw: "one", proseMirror: true).isEmpty,
             "another editor's text, or a single line, asks nothing")
precondition(unreachableScanned(twoQuotes, quoteCandidates)?.joins == [3]
             && unreachableScanned(fakeTree(twoQuotesSpec, linear: false), quoteCandidates)?.joins == [])
precondition(folded("one\ntwo", "onetwo", twoQuotes).breaks == ParagraphBreaks(offsets: [3], hidden: [.init(at: 4, text: "", kind: .gap)])
             && UnreachableLines.fold(text: "a\nb", breaks: ParagraphBreaks(offsets: [1]), raw: "ab",
                                      found: .init(markers: [], chips: [], joins: [1])).breaks.gaps == [2],
             "a stop that was read is kept though nothing folds")
// Review round 2's case: another ProseMirror editor's lists, no marker in the text and no Linear class, get no stop.
let bareLists = "0/G/0/1 0.0/T/0/1 1/L/1/2 1.0/G/1/2 1.0.0/T/1/2 2/L/2/3 2.0/G/2/3 2.0.0/T/2/3 3/G/3/4 3.0/T/3/4"
let otherLists = folded("p\na\nb\nc", "pabc", fakeTree(bareLists, linear: false))
let linearLists = folded("p\na\nb\nc", "pabc", fakeTree(bareLists))
precondition(otherLists.breaks.gaps.isEmpty && linearLists.breaks.gaps == [4])
precondition(chords(webPhysical("k", text: otherLists.text, caret: 4, profile: noLineKeys, breaks: otherLists.breaks)).prefix(2)
             == [.up, .lineStart]
             && chords(webPhysical("k", text: linearLists.text, caret: 4, profile: noLineKeys, breaks: linearLists.breaks)).prefix(3)
             == [.up, .up, .lineStart], "one ↑ where nothing shows a stop is drawn")
// Review round 3's case: Linear's blocks are told by their own classes wherever they stand, after any number of rules.
for rules in 0...4 {
    let spec = (0..<rules).map { "\($0)/R/0/0" } + [
        "\(rules)/L/0/5 \(rules).0/G/0/5 \(rules).0.0/G/0/1 \(rules).0.0.0/T/0/1 \(rules).0.1/G/1/5 \(rules).0.1.0/T/1/5",
        "\(rules + 1)/Q/5/11 \(rules + 1).0/G/5/11 \(rules + 1).0.0/T/5/11",
    ]
    let model = folded("\u{2022}\nitem\nquoted", "\u{2022}itemquoted", fakeTree(spec.joined(separator: " ")))
    precondition(model.breaks.gaps == [lineStart(of: "quoted", in: model.text)]
                 && chords(webPhysical("j", text: model.text, caret: 0, profile: keyProfile, breaks: model.breaks))
                 == [.paragraphEnd, .selectRight, .right], "\(rules) rules")
}
let threeRules = fakeTree("0/R/0/0 1/R/0/0 2/R/0/0 3/Q/0/3 3.0/G/0/3 3.0.0/T/0/3 4/Q/3/6 4.0/G/3/6 4.0.0/T/3/6")
precondition(unreachableScanned(threeRules, quoteCandidates)?.joins == [3])
let section = fakeTree("""
0/L/0/2 0.0/G/0/2 1/B/2/4 1.0/G/2/4 1.0.0/T/2/4 2/L/4/6 2.0/G/4/6 3/B/6/8 3.0/D/6/8 4/L/8/10 4.0/G/8/10 5/B/10/14 5.0/G/10/12
5.0.0/T/10/12 5.1/E/12/13 6/L/14/16 6.0/G/14/16 7/B/16/20 7.0/G/16/18 7.0.0/T/16/18 7.1/D/18/20
""")
precondition(unreachableScanned(section, rootsOnly) == UnreachableLines.Found(markers: [], chips: []),
             "a collapsible section, open or not, and code with no controls before it are not closed, and their text stays")
// softlash/LIN-1726 evidence/tree-empty-code.jsonl: `D` leaves the label, the two images, and an empty group where the code was.
let emptiedCode = fakeTree("""
0/L/0/24 0.0/G/0/24 0.0.0/G/0/1 0.0.0.0/T/0/1 0.0.1/G/1/24 0.0.1.0/T/1/24 1/B/24/34 1.0/N/24/33 1.1/E/33/34 2/Q/34/59 2.0/G/34/59
2.0.0/T/34/59
""")
let emptiedCodeModel = folded("\u{2022}\nBullet before code lima\nPlaintext\n\n\nQuote after code november",
                          "\u{2022}Bullet before code limaPlaintext\u{FFFC}\u{FFFC}\nQuote after code november", emptiedCode)
precondition(emptiedCodeModel.text == "Bullet before code lima\n\nQuote after code november" && emptiedCodeModel.breaks.gaps == [24, 25]
             && roundTrips(emptiedCodeModel), "an emptied code block keeps its label folded and its stops")

let blockDoc: [(String, Sim.ListLine)] = [
    ("Top paragraph", .init()), ("code one", .init(marker: "Markdown", leaves: 2, controls: true)),
    ("Middle paragraph", .init()), ("A quote", .init()), ("Bullet one", .init(marker: "\u{2022}", stop: true)),
    ("code two", .init(marker: "CSS", leaves: 2, stop: true, controls: true)), ("Quote two", .init(stop: true)),
    ("code three", .init(marker: "CSS", leaves: 2, stop: true, controls: true)),
    ("code four", .init(marker: "Plaintext", leaves: 2, stop: true, controls: true)),
    ("A to-do", .init(leaves: 2, checkbox: true, stop: true)), ("Quote three", .init(stop: true)),
    ("Numbered", .init(marker: "1.", stop: true)), ("Last paragraph.", .init()),
]
// A to-do below an empty paragraph, and one below a quote's empty last line, as softlash/LIN-1726 measured them.
let bareDoc: [(String, Sim.ListLine)] = [
    ("Top paragraph", .init()), ("", .init()), ("A to-do", .init(leaves: 2, checkbox: true)), ("A quote", .init(stop: true)),
    ("", .init()), ("Second to-do", .init(leaves: 2, checkbox: true, stop: true)), ("Last paragraph.", .init()),
]
func blockSim(_ profile: CapabilityProfile, _ doc: [(String, Sim.ListLine)] = blockDoc, caret: Int = 0) -> Sim {
    var host = Sim(text: doc.map(\.0).joined(separator: "\n"), caret: caret, profile: profile)
    host.emptyParagraphs = true
    host.listLines = doc.map(\.1)
    host.emulatesKeys = true
    host.readModel = .textContent
    return host
}
for profile in [keyProfile, writeKeys, removing([.lineStartKey], from: keyProfile), noLineKeys] {
    let down = String(repeating: "j", count: blockDoc.count)
    for keys in [down + String(repeating: "k", count: blockDoc.count), "3j2k4j5j3k", "9jkkkkkkkk", "5ljjjjjjjjjjjjkkkkkkkkkkkk",
                 "$jjjjjjjjjjjjkkkkkkkkkkkk", "jjjwwwwwwwwwwwwwwwwbbbbbbbbbbbbbbbb", "jjjjeeeeeeeeeeee", "jjjj2$", "jjjj0jj^jj$"] {
        var blocks = blockSim(profile)
        var plain = Sim(text: blocks.text, caret: 0, profile: profile)
        plain.emulatesKeys = true
        for key in keys {
            blocks.type(String(key))
            plain.type(String(key))
            precondition(blocks.caret == plain.caret && blocks.text == plain.text, "\(keys) at \(key)")
        }
        precondition(blocks.settleFailures == 0 && blocks.bells == 0, keys)
    }
    for keys in ["jjjjjjkkkkkk", "$jjjjjjkkkkkk", "wwwwwwwwwwbbbbbbbbbb", "jjeeeeee"] {
        var bare = blockSim(profile, bareDoc)
        var plain = Sim(text: bare.text, caret: 0, profile: profile)
        plain.emulatesKeys = true
        for key in keys {
            bare.type(String(key))
            plain.type(String(key))
            precondition(bare.caret == plain.caret && bare.text == plain.text, "bare \(keys) at \(key)")
        }
        precondition(bare.settleFailures == 0 && bare.bells == 0, "bare \(keys)")
    }
}
// Quotes alone, a paragraph shaped like a marker above them, and a to-do below an empty line: each stop is read (LIN-1726).
for (doc, caret, landing) in [
    ([("one", Sim.ListLine()), ("two", .init(stop: true))], 0, 4),
    ([("1.", .init()), ("one", .init()), ("two", .init(stop: true))], 3, 7),
    ([("", .init()), ("task", .init(leaves: 2, checkbox: true)), ("quoted", .init(stop: true))], 1, 6),
] {
    var host = blockSim(keyProfile, doc, caret: caret)
    host.type("j")
    precondition(host.caret == landing && host.settleFailures == 0 && host.bells == 0, "\(doc.map(\.0))")
}
// A paragraph made a quote, or a quote made a paragraph, keeps the text and the block count: the stops are read again.
var quoted = blockSim(keyProfile, [("item", .init(marker: "\u{2022}")), ("one", .init()), ("two", .init())], caret: 9)
quoted.type("k")
quoted.listLines?[1].stop = true
quoted.type("k")
quoted.type("j")
precondition(quoted.caret == 5 && quoted.settleFailures == 0 && quoted.bells == 0, "a stop made after the last read")
var unquoted = blockSim(keyProfile, [
    ("item", .init(marker: "\u{2022}")), ("one", .init(stop: true)), ("task", .init(leaves: 2, checkbox: true, stop: true)),
], caret: 0)
unquoted.type("j")
unquoted.listLines?[1].stop = false
unquoted.listLines?[2].stop = false
unquoted.type("j")
precondition(unquoted.caret == 9 && unquoted.settleFailures == 0 && unquoted.bells == 0, "a stop gone since the last read")

print("Vim engine tests passed")
