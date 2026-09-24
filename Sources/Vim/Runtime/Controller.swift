import AppKit
import ApplicationServices
import LoomCore

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

    /// The lazy write probe's running tally. In memory on purpose: a structural
    /// lie fails every command and commits in seconds, while a flaky field
    /// interleaves successes and is correctly forgotten at exit.
    private var ledger = StrikeLedger()

    /// Mirror of the tracker's binding, held for unbind hygiene.
    private var binding: FocusTracker.Binding?

    /// The recorder's command counter; its other half, the epoch, is on the tracker.
    private var seq: UInt64 = 0

    /// The command that opened the current Insert session, recorded at its Esc.
    private var openChange: (source: String, count: Int?, register: Register?, mutated: Bool)?

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

    /// The bound field's capability resolution, for the menu's badge rows;
    /// nil when unbound or forced (nothing configurable resolves there).
    public var capabilityReport: CapabilityReport? { binding?.capabilityReport }

    /// The bound field's surface — what the menu configures and names. Its
    /// bundle ID also gates the badges, so rows only describe the app they
    /// belong to (overlays bind across apps).
    public var boundSurface: Surface? { binding?.surface }

    /// A capability override changed (menu): rebuild the binding's profile
    /// now. Deliberately not `refreshPolicy` — its same-element
    /// short-circuit never re-probes.
    public func refreshCapabilities() {
        tracker.reresolveCapabilities()
    }

    /// The `InputHub` handler: returns the consume verdict. Zero AX on the
    /// steady paths (insert typing, unbound apps, ⌘-chords); one bounded
    /// resolve on Esc and one verify before running a completed command.
    public func handle(_ event: KeyEvent) -> Bool {
        guard enabled, event.kind == .keyDown else { return false }
        guard let token = KeyNotation.token(for: event) else {
            // The app gets this key, so a half-typed command must not outlive
            // it: the app may move the caret, and a later key would complete
            // the command against a position the user never aimed at (`d`,
            // ⌥←, `w` would delete a word somewhere else entirely).
            monitor.cancelPending()
            if state.field.mode.isInserting { monitor.markInsertLogLossy() }
            return false
        }

        // ⌃[ is the mode-engaging key — the one keystroke where a stale
        // binding has teeth. Rate-limited full re-check (secure/enabled too).
        // Physical Esc never gets here: KeyNotation returns nil for it.
        if token == "<C-[>" { tracker.reverify() }

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
        switch monitor.feed(token, mode: mode) {
        case .passthrough:
            return false
        case .pending, .cancelled:
            return true
        case .command(let completed):
            // Numbered here, not in `run`, so the three silent drops below are too.
            seq &+= 1
            let commandSeq = seq
            // Verify-before-run: never mutate a field focus has left. An
            // overlay summoned over a bound Normal-mode field emits no event
            // the tracker can see, so a completed command buys one bounded
            // resolve. ⌃[ already reverified this very event.
            if token != "<C-[>" {
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
                    guard let focused = AX.focusedElement() else {
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
            run(completed, on: binding, seq: commandSeq)
            // Publish even on mid-plan aborts: a .setMode commit may have
            // landed before a later step failed.
            publishMode()
            return true
        }
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
        if !transition.preservesDrawnCursor,
           let old = binding, let cursor = state.field.cursor,
           old.capabilities.has(.writeSelection) {
            // Unbind hygiene, through the executor, which owns all field
            // writes. A dead element rejects harmlessly (and bounded).
            executor.execute(
                PhysicalPlan(.setSelection(cursor.lowerBound..<cursor.lowerBound)),
                on: old.element,
                state: &state
            )
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
        let snapshot = Snapshotter.snapshot(
            of: binding.element,
            capabilities: binding.capabilities,
            anchor: anchor,
            cursor: state.field.cursor
        )
        let planned = PhysicalPlanner.planning(logical, snapshot: snapshot)
        let physical = planned.plan
        let epoch = tracker.epoch
        let before = state.field.mode
        let executed = executor.execute(physical, on: binding.element, state: &state)
        // Harvested before anything else can touch the executor: the abort path
        // below runs `repairStrandedSelection`, which executes its own plan and
        // resets `lastRun` — and that is precisely the path a failed write takes.
        let evidence = executor.lastRun
        // Deferred so it runs after hygiene and the dot bookkeeping, on both
        // paths, and so the republish a commit triggers happens as `run`
        // unwinds rather than re-entering the tracker mid-command.
        defer { learn(from: evidence, on: binding, epoch: epoch, seq: commandSeq) }
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
                insertPayload: completed.insertPayload
            )
        }
        guard executed else {
            if planned.abortedAtTextCheck(evidence.abortedAt) {
                // Only lane B checks text, and ← is its one way to collapse; the mode the plan asked for goes too.
                if let range = AX.selectedRange(of: binding.element), range.length > 0 {
                    executor.execute(PhysicalPlan(.press(.left, count: 1)), on: binding.element, state: &state)
                }
                if state.field.mode.isInserting {
                    executor.commit(.setMode(before.nonVisual), state: &state)
                }
            } else if !repairStrandedSelection(on: binding, operand: planned.operand),
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

    /// Fold one command's settle verdicts into the write probe's tally.
    ///
    /// Only hard settles produce evidence, and only an AX write is ever
    /// attributed — so this speaks exclusively about `writeSelection` and
    /// `insertText`, the two capabilities a field can *claim* and then fail to
    /// deliver. Reads were proven at bind; policies have no settle signal.
    ///
    /// A strike commits a demotion (`StrikeLedger.strikesToCommit`), persisted and applied
    /// at once, so the next command routes around the lie. The re-resolve is
    /// session-preserving (`.sameElement`), so it does not move the user mid-edit.
    private func learn(
        from evidence: Executor.RunEvidence, on binding: FocusTracker.Binding,
        epoch: UInt64, seq: UInt64
    ) {
        // A command that issued no AX write — the whole blind lane, and any plan
        // whose steps were all commits — teaches nothing and should not pay for
        // the config lookups below. Already on the command's line as `fail=nil`.
        guard evidence.failedCapability != nil || !evidence.settledCapabilities.isEmpty else {
            return
        }
        // No role means no stable key to accumulate against (a forced binding,
        // or an element AX would not name).
        guard let rung = binding.surface.roleRung else {
            Diag.notLearned(epoch, seq, reason: "no-rung", failed: evidence.failedCapability)
            return
        }

        /// The user has the last word: once they have set an atom explicitly,
        /// stop inferring about it. Without this their `.on` would lose to a
        /// machine guess, and clearing an override would not restore
        /// auto-detection because the learned demotion would silently persist.
        func isAuto(_ capability: Capability) -> Bool {
            CapabilityConfig.resolve(binding.surface, capability: capability.rawValue)
                .override == nil
        }

        // No silence check on the success path: clearing a tally is forgetting,
        // not inferring, and a capability the user has set can never have
        // accumulated one anyway — strikes below are what the rule gates.
        for capability in evidence.settledCapabilities {
            ledger.clear(rung: rung, capability: capability.rawValue)
        }

        guard let failed = evidence.failedCapability else { return }
        guard isAuto(failed) else {
            Diag.notLearned(epoch, seq, reason: "user-override", failed: failed)
            return
        }
        // At a threshold of one, false means already committed — a misattributed lie.
        guard ledger.strike(rung: rung, capability: failed.rawValue) else {
            Diag.notLearned(epoch, seq, reason: "already-committed", failed: failed)
            return
        }
        LearnedPriors.commit(
            rung: rung, version: binding.appVersion, capability: failed.rawValue
        )
        Diag.learned(epoch, seq, rung: rung, version: binding.appVersion, capability: failed)
        tracker.reresolveCapabilities()
    }

    /// Collapse a stranded selection, and report whether the field is safe to type into.
    private func repairStrandedSelection(on binding: FocusTracker.Binding, operand: Range<Int>?) -> Bool {
        // Unknown is not empty: a settle can fail *because* the read went dark.
        guard let range = AX.selectedRange(of: binding.element) else { return false }
        guard range.length > 0 else { return true }
        // Still the operand: the app's own editor substitutes on the first keystroke.
        if state.field.mode.isInserting, range.location..<(range.location + range.length) == operand { return true }
        guard binding.capabilities.has(.writeSelection) else { return false }
        executor.execute(
            PhysicalPlan(.setSelection(range.location..<range.location)),
            on: binding.element,
            state: &state
        )
        // The write that stranded this may be the one that lies, so confirm.
        return AX.selectedRange(of: binding.element).map { $0.length == 0 } ?? false
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
