import AppKit
import ApplicationServices
import LoomCore

/// "Which field does vim own right now?" as event-driven cached state — the
/// answer the tap callback reads for free, instead of re-deriving it with
/// synchronous AX round trips on every keystroke system-wide.
///
/// Rebinds are pushed, not pulled: app activation (NSWorkspace), the focused
/// app's own AX notifications, a global mouse monitor (clicks are how focus
/// moves in apps that emit no AX events), and two bounded pull escapes — a
/// rate-limited negative cache for non-activating overlays (Raycast /
/// Spotlight never announce themselves), and `reverify()` on Esc, the one
/// keystroke where a stale verdict has teeth.
///
/// The per-app disable list gates here, at binding time: a disabled app gets
/// no observer and no binding, so its every keystroke passes with zero work.
@MainActor
public final class FocusTracker {
    public struct Binding {
        public let element: AXUIElement
        public let pid: pid_t
        public let capabilities: CapabilityProfile
        /// Accessory-app focus (Raycast/Spotlight): frontmost stays the
        /// regular app, so the per-key pid staleness guard must not apply.
        public let isOverlay: Bool
        /// App-level binding for an AX-silent app (policy `.forced`): the
        /// element is a stand-in app element, capabilities are empty (lane C
        /// only), and identity is `(pid, windowID)` — never the element.
        public let isForced: Bool
        public let windowID: CGWindowID

        /// The learner's binding identity, resolved once at publish time.
        public let bundleID: String?
        public let appVersion: String?
        public let role: String?

        /// Provenance behind `capabilities`, for the menu's badge rows.
        /// nil for forced bindings — empty profile, nothing resolved.
        public let capabilityReport: CapabilityReport?
    }

    /// Fired on every change, including transitions to nil.
    public var onRebind: ((Binding?) -> Void)?
    /// Fired on every global mouse-up — forced bindings reset to Insert on
    /// clicks (the caret moved invisibly).
    public var onPointerAction: (() -> Void)?
    public private(set) var binding: Binding?

