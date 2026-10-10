import AppKit
import ApplicationServices
import Core

/// The runtime loop — `Sim`'s impure twin. Wires the tap's key events
/// through monitor → planners → executor against the currently-bound
/// field, and carries the runtime lore the Sim mirrors in pure form:
/// binding + probing on focus change, dot-body bookkeeping, and the
/// insert-payload commits.
///
/// The per-key path costs zero AX: the `FocusTracker` keeps the binding as
/// event-driven state, and `handle` only reads it (InputHub's contract —
/// the tap handler must return promptly). AX is spent where it counts:
/// focus changes, Esc, and command execution.
@MainActor
public final class Controller {
    public var enabled = true {
        didSet {
            guard enabled != oldValue else { return }
            tracker.setEnabled(enabled)
        }
    }

    /// Physical Esc engages Normal mode alongside ⌃[: the menu's Normal Mode Key.
    public var escapeEngages = false

    /// Mode channel for the menu-bar indicator; nil = unbound. Setting the
    /// callback publishes immediately — the tracker may have bound during
    /// init, before the app model could wire in.
    public var onModeChange: ((VimState.Mode?) -> Void)? {
        didSet {
            publishedMode = currentIndicatorMode
            onModeChange?(publishedMode)
        }
    }
    private var publishedMode: VimState.Mode?

    /// Fired whenever the binding changes, mode or no mode.
    ///
    /// The menu used to ride `onModeChange` for this, but `publishMode`
    /// early-returns on an unchanged indicator — so moving between two fields
    /// that are both in Normal fired nothing. That is exactly the case the
    /// capability rows care about: a browser's search box and an `<input>` in
    /// the page are different surfaces, and the menu would have gone on naming
    /// and configuring the one focus had left.
    public var onBindingChange: (() -> Void)?

    private let tracker = FocusTracker()
    private var monitor = RawMonitor()
    private var state = VimState.initial
    private let executor = Executor()

    /// Marker sampling for the bound field; a new element starts over.
    private var sampling = OffsetsSampling()

    /// The bound field's empty paragraphs, found again when its text changes.
    private var emptyParagraphs: EmptyParagraphs.Memo?

    /// Its list markers and chips, found again the same way.
    private var unreachable: UnreachableLines.Memo?

    /// Per-rung evidence this process, stored with the read model.
    private var tallies: [String: Tally] = [:]

    /// Per-rung refuted runs in a row this process; not stored, so a relaunch starts each count over.
    private var strikes: [String: Strikes] = [:]

    /// Mirror of the tracker's binding, held for unbind hygiene.
    private var binding: FocusTracker.Binding?

    /// The recorder's command counter; its other half, the epoch, is on the tracker.
    private var seq: UInt64 = 0

    /// The command that opened the current Insert session, recorded at its Esc.
    private var openChange: (source: String, count: Int?, register: Register?, mutated: Bool)?

    /// The last snapshot's, to convert the drawn cursor at unbind.
    private var fieldBreaks: ParagraphBreaks?

    public init() {
        tracker.onRebind = { [weak self] binding, transition in
            self?.rebind(to: binding, transition: transition)
        }
        tracker.onPointerAction = { [weak self] in self?.pointerActed() }
        // Force the recorder's one store read off the tap callback's first command.
        _ = Diag.recordsText
        tracker.start()
    }

    /// A click in a forced app moved the caret invisibly — Normal-mode
    /// offsets are fiction now. Back to the entry policy.
    private func pointerActed() {
        if state.field.mode.isInserting { monitor.markInsertLogLossy() }
        guard let binding, binding.isForced, state.field.mode != .insert else { return }
        monitor.reset()
        state.field = VimState.Field(mode: .insert)
        openChange = nil
        publishMode()
    }

    /// The disable list changed (menu toggle): re-evaluate the binding now.
    public func refreshPolicy() {
        tracker.refreshPolicy()
    }

    /// The bound field's capability resolution, for the menu's rows; nil when unbound or forced.
    public var capabilityReport: CapabilityReport? { binding?.capabilityReport }

