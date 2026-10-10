/// A simulated host: an in-memory text field plus the full engine loop.
///
/// The Sim plays the runtime's role against a fake field — it feeds tokens
/// through the monitor, plans against its own text/selection, interprets
/// the physical steps by string surgery, verifies settles against itself,
/// and hands commits to the reducer. That closes the loop entirely in pure
/// code: end-to-end goldens of the form
/// `(text, caret, keystrokes) → (text′, caret′, state′)` run under
/// `make test`, and later the flight recorder can replay through the same
/// machine.
///
/// It executes lane-A/B AX and clipboard steps exactly — including the
/// modeled pasteboard, written by `clipboardCut`/`clipboardCopy` and read
/// by `clipboardInsert(nil)`, which makes the clipboard=unnamed contract
/// pure-testable. Of Cocoa's keys it emulates, through `KeyModel`, the
/// ones lane B counts with, and every one the model knows under
/// `emulatesKeys`; any other `press` (the blind lane's chords, undo) counts
/// as `unsupportedSteps`, because the Sim can only prove we emit the plans
/// we designed, never that a blind plan works in a real app.
///
/// Its faults are the only way a golden reaches the abort path at all.
public struct Sim {
    public private(set) var text: String
    public private(set) var selection: Range<Int>
    public private(set) var state: VimState
    /// The modeled system pasteboard — the blind lanes' register.
    public private(set) var pasteboard: String?
    public var profile: CapabilityProfile

    /// Accepts `AXSelectedText` and does nothing — the Chromium contenteditable.
    public var swallowsReplace = false

    /// The same lie about `AXSelectedTextRange` — what a `writeSelection` demotion leaves.
    public var swallowsSelect = false

    /// Settle and repair reads get no `AXSelectedTextRange`; the snapshot's read still answers.
    public var unreadableSelection = false

    /// Makes the field a Chromium contenteditable: `AXSelectedTextRange` starts at `reads` of the selection's
    /// start and is as long as `AXSelectedText`, the true selected text less its paragraph breaks (LIN-1533).
    public var reads: ((_ offset: Int, _ text: String) -> Int)?

    /// Chromium rich text whose every `\n` ends a paragraph, as Chrome 153 shows it: see `ChromiumParagraphs` (LIN-1612).
    public var emptyParagraphs = false

    /// Off, discovery fails and the snapshot keeps `AXValue`'s lines.
    public var findsEmptyParagraphs = true

    /// In Chromium modes, the field ends in an inline icon: a U+FFFC only the marker text has.
    public var endsInTextlessLeaf = false

    /// With `emptyParagraphs`, Linear's editor: blocks each line draws before its text, and each U+2060 a chip.
    public var listLines: [ListLine]?

    /// Off, discovery of list markers and chips fails, and they stay lines.
    public var findsUnreachable = true

    /// A caret written at a chip's start, where Linear's next arrow does nothing.
    private var atChipStart = false

    /// With `listLines`, Linear's inline code spans: a caret at an edge is inside or outside one, and drawn (LIN-1683).
    public var codeSpans: [Range<Int>] = []

    /// A caret at a code span's edge is inside it; a plain arrow from the edge's near side only crosses the edge.
    private var codeInside = false

    /// A caret written at a code span's end, where Linear's next ← or ⇧← can do nothing.
    private var atWrittenCodeEnd = false

    /// The caret stopped between two lists, before the line after it.
    private var inListGap = false

    /// Linear draws the caret 20–160 ms after it arrives, so a quick command's snapshot can come first.
    public var drawsLate = false
    private var snapshotting = false

    /// Text the page generates while the field is empty, as ChatGPT's box shows "Ask anything" (LIN-1930).
    public var placeholder: String?

    /// Where in the placeholder the caret reads: its start in some editors, its end or near it in others.
    public var placeholderCaret = 0

    var showsPlaceholder: Bool { placeholder != nil && text.isEmpty }

    public var readSelection: Range<Int> {
        if showsPlaceholder { return placeholderCaret..<placeholderCaret }
        if emptyParagraphs { return chromium.field(selection) }
        guard let reads else { return selection }
        let start = reads(selection.lowerBound, text)
        return start..<start + readSelectedText.utf16.count
    }

    public var readSelectedText: String {
        if showsPlaceholder { return "" }
        if emptyParagraphs {
            let markers = Array(chromium.plainMarkers.utf16)
            let range = readSelection
            return String(decoding: markers[range.clamped(to: 0..<markers.count)], as: UTF16.self)
        }
        let selected = TextModel(text).substring(selection)
        return reads == nil ? selected : selected.filter { $0 != "\n" }
    }

    /// The field answers text-marker reads: the real selection, every `\n` a generated break.
    public var markers = false

    /// Selection writes land in `reads`' coordinates, as Chromium's do.
    public var writesInReadOffsets = false

    public var hasChildren = true

    /// Used only when no learner runs.
    public var readModel: OffsetsAnswer = .value

    /// Learns from each command and re-resolves `profile` from its beliefs.
    public private(set) var learner: Learner?

    /// Where the last command's run ended early, if it did.
    public private(set) var abortedStep: PhysicalStep?

    /// Every key `KeyModel` knows runs, not only the ones lane B counts with.
    public var emulatesKeys = false

    /// The field is web content; a Chromium read fault (`reads`) implies it.
    public var webContent = false

    /// Graphemes per visual row for ↓ ↑ ⌘← ⌘→; nil puts each line on one row.
    public var wrapWidth: Int?

    /// Keys this field ignores, as an app that rebinds them would.
    public var ignoredChords: Set<Chord> = []

    /// Keys this field treats as others, as an app that rebinds ⌃A to select-all would.
    public var reboundChords: [Chord: Chord] = [:]

    /// Keys the failed settles blamed, in order.
    public private(set) var blamed: [Capability] = []

    public private(set) var bells = 0
    public private(set) var settleFailures = 0
    /// Soft settles that missed, which ring nothing and abort nothing, as the executor logs them.
    public private(set) var softMisses = 0
    public private(set) var unsupportedSteps = 0

    /// The last command's evidence from its settles.
    public private(set) var attribution = RunAttribution()

