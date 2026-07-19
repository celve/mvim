/// A state commit: the only way `VimState` changes.
///
/// Effects ride inside plans as `commit` steps — authored by the logical
/// planner when only raw intent can decide them (`fx` writes the find
/// memory, `;` must not), and by the physical planner when payloads need
/// offsets or captures. The executor hands each one it *passes* to the
/// reducer, capture slots resolved to literals; steps after a failed settle
/// never run, so state tracks what actually happened to the field.
public enum VimEffect: Equatable, Sendable {
    case setMode(VimState.Mode)

    /// Where the Insert/Replace session began; nil when the caret was
    /// unreadable. Becomes mark `^` and drives `gi`.
    case setInsertStart(Int?)

    case searched(VimState.SearchMemory)
    case found(VimState.FindMemory)

    /// Text typed during the Insert session that just ended — the monitor's
    /// payload, committed by the runtime at Esc.
    case setLastInsert(String)

    /// The dot body. Authored by the runtime (keys are its currency), never
    /// by a planner.
    case setLastChange(VimState.ChangeMemory)

    /// The `gv` memory, recorded when Visual mode is left.
    case setLastVisual(VisualMemory)

    /// The drawn Normal-mode block cursor (nil = bare caret). Authored by
    /// the physical planner's `renderCursor` lowering.
    case setCursor(Range<Int>?)

    /// Register routing (unnamed mirror, delete ring, uppercase append) is
    /// the reducer's; the effect carries only what the user named.
    case deleted(into: Register?, content: TextPayload, wise: Wise)
    case yanked(into: Register?, content: TextPayload, wise: Wise)

    case setMark(Character, MarkPoint)
}

/// Register-bound text that may only exist mid-execution: known at plan
/// time, or captured by a clipboard/AX read step and resolved when the
/// commit step runs.
public enum TextPayload: Equatable, Sendable {
    case literal(String)
    case captured(CaptureSlot)
}

/// A runtime-filled value reference: capture steps write it, commit steps
/// read it. Allocated per plan, starting at zero.
public struct CaptureSlot: Equatable, Hashable, Sendable {
    public let id: Int

    public init(id: Int) {
        self.id = id
    }
}
