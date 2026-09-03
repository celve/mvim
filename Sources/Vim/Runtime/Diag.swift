import Foundation
import LoomCore
import os

/// Norm's flight recorder: the decision log the probe-and-learn system never
/// had.
///
/// The unit of record is **one command's decision**, not one keystroke. Norm's
/// central bet is that it cannot predict what a field will do, so it probes,
/// verifies and remembers — and until this existed that bet was unfalsifiable,
/// because a field that lied and a learner that drew the wrong conclusion from
/// the lie both went unrecorded. What a reader wants back is "the engine
/// believed X about this field, and X was false".
///
/// **Retrieval**, from a machine nobody is sitting at:
///
///     log show --predicate 'subsystem == "com.loom.Norm"' --last 1h --info --debug
///     log collect --last 2h --output norm.logarchive
///
/// A command that did not fully succeed logs at `.default` and is persisted to
/// disk for free — surviving the quit that a stranded user is about to
/// perform, which is what rules out an in-memory ring. A clean command logs at
/// `.debug`, off unless someone asks for it:
///
///     sudo log config --subsystem com.loom.Norm --mode "level:debug,persist:debug"
///     sudo log config --subsystem com.loom.Norm --mode "level:default"   # off again
///
/// **Promptness.** `InputHub`'s contract forbids work on the per-keystroke
/// path. The invariant, checkable by grep: no `Diag.` call appears in
/// `Controller.handle` outside the `case .command` arm. Everything here is on
/// the command path, which already spends up to 250ms in `Executor.settle` by
/// design; the clean-path `.debug` line is additionally guarded by
/// `isEnabled`, so its render never runs when nobody is listening.
///
/// **Privacy.** `Trace` cannot emit a text payload at all — that rule is a
/// unit test, not a convention. This type may emit more, and only under an
/// opt-in the menu does not offer and every bind announces.
enum Diag {
    static let bind = Logger(subsystem: Log.subsystem, category: "bind")
    static let cmd = Logger(subsystem: Log.subsystem, category: "cmd")
    static let settle = Logger(subsystem: Log.subsystem, category: "settle")
    static let learn = Logger(subsystem: Log.subsystem, category: "learn")
    static let gate = Logger(subsystem: Log.subsystem, category: "gate")

    /// The same category as `cmd`, kept only for `isEnabled`: `Logger` has no
    /// such query, and a clean command must not pay to render a line nobody
    /// asked for.
    private static let cmdLevel = OSLog(subsystem: Log.subsystem, category: "cmd")

    static let recordsTextKey = "normRecordText"

    /// Whether to record field content — text, DOM identifiers, insert
    /// payloads. Off, undiscoverable from the menu, and read once per process:
    ///
    ///     defaults write com.loom.Norm normRecordText -bool YES
    ///
    /// Field text is the user's mail and messages. It is occasionally the only
    /// way to explain a `TextModel` disagreement, which is why the switch
    /// exists — and why every bind says so out loud while it is on.
    static let recordsText = UserDefaults.standard.bool(forKey: recordsTextKey)

    // MARK: - Binding

    /// One binding published. `epoch` is the binding's identity; every command
    /// line below carries it, so `grep 'e12\\.'` is the whole join.
    static func bind(_ epoch: UInt64, _ transition: FocusTransition, _ binding: FocusTracker.Binding?) {
        guard let binding else {
            self.bind.log("e\(epoch, privacy: .public) unbound \(Trace.name(transition), privacy: .public)")
            return
        }
        var line = "e\(epoch) \(Trace.name(transition))"
        line += " forced=\(binding.isForced ? 1 : 0) overlay=\(binding.isOverlay ? 1 : 0)"
        // nil is the signal, not a gap: the learner keys on this rung and can
        // conclude nothing at all without one.
        line += " rung=\(binding.surface.roleRung ?? "nil")"
        line += " ver=\(binding.appVersion ?? "nil")"
        if let report = binding.capabilityReport {
            line += " caps=\(Trace.caps(report))"
        }
        if recordsText, let identifier = binding.surface.identifier {
            line += " id=\(identifier)"
        }
        self.bind.log("\(line, privacy: .public)")
        if recordsText {
            self.bind.log("TEXT RECORDING ON — defaults delete com.loom.Norm \(recordsTextKey, privacy: .public)")
        }
    }

    // MARK: - Commands

