import Core
import Foundation
import os

/// One line per command decision; no call sits on `InputHub`'s per-keystroke path.
enum Diag {
    static let bind = Logger(subsystem: Log.subsystem, category: "bind")
    static let cmd = Logger(subsystem: Log.subsystem, category: "cmd")
    static let settle = Logger(subsystem: Log.subsystem, category: "settle")
    static let learn = Logger(subsystem: Log.subsystem, category: "learn")
    static let gate = Logger(subsystem: Log.subsystem, category: "gate")

    /// Kept only for `isEnabled`, which `Logger` does not have.
    private static let cmdLevel = OSLog(subsystem: Log.subsystem, category: "cmd")
    private static let gateLevel = OSLog(subsystem: Log.subsystem, category: "gate")

    static let recordsTextKey = "mvimRecordText"

    /// Records field content; read once per process, so both edges need a relaunch.
    static let recordsText = UserDefaults.standard.bool(forKey: recordsTextKey)

    // MARK: - Binding

    /// `epoch` is the binding's identity; every line below carries it.
    static func bind(_ epoch: UInt64, _ transition: FocusTransition, _ binding: FocusTracker.Binding?) {
        guard let binding else {
            self.bind.log("e\(epoch, privacy: .public) unbound \(transition.traceName, privacy: .public)")
            return
        }
        var line = "e\(epoch) \(transition.traceName)"
        line += " forced=\(binding.isForced ? 1 : 0) overlay=\(binding.isOverlay ? 1 : 0)"
        // nil is the signal: the learner keys on this rung and needs one.
        line += " rung=\(binding.surface.roleRung ?? "nil")"
        line += " ver=\(binding.versions.app ?? "nil")"
        if let engine = binding.versions.engine {
            line += " engine=\(engine)"
        }
        if let report = binding.capabilityReport {
            line += " caps=\(report.traceGrid)"
        }
        if let beliefs = binding.beliefs {
            line += " offsets=\(beliefs.readModel.traceName)"
        }
        if binding.isChromium {
            line += " chromium=1"
        }
        if recordsText, let identifier = binding.surface.identifier {
            line += " id=\(identifier)"
        }
        self.bind.log("\(line, privacy: .public)")
        for belief in binding.beliefs?.traceLines ?? [] {
            self.bind.log("e\(epoch, privacy: .public) \(belief, privacy: .public)")
        }
        if recordsText {
            self.bind.log("""
                TEXT RECORDING ON — to stop: defaults delete com.loom.mvim \
                \(recordsTextKey, privacy: .public), then RELAUNCH mvim (read once per process)
                """)
        }
    }

    // MARK: - Commands