    private var monitor = RawMonitor()
    private var captures: [CaptureSlot: String] = [:]

    /// The field's button events so far, which the Controller reads from the window server.
    private var buttonEvents: UInt32 = 0

    /// The focus is the selection's lower bound.
    private var backward = false

    /// The command that opened the current Insert session, recorded at its Esc.
    private var openChange: (source: String, count: Int?, register: Register?, mutated: Bool)?

    /// The last snapshot's, to convert the drawn cursor at unbind.
    private var fieldBreaks: ParagraphBreaks?

    /// The last discoveries, kept as the Controller keeps them.
    private var foundEmptyParagraphs: EmptyParagraphs.Memo?
    private var foundUnreachable: UnreachableLines.Memo?

    public init(
        text: String,
        caret: Int = 0,
        state: VimState = .initial,
        profile: CapabilityProfile
    ) {
        self.text = text
        let clamped = TextModel(text).clamp(caret)
        self.selection = clamped..<clamped
        self.state = state
        self.profile = profile
    }

    public var caret: Int { selection.lowerBound }

    public mutating func learn(with learner: Learner) {
        self.learner = learner
        resolveBeliefs()
    }

    public mutating func update(to versions: Versions) {
        learner?.versions = versions
        learner?.sampling = OffsetsSampling()
        resolveBeliefs()
    }

    /// Feed each character of `keys` as one token.
    public mutating func type(_ keys: String) {
        for character in keys {
            feed(String(character))
        }
    }

    public mutating func feed(_ token: String) {
        let mode: RawMonitor.Mode
        switch state.field.mode {
        case .normal: mode = .normal
        case .visual: mode = .visual
        case .insert, .replace: mode = .insert
        }
        switch monitor.feed(token, mode: mode, clicks: mode == .insert ? nil : buttonEvents) {
        case .pending, .cancelled:
            break
        case .passthrough:
            applyTyping(token)
        case .command(let completed):
            run(completed)
        }
    }

    /// Step-level entry for goldens that exercise the interpreter directly —
    /// blind-lane plans never survive the keystroke loop (`.press` counts as
    /// unsupported), but their clipboard steps still deserve pure coverage.
    @discardableResult
    public mutating func perform(_ steps: [PhysicalStep]) -> Bool {
        captures = [:]
        return execute(steps) == nil
    }

    /// `Controller.rebind`'s pure twin: focus moved, and the transition says
    /// how much of the session survives. Lives here rather than in an
    /// extension because `monitor` and `openChange` are private — and they
    /// are exactly what the paired-halves invariant is about.
    ///
    /// Pass `text` to model a `sameDocument` swap literally: the next block
    /// is different text whose offsets restart at zero, which is precisely
    /// what makes the departing field's offsets fiction.
    public mutating func refocus(_ transition: FocusTransition, text: String? = nil, caret: Int = 0) {
        if !transition.preservesDrawnCursor {
            if let cursor = state.field.cursor,
               let release = PhysicalPlanner.releaseCursor(cursor, breaks: fieldBreaks, profile: profile) {
                executeAside(release)
            }
            fieldBreaks = nil
        }
        if transition != .sameElement {
            foundEmptyParagraphs = nil
            foundUnreachable = nil
        }
        if let text {
            self.text = text
            let clamped = TextModel(text).clamp(caret)
            selection = clamped..<clamped
            inListGap = false
        }
        state.field = state.field.carried(across: transition)
        if transition.clearsChangeInFlight {
            monitor.reset()
            openChange = nil
        }
    }

    /// A click in the bound field: the caret goes to `offset`, two button events are counted, and `Controller.pointerActed` runs.
    public mutating func click(at offset: Int) {
        let caret = TextModel(text).clamp(offset)
        selection = caret..<caret
        atChipStart = false
        codeInside = false
        atWrittenCodeEnd = false
        inListGap = false
        backward = false
        buttonEvents &+= 2
        if state.field.mode.isInserting { monitor.markInsertLogLossy() }
    }
}

// MARK: - The runtime loop

private extension Sim {
    mutating func run(_ completed: RawMonitor.Completed) {
        let command = completed.command
        let logical = LogicalPlanner.plan(command, state: state)
        var anchor: Int?
        if case .visual(let context) = state.field.mode {
            anchor = context.anchor
        }
        var memo = foundEmptyParagraphs
        var unreachable = foundUnreachable
        func snapshot() -> (built: (snapshot: FieldSnapshot, memo: EmptyParagraphs.Memo?, unreachable: UnreachableLines.Memo?),
                            observed: Learning.Observation, value: String?) {
            var (reads, observed) = read()
            let built = FieldSnapshot.Step.run(taking: { take($0, into: &reads, memo: &memo, unreachable: &unreachable) }) {
                FieldSnapshot.build(
                    reads, capabilities: profile, answer: observed.after, anchor: anchor, cursor: state.field.cursor, memo: memo,
                    unreachable: unreachable
                )
            }
            return (built, observed, shownValue)
        }
        snapshotting = true
        var (built, observed, value) = snapshot()
        snapshotting = false
        // The Snapshotter waits for the caret drawn at a code span's end that ends a paragraph, whose `<br>` moves offsets.
        let caret = selection.lowerBound
        if drawsLate, built.snapshot.breaks != nil, !built.snapshot.holdsDrawnCaret, selection.isEmpty,
           isCodeEdge(caret, start: false), TextModel(text).lineEnd(of: caret) == caret {
            (built, observed, value) = snapshot()
        }
        foundEmptyParagraphs = built.memo
        foundUnreachable = built.unreachable
        let snapshot = built.snapshot
        fieldBreaks = snapshot.breaks
        let missed = learner.map { $0.strikes.missed(judgedUnder: observed.after, app: $0.versions.app) } ?? []
        let planned = PhysicalPlanner.planning(logical, snapshot: snapshot, missed: missed)
        let physical = planned.plan
        let before = state.field.mode

        captures = [:]
        let abortedAt = execute(physical.steps, generated: showsPlaceholder)
        abortedStep = abortedAt.map { physical.steps[$0] }
        // After the hygiene below, as the Controller's is.
        defer { learn(from: observed) }
        guard abortedAt == nil else {
            // Abort hygiene, mirroring the Controller down to the stand-down.
            if planned.abortedAtTextCheck(abortedAt) {
                if !unreadableSelection, !readSelection.isEmpty {
                    executeAside(PhysicalPlanner.collapse(readSelection, misread: true, profile: profile))
                }
                if state.field.mode.isInserting {
                    state = VimReducer.reduce(state, .setMode(before.nonVisual))
                }
            } else if !repairStrandedSelection(operand: planned.operand, snapshot: snapshot, value: value),
                      state.field.mode.isInserting {
                state = VimReducer.reduce(state, .setMode(before.nonVisual))
            }
            // The monitor drained the payload it will never offer again.
            if let payload = completed.insertPayload, !state.field.mode.isInserting {
                closeInsertSession(payload, lossless: completed.insertPayloadIsLossless)
            }
            recordChange(for: command, from: before, mutated: physical.mutatesText, aborted: true)
            return
        }

        if let payload = completed.insertPayload {
            closeInsertSession(payload, lossless: completed.insertPayloadIsLossless)
        }

        recordChange(for: command, from: before, mutated: physical.mutatesText)
    }

