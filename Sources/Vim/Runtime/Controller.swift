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

    /// Mirror of the tracker's binding, held for unbind hygiene.
    private var binding: FocusTracker.Binding?

    /// A mutating command that entered Insert leaves its dot body open until
    /// the session's Esc delivers the typed payload.
    private var openChange: (source: String, count: Int?, register: Register?)?

    public init() {
        tracker.onRebind = { [weak self] binding, transition in
            self?.rebind(to: binding, transition: transition)
        }
        tracker.onPointerAction = { [weak self] in self?.pointerActed() }
        tracker.start()
    }

    /// A click in a forced app moved the caret invisibly — Normal-mode
    /// offsets are fiction now. Back to the entry policy.
    private func pointerActed() {
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
                        tracker.reverify(force: true)
                        return false
                    }
                } else {
                    guard let focused = AX.focusedElement() else {
                        tracker.reverify(force: true)
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
                            tracker.reverify(force: true)
                            return false
                        }
                        binding = moved
                    }
                }
            }
            run(completed, on: binding)
            // Publish even on mid-plan aborts: a .setMode commit may have
            // landed before a later step failed.
            publishMode()
            return true
        }
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

    private func run(_ completed: RawMonitor.Completed, on binding: FocusTracker.Binding) {
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
        let physical = PhysicalPlanner.plan(logical, snapshot: snapshot)
        let executed = executor.execute(physical, on: binding.element, state: &state)
        guard executed else {
            // Abort hygiene: a plan that died mid-flight may leave its
            // operator selection painted, and must not record memories for
            // an edit that never happened.
            repairStrandedSelection(on: binding)
            return
        }

        if let payload = completed.insertPayload {
            executor.commit(.setLastInsert(payload), state: &state)
            if let change = openChange {
                executor.commit(.setLastChange(VimState.ChangeMemory(
                    body: change.source + payload + "<Esc>",
                    count: change.count,
                    register: change.register
                )), state: &state)
                openChange = nil
            }
        }

        recordChange(for: command, mutated: physical.mutatesText)
    }

    /// Collapse whatever selection an aborted plan stranded — through the
    /// executor, which owns all field writes.
    private func repairStrandedSelection(on binding: FocusTracker.Binding) {
        guard binding.capabilities.has(.writeSelection),
              let range = AX.selectedRange(of: binding.element), range.length > 0 else { return }
        executor.execute(
            PhysicalPlan(.setSelection(range.location..<range.location)),
            on: binding.element,
            state: &state
        )
    }

    /// Dot-worthiness — the same lore `Sim.recordChange` encodes: a
    /// mutating command becomes `lastChange`, unless it entered Insert, in
    /// which case the body stays open until Esc appends the typed payload.
    /// Plain insert entries open a body too: their mutation is the typing.
    private func recordChange(for command: RawCommand, mutated: Bool) {
        if case .repeat = command.intent { return }
        let enteredInsert: Bool
        switch state.field.mode {
        case .insert, .replace: enteredInsert = true
        default: enteredInsert = false
        }
        if enteredInsert {
            if openChange == nil {
                openChange = (command.source, command.count, command.register)
            }
            return
        }
        guard mutated else { return }
        executor.commit(.setLastChange(VimState.ChangeMemory(
            body: command.source,
            count: command.count,
            register: command.register
        )), state: &state)
    }
}
