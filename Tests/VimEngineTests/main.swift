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
precondition(state.session.register("a") == RegisterContent(text: "hello", wise: .character))
precondition(state.session.register("A") == RegisterContent(text: "hello", wise: .character))

state.session.registers.numbered[1] = RegisterContent(text: "line\n", wise: .line)
precondition(state.session.register("1") == RegisterContent(text: "line\n", wise: .line))
precondition(state.session.register("2") == nil)

state.session.lastSearch = VimState.SearchMemory(pattern: "needle", direction: .forward)
precondition(state.session.register("/") == RegisterContent(text: "needle", wise: .character))

state.session.lastInsert = "typed"
precondition(state.session.register(".") == RegisterContent(text: "typed", wise: .character))
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
planning.session.registers.unnamed = RegisterContent(text: "howdy", wise: .character)
precondition(plan("p", state: planning).steps == [
    .put(.content(RegisterContent(text: "howdy", wise: .character)), PutAction(position: .after), count: 1),
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
])
let readProfile = CapabilityProfile(available: [.readText, .readLength, .readCaret, .readSelectedText])
let blindProfile = CapabilityProfile(available: [])

func physical(
    _ keys: String,
    text: String? = nil,
    caret: Int? = nil,
    profile: CapabilityProfile,
    state: VimState = .initial
) -> PhysicalPlan {
    let logical = LogicalPlanner.plan(RawCommand(keys), state: state)
    let snapshot = FieldSnapshot(capabilities: profile, text: text, selection: caret.map { $0..<$0 })
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
    .settle(Expectation(selection: 4..<9, length: 15)),
    .press(.deleteBack, count: 1),
    .settle(Expectation(selection: 4..<4, length: 10)),
    .commit(.deleted(into: nil, content: .literal("hello"), wise: .character)),
    .commit(.setMode(.insert)),
    .commit(.setInsertStart(4)),
])

let ciwC = physical("ciw", profile: blindProfile)
precondition(ciwC.steps == [
    .press(.wordLeft, count: 1),
    .press(.selectWordRight, count: 1),
    .clipboardCapture(into: CaptureSlot(id: 0), cutting: true),
    .commit(.deleted(into: nil, content: .captured(CaptureSlot(id: 0)), wise: .character)),
    .commit(.setMode(.insert)),
    .commit(.setInsertStart(nil)),
])
precondition(ciwC.mutatesText)