    /// The Controller's twin, and it must obey the host the same way; `value` is the `AXValue` the snapshot read.
    mutating func repairStrandedSelection(operand: Range<Int>?, snapshot: FieldSnapshot, value: String?) -> Bool {
        guard !unreadableSelection else { return false }   // unknown is not empty
        guard !readSelection.isEmpty else { return true }
        if state.field.mode.isInserting, readSelection == operand { return true }
        let paragraphs = snapshot.breaks != nil
        let read = readSelection
        // As the Controller: the markers answer for the side, and the field is read again once `AXValue` has changed.
        let marked = paragraphs && (markers || emptyParagraphs)
        let collapse = PhysicalPlanner.collapse(
            read, side: marked ? chromium.side(selection.lowerBound) : nil, paragraphs: paragraphs,
            snapshot: marked ? (shownValue == value ? snapshot : snapshotAside()) : nil, profile: profile
        )
        if !executeAside(collapse), profile.has(.writeSelection) {
            executeAside(PhysicalPlanner.collapse(read, paragraphs: paragraphs, profile: profile))
        }
        return readSelection.isEmpty
    }

    /// Fold a just-ended Insert session into the dot memories.
    mutating func closeInsertSession(_ payload: String, lossless: Bool) {
        if !payload.isEmpty {
            state = VimReducer.reduce(state, .setLastInsert(payload))
        }
        guard let change = openChange else { return }
        openChange = nil
        guard lossless else {
            state = VimReducer.reduce(state, .setLastChange(.unreplayable))
            return
        }
        // An empty session is still a change if its entry mutated (`ciw`, `o`).
        guard change.mutated || !payload.isEmpty else { return }
        state = VimReducer.reduce(state, .setLastChange(VimState.ChangeMemory(
            body: change.source,
            count: change.count,
            register: change.register,
            insert: payload
        )))
    }

    /// Records a mutating command as `lastChange`, or opens a body if it entered Insert.
    mutating func recordChange(
        for command: RawCommand, from before: VimState.Mode, mutated: Bool, aborted: Bool = false
    ) {
        if case .repeat = command.intent { return }   // `.` must not overwrite what it replays
        // An aborted plan mutated nothing, whatever its steps intended.
        let changed = mutated && !aborted
        if case .visual = before {
            // Visual keys name a selection `.` cannot rebuild.
            if changed || state.field.mode.isInserting {
                state = VimReducer.reduce(state, .setLastChange(.unreplayable))
            }
            return
        }
        if state.field.mode.isInserting {
            if openChange == nil {
                openChange = (command.source, command.count, command.register, changed)
            }
            return
        }
        guard changed else { return }
        state = VimReducer.reduce(state, .setLastChange(VimState.ChangeMemory(
            body: command.source,
            count: command.count,
            register: command.register
        )))
    }

    /// Insert-mode passthrough typing lands in the fake field the way the
    /// real app would apply it.
    mutating func applyTyping(_ token: String) {
        if token == "<BS>" {
            if selection.isEmpty {
                selection = TextModel(text).advance(selection.lowerBound, byGraphemes: -1)..<selection.upperBound
            }
            applyReplace("")
            return
        }
        if token == "<CR>" {
            applyReplace("\n")
            return
        }
        guard token.count == 1, let scalar = token.unicodeScalars.first else { return }
        if scalar.value < 0x20, token != "\n", token != "\r", token != "\t" { return }
        applyReplace(token == "\r" ? "\n" : token)
    }
}

// MARK: - Physical step interpreter

