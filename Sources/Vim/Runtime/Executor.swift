import AppKit
import ApplicationServices
import Core

/// The real `PhysicalStep` interpreter — `Sim.execute`'s impure twin, and
/// the **sole caller of `VimReducer`**: state changes happen only when
/// execution reaches a commit step the run did not abort past (or when the
/// controller routes a runtime-authored effect through `commit(_:state:)`).
///
/// Runs synchronously on the main run loop: AX writes are fast, settle polls
/// are bounded, and blocking the tap callback is precisely what serializes
/// keys during execution.
@MainActor
public final class Executor {
    public init() {}

    private var captures: [CaptureSlot: String] = [:]

    /// Copy it right after `execute()`: hygiene plans reuse this executor and reset it.
    public struct RunEvidence: Equatable, Sendable {
        public internal(set) var attribution = RunAttribution()

        public var failedCapability: Capability? {
            attribution.evidence.first { $0.outcome == .refutes }?.question.capability
        }
        public var settledCapabilities: Set<Capability> {
            Set(attribution.evidence.compactMap { $0.outcome == .supports(nil) ? $0.question.capability : nil })
        }

        /// Recorder only.
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

    /// That paste was in Chromium's rich text, where a settle after it that predicts nothing waits for it to land.
    private var pasteWaits = false

    /// The caret the paste began at, when it read as one.
    private var pastedFrom: (range: Range<Int>, side: ParagraphBreaks.Side?)?

    /// Settles straight after a ⇧← → that keeps a caret outside a code span, whose target showed before those two keys.
    private var afterNormalizing: Set<Int> = []

    /// The field selects in text content (Chromium rich text).
    private var paragraphs = false

    /// Keys pressed since the last settle.
    private var pressed = 0

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

    /// Pastes land up to 250 ms late: a settle after one that predicts nothing waits for the caret to stay off its start.
    private func awaitPaste(_ expectation: Expectation, at index: Int, on element: AXUIElement) {
        guard pastedAt == index - 1, pasteWaits, expectation.landing == nil, expectation.length == nil,
              expectation.selectedText == nil else { return }
        let deadline = Date().addingTimeInterval(0.25)
        var moved = 0
        while Date() < deadline {
            // A caret Linear draws beside code reads as a selection, or elsewhere, for a moment, which is no landing.
            if let from = pastedFrom, let marked = Snapshotter.markedSelection(of: element), marked.isCollapsed,
               marked.range != from.range || Snapshotter.paragraphSide(of: marked, upper: true) != from.side {
                moved += 1
                if moved == 2 { return }
            } else {
                moved = 0
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Only a caret landing straight after the paste proves the target read it: a length can match before it lands.
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
        pasteWaits = false
        pastedFrom = nil
        lastRun = RunEvidence()
        lastWriteError = nil
        lastObserved = nil
        self.paragraphs = paragraphs
        pressed = 0
        kept = [:]
        let outside: [PhysicalStep] = [.press(.selectLeft, count: 1), .press(.right, count: 1)]
        afterNormalizing = Set(plan.steps.indices.filter { $0 >= 2 && Array(plan.steps[$0 - 2..<$0]) == outside })
        for (index, next) in plan.steps.enumerated() {
            var step = next
            if case .settle(let expectation) = next { step = .settle(expectation.resolving(kept)) }
            let passed = perform(step, at: index, on: element, state: &state)
            if passed, case .settle(let expectation) = step, let slot = expectation.keeps, let caret = lastObserved?.lowerBound {
                kept[slot] = caret
            }
            let failure = passed ? nil : lastRun.settleFailures.last
            lastRun.attribution.record(
                step, passed: passed, selection: lastObserved, length: failure?.observedLength,
                selectedText: failure?.observedSelectedText
            )
            switch step {
            case .setSelection, .replaceSelection:
                break
            default:
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
            pressed += count
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
                // No sleep before ⌘V: the app reads the pasteboard only as it handles the ⌘V, queued after the write.
                PasteboardLoan.shared.put(content)
                pastedAt = index
                pasteWaits = paragraphs
                pastedFrom = paragraphs ? Snapshotter.markedSelection(of: element).flatMap {
                    $0.isCollapsed ? ($0.range, Snapshotter.paragraphSide(of: $0, upper: true)) : nil
                } : nil
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
            awaitPaste(expectation, at: index, on: element)
            var outcome = Self.settle(expectation, on: element, paragraphs: paragraphs, presses: pressed)
            pressed = 0
            if outcome.converged, afterNormalizing.contains(index) {
                // Read again once the ⇧← → are in, so the next command never reads the selection between them.
                Thread.sleep(forTimeInterval: 0.015)
                outcome = Self.settle(expectation, on: element, paragraphs: paragraphs)
            }
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
            awaitPaste(expectation, at: index, on: element)
            let outcome = Self.settle(expectation, on: element, paragraphs: paragraphs, presses: pressed)
            pressed = 0
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
    /// document dozens of times per settle.
    nonisolated static func settle(
        _ expectation: Expectation, on element: AXUIElement, paragraphs: Bool, presses: Int = 0
    ) -> SettleOutcome {
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
        // Chromium applies a long run of shifted arrows more slowly than mvim sends it, so the wait grows with the run.
        let deadline = start.addingTimeInterval(0.25 + (paragraphs ? 0.0025 * Double(presses) : 0))
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
            // Chromium adds a U+FFFC here for each text-less leaf, which `Expectation.matches` looks past.
            let text = textSlot.flatMap { reads.string($0) }
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
            if expectation.converged(selection: selection, length: length, selectedText: text, side: nil) {
                return outcome(true)
            }
            // Only the markers place a caret between elements or tell a boundary's sides apart.
            if paragraphs, selectionSlot != nil, let marked = Snapshotter.markedSelection(of: element) {
                selection = marked.range
                let side = expectation.edge == nil ? nil : Snapshotter.paragraphSide(of: marked, upper: true)
                if expectation.converged(selection: selection, length: length, selectedText: text, side: side) {
                    return outcome(true)
                }
                // The caret Linear draws at a code span's edge is lines of its own, which no expected length counts.
                if let expected = expectation.length, let observed = length, (1...2).contains(observed - expected),
                   expectation.converged(selection: selection, length: observed - Snapshotter.drawnLength(at: marked),
                                         selectedText: text, side: side) {
                    return outcome(true)
                }
            }
            guard Date() < deadline else { return outcome(false) }
            // In the rich-text fields measured, a missed poll cost the host ~0.5 ms of CPU on average (LIN-1727).
            Thread.sleep(forTimeInterval: 0.003)
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