    /// One command's whole decision. The anchor event: everything else joins
    /// to it through `e<epoch>.c<seq>`.
    ///
    /// `steps` is the ordered, payload-free plan — see `Trace` for the
    /// alphabet. Order is what distinguishes the two shapes of a stranded
    /// mode: a `!` after an `R` is a claimed AX write that did not land, and a
    /// `!` after a `P` is a hard settle behind a blind actuation, which can
    /// never name a capability and so teaches the learner nothing.
    static func command(
        _ epoch: UInt64, _ seq: UInt64,
        command: RawCommand,
        from before: VimState.Mode?, to after: VimState.Mode?,
        plan: PhysicalPlan,
        rejection: PhysicalPlanner.Rejection?,
        bell: LogicalStep.BellReason?,
        executed: Bool,
        evidence: Executor.RunEvidence,
        insertPayload: String?
    ) {
        let anomalous = !executed
            || rejection != nil
            || bell != nil
            || evidence.failedCapability != nil
            || !evidence.settleFailures.isEmpty
        guard anomalous || cmdLevel.isEnabled(type: .debug) else { return }

        let tag = "e\(epoch).c\(seq)"
        var line = "\(tag) keys=\(Trace.keys(command))"
        line += " mode=\(Trace.name(before))→\(Trace.name(after))"
        line += " steps=\(Trace.shape(plan).isEmpty ? "-" : Trace.shape(plan))"
        if let rejection {
            line += " reject=\(Trace.name(rejection.step))@\(rejection.index)"
        }
        if let bell {
            line += " bell=\(Trace.name(bell))"
        }
        if let abortedAt = evidence.abortedAt {
            line += " abort@\(abortedAt)"
        }
        line += " ok=\(executed ? 1 : 0)"
        line += " fail=\(evidence.failedCapability.map(Trace.name) ?? "nil")"
        line += " settled=\(Trace.names(evidence.settledCapabilities))"
        if let insertPayload {
            line += recordsText ? " insert=\(insertPayload)" : " insert=(\(insertPayload.utf16.count))"
        }
        if anomalous {
            cmd.log("\(line, privacy: .public)")
        } else {
            cmd.debug("\(line, privacy: .public)")
        }

        for failure in evidence.settleFailures {
            settleFailed(tag, failure)
        }
    }

    /// A settle that did not converge — including the soft ones, which ring
    /// nothing and abort nothing and were until now invisible everywhere.
    private static func settleFailed(_ tag: String, _ failure: Executor.SettleFailure) {
        var line = "\(tag) \(failure.hard ? "FAIL" : "soft")@\(failure.index)"
        line += " want sel=\(Trace.range(failure.expectation.selection))"
        line += " len=\(Trace.optional(failure.expectation.length))"
        line += " got sel=\(Trace.range(failure.observedSelection))"
        line += " len=\(Trace.optional(failure.observedLength))"
        // The distinction the executor used to collapse: a field that answered
        // something else, versus one that would not answer at all.
        line += " answered=\(failure.answered ? 1 : 0)"
        line += " polls=\(failure.polls) ms=\(failure.milliseconds)"
        if let error = failure.writeError {
            line += " axerror=\(error)"
        }
        settle.log("\(line, privacy: .public)")
    }

    // MARK: - The learner

    static func learned(_ epoch: UInt64, _ seq: UInt64, rung: String, version: String?, capability: Capability) {
        learn.log("""
            e\(epoch, privacy: .public).c\(seq, privacy: .public) commit \
            rung=\(rung, privacy: .public) cap=\(Trace.name(capability), privacy: .public) \
            ver=\(version ?? "nil", privacy: .public) → republish
            """)
    }

    /// A command that produced evidence the learner then declined to use. Each
    /// reason is a way the probe-and-learn system can be silently inert.
    static func notLearned(_ epoch: UInt64, _ seq: UInt64, reason: String, failed: Capability?) {
        learn.log("""
            e\(epoch, privacy: .public).c\(seq, privacy: .public) skip=\(reason, privacy: .public) \
            fail=\(failed.map(Trace.name) ?? "nil", privacy: .public)
            """)
    }

    // MARK: - The gate

    /// Why an element did not become a binding. `FieldProber.gate` computes
    /// all three of these and the tracker used to drop them, so "Norm just
    /// doesn't work in this app" produced no signal of any kind.
    static func denied(_ epoch: UInt64, _ gate: FieldProber.FieldGate, fresh: Bool) {
        self.gate.log("""
            e\(epoch, privacy: .public) deny \(fresh ? "fresh" : "bound", privacy: .public) \
            textual=\(gate.isTextual ? 1 : 0, privacy: .public) \
            secure=\(gate.isSecure ? 1 : 0, privacy: .public) \
            enabled=\(gate.isEnabled ? 1 : 0, privacy: .public) \
            role=\(gate.role ?? "nil", privacy: .public)
            """)
    }

    /// The bound element short-circuited a resolve without re-probing. Every
    /// AX notification, activation and keydown resolve takes this exit, so a
    /// field that changes what it can do mid-session is never noticed.
    static func shortCircuited(_ epoch: UInt64) {
        gate.debug("e\(epoch, privacy: .public) short-circuit same-element revalidate=0")
    }

    /// A web field whose origin did not resolve. It is now keyed as though it
    /// were native, which merges a page's fields with the browser's own
    /// chrome at the rung the learner writes to.
    static func originLost(_ epoch: UInt64, role: String?) {
        gate.log("""
            e\(epoch, privacy: .public) surface origin=nil web=1 \
            role=\(role ?? "nil", privacy: .public)
            """)
    }
}