private extension Sim {
    /// The index of the step that ended the run, nil when every step ran; `generated` as the executor's.
    mutating func execute(_ steps: [PhysicalStep], generated: Bool = false) -> Int? {
        var kept: [Int: Int] = [:]
        var generated = generated
        attribution = RunAttribution()
        for (index, step) in steps.enumerated() {
            if case .settle = step {} else { attribution.record(step) }
            switch step {
            case .setSelection(let range):
                guard !swallowsSelect else { break }
                let model = TextModel(text)
                var lower = model.clamp(landing(range.lowerBound))
                var upper = model.clamp(landing(range.upperBound))
                // Written at a chip's start, a selection's end moves past the chip, and a caret stops the next arrow.
                let atoms = chromium.atoms
                if !range.isEmpty, atoms.contains(lower) { lower += 1 }
                if !range.isEmpty, atoms.contains(upper) { upper += 1 }
                selection = min(lower, upper)..<max(lower, upper)
                atChipStart = selection.isEmpty && atoms.contains(lower)
                // Measured, a caret written at a code span's start lands outside it, one at its end inside.
                codeInside = selection.isEmpty && isCodeEdge(lower, start: false) && !isCodeEdge(lower, start: true)
                atWrittenCodeEnd = codeInside
                inListGap = false
                backward = false

            case .replaceSelection(let replacement):
                if !swallowsReplace { applyReplace(replacement) }

            case .typeText(let typed):
                applyReplace(typed)

            case .press(let chord, let count):
                for _ in 0..<count where !ignoredChords.contains(chord) {
                    guard emulatesKeys || Self.countedKeys.contains(chord), press(reboundChords[chord] ?? chord) else {
                        unsupportedSteps += 1
                        break
                    }
                }

            case .clipboardCut:
                pasteboard = TextModel(text).substring(selection)
                applyReplace("")

            case .clipboardCopy:
                pasteboard = TextModel(text).substring(selection)

            case .clipboardInsert(let content):
                applyReplace(content ?? pasteboard ?? "")

            case .captureSelectedText(let slot):
                captures[slot] = readSelectedText

            case .settle(let planned):
                let expectation = planned.resolving(kept)
                let (passed, observed, length) = settles(expectation, generated: generated)
                generated = !passed || expectation.metByEmptyField
                attribution.record(.settle(expectation), passed: passed, selection: observed, length: length,
                                   selectedText: readSelectedText)
                if !passed {
                    settleFailures += 1
                    if let key = expectation.blamed(observed: observed) { blamed.append(key) }
                    drainResidency(of: steps, after: index)
                    return index   // the rest dies, like the real executor
                }
                if let slot = expectation.keeps, let caret = observed?.lowerBound { kept[slot] = caret }

            case .softSettle(let expectation):
                // Best-effort barrier: never aborts. In this synchronous host
                // there is nothing async to wait for, and the blind step it
                // follows may be an unsupported no-op, so the field need not match
                // the prediction — which is exactly why a soft settle must proceed.
                let passed = settles(expectation, generated: generated).passed
                if !passed { softMisses += 1 }
                generated = !passed || expectation.metByEmptyField

            case .commit(let effect):
                state = VimReducer.reduce(state, effect, captures: captures)

            case .bell:
                bells += 1
            }
        }
        return nil
    }

    /// In `reads`' coordinates a boundary offset lands at the next paragraph's start.
    func landing(_ offset: Int) -> Int {
        if emptyParagraphs { return chromium.landing(offset, from: selection.lowerBound) }
        guard writesInReadOffsets, let reads else { return offset }
        return (0...text.utf16.count).last { reads($0, text) <= offset } ?? 0
    }

    /// A settle's verdict and what it read, judged as the executor judges it beside generated text (LIN-1930).
    func settles(_ expectation: Expectation, generated: Bool) -> (passed: Bool, selection: Range<Int>?, length: Int) {
        // A non-answer satisfies nothing, exactly as `Expectation.matches` has it.
        let observed = unreadableSelection ? nil : readSelection
        let met = expectation.converged(
            selection: observed, length: fieldLength - drawnLength, selectedText: readSelectedText, side: upperSide
        )
        let answered = observed != nil || expectation.landing == nil
        let passed = GeneratedText.judged(met, expectation, answered: answered, generated: generated) { showsPlaceholder }
        return (passed, observed, fieldLength)
    }

    /// The keys lane B counts with, which run whether or not `emulatesKeys` is on.
    static let countedKeys: Set<Chord> = [.left, .right, .up, .down, .lineStart, .selectRight, .selectLeft, .deleteBack]

    /// One key as `KeyModel` has Cocoa's bindings do it, which is how LIN-1533 measured Chromium's arrows; false for
    /// a key the model does not know.
    mutating func press(_ chord: Chord) -> Bool {
        if atChipStart, [Key.arrowLeft, .arrowRight].contains(chord.key), !chord.modifiers.contains(.option) {
            atChipStart = false
            return true
        }
        atChipStart = false
        // Measured at some ends and not others, so always here: the first ← or ⇧← after a write at a code span's end.
        defer { atWrittenCodeEnd = false }
        if atWrittenCodeEnd, [.left, .selectLeft].contains(chord) { return true }
        // Measured: from inside a code span's start, ⇧⌃E does nothing, and ⇧→ too unless the span starts its line.
        if [.selectRight, Chord.paragraphEnd.shifted].contains(chord), selection.isEmpty, codeInside,
           isCodeEdge(selection.lowerBound, start: true),
           chord != .selectRight || TextModel(text).lineStart(of: selection.lowerBound) != selection.lowerBound {
            return true
        }
        if !inListGap, chord.modifiers.isEmpty, selection.isEmpty, [Key.arrowLeft, .arrowRight].contains(chord.key) {
            let at = selection.lowerBound
            let (start, end) = (isCodeEdge(at, start: true), isCodeEdge(at, start: false))
            // From the side of an edge the arrow points across, it steps inside or out and stays put, but ← leaves a paragraph.
            let crosses = chord.key == .arrowRight
                ? start && !codeInside || end && codeInside
                : start && codeInside && TextModel(text).lineStart(of: at) != at || end && !codeInside
            if crosses {
                codeInside.toggle()
                return true
            }
        }
        let shown = chromium
        var keys = KeyModel(
            text: text,
            anchor: backward ? selection.upperBound : selection.lowerBound,
            focus: backward ? selection.lowerBound : selection.upperBound,
            wrap: wrapWidth,
            atoms: shown.atoms,
            gaps: shown.gaps,
            inGap: inListGap
        )
        guard keys.press(chord) else { return false }
        inListGap = keys.inGap
        if keys.text != text {
            let deleted = keys.selection.lowerBound..<(keys.selection.lowerBound + text.utf16.count - keys.text.utf16.count)
            listLines = listLines.map { ListLine.carried($0, in: text, replacing: deleted, with: "") }
            codeSpans = Self.carried(codeSpans, replacing: deleted, with: "", into: keys.text)
        }
        text = keys.text
        selection = keys.selection
        backward = keys.focus < keys.anchor
        // Measured: → and ⌥→ arrive outside a start and inside an end, ← the reverse but at a line start, the rest outside.
        let arrived = selection.isEmpty ? selection.lowerBound : -1
        switch (chord.key, chord.modifiers) {
        case (.arrowRight, []), (.arrowRight, [.option]): codeInside = isCodeEdge(arrived, start: false)
        case (.arrowLeft, []):
            codeInside = isCodeEdge(arrived, start: true) && TextModel(text).lineStart(of: arrived) != arrived
        default: codeInside = false
        }
        if inListGap { codeInside = false }
        return true
    }

    func isCodeEdge(_ offset: Int, start: Bool) -> Bool {
        listLines != nil && codeSpans.contains { (start ? $0.lowerBound : $0.upperBound) == offset }
    }