    private var appObserver: AXObserver?
    private var observedPid: pid_t = 0
    /// Exact (element, notification) pairs successfully registered — torn
    /// down pair-for-pair so retargets never leak run-loop work.
    private var registrations: [(AXUIElement, String)] = []
    private var workspaceToken: NSObjectProtocol?
    private var mouseMonitor: Any?
    /// Shared stamp: the negative-cache window and the reverify rate limit.
    private var lastResolveAt: CFAbsoluteTime = 0
    private var reverifyScheduled = false
    private var enabled = true
    private var started = false

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated { [weak self] in self?.appActivated(note) }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.onPointerAction?()
                self?.scheduleReverify()
            }
        }
        resolveAndPublish(revalidateGate: false)
    }

    public func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            lastResolveAt = 0
            resolveAndPublish(revalidateGate: true)
        } else {
            publish(nil)
            teardownObserver()
        }
    }

    /// The per-key lookup: the cache when bound; when unbound, at most one
    /// inline resolve per window — the escape hatch for overlays that took
    /// focus without telling anyone.
    public func bindingForKeydown() -> Binding? {
        if let binding { return binding }
        guard enabled, CFAbsoluteTimeGetCurrent() - lastResolveAt >= 0.15 else { return nil }
        resolveAndPublish(revalidateGate: false)
        return binding
    }

    /// One synchronous re-resolution with a full gate re-check (secure /
    /// enabled flips included). The rate limit absorbs Esc autorepeat.
    public func reverify(force: Bool = false) {
        guard enabled else { return }
        guard force || CFAbsoluteTimeGetCurrent() - lastResolveAt >= 0.1 else { return }
        resolveAndPublish(revalidateGate: true)
    }

    /// Debounced reverify — the mouse monitor's entry: lets focus land after
    /// the click; the app's own AX notification corrects any race.
    public func scheduleReverify() {
        guard enabled, !reverifyScheduled else { return }
        reverifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.reverifyScheduled = false
                self.reverify(force: true)
            }
        }
    }

    /// The disable list changed: re-evaluate the current binding now.
    public func refreshPolicy() {
        guard enabled else { return }
        lastResolveAt = 0
        resolveAndPublish(revalidateGate: true)
    }

    /// A capability override changed (menu): rebuild the bound element's
    /// profile and republish — `resolveAndPublish`'s same-element
    /// short-circuit deliberately never re-probes, so this is its own
    /// entry. The republish rebinds, resetting the field to the Insert
    /// entry policy — acceptable for a menu-driven change. Forced bindings
    /// carry no profile; a dead or de-gated element falls back to the full
    /// resolve.
    public func reresolveCapabilities() {
        guard enabled, let bound = binding, !bound.isForced else { return }
        let gate = FieldProber.gate(bound.element)
        guard gate.engageable else {
            resolveAndPublish(revalidateGate: true)
            return
        }
        let identity = Self.appIdentity(for: bound.pid)
        let resolved = FieldProber.resolve(bound.element, bundleID: identity.bundleID)
        publish(Binding(
            element: bound.element,
            pid: bound.pid,
            capabilities: resolved.profile,
            isOverlay: bound.isOverlay,
            isForced: false,
            windowID: bound.windowID,
            bundleID: identity.bundleID,
            appVersion: identity.version,
            role: gate.role,
            capabilityReport: resolved.report
        ))
    }

    // MARK: - The resolve (the moved rebind body)

    private func resolveAndPublish(revalidateGate: Bool) {
        guard enabled else {
            publish(nil)
            return
        }
        lastResolveAt = CFAbsoluteTimeGetCurrent()
        // Secure input suspends both paths: defense-in-depth for AX fields,
        // THE password guard for forced bindings (the flag is system-wide,
        // covering fields AX cannot see). ⌃[ reverifies through here, so
        // engage-time coverage is free.
        guard !SecureInput.isActive else {
            publish(nil)
            return
        }
        guard let element = AX.focusedElement(), let pid = AX.ownerPID(of: element) else {
            publishForcedOrNil()   // nothing resolves — the forced fallback's home turf
            return
        }
        // Policy first, before any further AX: an off app gets no binding
        // and no observer. Forced never overrides a real element below —
        // it is a fallback.
        if policy(for: pid) == .off {
            publish(nil)
            teardownObserver()
            return
        }
        if let bound = binding, !bound.isForced, CFEqual(bound.element, element) {
            guard revalidateGate else { return }
            if FieldProber.gate(element).engageable { return }
            publishForcedOrNil()   // the bound element lost the gate
            return
        }
        // Watch this app either way: an unbound-but-enabled app must still
        // report when focus reaches a textual field.
        retargetObserver(to: pid)
        let gate = FieldProber.gate(element)
        guard gate.engageable else {
            publishForcedOrNil()   // the fresh element fails the gate
            return
        }
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let isOverlay = pid != frontPid
            && NSRunningApplication(processIdentifier: pid)?.activationPolicy == .accessory
        let identity = Self.appIdentity(for: pid)
        let resolved = FieldProber.resolve(element, bundleID: identity.bundleID)
        publish(Binding(
            element: element,
            pid: pid,
            capabilities: resolved.profile,
            isOverlay: isOverlay,
            isForced: false,
            windowID: 0,
            bundleID: identity.bundleID,
            appVersion: identity.version,
            role: gate.role,
            capabilityReport: resolved.report
        ))
    }

    /// Resolved only at real publish sites — the same-element short-circuit
    /// returns first, so ⌃[ reverifies never touch the app's Info.plist.
    private static func appIdentity(for pid: pid_t) -> (bundleID: String?, version: String?) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return (nil, nil) }
        let version = app.bundleURL.flatMap(Bundle.init(url:))?
            .infoDictionary?["CFBundleShortVersionString"] as? String
        return (app.bundleIdentifier, version)
    }

    /// The forced fallback: no engageable element anywhere, but the
    /// frontmost app may be opted into app-level lane-C vim. Gate order is
    /// cheap→expensive: workspace facts → policy → one CG window read →
    /// display compare → one bounded AX title read.
    private func publishForcedOrNil() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = app.bundleIdentifier,
              Prefs.policy(for: bundleID) == .forced else {
            publish(nil)
            return
        }
        let pid = app.processIdentifier
        guard let window = AX.frontWindow(of: pid) else {
            publish(nil)   // zero on-screen windows: nothing to bind
            return
        }
        guard !AX.coversFullScreen(window.bounds) else {
            publish(nil)   // fullscreen is game/video territory
            return
        }
        if let title = AX.focusedWindowTitle(of: pid), title.lowercased().contains("vim") {
            publish(nil)   // a real vim runs inside — back off
            return
        }
        // Identity is (pid, windowID), NEVER the element: app-element
        // stand-ins always CFEqual each other, and a republish would reset
        // the field to Insert on every reverify.
        if let bound = binding, bound.isForced, bound.pid == pid, bound.windowID == window.id {
            return
        }
        retargetObserver(to: pid)   // harmless if AX-silent; catches events if any
        publish(Binding(
            element: AXUIElementCreateApplication(pid),
            pid: pid,
            capabilities: CapabilityProfile(),   // empty: the engine plans lane C only
            isOverlay: false,
            isForced: true,
            windowID: window.id,
            bundleID: bundleID,
            appVersion: nil,   // the learner ignores forced bindings
            role: nil,
            capabilityReport: nil
        ))
    }

    private func publish(_ new: Binding?) {
        if binding == nil, new == nil { return }
        // The element-destroyed registration moves with the binding; forced
        // stand-ins register nothing.
        if let old = binding, !old.isForced {
            unobserve(kAXUIElementDestroyedNotification, on: old.element)
        }
        binding = new
        if let new, !new.isForced {
            observe(kAXUIElementDestroyedNotification, on: new.element)
        }
        onRebind?(new)
    }

    private func policy(for pid: pid_t) -> VimPolicy {
        guard let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
            return .auto
        }
        return Prefs.policy(for: bundleID)
    }

    // MARK: - Event sources

    private func appActivated(_ note: Notification) {
        guard enabled else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        // Only `.off` stops here — `.forced` must retarget and resolve so
        // forced apps bind at activation, before their first keydown.
        if let bundleID = app.bundleIdentifier, Prefs.policy(for: bundleID) == .off {
            publish(nil)
            teardownObserver()
            return
        }
        // Retarget first, resolve second: focus may not have landed yet, and
        // the fresh observer catches it when it does.
        retargetObserver(to: app.processIdentifier)
        resolveAndPublish(revalidateGate: false)
    }

    fileprivate func handleAXNotification(_ notification: String, element: AXUIElement) {
        if notification == kAXUIElementDestroyedNotification,
           let bound = binding, CFEqual(bound.element, element) {
            publish(nil)
        }
        resolveAndPublish(revalidateGate: false)
    }

    // MARK: - AXObserver lifecycle

    private func retargetObserver(to pid: pid_t) {
        if pid == observedPid, appObserver != nil { return }
        teardownObserver()
        observedPid = pid
        var observer: AXObserver?
        // Creation fails for AX-silent apps; the binding still works — the
        // mouse monitor, Esc reverify, and verify-before-run cover
        // invalidation.
        guard AXObserverCreate(pid, focusTrackerAXCallback, &observer) == .success,
              let observer else { return }
        appObserver = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        let appElement = AXUIElementCreateApplication(pid)
        observe(kAXFocusedUIElementChangedNotification, on: appElement)
        observe(kAXFocusedWindowChangedNotification, on: appElement)
    }

    /// `passUnretained` is safe: the tracker lives for the app's lifetime
    /// and teardown always precedes release.
    private func observe(_ notification: String, on element: AXUIElement) {
        guard let observer = appObserver else { return }
        let error = AXObserverAddNotification(
            observer, element, notification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if error == .success {
            registrations.append((element, notification))
        }
    }

    private func unobserve(_ notification: String, on element: AXUIElement) {
        guard let observer = appObserver,
              let index = registrations.firstIndex(where: {
                  CFEqual($0.0, element) && $0.1 == notification
              }) else { return }
        AXObserverRemoveNotification(observer, element, notification as CFString)
        registrations.remove(at: index)
    }

    private func teardownObserver() {
        observedPid = 0
        guard let observer = appObserver else {
            registrations = []
            return
        }
        for (element, notification) in registrations {
            // The app may be dead; removal failures are fine.
            AXObserverRemoveNotification(observer, element, notification as CFString)
        }
        registrations = []
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        appObserver = nil
    }
}

/// Top-level C callback (no captures); the source lives on the main run
/// loop, so `MainActor.assumeIsolated` is valid — the InputHub pattern.
private func focusTrackerAXCallback(_ observer: AXObserver, _ element: AXUIElement,
                                    _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        tracker.handleAXNotification(notification as String, element: element)
    }
}