    /// The bound field's beliefs, for the menu's Learned section; nil when unbound or forced.
    public var boundBeliefs: ResolvedBeliefs? { binding?.beliefs }

    /// What the menu configures and names; its bundle ID keeps rows to their own app, since overlays bind across apps.
    public var boundSurface: Surface? { binding?.surface }

    /// A capability override changed (menu): rebuild the binding's profile
    /// now. Deliberately not `refreshPolicy` — its same-element
    /// short-circuit never re-probes.
    public func refreshCapabilities() {
        tracker.reresolveCapabilities()
    }

    /// The menu's On, Off or Auto, written to the beliefs file with the belief it retires.
    public func setOverride(
        _ override: CapabilityConfig.Override?, at rung: String?, on surface: Surface, for capability: Capability
    ) {
        updateBeliefs { contents in
            contents.overrides = CapabilityConfig.setting(
                override, at: rung, on: surface, capability: capability.rawValue, in: contents.overrides
            )
            if override != nil, let role = surface.roleRung { contents.retire(capability, at: role) }
        }
    }

    public func clearOverrides(atAndBelow rung: String, on surface: Surface) {
        updateBeliefs { $0.overrides = CapabilityConfig.clearing(atAndBelow: rung, on: surface, in: $0.overrides) }
    }

    /// The menu's Try Again and Forget.
    public func forget(_ beliefs: [Belief]) {
        updateBeliefs { $0.forget(beliefs) }
    }

    /// The beliefs file, for the menu to open.
    public var beliefsURL: URL { Beliefs.shared.url }

    /// The overrides uvim applies; not from the file while it does not read, but from the last version that did.
    public func appliedOverrides() -> (overrides: SurfaceLadder.UserStore, fromFile: Bool) {
        let current = Beliefs.shared.current()
        return (current.contents.overrides, current.problem == nil)
    }

    private func updateBeliefs(_ change: (inout Beliefs.Contents) -> Void) {
        do {
            try Beliefs.shared.update(change)
        } catch {
            Diag.beliefsFile(error)
        }
    }

    /// The `InputHub` handler: returns the consume verdict. Zero AX on the
    /// steady paths (insert typing, unbound apps, ⌘-chords); one bounded
    /// resolve on Esc and one verify before running a completed command.
    public func handle(_ event: KeyEvent) -> Bool {
        // The user's own paste reads the pasteboard, so it ends a register paste's loan first, even while disabled.
        if event.kind == .keyDown, event.mods.contains(.command), event.characters.lowercased() == "v" || event.keyCode == 9 {
            PasteboardLoan.shared.restore()
        }
        guard enabled, event.kind == .keyDown else { return false }
        // ⌃f/⌃b always tokenize; the field a command runs on may hand them back below.
        guard let token = gate(event, profile: Self.readsAppKeys) else {
            // The app gets this key, so a half-typed command must not outlive
            // it: the app may move the caret, and a later key would complete
            // the command against a position the user never aimed at (`d`,
            // ⌥←, `w` would delete a word somewhere else entirely).
            monitor.cancelPending()
            if state.field.mode.isInserting { monitor.markInsertLogLossy() }
            return false
        }

        // An engage key is where a stale binding has teeth: a rate-limited full re-check.
        if Self.engageTokens.contains(token) { tracker.reverify() }

        guard var binding = tracker.bindingForKeydown() else { return false }

        // Free staleness guard: catches app switches even from apps that
        // never emit AX notifications. Overlay bindings are exempt — their
        // pid legitimately differs from the frontmost app's.
        if !binding.isOverlay,
           binding.pid != NSWorkspace.shared.frontmostApplication?.processIdentifier {
            tracker.scheduleReverify()
            return false
        }

        let mode: RawMonitor.Mode
        switch state.field.mode {
        case .normal: mode = .normal
        case .visual: mode = .visual
        case .insert, .replace: mode = .insert
        }

        // Insert-mode non-Esc tokens must keep flowing through the monitor:
        // they build the insert log the dot body replays.
        switch monitor.feed(token, mode: mode, clicks: mode == .insert ? nil : Self.buttonEvents()) {
        case .passthrough:
            return false
        case .pending, .cancelled:
            guard gate(event, profile: binding.capabilities) != nil else {
                monitor.cancelPending()
                return false
            }
            return true
        case .command(let completed):
            // Numbered here, not in `run`, so the three silent drops below are too.
            seq &+= 1
            let commandSeq = seq
            // Never mutate a field focus has left (an overlay emits no event); an engage key already reverified.
            if !Self.engageTokens.contains(token) {
                if binding.isForced {
                    // AX-silent apps resolve no focused element — the
                    // element check would swallow every command. Verify at
                    // the granularity forced bindings have: (pid, window).
                    guard binding.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier,
                          AX.frontWindow(of: binding.pid)?.id == binding.windowID else {
                        drop(completed, commandSeq, "stale-forced")
                        return false
                    }
                } else {
                    guard let focused = tracker.focusedField() else {
                        drop(completed, commandSeq, "no-focused-element")
                        return false
                    }
                    if !CFEqual(focused, binding.element) {
                        // The field moved under us. In a block editor that is
                        // routinely OUR doing — the previous command's blind
                        // chord crossed into the next block — and the AX
                        // notification may not have landed yet. Same document
                        // ⇒ retarget and run; bailing here would both destroy
                        // the command and type its final key into the text.
                        guard let moved = tracker.retarget(to: focused, from: binding) else {
                            // Destroys the command AND swallows its final key.
                            drop(completed, commandSeq, "retarget-failed")
                            return false
                        }
                        binding = moved
                    }
                }
            }
            guard gate(event, profile: binding.capabilities) != nil else {
                Diag.dropped(tracker.epoch, commandSeq, command: completed.command, reason: "app-key")
                return false
            }
            run(completed, on: binding, seq: commandSeq)
            // Publish even on mid-plan aborts: a .setMode commit may have
            // landed before a later step failed.
            publishMode()
            return true
        }
    }

