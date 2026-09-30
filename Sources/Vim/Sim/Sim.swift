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

    /// Answers no `AXSelectedTextRange` at all — the recorder's `answered=0`.
    public var unreadableSelection = false

    /// Makes the field a Chromium contenteditable: `AXSelectedTextRange` starts at `reads` of the selection's
    /// start and is as long as `AXSelectedText`, the true selected text less its paragraph breaks (LIN-1533).
    public var reads: ((_ offset: Int, _ text: String) -> Int)?

    /// Chromium rich text whose every `\n` ends a paragraph, as Chrome 153 shows it: see `ChromiumParagraphs` (LIN-1612).
    public var emptyParagraphs = false

    /// Off, discovery fails and the snapshot keeps `AXValue`'s lines.
    public var findsEmptyParagraphs = true

    public var readSelection: Range<Int> {
        if emptyParagraphs { return chromium.field(selection) }
        guard let reads else { return selection }
        let start = reads(selection.lowerBound, text)
        return start..<start + readSelectedText.utf16.count
    }

    public var readSelectedText: String {
        if emptyParagraphs {
            let markers = Array(chromium.shown.markers.utf16)
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
    public private(set) var unsupportedSteps = 0

    /// The last command's evidence from its settles.
    public private(set) var attribution = RunAttribution()

    private var monitor = RawMonitor()
    private var captures: [CaptureSlot: String] = [:]

    /// The focus is the selection's lower bound.
    private var backward = false

    /// The command that opened the current Insert session, recorded at its Esc.
    private var openChange: (source: String, count: Int?, register: Register?, mutated: Bool)?

    /// The last snapshot's, to convert the drawn cursor at unbind.
    private var fieldBreaks: ParagraphBreaks?

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
        switch monitor.feed(token, mode: mode) {
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
        if let text {
            self.text = text
            let clamped = TextModel(text).clamp(caret)
            selection = clamped..<clamped
        }
        state.field = state.field.carried(across: transition)
        if transition.clearsChangeInFlight {
            monitor.reset()
            openChange = nil
        }
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
        let reading = read()
        // Same cursor match-stamp as the runtime's Snapshotter.
        var cursor: Range<Int>?
        if let drawn = state.field.cursor, !drawn.isEmpty, drawn == reading.selection {
            cursor = drawn
        }
        let snapshot = FieldSnapshot(
            capabilities: profile,
            text: reading.text ?? text,
            selection: reading.selection,
            length: fieldLength,
            anchor: anchor,
            cursor: cursor,
            webContent: webContent || reads != nil || emptyParagraphs,
            breaks: reading.breaks,
            caretInEmptyParagraph: reading.emptyParagraph,
            textlessLeaves: reading.textlessLeaves,
            valueGap: reading.gap,
            holdsEmptyParagraphs: reading.holdsEmptyParagraphs
        )
        fieldBreaks = snapshot.breaks
        let planned = PhysicalPlanner.planning(logical, snapshot: snapshot)
        let physical = planned.plan
        let before = state.field.mode

        captures = [:]
        let abortedAt = execute(physical.steps)
        abortedStep = abortedAt.map { physical.steps[$0] }
        // After the hygiene below, as the Controller's is.
        defer { learn(from: reading) }
        guard abortedAt == nil else {
            // Abort hygiene, mirroring the Controller down to the stand-down.
            if planned.abortedAtTextCheck(abortedAt) {
                if !unreadableSelection, !readSelection.isEmpty {
                    executeAside(PhysicalPlanner.collapse(readSelection, misread: true, profile: profile))
                }
                if state.field.mode.isInserting {
                    state = VimReducer.reduce(state, .setMode(before.nonVisual))
                }
            } else if !repairStrandedSelection(operand: planned.operand), state.field.mode.isInserting {
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

    /// The Controller's twin, and it must obey the host the same way.
    mutating func repairStrandedSelection(operand: Range<Int>?) -> Bool {
        guard !unreadableSelection else { return false }   // unknown is not empty
        guard !readSelection.isEmpty else { return true }
        if state.field.mode.isInserting, readSelection == operand { return true }
        executeAside(PhysicalPlanner.collapse(readSelection, profile: profile))
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
    /// The index of the step that ended the run, nil when every step ran.
    mutating func execute(_ steps: [PhysicalStep]) -> Int? {
        var kept: [Int: Int] = [:]
        attribution = RunAttribution()
        for (index, step) in steps.enumerated() {
            if case .settle = step {} else { attribution.record(step) }
            switch step {
            case .setSelection(let range):
                guard !swallowsSelect else { break }
                let model = TextModel(text)
                selection = model.clamp(landing(range.lowerBound))..<model.clamp(landing(range.upperBound))
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
                // A non-answer satisfies nothing, exactly as `Expectation.matches` has it.
                let observed = unreadableSelection ? nil : readSelection
                let passed = expectation.matches(selection: observed, length: fieldLength, selectedText: readSelectedText)
                    && (!emptyParagraphs || chromium.onEdge(expectation.edge, selection))
                attribution.record(.settle(expectation), passed: passed, selection: observed, length: fieldLength,
                                   selectedText: readSelectedText)
                if !passed {
                    settleFailures += 1
                    if let key = expectation.blamed(observed: observed) { blamed.append(key) }
                    drainResidency(of: steps, after: index)
                    return index   // the rest dies, like the real executor
                }
                if let slot = expectation.keeps, let caret = observed?.lowerBound { kept[slot] = caret }

            case .softSettle:
                // Best-effort barrier: never aborts. In this synchronous host
                // there is nothing async to wait for, and the blind step it
                // follows may be an unsupported no-op, so the field need not match
                // the prediction — which is exactly why a soft settle must proceed.
                break

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
        if emptyParagraphs { return chromium.landing(offset) }
        guard writesInReadOffsets, let reads else { return offset }
        return (0...text.utf16.count).last { reads($0, text) <= offset } ?? 0
    }

    /// The keys lane B counts with, which run whether or not `emulatesKeys` is on.
    static let countedKeys: Set<Chord> = [.left, .right, .up, .down, .lineStart, .selectRight, .deleteBack]

    /// One key as `KeyModel` has Cocoa's bindings do it, which is how LIN-1533 measured Chromium's arrows; false for
    /// a key the model does not know.
    mutating func press(_ chord: Chord) -> Bool {
        var keys = KeyModel(
            text: text,
            anchor: backward ? selection.upperBound : selection.lowerBound,
            focus: backward ? selection.lowerBound : selection.upperBound,
            wrap: wrapWidth
        )
        guard keys.press(chord) else { return false }
        text = keys.text
        selection = keys.selection
        backward = keys.focus < keys.anchor
        return true
    }

    /// Runs a repair or release, keeping the command's evidence, which the Controller harvests before them.
    mutating func executeAside(_ plan: PhysicalPlan) {
        let evidence = attribution
        _ = execute(plan.steps)
        attribution = evidence
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
        text = TextModel(text).replacing(selection, with: replacement)
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

    struct Reading {
        let selection: Range<Int>?
        let breaks: ParagraphBreaks?
        let emptyParagraph: Bool
        let textlessLeaves: Bool
        let observed: Learning.Observation
        /// The planner's text where it is not the Sim's own.
        var text: String?
        var gap = 0
        var holdsEmptyParagraphs = false
    }
}

extension Sim {
    /// The learner observes these reads before the snapshot interprets them.
    mutating func read() -> Reading {
        let (current, source) = learner.map { $0.model.reading(chromium: $0.chromium, children: hasChildren) }
            ?? (readModel, .start)
        if emptyParagraphs { return readChromium(current: current, source: source) }
        let plain = unreadableSelection ? nil : readSelection
        let sampled = current == .value && source.observes && learner?.sampling.samples(text: text, plain: plain) == true
        let reads = FieldReads(
            text: text,
            plain: plain,
            selectedText: readSelectedText,
            markers: markers && (current != .value || sampled) ? markerReads : nil
        )
        var observed = Learning.Observation(before: current, source: source)
        if var learner {
            observed = Learning.observe(reads, before: current, source: source, newEngine: learner.model.newEngine)
            if sampled { learner.sampling.sampled(markers: markers, evidence: observed.evidence, text: text, plain: plain) }
            if let evidence = observed.evidence {
                learner.tally.count(evidence)
                learner.evidence.append(evidence)
            }
            self.learner = learner
        }
        let interpreted = reads.interpreted(under: observed.after)
        return Reading(
            // A snapshot takes the plain read even where a settle would find none.
            selection: observed.after == .value ? readSelection : interpreted.selection,
            breaks: interpreted.breaks, emptyParagraph: interpreted.emptyParagraph, textlessLeaves: interpreted.textlessLeaves,
            observed: observed
        )
    }

    /// `Snapshotter.snapshot`'s order: the learner judges the reads as given, then the empty paragraphs go back in.
    mutating func readChromium(current: OffsetsAnswer, source: OffsetsSource) -> Reading {
        let chromium = self.chromium
        let shown = chromium.shown
        let field = readSelection
        let aligned = ParagraphBreaks(value: shown.value, fieldText: shown.markers)
        let truth = selection
        let side = { (end: ParagraphBreaks.End) in chromium.side(end == .upper ? truth.upperBound : truth.lowerBound) }
        let reads = FieldReads(
            text: shown.value, plain: unreadableSelection ? nil : field, selectedText: readSelectedText,
            markers: MarkerReads(breaks: aligned, value: aligned?.valueRange(field, side: side))
        )
        var observed = Learning.Observation(before: current, source: source)
        if var learner {
            observed = Learning.observe(reads, before: current, source: source, newEngine: learner.model.newEngine)
            if let evidence = observed.evidence {
                learner.tally.count(evidence)
                learner.evidence.append(evidence)
            }
            self.learner = learner
        }
        let interpreted = reads.interpreted(under: observed.after)
        var reading = Reading(
            selection: interpreted.selection, breaks: interpreted.breaks,
            emptyParagraph: interpreted.selection != nil && chromium.inEmptyParagraph(truth), textlessLeaves: false,
            observed: observed, text: shown.value
        )
        guard observed.after == .textContent, findsEmptyParagraphs, let aligned,
              let model = EmptyParagraphs.restore(value: shown.value, fieldText: shown.markers, aligned: aligned, found: shown.found),
              let resolved = model.breaks.valueRange(field, side: side) else { return reading }
        reading = Reading(selection: resolved, breaks: model.breaks, emptyParagraph: false, textlessLeaves: false,
                          observed: observed, text: model.text, gap: model.gap, holdsEmptyParagraphs: !shown.found.isEmpty)
        return reading
    }

    /// `kAXNumberOfCharacters`: `AXValue`'s length.
    var fieldLength: Int { emptyParagraphs ? chromium.shown.value.utf16.count : text.utf16.count }

    var chromium: ChromiumParagraphs { ChromiumParagraphs(text: text) }

    var markerReads: MarkerReads {
        MarkerReads(breaks: ParagraphBreaks(value: text, fieldText: text.filter { $0 != "\n" }), value: selection)
    }

    mutating func learn(from reading: Reading) {
        guard var learner else { return }
        if reading.observed.source.observes {
            for item in attribution.evidence { learner.tally.count(item) }
        }
        let config = learner.config
        let lesson = Learning.learn(
            store: &learner.store, rung: learner.rung, versions: learner.versions, model: learner.model,
            observed: reading.observed, run: attribution.evidence,
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

/// The Sim's text as Chrome 153 shows it when every `\n` ends a paragraph (LIN-1612).
struct ChromiumParagraphs {
    let text: String
    let paragraphs: [String]
    let shown: (value: String, markers: String, found: [Int])

    init(text: String) {
        self.text = text
        paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        shown = EmptyParagraphs.chromium(paragraphs)
    }

    /// The marker offset of each true offset: paragraphs run together, an empty one standing as its `<br>`.
    func field(_ offset: Int) -> Int {
        var start = 0
        var marker = 0
        for paragraph in paragraphs {
            let length = paragraph.utf16.count
            if offset <= start + length { return marker + offset - start }
            start += length + 1
            marker += max(length, 1)
        }
        return marker
    }

    func field(_ range: Range<Int>) -> Range<Int> {
        let (a, b) = (field(range.lowerBound), field(range.upperBound))
        return min(a, b)..<max(a, b)
    }

    /// Where a write of marker offset `offset` lands: the last caret that reads it, as Chromium's land downstream.
    func landing(_ offset: Int) -> Int {
        (0...text.utf16.count).last { field($0) <= offset } ?? 0
    }

    private func isParagraphStart(_ offset: Int) -> Bool {
        offset == 0 || Array(text.utf16)[offset - 1] == 10
    }

    /// `Snapshotter.paragraphSide`: a paragraph's start, empty or not, reads as the start.
    func side(_ offset: Int) -> ParagraphBreaks.Side {
        isParagraphStart(offset) ? .start(skipping: 0) : .end
    }

    func onEdge(_ edge: Expectation.Edge?, _ selection: Range<Int>) -> Bool {
        guard let edge else { return true }
        return isParagraphStart(selection.upperBound) == (edge == .paragraphStart)
    }

    func inEmptyParagraph(_ selection: Range<Int>) -> Bool {
        guard selection.isEmpty else { return false }
        let model = TextModel(text)
        return model.lineStart(of: selection.lowerBound) == model.lineEnd(of: selection.lowerBound)
    }
}