    /// The anchor event — everything else joins to it through `e<epoch>.c<seq>`.
    static func command(
        _ epoch: UInt64, _ seq: UInt64,
        command: RawCommand,
        from before: VimState.Mode?, to after: VimState.Mode?,
        plan: PhysicalPlan,
        rejection: PhysicalPlanner.Rejection?,
        bell: LogicalStep.BellReason?,
        executed: Bool,
        evidence: Executor.RunEvidence,
        insertPayload: String?,
        emptyLines: Int = 0
    ) {
        let anomalous = !executed
            || rejection != nil
            || bell != nil
            || evidence.failedCapability != nil
            || !evidence.settleFailures.isEmpty
        guard anomalous || cmdLevel.isEnabled(type: .debug) else { return }

        let tag = "e\(epoch).c\(seq)"
        var line = "\(tag) keys=\(command.traceKeys)"
        line += " mode=\(before.traceName)→\(after.traceName)"
        line += " steps=\(plan.traceShape.isEmpty ? "-" : plan.traceShape)"
        if let rejection {
            line += " reject=\(rejection.step.traceName)@\(rejection.index)"
        }
        if let bell {
            line += " bell=\(bell.traceName)"
        }
        if let abortedAt = evidence.abortedAt {
            line += " abort@\(abortedAt)"
        }
        line += " ok=\(executed ? 1 : 0)"
        line += " fail=\(evidence.failedCapability?.traceName ?? "nil")"
        line += " settled=\(evidence.settledCapabilities.traceNames)"
        if emptyLines != 0 {
            line += " empty=\(emptyLines)"
        }
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

    /// Includes the soft ones, which ring nothing, abort nothing and were invisible.
    private static func settleFailed(_ tag: String, _ failure: Executor.SettleFailure) {
        var line = "\(tag) \(failure.hard ? "FAIL" : "soft")@\(failure.index)"
        line += " want \(failure.expectation.traceFields(text: recordsText))"
        let observed = Expectation(
            selection: failure.observedSelection, length: failure.observedLength,
            selectedText: failure.observedSelectedText
        )
        line += " got \(observed.traceFields(text: recordsText))"
        // A field that answered something else, versus one that would not answer.
        line += " answered=\(failure.answered ? 1 : 0)"
        line += " polls=\(failure.polls) ms=\(failure.milliseconds)"
        if let error = failure.writeError {
            line += " axerror=\(error)"
        }
        settle.log("\(line, privacy: .public)")
    }

    // MARK: - The learner

    static func learned(_ epoch: UInt64, _ seq: UInt64, _ lesson: Learning.Lesson, rung: String, versions: Versions) {
        for line in lesson.traceLines(rung: rung, versions: versions) {
            learn.log("e\(epoch, privacy: .public).c\(seq, privacy: .public) \(line, privacy: .public)")
        }
    }

    /// One line per item; only a settle that did not pass reaches the default level.
    static func evidence(_ epoch: UInt64, _ seq: UInt64, _ items: [Evidence]) {
        for item in items {
            if item.seen == .snapshot || item.outcome == .supports(nil) {
                learn.debug("e\(epoch, privacy: .public).c\(seq, privacy: .public) evidence \(item.traceFields, privacy: .public)")
            } else {
                learn.log("e\(epoch, privacy: .public).c\(seq, privacy: .public) evidence \(item.traceFields, privacy: .public)")
            }
        }
    }

    /// The beliefs file would not read or write; mvim applies the last version that read.
    static func beliefsFile(_ error: Error) {
        learn.error("beliefs-file \(String(describing: error), privacy: .public)")
    }

    /// Each reason is a way the probe-and-learn system can be silently inert.
    static func notLearned(_ epoch: UInt64, _ seq: UInt64, reason: String, _ items: [Evidence]) {
        for item in items {
            learn.log("""
                e\(epoch, privacy: .public).c\(seq, privacy: .public) skip=\(reason, privacy: .public) \
                q=\(item.question.rawValue, privacy: .public) why=\(item.why.rawValue, privacy: .public)
                """)
        }
    }

    // MARK: - The gate

    /// A repeat demotes: the keydown path re-resolves every 150ms and publishes nothing.
    static func denied(_ epoch: UInt64, _ gate: FieldProber.FieldGate, fresh: Bool, repeated: Bool) {
        // The repeat path is on the keydown cache: render nothing if unread.
        guard !repeated || gateLevel.isEnabled(type: .debug) else { return }
        let line = """
            e\(epoch) deny \(fresh ? "fresh" : "bound") \
            textual=\(gate.isTextual ? 1 : 0) secure=\(gate.isSecure ? 1 : 0) \
            enabled=\(gate.isEnabled ? 1 : 0) role=\(gate.role ?? "nil")
            """
        if repeated {
            self.gate.debug("\(line, privacy: .public)")
        } else {
            self.gate.log("\(line, privacy: .public)")
        }
    }

    /// A text's empty-paragraph discovery; `failed` leaves the field on `AXValue`'s lines.
    static func emptyParagraphs(_ epoch: UInt64, _ seq: UInt64, _ memo: EmptyParagraphs.Memo) {
        let found = memo.found.map { "found=\($0.count)" } ?? "failed"
        gate.debug("e\(epoch, privacy: .public).c\(seq, privacy: .public) empty-paragraphs \(found, privacy: .public)")
    }

    /// A completed command verify-before-run threw away; one form eats its final key.
    static func dropped(_ epoch: UInt64, _ seq: UInt64, command: RawCommand, reason: String) {
        cmd.log("""
            e\(epoch, privacy: .public).c\(seq, privacy: .public) \
            keys=\(command.traceKeys, privacy: .public) drop=\(reason, privacy: .public)
            """)
    }

    /// Every notification, activation and keydown resolve takes this exit without re-probing.
    static func shortCircuited(_ epoch: UInt64) {
        gate.debug("e\(epoch, privacy: .public) short-circuit same-element revalidate=0")
    }

    /// A web field's walk to its site; a miss keys the page with the app's own chrome.
    static func origin(_ epoch: UInt64, role: String?, walk: WebAreaWalk.Result) {
        let found = walk.origin != nil
        guard !found || gateLevel.isEnabled(type: .debug) else { return }
        let line = """
            e\(epoch) surface origin=\(walk.origin ?? "nil") web=1 \
            role=\(role ?? "nil") \(walk.traceFields)
            """
        if found {
            gate.debug("\(line, privacy: .public)")
        } else {
            gate.log("\(line, privacy: .public)")
        }
    }
}