    private static let readsAppKeys = CapabilityProfile(available: [.nativeMotions])

    private static let engageTokens: Set<String> = ["<C-[>", "<Esc>"]

    private func gate(_ event: KeyEvent, profile: CapabilityProfile) -> String? {
        KeyNotation.token(for: event, profile: profile, escapeEngages: escapeEngages)
    }

    /// The session's button presses and releases, which the window server counts in step with the tap's keys, as no monitor does.
    private static func buttonEvents() -> UInt32 {
        [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
            .reduce(0) { $0 &+ CGEventSource.counterForEventType(.combinedSessionState, eventType: $1) }
    }

    /// A completed command verify-before-run threw away, then handed to its reverify.
    private func drop(_ completed: RawMonitor.Completed, _ seq: UInt64, _ reason: String) {
        Diag.dropped(tracker.epoch, seq, command: completed.command, reason: reason)
        tracker.reverify(force: true)
    }

    /// Focus moved (tracker event). The element plumbing is unconditional;
    /// how much of the *session* survives is the transition's call — see
    /// `FocusTransition`. A block crossing keeps the mode it was in, because
    /// a vim motion causing it is not the user going somewhere new.
    private func rebind(to new: FocusTracker.Binding?, transition: FocusTransition) {
        if !transition.preservesDrawnCursor, let old = binding, let cursor = state.field.cursor,
           let release = PhysicalPlanner.releaseCursor(cursor, breaks: fieldBreaks, profile: old.capabilities) {
            // Through the executor, which owns all field writes; a dead element rejects it harmlessly (and bounded).
            executor.execute(release, on: old.element, state: &state)
        }
        if !transition.preservesDrawnCursor { fieldBreaks = nil }
        if transition != .sameElement {
            sampling = OffsetsSampling()
            emptyParagraphs = nil
            unreachable = nil
        }
        binding = new
        Diag.bind(tracker.epoch, transition, new)
        // Keys-in-flight and the open dot body are one unit, and neither
        // holds an offset — a block crossing does not stale them.
        if transition.clearsChangeInFlight {
            monitor.reset()
            openChange = nil
        }
        state.field = state.field.carried(across: transition)
        publishMode()
        // Unconditional, unlike publishMode: a same-mode rebind still changes
        // which surface the menu describes.
        onBindingChange?()
    }

    private var currentIndicatorMode: VimState.Mode? {
        binding == nil ? nil : state.field.mode
    }

    private func publishMode() {
        let mode = currentIndicatorMode
        guard !Self.sameIndicator(mode, publishedMode) else { return }
        publishedMode = mode
        onModeChange?(mode)
    }

    /// Case identity only — visual anchor churn must not re-render the icon.
    private static func sameIndicator(_ a: VimState.Mode?, _ b: VimState.Mode?) -> Bool {
        switch (a, b) {
        case (nil, nil), (.normal?, .normal?), (.insert?, .insert?),
             (.replace?, .replace?), (.visual?, .visual?):
            return true
        default:
            return false
        }
    }

    private func run(_ completed: RawMonitor.Completed, on binding: FocusTracker.Binding, seq commandSeq: UInt64) {
        let command = completed.command
        let logical = LogicalPlanner.plan(command, state: state)
        var anchor: Int?
        if case .visual(let context) = state.field.mode {
            anchor = context.anchor
        }
        let reading = Snapshotter.snapshot(
            of: binding.element,
            capabilities: binding.capabilities,
            anchor: anchor,
            cursor: state.field.cursor,
            chromium: binding.isChromium,
            model: binding.beliefs?.readModel ?? ReadModel(answer: .value),
            sampling: sampling,
            known: emptyParagraphs,
            knownUnreachable: unreachable
        )
        if reading.emptyParagraphs != emptyParagraphs, let memo = reading.emptyParagraphs {
            Diag.emptyParagraphs(tracker.epoch, commandSeq, memo)
        }
        emptyParagraphs = reading.emptyParagraphs
        if reading.unreachable != unreachable, let memo = reading.unreachable {
            Diag.unreachable(tracker.epoch, commandSeq, memo)
        }
        unreachable = reading.unreachable
        if reading.sampled {
            sampling.sampled(markers: reading.markers, evidence: reading.observed.evidence, text: reading.reads.text,
                             plain: reading.reads.plain)
        }
        let snapshot = reading.snapshot
        fieldBreaks = snapshot.breaks
        let paragraphs = snapshot.breaks != nil
        let planned = PhysicalPlanner.planning(
            logical, snapshot: snapshot, missed: missedRoutes(on: binding, under: reading.observed.after)
        )
        let physical = planned.plan
        let epoch = tracker.epoch
        let before = state.field.mode
        let executed = executor.execute(physical, on: binding.element, state: &state, paragraphs: paragraphs)
        // Harvested before anything else can touch the executor: the abort path
        // below runs `repairStrandedSelection`, which executes its own plan and
        // resets `lastRun` — and that is precisely the path a failed write takes.
        let evidence = executor.lastRun
        // Deferred so it runs after hygiene and the dot bookkeeping, on both
        // paths, and so the republish a commit triggers happens as `run`
        // unwinds rather than re-entering the tracker mid-command.
        defer { learn(from: evidence, reading: reading, on: binding, epoch: epoch, seq: commandSeq) }
        // Declared second so LIFO runs it first, before the republish it may cause.
        defer {
            Diag.command(
                epoch, commandSeq,
                command: command,
                from: before, to: state.field.mode,
                plan: physical,
                rejection: planned.rejection,
                bell: Self.bellReason(logical),
                executed: executed,
                evidence: evidence,
                insertPayload: completed.insertPayload,
                emptyLines: snapshot.valueGap,
                foldedLength: snapshot.foldedLength
            )
        }
        guard executed else {
            if planned.abortedAtTextCheck(evidence.abortedAt) {
                // Other text than the plan meant was selected, so the mode it asked for goes too.
                if let read = selection(of: binding.element, paragraphs: paragraphs), !read.caret {
                    let collapse = PhysicalPlanner.collapse(read.range, misread: true, profile: binding.capabilities)
                    executor.execute(collapse, on: binding.element, state: &state, paragraphs: paragraphs)
                }
                if state.field.mode.isInserting {
                    executor.commit(.setMode(before.nonVisual), state: &state)
                }
            } else if !repairStrandedSelection(on: binding, operand: planned.operand, reading: reading),
                      state.field.mode.isInserting {
                // A selection we could not collapse is one the app would type over.
                executor.commit(.setMode(before.nonVisual), state: &state)
            }
            // `RawMonitor` drained the payload it will never offer again.
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

    /// Fold a just-ended Insert session into the dot memories.
    private func closeInsertSession(_ payload: String, lossless: Bool) {
        if !payload.isEmpty {
            executor.commit(.setLastInsert(payload), state: &state)
        }
        guard let change = openChange else { return }
        openChange = nil
        guard lossless else {
            executor.commit(.setLastChange(.unreplayable), state: &state)
            return
        }
        // An empty session is still a change if its entry mutated (`ciw`, `o`).
        guard change.mutated || !payload.isEmpty else { return }
        executor.commit(.setLastChange(VimState.ChangeMemory(
            body: change.source,
            count: change.count,
            register: change.register,
            insert: payload
        )), state: &state)
    }

    /// The lowering drops `BellReason`, but it never had to survive the planner.
    private static func bellReason(_ logical: LogicalPlan) -> LogicalStep.BellReason? {
        for step in logical.steps {
            if case .bell(let reason) = step { return reason }
        }
        return nil
    }

    /// The optional routes to plan without: those that missed at the rung, or all where no rung remembers a miss.
    private func missedRoutes(on binding: FocusTracker.Binding, under offsets: OffsetsAnswer) -> Set<Route> {
        guard binding.beliefs != nil, let rung = binding.surface.roleRung else { return Set(Route.allCases) }
        return strikes[rung]?.missed(judgedUnder: offsets, app: binding.versions.app) ?? []
    }

    /// A change applies at once, keeping the session (`.sameElement`), so the next command routes around it.
    private func learn(
        from evidence: Executor.RunEvidence, reading: Snapshotter.Reading, on binding: FocusTracker.Binding,
        epoch: UInt64, seq: UInt64
    ) {
        let run = evidence.attribution.evidence
        let observed = reading.observed
        let items = (observed.evidence.map { [$0] } ?? []) + run
        Diag.evidence(epoch, seq, items)
        // A forced binding resolves nothing to learn against.
        guard let beliefs = binding.beliefs else { return }
        let model = beliefs.readModel
        let teaching = items.filter(Learning.teaches)
        // No role means no stable key to accumulate against.
        guard let rung = binding.surface.roleRung else {
            Diag.notLearned(epoch, seq, reason: "no-rung", teaching)
            return
        }
        if observed.source.observes {
            for item in items { tallies[rung, default: Tally()].count(item) }
        }
        strikes[rung]?.pass(run)
        if let route = evidence.attribution.missedRoute {
            strikes[rung, default: Strikes()].miss(route, judgedUnder: observed.after, app: binding.versions.app)
        }
        guard !teaching.isEmpty || observed.after != model.answer else { return }
        var lesson = Learning.Lesson()
        let before = strikes[rung] ?? Strikes()
        var after = before
        do {
            try Beliefs.shared.update { contents in
                var store = contents.store
                let overrides = contents.overrides
                // `update` reapplies this to a file saved meanwhile, so each try counts from the same strikes.
                after = before
                lesson = Learning.learn(
                    store: &store, strikes: &after, rung: rung, versions: binding.versions, model: model,
                    observed: observed, run: run,
                    // The user has the last word: once they set an atom, stop inferring about it.
                    overridden: {
                        CapabilityConfig.resolve(binding.surface, capability: $0.rawValue, overrides: overrides).override != nil
                    },
                    provenance: Beliefs.provenance(tag: "e\(epoch).c\(seq)"), tally: tallies[rung] ?? Tally()
                )
                contents.store = store
            }
        } catch {
            Diag.beliefsFile(error)
            Diag.notLearned(epoch, seq, reason: "beliefs-file", teaching)
            return
        }
        strikes[rung] = after.isEmpty ? nil : after
        Diag.learned(epoch, seq, lesson, rung: rung, versions: binding.versions)
        if lesson.republish { tracker.reresolveCapabilities() }
    }

    /// Collapse a stranded selection, and report whether the field is safe to type into.
    private func repairStrandedSelection(
        on binding: FocusTracker.Binding, operand: Range<Int>?, reading: Snapshotter.Reading
    ) -> Bool {
        let paragraphs = reading.snapshot.breaks != nil
        // Unknown is not empty: a settle can fail *because* the read went dark.
        guard let read = selection(of: binding.element, paragraphs: paragraphs) else { return false }
        guard !read.caret else { return true }
        // Still the operand: the app's own editor substitutes on the first keystroke.
        if state.field.mode.isInserting, read.range == operand { return true }
        var side: ParagraphBreaks.Side?
        var snapshot: FieldSnapshot?
        if let marked = read.marked {
            side = Snapshotter.paragraphSide(of: marked, upper: false)
            // An edit, or a caret Linear drew or took away, leaves the run's snapshot describing other text.
            snapshot = AX.value(of: binding.element) == reading.reads.text ? reading.snapshot : Snapshotter.snapshot(
                of: binding.element, capabilities: binding.capabilities, anchor: nil, cursor: state.field.cursor,
                chromium: binding.isChromium, model: binding.beliefs?.readModel ?? ReadModel(answer: .value),
                sampling: sampling, known: emptyParagraphs, knownUnreachable: unreachable
            ).snapshot
        }
        let collapse = PhysicalPlanner.collapse(
            read.range, side: side, paragraphs: paragraphs, snapshot: snapshot, profile: binding.capabilities
        )
        let writes = binding.capabilities.has(.writeSelection)
        let settled = executor.execute(collapse, on: binding.element, state: &state, paragraphs: paragraphs)
        // Keys the field ignored fail their settle, and a write lane then writes the start as it was read.
        if !settled, writes {
            let asRead = PhysicalPlanner.collapse(read.range, paragraphs: paragraphs, profile: binding.capabilities)
            executor.execute(asRead, on: binding.element, state: &state, paragraphs: paragraphs)
        }
        // Keys can still be landing when their settle passes, so where they replaced a write the caret is waited for.
        let keyed = settled && writes && !collapse.steps.allSatisfy(PhysicalPlanner.isWrite)
        // The write that stranded this may be the one that lies, so confirm.
        return becomesCaret(binding.element, paragraphs: paragraphs, within: keyed ? 0.1 : 0)
    }

    /// Whether the selection reads as a caret, by `wait` seconds from now: Chromium shows a key milliseconds after it is sent.
    private func becomesCaret(_ element: AXUIElement, paragraphs: Bool, within wait: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(wait)
        while let read = selection(of: element, paragraphs: paragraphs) {
            if read.caret || Date() >= deadline { return read.caret }
            Thread.sleep(forTimeInterval: 0.003)
        }
        return false
    }

    /// In field offsets, through the markers (`marked`) in a text-content field, where a selected paragraph break is no caret.
    private func selection(
        of element: AXUIElement, paragraphs: Bool
    ) -> (range: Range<Int>, caret: Bool, marked: AX.MarkedSelection?)? {
        guard paragraphs, let marked = Snapshotter.markedSelection(of: element) else {
            return AX.selectedRange(of: element).map { ($0.location..<($0.location + $0.length), $0.length == 0, nil) }
        }
        return (marked.range, marked.isCollapsed, marked)
    }

    /// Records a mutating command as `lastChange`, or opens a body if it entered Insert.
    private func recordChange(
        for command: RawCommand, from before: VimState.Mode, mutated: Bool, aborted: Bool = false
    ) {
        if case .repeat = command.intent { return }
        // An aborted plan mutated nothing, whatever its steps intended.
        let changed = mutated && !aborted
        if case .visual = before {
            // Visual keys name a selection `.` cannot rebuild.
            if changed || state.field.mode.isInserting {
                executor.commit(.setLastChange(.unreplayable), state: &state)
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
        executor.commit(.setLastChange(VimState.ChangeMemory(
            body: command.source,
            count: command.count,
            register: command.register
        )), state: &state)
    }
}
