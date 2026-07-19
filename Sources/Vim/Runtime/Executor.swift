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

    /// Capability evidence from the most recent `execute()` — the lazy
    /// write probe's raw readings. Attribution is positional: the most
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

        public init() {}
    }

    public private(set) var lastRun = RunEvidence()

    /// Runs the plan in order; a failed settle (or unrealizable step) rings
    /// and aborts the remainder. Returns whether every step ran.
    @discardableResult
    public func execute(_ plan: PhysicalPlan, on element: AXUIElement, state: inout VimState) -> Bool {
        captures = [:]
        lastRun = RunEvidence()
        var attribution: Capability?
        for step in plan.steps {
            let passed = perform(step, on: element, state: &state)
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
            default:
                attribution = nil
            }
            guard passed else { return false }
        }
        return true
    }

    /// Runtime-authored effects (insert payloads, dot bodies) enter through
    /// the executor too, so the reducer keeps exactly one caller.
    public func commit(_ effect: VimEffect, state: inout VimState) {
        state = VimReducer.reduce(state, effect, captures: captures)
    }

    // MARK: - Steps

    private func perform(_ step: PhysicalStep, on element: AXUIElement, state: inout VimState) -> Bool {
        switch step {
        case .setSelection(let range):
            AX.setSelectedRange(CFRange(location: range.lowerBound, length: range.count), on: element)
            return true

        case .replaceSelection(let replacement):
            AX.setSelectedText(replacement, on: element)
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
            if settle(expectation, on: element) { return true }
            NSSound.beep()
            return false

        case .commit(let effect):
            commit(effect, state: &state)
            return true

        case .bell:
            NSSound.beep()
            return true
        }
    }

    /// Bounded convergence poll against the planner's prediction.
    private func settle(_ expectation: Expectation, on element: AXUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(0.25)
        while true {
            var converged = true
            if let expected = expectation.selection {
                if let range = AX.selectedRange(of: element) {
                    converged = converged && (range.location..<(range.location + range.length)) == expected
                } else {
                    converged = false
                }
            }
            if let expectedLength = expectation.length {
                let length = AX.length(of: element) ?? AX.value(of: element).map { $0.utf16.count }
                converged = converged && length == expectedLength
            }
            if converged { return true }
            guard Date() < deadline else { return false }
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
