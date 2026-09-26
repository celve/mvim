import AppKit
import ApplicationServices
import LoomCore

/// The real `PhysicalStep` interpreter — `Sim.execute`'s impure twin, and
/// the **sole caller of `VimReducer`**: state changes happen only when
/// execution reaches a commit step the run did not abort past (or when the
/// controller routes a runtime-authored effect through `commit(_:state:)`).
///
/// Runs synchronously on the main run loop, the Loom-proven model: AX
/// writes are fast, settle polls are bounded, and blocking the tap callback
/// is precisely what serializes keys during execution.
@MainActor
public final class Executor {
    public init() {}

    private var captures: [CaptureSlot: String] = [:]

    /// What the most recent `execute()` did — the lazy write probe's raw
    /// readings, plus what the recorder needs to explain them. Only the two
    /// capability fields feed the learner. Attribution is positional: the most
    /// recent attributable step before a settle (`.setSelection` →
    /// writeSelection, `.replaceSelection` → insertText; anything else
    /// clears it), and each settle consumes it. A planner shape that ever
    /// interleaves other steps between write and settle fails toward NO
    /// evidence — never a false strike. Zero-settle plans say nothing.
    /// A settle that names a native key (`Expectation.blame`) attributes to it instead.
    /// Callers must copy this immediately after their execute: hygiene
    /// plans (cursor collapse, stranded-selection repair) reuse this
    /// executor and reset it.
    public struct RunEvidence: Equatable, Sendable {
        public internal(set) var failedCapability: Capability?
        public internal(set) var settledCapabilities: Set<Capability> = []

        /// Recorder only — the learner reads the two fields above.
        public internal(set) var abortedAt: Int?

        /// Hard and soft: a soft one rings nothing and aborts nothing, so it was invisible.
        public internal(set) var settleFailures: [SettleFailure] = []

        public init() {}
    }

    /// `answered == false` is a field that produced no attribute at all, not one that disagreed.
    public struct SettleFailure: Equatable, Sendable {
        public let hard: Bool
        public let index: Int
        public let expectation: Expectation
        public let observedSelection: Range<Int>?
        public let observedLength: Int?
        public let observedSelectedText: String?
        public let answered: Bool
        public let polls: Int
        public let milliseconds: Int
        /// Told a refused write apart from one that landed and then read back wrong.
        public let writeError: Int32?
    }

    public private(set) var lastRun = RunEvidence()

    /// From the write a following settle verifies; cleared where attribution is.
    private var lastWriteError: Int32?

    /// The selection the last settle read, which says whether a native key did anything.
    private var lastObserved: Range<Int>?
    /// Carets this run's settles kept, for `.between` landings.
    private var kept: [Int: Int] = [:]

    /// This run's last register paste, which only the settle straight after it can confirm.
    private var pastedAt: Int?

    /// The field selects in text content (Chromium rich text).
    private var paragraphs = false

    /// An `AXError` worth reporting: `.success` is not one.
    private static func rejection(_ error: AXError) -> Int32? {
        error == .success ? nil : error.rawValue
    }

