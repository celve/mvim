import AppKit
import ApplicationServices
import LoomCore

/// The real `PhysicalStep` interpreter — `Sim.execute`'s impure twin, and
/// the **sole caller of `VimReducer`**: state changes happen only when
/// execution passes a commit step (or when the controller routes a
/// runtime-authored effect through `commit(_:state:)`).
///
/// Runs synchronously on the main run loop, the Loom-proven model: AX
/// writes are fast, settle polls are bounded, and blocking the tap callback
/// is precisely what serializes keys during execution.
@MainActor
public final class Executor {
    public init() {}

    /// How long a literal clipboard insert keeps its transient content
    /// before the saved string is restored (guarded by changeCount).
    private static let restoreDelay: TimeInterval = 0.2

    private var captures: [CaptureSlot: String] = [:]

    /// What the most recent `execute()` did — the lazy write probe's raw
    /// readings, plus what the recorder needs to explain them. Only the two
    /// capability fields feed the learner. Attribution is positional: the most
    /// recent attributable step before a settle (`.setSelection` →
    /// writeSelection, `.replaceSelection` → insertText; anything else
    /// clears it), and each settle consumes it. A planner shape that ever
    /// interleaves other steps between write and settle fails toward NO
    /// evidence — never a false strike. Zero-settle plans say nothing.
    /// Callers must copy this immediately after their execute: hygiene
    /// plans (cursor collapse, stranded-selection repair) reuse this
    /// executor and reset it.
    public struct RunEvidence: Equatable, Sendable {
        public internal(set) var failedCapability: Capability?
        public internal(set) var settledCapabilities: Set<Capability> = []

        /// Which step `execute` stopped on, when it stopped early. Recorder
        /// only — the learner reads the two fields above.
        public internal(set) var abortedAt: Int?

        /// Every settle that did not converge, **hard and soft**. A soft one
        /// is the class of failure that is otherwise invisible: it neither
        /// rings nor aborts, and its attribution is already cleared, so
        /// nothing downstream would ever hear about it.
        public internal(set) var settleFailures: [SettleFailure] = []

        public init() {}
    }

    /// What a settle saw when it gave up — the prediction, and what the field
    /// answered instead.
    ///
    /// `answered == false` means the field did not produce the attribute at
    /// all (unreadable, or an AX error `AX.attributes` resolved to nil). That
    /// is a different failure from disagreeing about the value, and until this
    /// existed the two were the same bare `false`.
    public struct SettleFailure: Equatable, Sendable {
        public let hard: Bool
        public let index: Int
        public let expectation: Expectation
        public let observedSelection: Range<Int>?
        public let observedLength: Int?
        public let answered: Bool
        public let polls: Int
        public let milliseconds: Int
        /// The `AXError` from the write this settle is verifying, when it was
        /// not `.success`. `AX` hands it back for exactly this and the
        /// executor used to drop it, so "the app refused the write" and "the
        /// write landed but the read-back disagrees" were indistinguishable.
        public let writeError: Int32?
    }

    public private(set) var lastRun = RunEvidence()

    /// The rejection from the write a following settle verifies, if any. Reset
    /// per run and cleared by any step that ends attribution's reach.
    private var lastWriteError: Int32?

    /// An `AXError` worth reporting: `.success` is not one.
    private static func rejection(_ error: AXError) -> Int32? {
        error == .success ? nil : error.rawValue
    }

    /// Fold one settle's reading into the run's evidence. Returns whether it
    /// converged, so the two call sites read as they did before.
    @discardableResult
    private func record(
        _ outcome: SettleOutcome, _ expectation: Expectation, at index: Int, hard: Bool
    ) -> Bool {
        guard !outcome.converged else { return true }
        lastRun.settleFailures.append(SettleFailure(
            hard: hard,
            index: index,
            expectation: expectation,
            observedSelection: outcome.observedSelection,
            observedLength: outcome.observedLength,
            answered: outcome.answered,
            polls: outcome.polls,
            milliseconds: outcome.milliseconds,
            writeError: lastWriteError
        ))
        return false
    }

    /// Runs the plan in order; a failed settle (or unrealizable step) rings
    /// and aborts the remainder. Returns whether every step ran.
    @discardableResult
    public func execute(_ plan: PhysicalPlan, on element: AXUIElement, state: inout VimState) -> Bool {
        captures = [:]
        lastRun = RunEvidence()
        lastWriteError = nil
        var attribution: Capability?
        for (index, step) in plan.steps.enumerated() {
            let passed = perform(step, at: index, on: element, state: &state)
            switch step {
            case .setSelection:
                attribution = .writeSelection
            case .replaceSelection:
                attribution = .insertText
            case .settle:
                if passed, let attributed = attribution {
                    lastRun.settledCapabilities.insert(attributed)
                } else if !passed {
                    lastRun.failedCapability = attribution
                }
                attribution = nil
                lastWriteError = nil
            default:
                attribution = nil
                // The error belongs to the write a settle verifies, so the
                // settle consumes it and any other step ends its reach —
                // exactly as both do for attribution.
                lastWriteError = nil
            }
            guard passed else {
                lastRun.abortedAt = index
                return false
            }
        }
        return true
    }

    /// Runtime-authored effects (insert payloads, dot bodies) enter through
    /// the executor too, so the reducer keeps exactly one caller.
    public func commit(_ effect: VimEffect, state: inout VimState) {
        state = VimReducer.reduce(state, effect, captures: captures)
    }

    // MARK: - Steps

