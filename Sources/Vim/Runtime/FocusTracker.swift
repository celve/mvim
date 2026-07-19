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
    }

    /// Fired on every change, including transitions to nil.
    public var onRebind: ((Binding?) -> Void)?
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
            MainActor.assumeIsolated { [weak self] in self?.scheduleReverify() }
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

    // MARK: - The resolve (the moved rebind body)

    private func resolveAndPublish(revalidateGate: Bool) {
        guard enabled else {
            publish(nil)
            return
        }
        lastResolveAt = CFAbsoluteTimeGetCurrent()
        guard let element = AX.focusedElement(), let pid = AX.ownerPID(of: element) else {
            publish(nil)
            return
        }
        // Policy first, before any further AX: a disabled app gets no
        // binding and no observer.
        guard !isDisabledApp(pid) else {
            publish(nil)
            teardownObserver()
            return
        }
        if let bound = binding, CFEqual(bound.element, element) {
            guard revalidateGate else { return }
            if FieldProber.gate(element).engageable { return }
            publish(nil)
            return
        }
        // Watch this app either way: an unbound-but-enabled app must still
        // report when focus reaches a textual field.
        retargetObserver(to: pid)
        guard FieldProber.gate(element).engageable else {
            publish(nil)
            return
        }
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let isOverlay = pid != frontPid
            && NSRunningApplication(processIdentifier: pid)?.activationPolicy == .accessory
        publish(Binding(
            element: element,
            pid: pid,
            capabilities: FieldProber.probe(element),
            isOverlay: isOverlay
        ))
    }

    private func publish(_ new: Binding?) {
        if binding == nil, new == nil { return }
        // The element-destroyed registration moves with the binding.
        if let old = binding { unobserve(kAXUIElementDestroyedNotification, on: old.element) }
        binding = new
        if let new { observe(kAXUIElementDestroyedNotification, on: new.element) }
        onRebind?(new)
    }

    private func isDisabledApp(_ pid: pid_t) -> Bool {
        guard let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
            return false
        }
        return Prefs.isDisabled(bundleID: bundleID)
    }

    // MARK: - Event sources

    private func appActivated(_ note: Notification) {
        guard enabled else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if let bundleID = app.bundleIdentifier, Prefs.isDisabled(bundleID: bundleID) {
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
