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
        tracker.onRebind = { [weak self] binding in self?.rebind(to: binding) }
        tracker.start()
    }

    /// The disable list changed (menu toggle): re-evaluate the binding now.
    public func refreshPolicy() {
        tracker.refreshPolicy()
    }

    /// The `InputHub` handler: returns the consume verdict. Zero AX on the
    /// steady paths (insert typing, unbound apps, ⌘-chords); one bounded
    /// resolve on Esc and one verify before running a completed command.
    public func handle(_ event: KeyEvent) -> Bool {
        guard enabled, event.kind == .keyDown else { return false }
        guard let token = KeyNotation.token(for: event) else { return false }

        // ⌃[ is the mode-engaging key — the one keystroke where a stale
        // binding has teeth. Rate-limited full re-check (secure/enabled too).
        // Physical Esc never gets here: KeyNotation returns nil for it.
        if token == "<C-[>" { tracker.reverify() }

        guard let binding = tracker.bindingForKeydown() else { return false }

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
                guard let focused = AX.focusedElement(), CFEqual(focused, binding.element) else {
                    tracker.reverify(force: true)
                    return false
                }
            }
            run(completed, on: binding)
            return true
        }
    }

    /// Focus moved (tracker event): drop keys-in-flight, reset field state,
    /// keep the session — and un-draw the block cursor the departing field
    /// may still be showing.
    private func rebind(to new: FocusTracker.Binding?) {
        if let old = binding, let cursor = state.field.cursor,
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
        monitor.reset()
        // Entry policy: fields open in Insert — typing just works, Esc
        // engages Normal. (Per-app entry policy comes later.)
        state.field = VimState.Field(mode: .insert)
        openChange = nil
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