    private func perform(
        _ step: PhysicalStep, at index: Int, on element: AXUIElement, state: inout VimState
    ) -> Bool {
        switch step {
        case .setSelection(let range):
            lastWriteError = Self.rejection(
                AX.setSelectedRange(CFRange(location: range.lowerBound, length: range.count), on: element)
            )
            return true

        case .replaceSelection(let replacement):
            lastWriteError = Self.rejection(AX.setSelectedText(replacement, on: element))
            return true

        case .press(let chord, let count):
            guard let code = keyCode(for: chord.key) else {
                NSSound.beep()
                return false
            }
            Synth.key(code, flags(for: chord.modifiers), times: count)
            return true

        case .typeText(let text):
            Synth.type(text)
            return true

        case .clipboardCut:
            // The pasteboard IS the register (clipboard=unnamed): post the
            // cut and move on — nothing read back, silence on failure.
            Synth.key(7, .maskCommand)   // kVK_ANSI_X
            return true

        case .clipboardCopy:
            Synth.key(8, .maskCommand)   // kVK_ANSI_C
            return true

        case .clipboardInsert(let content):
            if let content {
                // Set → ⌘V → return. No pre-⌘V sleep: setString is
                // synchronous, and the app reads the pasteboard only when IT
                // processes the ⌘V, which the event queue orders after the
                // write. The restore is deferred hygiene, not a wait.
                let pasteboard = NSPasteboard.general
                let saved = pasteboard.string(forType: .string)
                pasteboard.clearContents()
                pasteboard.setString(content, forType: .string)
                let stamp = pasteboard.changeCount
                Synth.commandV()
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay) {
                    let pasteboard = NSPasteboard.general
                    // Newer owner (a blind cut, a user ⌘C) wins: only ever
                    // decline to write, never clobber.
                    guard pasteboard.changeCount == stamp else { return }
                    pasteboard.clearContents()
                    if let saved { pasteboard.setString(saved, forType: .string) }
                }
            } else {
                Synth.commandV()   // registers +/* and pasteboard markers: paste as-is
            }
            return true

        case .captureSelectedText(let slot):
            guard let text = AX.selectedText(of: element) else {
                NSSound.beep()
                return false
            }
            captures[slot] = text
            return true

        case .settle(let expectation):
            if record(settle(expectation, on: element), expectation, at: index, hard: true) {
                return true
            }
            NSSound.beep()
            return false

        case .softSettle(let expectation):
            // Same poll — a following AX read still sees the blind action land
            // — but a timeout is not a failure: proceed, no bell, never abort.
            _ = record(settle(expectation, on: element), expectation, at: index, hard: false)
            return true

        case .commit(let effect):
            commit(effect, state: &state)
            return true

        case .bell:
            NSSound.beep()
            return true
        }
    }

    /// One settle's reading. The observed values ride along on every exit so
    /// a timeout can say what the field answered — they are already in hand,
    /// so reporting them costs no extra round trip.
    private struct SettleOutcome {
        let converged: Bool
        let observedSelection: Range<Int>?
        let observedLength: Int?
        let answered: Bool
        let polls: Int
        let milliseconds: Int
    }

    /// Bounded convergence poll against the planner's prediction.
    ///
    /// One IPC per poll: the attribute list is built from what the
    /// expectation actually asks about, so a selection-only settle never
    /// reads length. `kAXValue` deliberately stays OUT of the batch — it is
    /// the rare fallback for an element that claimed `readLength` and then
    /// answered nil, and fetching it every poll would marshal the entire
    /// document 25 times per settle.
    private func settle(_ expectation: Expectation, on element: AXUIElement) -> SettleOutcome {
        var names: [String] = []
        var selectionSlot: Int?
        var lengthSlot: Int?
        if expectation.selection != nil {
            selectionSlot = names.count
            names.append(kAXSelectedTextRangeAttribute)
        }
        if expectation.length != nil {
            lengthSlot = names.count
            names.append(kAXNumberOfCharactersAttribute)
        }
        // An expectation that predicts nothing is already met — and must not
        // spend a round trip discovering that.
        guard !names.isEmpty else {
            return SettleOutcome(
                converged: true, observedSelection: nil, observedLength: nil,
                answered: true, polls: 0, milliseconds: 0
            )
        }

        let start = Date()
        let deadline = start.addingTimeInterval(0.25)
        var polls = 0
        while true {
            polls += 1
            let reads = AX.attributes(names, of: element)
            var selection: Range<Int>?
            var length: Int?
            if let slot = selectionSlot, let range = reads.range(slot) {
                selection = range.location..<(range.location + range.length)
            }
            if let slot = lengthSlot {
                length = reads.int(slot) ?? AX.value(of: element).map { $0.utf16.count }
            }
            // Not the same question as convergence: an attribute the field
            // never produced is a silent app, where a wrong value is a lying
            // one, and the learner should eventually tell them apart.
            let answered = (selectionSlot == nil || selection != nil)
                && (lengthSlot == nil || length != nil)
            func outcome(_ converged: Bool) -> SettleOutcome {
                SettleOutcome(
                    converged: converged,
                    observedSelection: selection, observedLength: length,
                    answered: answered, polls: polls,
                    milliseconds: Int(Date().timeIntervalSince(start) * 1000)
                )
            }
            if expectation.matches(selection: selection, length: length) { return outcome(true) }
            guard Date() < deadline else { return outcome(false) }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    // MARK: - Chord lowering (symbolic → hardware)

    private func keyCode(for key: Key) -> CGKeyCode? {
        switch key {
        case .arrowLeft: return 123
        case .arrowRight: return 124
        case .arrowDown: return 125
        case .arrowUp: return 126
        case .delete: return 51
        case .forwardDelete: return 117
        case .enter: return 36
        case .escape: return 53
        case .character(let character):
            switch character {
            case "z": return 6    // kVK_ANSI_Z (undo/redo)
            case "v": return 9    // kVK_ANSI_V
            default: return nil
            }
        }
    }

    private func flags(for modifiers: Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }
}
