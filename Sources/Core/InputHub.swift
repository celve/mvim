import CoreGraphics
import Foundation

/// The single system-wide keystroke monitor — Norm's copy of the shared Loom
/// substrate. Owns ONE consuming `CGEventTap` and fans each event out to an
/// ordered set of registered handlers.
///
/// Handler contract (READ THIS): a handler runs SYNCHRONOUSLY on the main run
/// loop for EVERY keystroke system-wide, and its return value is the consume
/// verdict. It MUST return promptly and DEFER any real work (AX / settle
/// waits) off the callback — a blocking handler freezes all keyboard input
/// until the OS disables the tap on timeout.
///
/// Dispatch is OBSERVE-ALL / CONSUME-IF-ANY: every handler sees every
/// (non-self) event in priority order, and the event is consumed iff ANY
/// handler returns true. Norm registers a single editor handler today; the
/// shape is kept because it is proven under fire in Loom and its
/// teardown-on-empty keeps a handler-less app from holding a tap (and from
/// triggering an Input-Monitoring prompt).
@MainActor
public final class InputHub {
    public static let shared = InputHub()

    /// Higher priority observes (and so its deferred side effects fire) first.
    public enum Priority: Int { case editor = 100, trigger = 50 }

    /// Opaque handle returned by `register`, passed back to `unregister`.
    public struct Token: Hashable { fileprivate let id: UInt64 }

    private struct Entry { let token: Token; let priority: Priority; let handler: (KeyEvent) -> Bool }

    private var entries: [Entry] = []           // kept sorted by priority, descending
    private var nextID: UInt64 = 0
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private init() {}

    public var isTapInstalled: Bool { tap != nil }

    /// Register a keystroke handler. Creates the shared tap on the first
    /// registration (prompting for Input Monitoring if needed). See the type
    /// doc for the handler contract.
    @discardableResult
    public func register(_ priority: Priority, _ handler: @escaping (KeyEvent) -> Bool) -> Token {
        let token = Token(id: nextID); nextID &+= 1
        entries.append(Entry(token: token, priority: priority, handler: handler))
        entries.sort { $0.priority.rawValue > $1.priority.rawValue }
        ensureTap()
        return token
    }

    /// Remove a previously registered handler. Tears the tap down when the
    /// last one leaves.
    public func unregister(_ token: Token) {
        entries.removeAll { $0.token == token }
        if entries.isEmpty { teardownTap() }
    }

    // MARK: - tap lifecycle (one tap, one run-loop source, one re-enable, one permission request)

    private func ensureTap() {
        guard tap == nil else { return }
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }   // register Norm + prompt
        // keyDown only: vim consumes key-downs. flagsChanged (Loom's
        // modifier-tap triggers) and keyUp are deliberately not observed —
        // Norm has no consumer for either.
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: inputHubCallback, userInfo: selfPtr) else {
            Log.system.error("tapCreate failed — Input Monitoring not granted?")
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func teardownTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    fileprivate func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    /// Build the `KeyEvent` once, fan it out to every handler (observe-all),
    /// consume if any voted. Iterates a snapshot so a registration from a
    /// handler can't corrupt the walk.
    fileprivate func dispatch(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard let keyEvent = KeyEvent(cgType: type, cgEvent: event) else { return false }
        var consume = false
        for entry in entries { if entry.handler(keyEvent) { consume = true } }   // do NOT short-circuit
        return consume
    }
}

/// Top-level C callback (no captures). Runs on the main run loop (the source
/// is added to the main run loop), so `MainActor.assumeIsolated` is valid.
private func inputHubCallback(proxy: CGEventTapProxy, type: CGEventType,
                              event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let hub = Unmanaged<InputHub>.fromOpaque(userInfo).takeUnretainedValue()
            MainActor.assumeIsolated { hub.reenable() }
        }
        return Unmanaged.passUnretained(event)
    }
    // Bypass tagged synthesized events. Norm's own no longer traverse this
    // tap (Synth posts below the session stage — the settle-deadlock
    // lesson), but Sotto's do, and the shared magic is a cross-app ABI:
    // otherwise Normal mode would consume a dictation transcript as
    // commands.
    if SynthTag.isSelf(event) { return Unmanaged.passUnretained(event) }
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let hub = Unmanaged<InputHub>.fromOpaque(userInfo).takeUnretainedValue()
    let consume = MainActor.assumeIsolated { hub.dispatch(type, event) }
    return consume ? nil : Unmanaged.passUnretained(event)
}
