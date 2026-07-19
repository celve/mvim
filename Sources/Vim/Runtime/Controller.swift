import ApplicationServices
import LoomCore

/// The runtime loop — `Sim`'s impure twin. Wires the tap's key events
/// through monitor → planners → executor against the actually-focused
/// field, and carries the runtime lore the Sim mirrors in pure form:
/// binding + probing on focus change, dot-body bookkeeping, and the
/// insert-payload commits.
@MainActor
public final class Controller {
    public var enabled = true

    private var monitor = RawMonitor()
    private var state = VimState.initial
    private let executor = Executor()

    private var boundElement: AXUIElement?
    private var capabilities = CapabilityProfile()

    /// A mutating command that entered Insert leaves its dot body open until
    /// the session's Esc delivers the typed payload.
    private var openChange: (source: String, count: Int?, register: Register?)?

    public init() {}

    /// The `InputHub` handler: returns the consume verdict.
    public func handle(_ event: KeyEvent) -> Bool {
        guard enabled, event.kind == .keyDown else { return false }
        guard let element = AX.focusedElement(),
              FieldProber.isTextual(element),
              !AX.isSecure(element),
              AX.isEnabled(element) else {
            boundElement = nil
            return false
        }
        rebindIfNeeded(element)

        guard let token = KeyNotation.token(for: event) else { return false }

        let mode: RawMonitor.Mode
        switch state.field.mode {
        case .normal: mode = .normal
        case .visual: mode = .visual
        case .insert, .replace: mode = .insert
        }

        switch monitor.feed(token, mode: mode) {
        case .passthrough:
            return false
        case .pending, .cancelled:
            return true
        case .command(let completed):
            run(completed, on: element)
            return true
        }
    }

    /// Focus moved: probe (every rebind for now — the per-app cache arrives
    /// with the learner), drop keys-in-flight, reset field state, keep the
    /// session.
    private func rebindIfNeeded(_ element: AXUIElement) {
        if let bound = boundElement, CFEqual(bound, element) { return }
        boundElement = element
        capabilities = FieldProber.probe(element)
        monitor.reset()
        // Entry policy: fields open in Insert — typing just works, Esc
        // engages Normal. (Per-app configuration comes later.)
        state.field = VimState.Field(mode: .insert)
        openChange = nil
    }

    private func run(_ completed: RawMonitor.Completed, on element: AXUIElement) {
        let command = completed.command
        let logical = LogicalPlanner.plan(command, state: state)
        var anchor: Int?
        if case .visual(let context) = state.field.mode {
            anchor = context.anchor
        }
        let snapshot = Snapshotter.snapshot(
            of: element,
            capabilities: capabilities,
            anchor: anchor,
            cursor: state.field.cursor
        )
        let physical = PhysicalPlanner.plan(logical, snapshot: snapshot)
        let executed = executor.execute(physical, on: element, state: &state)
        guard executed else {
            // Abort hygiene: a plan that died mid-flight may leave its
            // operator selection painted, and must not record memories for
            // an edit that never happened.
            repairStrandedSelection(on: element)
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
    private func repairStrandedSelection(on element: AXUIElement) {
        guard capabilities.has(.writeSelection),
              let range = AX.selectedRange(of: element), range.length > 0 else { return }
        executor.execute(
            PhysicalPlan(.setSelection(range.location..<range.location)),
            on: element,
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