    /// `spans` after an edit into `text`, as ProseMirror's marks: inside one it stays in, at an edge out; they join, `\n` splits.
    static func carried(_ spans: [Range<Int>], replacing range: Range<Int>, with replacement: String, into text: String)
        -> [Range<Int>] {
        let count = replacement.utf16.count
        let delta = count - range.count
        let kept = spans.compactMap { span -> Range<Int>? in
            let kept: Range<Int>
            if range.upperBound <= span.lowerBound {
                kept = (span.lowerBound + delta)..<(span.upperBound + delta)
            } else if range.lowerBound >= span.upperBound {
                kept = span
            } else if span.lowerBound <= range.lowerBound, range.upperBound <= span.upperBound {
                kept = span.lowerBound..<(span.upperBound + delta)
            } else if range.lowerBound <= span.lowerBound, span.upperBound <= range.upperBound {
                return nil
            } else if range.lowerBound < span.lowerBound {
                kept = (range.lowerBound + count)..<(span.upperBound + delta)
            } else {
                kept = span.lowerBound..<range.lowerBound
            }
            return kept.isEmpty ? nil : kept
        }.sorted { $0.lowerBound < $1.lowerBound }
        let joined: [Range<Int>] = kept.reduce(into: []) { joined, span in
            if let last = joined.last, last.upperBound >= span.lowerBound {
                joined[joined.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else {
                joined.append(span)
            }
        }
        let units = Array(text.utf16)
        return joined.flatMap { span in
            var pieces: [Range<Int>] = []
            var start = span.lowerBound
            for index in span where index < units.count && units[index] == 10 {
                if index > start { pieces.append(start..<index) }
                start = index + 1
            }
            if span.upperBound > start { pieces.append(start..<span.upperBound) }
            return pieces
        }
    }

    /// The field as it reads now, for a repair: unlike a run's snapshot it teaches nothing and keeps no discovery.
    mutating func snapshotAside() -> FieldSnapshot {
        let learned = learner
        defer { learner = learned }
        var (reads, observed) = read()
        var memo = foundEmptyParagraphs
        var unreachable = foundUnreachable
        return FieldSnapshot.Step.run(taking: { take($0, into: &reads, memo: &memo, unreachable: &unreachable) }) {
            FieldSnapshot.build(
                reads, capabilities: profile, answer: observed.after, anchor: nil, cursor: state.field.cursor, memo: memo,
                unreachable: unreachable
            )
        }.snapshot
    }

    /// Runs a repair or release, keeping the command's evidence, which the Controller harvests before them; false when a step failed.
    @discardableResult
    mutating func executeAside(_ plan: PhysicalPlan) -> Bool {
        let evidence = attribution
        let aborted = execute(plan.steps)
        attribution = evidence
        return aborted == nil
    }

    /// The twin of the real executor's surviving-commit scan.
    mutating func drainResidency(of steps: [PhysicalStep], after index: Int) {
        for survivor in steps[(index + 1)...] {
            if case .commit(let effect) = survivor, effect.survivesAbort {
                state = VimReducer.reduce(state, effect, captures: captures)
            }
        }
    }

    mutating func applyReplace(_ replacement: String) {
        listLines = listLines.map { ListLine.carried($0, in: text, replacing: selection, with: replacement) }
        let replaced = TextModel(text).replacing(selection, with: replacement)
        codeSpans = Self.carried(codeSpans, replacing: selection, with: replacement, into: replaced)
        codeInside = false
        atWrittenCodeEnd = false
        inListGap = false
        text = replaced
        let caretAfter = selection.lowerBound + replacement.utf16.count
        selection = caretAfter..<caretAfter
        backward = false
    }
}

// MARK: - The learner

public extension Sim {
    /// The Controller's learner for one field.
    struct Learner: Equatable, Sendable {
        public var store: BeliefStore
        public var rung: String
        public var versions: Versions
        public var chromium: Bool
        public var probed: CapabilityProfile
        public var config: [Capability: ConfigChoice] = [:]
        public var sampling = OffsetsSampling()
        public var tally = Tally()
        public var strikes = Strikes()
        public internal(set) var resolved: ResolvedBeliefs?
        /// What each snapshot's reads said.
        public internal(set) var evidence: [Evidence] = []
        public internal(set) var lessons: [Learning.Lesson] = []

        public init(
            store: BeliefStore = BeliefStore(), rung: String = "sim|role:AXTextArea", versions: Versions = Versions(app: "1"),
            chromium: Bool = false, probed: CapabilityProfile
        ) {
            self.store = store
            self.rung = rung
            self.versions = versions
            self.chromium = chromium
            self.probed = probed
            // A policy the profile leaves out is seeded off, as `nativeMotions` is everywhere.
            for policy in Capability.allCases where policy.species == .policy && !probed.has(policy) {
                config[policy] = ConfigChoice(seededOff: true)
            }
        }

        public var model: ReadModel { resolved?.readModel ?? ReadModel(answer: chromium ? .textContent : .value) }
    }
}

extension Sim {
    /// The fake field's reads, which the learner observes here.
    mutating func read() -> (reads: FieldSnapshot.Reads, observed: Learning.Observation) {
        let (current, source) = learner.map { $0.model.reading(chromium: $0.chromium, children: hasChildren) }
            ?? (readModel, .start)
        let plain = readSelection
        var sampled = false
        var reads = FieldSnapshot.Reads(
            field: FieldReads(text: shownValue, plain: plain, selectedText: readSelectedText), length: fieldLength,
            webContent: webContent || self.reads != nil || emptyParagraphs, blocks: blocks
        )
        reads.roots = roots
        reads.proseMirror = listLines != nil
        if showsPlaceholder {
            // What the Snapshotter makes of a field its scan finds shows only generated text (LIN-1930).
            reads = FieldSnapshot.Reads(
                generatedOnly: FieldReads(text: shownValue, plain: plain, selectedText: readSelectedText), length: fieldLength,
                webContent: reads.webContent, blocks: blocks, markers: (markers || emptyParagraphs) && current != .value
            )
        } else if emptyParagraphs {
            let value = chromium.shown.value
            let text = chromium.shown.markers + (endsInTextlessLeaf ? "\u{FFFC}" : "")
            var memo: EmptyParagraphs.Memo?
            var unreachable: UnreachableLines.Memo?
            let aligned = FieldSnapshot.Step.run(taking: { take($0, into: &reads, memo: &memo, unreachable: &unreachable) }) {
                MarkerReads.aligning(value: value, range: plain, text: text, sides: reads.sides)
            }
            reads.field = FieldReads(text: value, plain: plain, selectedText: readSelectedText, markers: aligned.reads)
            reads.marked = plain
            reads.markerText = aligned.text
        } else {
            sampled = current == .value && source.observes && learner?.sampling.samples(text: text, plain: plain) == true
            if markers && (current != .value || sampled) { reads.field.markers = markerReads }
        }
        let field = reads.field
        var observed = Learning.Observation(before: current, source: source)
        if var learner {
            observed = Learning.observe(field, before: current, source: source, newEngine: learner.model.newEngine)
            if sampled { learner.sampling.sampled(markers: markers, evidence: observed.evidence, text: text, plain: plain) }
            if let evidence = observed.evidence {
                learner.tally.count(evidence)
                learner.evidence.append(evidence)
            }
            self.learner = learner
        }
        return (reads, observed)
    }

    /// Answers a step's read from the fake field, as `Snapshotter` does over AX.
    func take(
        _ need: FieldSnapshot.Need, into reads: inout FieldSnapshot.Reads, memo: inout EmptyParagraphs.Memo?,
        unreachable: inout UnreachableLines.Memo?
    ) {
        switch need {
        case .side(let end):
            reads.sides.updateValue(chromium.side(end == .upper ? selection.upperBound : selection.lowerBound), forKey: end)
        case .emptyParagraph:
            reads.inEmptyParagraph = chromium.inEmptyParagraph(selection)
        case .emptyParagraphs(let value, let markers, let why):
            let found = findsEmptyParagraphs ? chromium.shown.found : nil
            memo = EmptyParagraphs.Memo(value: value, markers: markers, blocks: blocks, found: found, origin: .walked(why))
        case .unreachable(let value, let markers, let candidates, let why):
            let shown = chromium
            let found = findsUnreachable ? UnreachableLines.Found(
                markers: candidates.markers.map(\.lowerBound).filter(Set(shown.listMarkers).contains),
                chips: shown.chips.filter { chip in
                    candidates.chips.contains { $0.lowerBound == chip.range.lowerBound && chip.range.upperBound <= $0.upperBound }
                },
                carets: shown.drawnCaret.map { candidates.carets.contains($0.offset) ? [$0] : [] } ?? [],
                joins: shown.joins, controls: shown.controls
            ) : nil
            unreachable = UnreachableLines.Memo(
                value: value, markers: markers, blocks: blocks, roots: roots, found: found, origin: .walked(why)
            )
        }
    }

    /// `AXValue`.
    var shownValue: String {
        if showsPlaceholder, let placeholder { return placeholder }
        return emptyParagraphs ? chromium.shown.value : text
    }

    /// `kAXNumberOfCharacters`: `AXValue`'s length.
    var fieldLength: Int { shownValue.utf16.count }

    /// The child count: a block per paragraph.
    var blocks: Int { hasChildren ? text.utf16.filter { $0 == 10 }.count + 1 : 0 }

    /// The roots by identity: a line whose block changes kind is a new root, though the text and the count stay.
    var roots: Int? {
        listLines.map { lines in
            var hasher = Hasher()
            hasher.combine(lines)
            return hasher.finalize()
        }
    }

    var chromium: ChromiumParagraphs {
        let caret = selection.isEmpty ? selection.lowerBound : nil
        let drawn = drawsLate && snapshotting ? nil
            : caret.flatMap { isCodeEdge($0, start: true) || isCodeEdge($0, start: false) ? $0 : nil }
        return ChromiumParagraphs(text: text, lines: listLines, caret: caret, drawn: drawn)
    }

    /// What the caret Linear draws adds to `fieldLength`, which a settle leaves out.
    var drawnLength: Int {
        let shown = chromium
        guard shown.drawnCaret != nil else { return 0 }
        return shown.shown.value.utf16.count
            - ChromiumParagraphs(text: text, lines: listLines, caret: selection.lowerBound).shown.value.utf16.count
    }

    /// The upper end's paragraph side from the Sim's own text, in every Chromium mode.
    var upperSide: ParagraphBreaks.Side? {
        reads != nil || markers || emptyParagraphs ? ChromiumParagraphs.side(selection.upperBound, in: text) : nil
    }

    var markerReads: MarkerReads {
        guard !showsPlaceholder else { return MarkerReads(breaks: ParagraphBreaks(), value: readSelection) }
        return MarkerReads(
            breaks: ParagraphBreaks(value: text, fieldText: text.filter { $0 != "\n" }), value: selection,
            textlessLeaves: endsInTextlessLeaf
        )
    }

    mutating func learn(from observed: Learning.Observation) {
        guard var learner else { return }
        if observed.source.observes {
            for item in attribution.evidence { learner.tally.count(item) }
        }
        if let route = attribution.missedRoute {
            learner.strikes.miss(route, judgedUnder: observed.after, app: learner.versions.app)
        }
        let config = learner.config
        let lesson = Learning.learn(
            store: &learner.store, strikes: &learner.strikes, rung: learner.rung, versions: learner.versions,
            model: learner.model, observed: observed, run: attribution.evidence,
            overridden: { config[$0]?.override != nil }, provenance: Provenance(), tally: learner.tally
        )
        learner.lessons.append(lesson)
        self.learner = learner
        if lesson.republish { resolveBeliefs() }
    }

    mutating func resolveBeliefs() {
        guard var learner else { return }
        let resolved = learner.store.resolve(
            rungs: [learner.rung], rung: learner.rung, versions: learner.versions, chromium: learner.chromium,
            children: hasChildren, userPinsOffsets: learner.config[.readCaret]?.override != nil
        )
        learner.resolved = resolved
        profile = CapabilityResolver.resolve(probed: learner.probed, config: learner.config, beliefs: resolved).profile
        self.learner = learner
    }
}

public extension Sim {
    /// What Linear draws before a line's text, each a block of its own in `AXValue`: a list marker, then text-less leaves.
    struct ListLine: Hashable, Sendable {
        public var marker: String?
        public var leaves: Int
        /// The leaves are a to-do's checkbox, which a write at its line's start lands beside by where the caret was.
        public var checkbox: Bool
        /// The marker starts its item's line, as Chromium draws its own lists' markers.
        public var inline: Bool
        /// The line starts a list, code block or quote right after another, so → ↓ from the line above or ↑ from it stops first.
        public var stop: Bool
        /// The marker is a code block's language label, which its block tells from text, not its shape.
        public var controls: Bool

        public init(
            marker: String? = nil, leaves: Int = 0, checkbox: Bool = false, inline: Bool = false, stop: Bool = false,
            controls: Bool = false
        ) {
            self.marker = marker
            self.leaves = leaves
            self.checkbox = checkbox
            self.inline = inline
            self.stop = stop
            self.controls = controls
        }

        /// `lines` once `range` of `text` is `replacement`: the first keeps its own, but a deleted plain line the next's.
        static func carried(
            _ lines: [ListLine], in text: String, replacing range: Range<Int>, with replacement: String
        ) -> [ListLine] {
            let units = Array(text.utf16)
            guard lines.count == units.filter({ $0 == 10 }).count + 1 else { return lines }
            let first = units[..<range.lowerBound].filter { $0 == 10 }.count
            let last = units[..<range.upperBound].filter { $0 == 10 }.count
            var head = lines[first]
            let wholeLines = replacement.isEmpty && !range.isEmpty && units[range.upperBound - 1] == 10
                && (range.lowerBound == 0 || units[range.lowerBound - 1] == 10)
            if wholeLines, head == ListLine() { head = lines[last] }
            let made = replacement.utf16.filter { $0 == 10 }.count
            return Array(lines[..<first]) + [head] + Array(repeating: ListLine(), count: made) + Array(lines[(last + 1)...])
        }
    }
}

public extension EmptyParagraphs {
    /// `AXValue`, the plain marker text and each empty paragraph's `<br>` offset, as Chrome 153 shows `paragraphs`.
    static func chromium(_ paragraphs: [String]) -> (value: String, markers: String, found: [Int]) {
        var value = ""
        var markers = ""
        var found: [Int] = []
        for (index, paragraph) in paragraphs.enumerated() {
            if paragraph.isEmpty {
                found.append(markers.utf16.count)
                markers += "\n"
                value += "\n"
            } else {
                if index > 0, !paragraphs[index - 1].isEmpty { value += "\n" }
                markers += paragraph
                value += paragraph
            }
        }
        return (value, markers, found)
    }
}

/// The Sim's text as Chrome 153 shows it when every `\n` ends a paragraph (LIN-1612); with `lines`, as Linear does.
struct ChromiumParagraphs {
    static let chip: UInt16 = 0x2060
    static let label = Array("\u{2060}\u{00A0}LIN-1 chip".utf16)

    let text: String
    let paragraphs: [String]
    let lines: [Sim.ListLine]?
    /// `AXValue`, the raw marker text and each empty paragraph's `<br>` offset.
    let shown: (value: String, markers: String, found: [Int])
    let plainMarkers: String
    /// Plain starts of the list markers, and the chips.
    let listMarkers: [Int]
    let chips: [UnreachableLines.Chip]
    /// Plain starts of blocks a stop comes before, the Sim offsets of their first lines, and code blocks' labels.
    let joins: [Int]
    let gaps: Set<Int>
    let controls: [Range<Int>]
    /// The caret Linear draws at a code span's edge, and the paragraph whose end it ends with a `<br>`.
    let drawnCaret: UnreachableLines.Caret?
    let drawnAtEnd: Int?

    /// `caret` beside a chip that starts or ends its paragraph brings Linear's image, and `drawn` its drawn caret, each a line.
    init(text: String, lines: [Sim.ListLine]? = nil, caret: Int? = nil, drawn drawnAt: Int? = nil) {
        self.text = text
        paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        self.lines = lines
        guard let lines else {
            shown = EmptyParagraphs.chromium(paragraphs)
            plainMarkers = shown.markers
            listMarkers = []
            chips = []
            joins = []
            gaps = []
            controls = []
            drawnCaret = nil
            drawnAtEnd = nil
            return
        }
        var drawnCaret: UnreachableLines.Caret?
        var drawnAtEnd: Int?
        var value = ""
        var raw = ""
        var found: [Int] = []
        var markers: [Int] = []
        var chips: [UnreachableLines.Chip] = []
        var joins: [Int] = []
        var gaps: Set<Int> = []
        var controls: [Range<Int>] = []
        var plain = 0
        var start = 0
        var afterBreak = false
        // Chromium breaks the line before each block but the first, a `<br>` alone, or one after a `<br>`.
        func block(_ text: [UInt16], br: Bool = false) {
            if !value.isEmpty || !raw.isEmpty, !br, !afterBreak { value += "\n" }
            value += String(decoding: text, as: UTF16.self)
            afterBreak = br || (text.isEmpty && afterBreak)
        }
        for (index, paragraph) in paragraphs.enumerated() {
            let line = lines.indices.contains(index) ? lines[index] : Sim.ListLine()
            let units = Array(paragraph.utf16)
            let prefix = line.inline ? Array((line.marker ?? "").utf16) : []
            if line.stop {
                joins.append(plain)
                gaps.insert(start)
            }
            if let marker = line.marker {
                if line.controls { controls.append(plain..<(plain + marker.utf16.count)) } else { markers.append(plain) }
                if !line.inline {
                    block(Array(marker.utf16))
                    raw += marker
                }
                plain += marker.utf16.count
            }
            for _ in 0..<line.leaves {
                block([])
                raw += "\u{FFFC}"
            }
            guard !units.isEmpty else {
                // Chromium keeps the line of its own list's empty item, which holds the marker.
                if prefix.isEmpty { found.append(plain) } else { block(prefix) }
                raw += String(decoding: prefix, as: UTF16.self)
                block([10], br: true)
                raw += "\n"
                plain += 1
                start += 1
                continue
            }
            // Each chip is a line of its own, which spaces after it join, and one ending the paragraph is followed by a `<br>`.
            var parts: [[UInt16]] = []
            var pending: [UInt16] = []
            func flush() {
                guard !pending.isEmpty else { return }
                if parts.last == Self.label, pending.allSatisfy({ $0 == 0x20 }) {
                    parts[parts.count - 1] += pending
                } else {
                    parts.append(pending)
                }
                pending = []
            }
            var partsRaw: [UInt16] = []
            var paragraphChips: [Range<Int>] = []
            let paragraphStart = plain
            // Measured, there is none before a chip right after another chip's `<br>`.
            let followsBreak = afterBreak
            let drawn = drawnAt.flatMap { (start...(start + units.count)).contains($0) ? $0 - start : nil }
            for (offset, unit) in units.enumerated() {
                if offset == drawn {
                    flush()
                    // Measured, one starting a paragraph right after a `<br>` has no line of its own.
                    if offset > 0 || !followsBreak { parts.append([]) }
                    partsRaw.append(0xFFFC)
                    drawnCaret = UnreachableLines.Caret(offset: plain, place: offset == 0 ? .start : .middle)
                }
                guard unit == Self.chip else {
                    pending.append(unit)
                    partsRaw.append(unit)
                    plain += 1
                    continue
                }
                flush()
                if offset == 0, caret == start, !followsBreak {
                    parts.append([])
                    partsRaw.append(0xFFFC)
                }
                parts.append(Self.label)
                partsRaw += Self.label
                paragraphChips.append(plain..<(plain + Self.label.count))
                plain += Self.label.count
                if offset == units.count - 1, caret == start + units.count {
                    parts.append([])
                    partsRaw.append(0xFFFC)
                }
            }
            flush()
            if drawn == units.count {
                parts.append([])
                partsRaw.append(0xFFFC)
                drawnCaret = UnreachableLines.Caret(offset: plain, place: .end)
                drawnAtEnd = index
            }
            block(prefix + parts[0])
            raw += String(decoding: prefix, as: UTF16.self)
            for part in parts.dropFirst() { value += "\n" + String(decoding: part, as: UTF16.self) }
            raw += String(decoding: partsRaw, as: UTF16.self)
            if units.last == Self.chip || drawn == units.count {
                value += "\n"
                raw += "\n"
                plain += 1
                afterBreak = true
            } else if parts.count > 1 {
                afterBreak = false
            }
            chips += paragraphChips.map { UnreachableLines.Chip(range: $0, paragraph: paragraphStart..<plain) }
            start += units.count + 1
        }
        shown = (value, raw, found)
        plainMarkers = FieldReads.withoutAttachments(raw)
        listMarkers = markers
        self.chips = chips
        self.joins = joins
        self.gaps = gaps
        self.controls = controls
        self.drawnCaret = drawnCaret
        self.drawnAtEnd = drawnAtEnd
    }

    /// The plain offset of each Sim offset; a caret after a chip ending its paragraph reads past the `<br>` after it.
    func field(_ offset: Int, caret: Bool = true) -> Int {
        var start = 0
        var plain = 0
        for (index, paragraph) in paragraphs.enumerated() {
            let line = lines.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? Sim.ListLine()
            plain += line.marker?.utf16.count ?? 0
            let units = Array(paragraph.utf16)
            let chips = lines == nil ? 0 : units.filter { $0 == Self.chip }.count
            let trailing = lines != nil && units.last == Self.chip || drawnAtEnd == index ? 1 : 0
            if offset <= start + units.count {
                let local = offset - start
                let before = lines == nil ? 0 : units[..<local].filter { $0 == Self.chip }.count
                let past = caret && local == units.count && drawnAtEnd != index ? trailing : 0
                return plain + local + before * (Self.label.count - 1) + past
            }
            plain += max(units.count + chips * (Self.label.count - 1), 1) + trailing
            start += units.count + 1
        }
        return plain
    }

    func field(_ range: Range<Int>) -> Range<Int> {
        guard !range.isEmpty else { return field(range.lowerBound)..<field(range.lowerBound) }
        let (a, b) = (field(range.lowerBound, caret: false), field(range.upperBound, caret: false))
        return min(a, b)..<max(a, b)
    }

    /// Where a write lands: the last caret before `offset`, or at a marker or checkbox, the side `caret` comes from.
    func landing(_ offset: Int, from caret: Int) -> Int {
        let last = (0...text.utf16.count).last { field($0, caret: false) <= offset } ?? 0
        let units = Array(text.utf16)
        guard let lines else { return last }
        func prefix(_ start: Int) -> Sim.ListLine {
            let line = units[..<start].filter { $0 == 10 }.count
            return lines.indices.contains(line) ? lines[line] : Sim.ListLine()
        }
        if last > 0, units[last - 1] == 10, caret > last, prefix(last).checkbox, field(last - 1) == field(last) {
            return last - 1
        }
        guard last < units.count, units[last] == 10 else { return last }
        let next = prefix(last + 1)
        let marker = next.marker?.utf16.count ?? 0
        // Chromium's own list lands a write in its marker after it, whichever way the caret came.
        return marker > 0 && offset >= field(last + 1) - marker && (caret <= last || next.inline) ? last + 1 : last
    }

    /// Offsets of the chips, which keys cross in one step.
    var atoms: Set<Int> {
        guard lines != nil else { return [] }
        return Set(text.utf16.enumerated().filter { $0.element == Self.chip }.map(\.offset))
    }

    /// `Snapshotter.paragraphSide`: a paragraph's start, empty or not, reads as the start.
    static func side(_ offset: Int, in text: String) -> ParagraphBreaks.Side {
        offset == 0 || Array(text.utf16)[offset - 1] == 10 ? .start(skipping: 0) : .end
    }

    func side(_ offset: Int) -> ParagraphBreaks.Side {
        Self.side(offset, in: text)
    }

    func inEmptyParagraph(_ selection: Range<Int>) -> Bool {
        guard selection.isEmpty else { return false }
        let model = TextModel(text)
        return model.lineStart(of: selection.lowerBound) == model.lineEnd(of: selection.lowerBound)
    }
}