    /// Returns whether it converged, so the two call sites read as they did before.
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
            observedSelectedText: outcome.observedSelectedText,
            answered: outcome.answered,
            polls: outcome.polls,
            milliseconds: outcome.milliseconds,
            writeError: lastWriteError
        ))
        return false
    }

    /// Only a caret landing, read straight after the paste, says the target has read it: an equal-length replacement
    /// (`g~j` in Chromium rich text, where the settle checks length alone) matches its length before it lands.
    private func confirmPaste(_ outcome: SettleOutcome, _ expectation: Expectation, at index: Int) {
        guard pastedAt == index - 1, outcome.converged, expectation.landing != nil else { return }
        PasteboardLoan.shared.landed()
    }

    /// Runs the plan in order, sparing residency when a step fails; returns whether every step ran.
    @discardableResult
    public func execute(
        _ plan: PhysicalPlan, on element: AXUIElement, state: inout VimState, paragraphs: Bool = false
    ) -> Bool {
        captures = [:]
        pastedAt = nil
        lastRun = RunEvidence()
        lastWriteError = nil
        lastObserved = nil
        self.paragraphs = paragraphs
        kept = [:]
        var attribution: Capability?
        for (index, next) in plan.steps.enumerated() {
            var step = next
            if case .settle(let expectation) = next { step = .settle(expectation.resolving(kept)) }
            let passed = perform(step, at: index, on: element, state: &state)
            if passed, case .settle(let expectation) = step, let slot = expectation.keeps, let caret = lastObserved?.lowerBound {
                kept[slot] = caret
            }
            switch step {
            case .setSelection:
                attribution = .writeSelection
            case .replaceSelection:
                attribution = .insertText
            case .settle(let expectation):
                if passed, let attributed = expectation.blame?.capability ?? attribution {
                    lastRun.settledCapabilities.insert(attributed)
                } else if !passed {
                    lastRun.failedCapability = expectation.blame == nil
                        ? attribution : expectation.blamed(observed: lastObserved)
                }
                attribution = nil
                lastWriteError = nil
            default:
                attribution = nil
                // The settle consumes the error; any other step ends its reach.
                lastWriteError = nil
            }
            guard passed else {
                lastRun.abortedAt = index
                // A second pass, not a `continue`: `perform` would re-post a blind keypress.
                for survivor in plan.steps[(index + 1)...] {
                    if case .commit(let effect) = survivor, effect.survivesAbort {
                        commit(effect, state: &state)
                    }
                }
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
                // write. Giving it back is the loan's, not a wait.
                PasteboardLoan.shared.put(content)
                pastedAt = index
                Synth.commandV()
            } else {
                // Registers +/* and pasteboard markers paste what the user has there, not a register still on loan.
                PasteboardLoan.shared.restore()
                Synth.commandV()
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
            let outcome = Self.settle(expectation, on: element, paragraphs: paragraphs)
            lastObserved = outcome.observedSelection
            confirmPaste(outcome, expectation, at: index)
            if record(outcome, expectation, at: index, hard: true) {
                return true
            }
            NSSound.beep()
            return false

        case .softSettle(let expectation):
            // Same poll — a following AX read still sees the blind action land
            // — but a timeout is not a failure: proceed, no bell, never abort.
            let outcome = Self.settle(expectation, on: element, paragraphs: paragraphs)
            lastObserved = outcome.observedSelection
            confirmPaste(outcome, expectation, at: index)
            _ = record(outcome, expectation, at: index, hard: false)
            return true

        case .commit(let effect):
            commit(effect, state: &state)
            return true

        case .bell:
            NSSound.beep()
            return true
        }
    }

    /// The observed values ride every exit, so a timeout costs no extra round trip.
    struct SettleOutcome {
        let converged: Bool
        let observedSelection: Range<Int>?
        let observedLength: Int?
        let observedSelectedText: String?
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
    nonisolated static func settle(_ expectation: Expectation, on element: AXUIElement, paragraphs: Bool) -> SettleOutcome {
        var names: [String] = []
        var selectionSlot: Int?
        var lengthSlot: Int?
        var textSlot: Int?
        if expectation.landing != nil {
            selectionSlot = names.count
            names.append(kAXSelectedTextRangeAttribute)
        }
        if expectation.length != nil {
            lengthSlot = names.count
            names.append(kAXNumberOfCharactersAttribute)
        }
        if expectation.selectedText != nil {
            textSlot = names.count
            names.append(kAXSelectedTextAttribute)
        }
        // An expectation that predicts nothing is already met — and must not
        // spend a round trip discovering that.
        guard !names.isEmpty else {
            return SettleOutcome(
                converged: true, observedSelection: nil, observedLength: nil, observedSelectedText: nil,
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
            // Chromium adds a U+FFFC here for each text-less leaf; the plan, read from `AXValue`, has none.
            let text = textSlot.flatMap { reads.string($0) }.map { paragraphs ? MarkerText.plain($0) : $0 }
            // Not convergence: an absent attribute is a silent app, a wrong one a liar.
            let answered = (selectionSlot == nil || selection != nil)
                && (lengthSlot == nil || length != nil)
                && (textSlot == nil || text != nil)
            func outcome(_ converged: Bool) -> SettleOutcome {
                SettleOutcome(
                    converged: converged,
                    observedSelection: selection, observedLength: length, observedSelectedText: text,
                    answered: answered, polls: polls,
                    milliseconds: Int(Date().timeIntervalSince(start) * 1000)
                )
            }
            let matched = expectation.matches(selection: selection, length: length, selectedText: text)
            if paragraphs, selectionSlot != nil, !matched || expectation.edge != nil {
                // Only the markers place a caret between elements or tell a boundary's sides apart.
                if let marked = AX.markedSelection(of: element) {
                    selection = marked.range
                    let edge = expectation.edge.map { edge in
                        Snapshotter.paragraphSide(of: marked, upper: true).map { ($0 == .end) == (edge == .paragraphEnd) } ?? false
                    } ?? true
                    if edge, expectation.matches(selection: selection, length: length, selectedText: text) {
                        return outcome(true)
                    }
                }
            } else if matched {
                return outcome(true)
            }
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
        case .pageUp: return 116
        case .pageDown: return 121
        case .delete: return 51
        case .forwardDelete: return 117
        case .enter: return 36
        case .escape: return 53
        case .character(let character):
            switch character {
            case "a": return 0    // kVK_ANSI_A (⌃A)
            case "e": return 14   // kVK_ANSI_E (⌃E)
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