// fx moves and commits the find memory; `;` repeats without re-committing.
precondition(physical("fl", text: "say hello", caret: 0, profile: axProfile).steps == [
    .setSelection(6..<6),
    .settle(Expectation(selection: 6..<6, length: 9)),
    .commit(.found(VimState.FindMemory(character: "l", direction: .forward, beforeCharacter: false))),
    .setSelection(6..<7),
    .commit(.setCursor(6..<7)),
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
putState.session.registers.unnamed = RegisterContent(text: "XY", wise: .character)
precondition(physical("p", text: "abc", caret: 1, profile: axProfile, state: putState).steps == [
    .setSelection(2..<2),
    .replaceSelection("XY"),
    .settle(Expectation(selection: 4..<4, length: 5)),
    .setSelection(4..<5),
    .commit(.setCursor(4..<5)),
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

// A drawn cursor is collapsed before the next command acts.
let cursored = FieldSnapshot(capabilities: axProfile, text: "abc", selection: 0..<1, cursor: 0..<1)
precondition(PhysicalPlanner.plan(
    LogicalPlanner.plan(RawCommand("x"), state: .initial),
    snapshot: cursored
).steps.first == .setSelection(0..<0))

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

// Insert: passthrough with a typed log, handed over exactly once at Esc.
precondition(monitor.feed("h", mode: .insert) == .passthrough)
precondition(monitor.feed("i", mode: .insert) == .passthrough)
precondition(monitor.feed("<Left>", mode: .insert) == .passthrough)
precondition(monitor.feed("<Esc>", mode: .insert) ==
    .command(RawMonitor.Completed(command: RawCommand("<Esc>"), insertPayload: "hi")))
precondition(monitor.feed("<Esc>", mode: .insert) ==
    .command(RawMonitor.Completed(command: RawCommand("<Esc>"))))

// MARK: - VimReducer

var reduced = VimState.initial
reduced = VimReducer.reduce(reduced, .yanked(into: nil, content: .literal("one\n"), wise: .line))
precondition(reduced.session.register("\"") == RegisterContent(text: "one\n", wise: .line))
precondition(reduced.session.register("0") == RegisterContent(text: "one\n", wise: .line))

// Linewise deletes shift the ring; the yank slot is untouched.
reduced = VimReducer.reduce(reduced, .deleted(into: nil, content: .literal("a\n"), wise: .line))
reduced = VimReducer.reduce(reduced, .deleted(into: nil, content: .literal("b\n"), wise: .line))
precondition(reduced.session.register("1") == RegisterContent(text: "b\n", wise: .line))
precondition(reduced.session.register("2") == RegisterContent(text: "a\n", wise: .line))
precondition(reduced.session.register("0") == RegisterContent(text: "one\n", wise: .line))

// Sub-line deletes go to the small-delete register, not the ring.
reduced = VimReducer.reduce(reduced, .deleted(into: nil, content: .literal("ch"), wise: .character))
precondition(reduced.session.register("-") == RegisterContent(text: "ch", wise: .character))
precondition(reduced.session.register("1") == RegisterContent(text: "b\n", wise: .line))

// Named writes mirror to unnamed; uppercase appends; the black hole swallows.
reduced = VimReducer.reduce(reduced, .yanked(into: Register("a"), content: .literal("hi"), wise: .character))
reduced = VimReducer.reduce(reduced, .yanked(into: Register("A"), content: .literal("!"), wise: .character))
precondition(reduced.session.register("a") == RegisterContent(text: "hi!", wise: .character))
precondition(reduced.session.register("\"") == RegisterContent(text: "hi!", wise: .character))
reduced = VimReducer.reduce(reduced, .deleted(into: Register("_"), content: .literal("gone"), wise: .character))
precondition(reduced.session.register("\"") == RegisterContent(text: "hi!", wise: .character))

// An unfilled capture skips the write rather than inventing content.
reduced = VimReducer.reduce(reduced, .deleted(into: nil, content: .captured(CaptureSlot(id: 9)), wise: .character))
precondition(reduced.session.register("\"") == RegisterContent(text: "hi!", wise: .character))

// Cursor state: set by renderCursor's commit, cleared on leaving Normal.
reduced = VimReducer.reduce(reduced, .setCursor(3..<4))
precondition(reduced.field.cursor == 3..<4)
reduced = VimReducer.reduce(reduced, .setMode(.insert))
precondition(reduced.field.cursor == nil)

// MARK: - Sim goldens: (text, caret, keys) → (text′, caret′, state′)

var sim = Sim(text: "say hello world", caret: 6, profile: axProfile)
sim.type("x")
precondition(sim.text == "say helo world")
precondition(sim.caret == 6)
precondition(sim.selection == 6..<7)                       // the block cursor, on 'o'
precondition(sim.state.field.cursor == 6..<7)
precondition(sim.state.session.register("-") == RegisterContent(text: "l", wise: .character))

sim = Sim(text: "abcdef", caret: 0, profile: axProfile)
sim.type("3x")
precondition(sim.text == "def")
precondition(sim.state.session.register("\"") == RegisterContent(text: "abc", wise: .character))

sim = Sim(text: "say hello", caret: 0, profile: axProfile)
sim.type("dw")
precondition(sim.text == "hello")
precondition(sim.state.session.register("-") == RegisterContent(text: "say ", wise: .character))

sim = Sim(text: "a\nb\nc", caret: 0, profile: axProfile)
sim.type("dddd")
precondition(sim.text == "c")
precondition(sim.state.session.register("1") == RegisterContent(text: "b\n", wise: .line))
precondition(sim.state.session.register("2") == RegisterContent(text: "a\n", wise: .line))

sim = Sim(text: "one\ntwo", caret: 0, profile: axProfile)
sim.type("yyp")
precondition(sim.text == "one\none\ntwo")
precondition(sim.state.session.register("0") == RegisterContent(text: "one\n", wise: .line))

// The flagship: change-inner-word, type, escape — full loop.
sim = Sim(text: "say hello world", caret: 6, profile: axProfile)
sim.type("ciwbye")
sim.feed("<Esc>")
precondition(sim.text == "say bye world")
precondition(sim.caret == 6)
precondition(sim.state.field.cursor == 6..<7)              // redrawn on insert exit
precondition(sim.state.field.mode == .normal)
precondition(sim.state.session.lastInsert == "bye")
precondition(sim.state.session.register(".") == RegisterContent(text: "bye", wise: .character))
precondition(sim.state.session.lastChange == VimState.ChangeMemory(body: "ciwbye<Esc>"))
precondition(sim.settleFailures == 0 && sim.bells == 0 && sim.unsupportedSteps == 0)

// Insert entry via A opens a dot body even though entry itself mutated nothing.
sim = Sim(text: "hi", caret: 0, profile: axProfile)
sim.type("A!")
sim.feed("<Esc>")
precondition(sim.text == "hi!")
precondition(sim.caret == 2)
precondition(sim.state.session.lastChange == VimState.ChangeMemory(body: "A!<Esc>"))

// Dot replays the last change and must not overwrite it.
sim = Sim(text: "aabb", caret: 0, profile: axProfile)
sim.type("x.")
precondition(sim.text == "bb")
precondition(sim.state.session.lastChange == VimState.ChangeMemory(body: "x"))

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

print("Vim engine tests passed")
