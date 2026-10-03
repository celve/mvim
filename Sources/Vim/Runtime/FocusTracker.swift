import AppKit
import ApplicationServices
import Core

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

        /// The window containing `element`, resolved once at publish time.
        /// Distinct from `windowID`, which carries *forced* identity: this
        /// answers "same document?" for real bindings, where a block editor
        /// hands out one element per block but one window per page. nil when
        /// AX would not say — the transition then fails closed to a new
        /// session.
        public let window: AXUIElement?

        /// What capability config is keyed by — the text engine behind the
        /// field, not the app hosting it. Resolved once at publish time and
        /// frozen; recomputing it mid-session would let the key drift out from
        /// under the answers already resolved against it.
        public let surface: Surface

        /// An app update reopens every trial, an engine update the read model.
        public let versions: Versions

        /// Provenance behind `capabilities`, for the menu's rows; nil for forced bindings, which resolve nothing.
        public let capabilityReport: CapabilityReport?

        /// Nil for forced bindings, which learn nothing.
        public let beliefs: ResolvedBeliefs?

        public let isChromium: Bool
    }

    /// Fired on every change, including transitions to nil. The transition
    /// is a property of the *edge*, not of either binding — it tells the
    /// controller how much of the session survives.
    public var onRebind: ((Binding?, FocusTransition) -> Void)?
    /// Fired on every global mouse-up — forced bindings reset to Insert on
    /// clicks (the caret moved invisibly).
    public var onPointerAction: (() -> Void)?
    public private(set) var binding: Binding?

    /// Here, not on the controller: the gate events below fire where nothing is published.
    public private(set) var epoch: UInt64 = 0

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
    /// Throttles the keydown path; the pid is load-bearing, as nothing else marks an app change.
    private struct Denial: Equatable {
        let pid: pid_t
        let fresh: Bool
        let textual: Bool
        let secure: Bool
        let enabled: Bool
        let role: String?
    }
    private var lastDenial: Denial?
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

    /// Re-probes and republishes the same element (`.sameElement`), so mode, marks and cursor survive.
    public func reresolveCapabilities() {
        guard enabled, let bound = binding, !bound.isForced else { return }
        let gate = FieldProber.gate(bound.element)
        guard gate.engageable else {
            resolveAndPublish(revalidateGate: true)
            return
        }
        let identity = Self.appIdentity(for: bound.pid)
        // Carry the bound origin: the answer applied here was written at its rung.
        let surface = Surface(
            bundleID: identity.bundleID,
            origin: bound.surface.origin,
            role: gate.role,
            identifier: gate.identifier
        )
        let resolved = FieldProber.resolve(bound.element, surface: surface, versions: identity.versions, chromium: gate.isChromium)
        publish(Binding(
            element: bound.element,
            pid: bound.pid,
            capabilities: resolved.profile,
            isOverlay: bound.isOverlay,
            isForced: false,
            windowID: bound.windowID,
            // Recomputed, never carried: this method exists to apply a menu
            // override, and toggling `fieldIsSession` off makes the fresh
            // profile scoped while the held window is still nil — carrying it
            // would leave `sameDocument` unreachable until the next full
            // resolve.
            window: Self.documentWindow(of: bound.element, profile: resolved.profile),
            surface: surface,
            versions: identity.versions,
            capabilityReport: resolved.report,
            beliefs: resolved.beliefs,
            isChromium: gate.isChromium
        ))
    }

    /// Adopt a freshly-focused element **only** if it is the same document
    /// as `current` — the block-crossing case, where our own motion moved
    /// focus and the AX notification has not landed yet.
    ///
    /// Returns the new binding on success, nil when this is a genuine focus
    /// change the caller must handle as such. Costs one gate plus one
    /// resolve, and only on the rare keystroke that finds the element moved.
    public func retarget(to element: AXUIElement, from current: Binding) -> Binding? {
        // The pid must be proven, not assumed: `candidate` is stamped with
        // `current.pid`, so an element from another app would compare equal
        // to itself and could masquerade as the same document.
        guard enabled, !current.isForced,
              AX.ownerPID(of: element) == current.pid else { return nil }
        let gate = FieldProber.gate(element)
        guard gate.engageable else { return nil }
        let identity = Self.appIdentity(for: current.pid)
        // The origin is INHERITED, not walked. This is the one hot path — it
        // runs on the block-crossing keystroke — and a parent walk per
        // keystroke is exactly what the round-trip budget cannot absorb.
        // Sound because retarget only survives a `.sameDocument` verdict below,
        // which demands the same window in the same app: the page cannot have
        // navigated out from under it. The element half is still recomputed,
        // since that is the thing that just changed.
        let surface = Surface(
            bundleID: identity.bundleID,
            origin: current.surface.origin,
            role: gate.role,
            identifier: gate.identifier
        )
        let resolved = FieldProber.resolve(element, surface: surface, versions: identity.versions, chromium: gate.isChromium)
        let candidate = Binding(
            element: element,
            pid: current.pid,
            capabilities: resolved.profile,
            isOverlay: current.isOverlay,
            isForced: false,
            windowID: current.windowID,
            window: Self.documentWindow(of: element, profile: resolved.profile),
            surface: surface,
            versions: identity.versions,
            capabilityReport: resolved.report,
            beliefs: resolved.beliefs,
            isChromium: gate.isChromium
        )
        guard transition(from: current, to: candidate) == .sameDocument else { return nil }
        publish(candidate)
        return candidate
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
        guard let reported = AX.focusedElement(), let pid = AX.ownerPID(of: reported) else {
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
        let element = typingTarget(of: reported)
        if let bound = binding, !bound.isForced, CFEqual(bound.element, element) {
            guard revalidateGate else {
                Diag.shortCircuited(epoch)
                return
            }
            let gate = FieldProber.gate(element)
            if gate.engageable { return }
            reportDenial(gate, fresh: false, pid: pid)
            publishForcedOrNil()   // the bound element lost the gate
            return
        }
        // Watch this app either way: an unbound-but-enabled app must still
        // report when focus reaches a textual field.
        retargetObserver(to: pid)
        let gate = FieldProber.gate(element)
        guard gate.engageable else {
            reportDenial(gate, fresh: true, pid: pid)
            publishForcedOrNil()   // the fresh element fails the gate
            return
        }
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let isOverlay = pid != frontPid
            && NSRunningApplication(processIdentifier: pid)?.activationPolicy == .accessory
        let identity = Self.appIdentity(for: pid)
        let (surface, walk) = Self.surface(for: element, gate: gate, bundleID: identity.bundleID)
        let resolved = FieldProber.resolve(element, surface: surface, versions: identity.versions, chromium: gate.isChromium)
        publish(Binding(
            element: element,
            pid: pid,
            capabilities: resolved.profile,
            isOverlay: isOverlay,
            isForced: false,
            windowID: 0,
            window: Self.documentWindow(of: element, profile: resolved.profile),
            surface: surface,
            versions: identity.versions,
            capabilityReport: resolved.report,
            beliefs: resolved.beliefs,
            isChromium: gate.isChromium
        ))
        // After the publish, so it carries its own binding's epoch, not the outgoing one.
        if let walk { Diag.origin(epoch, role: gate.role, walk: walk) }
    }

    /// The focused element, or the field typing reaches where Chromium reports that field's highlighted popup row instead.
    public func focusedField() -> AXUIElement? {
        AX.focusedElement().map(typingTarget)
    }

    /// No read while focus is on the bound element.
    private func typingTarget(of reported: AXUIElement) -> AXUIElement {
        if let bound = binding, CFEqual(bound.element, reported) { return reported }
        return TypingTargetReads.field(for: reported) ?? reported
    }

    /// Value-typed, so the keydown negative cache allocates nothing.
    private func reportDenial(_ gate: FieldProber.FieldGate, fresh: Bool, pid: pid_t) {
        let verdict = Denial(
            pid: pid, fresh: fresh, textual: gate.isTextual,
            secure: gate.isSecure, enabled: gate.isEnabled, role: gate.role
        )
        Diag.denied(epoch, gate, fresh: fresh, repeated: lastDenial == verdict)
        lastDenial = verdict
    }

    /// The key capability config resolves on; only a fresh web bind pays the walk.
    private static func surface(
        for element: AXUIElement, gate: FieldProber.FieldGate, bundleID: String?
    ) -> (surface: Surface, walk: WebAreaWalk.Result?) {
        let walk = gate.isWebElement ? AX.enclosingWebArea(of: element) : nil
        let surface = Surface(
            bundleID: bundleID,
            origin: walk?.origin,
            role: gate.role,
            identifier: gate.identifier
        )
        return (surface, walk)
    }

    /// Resolved only at real publish sites — the same-element short-circuit
    /// returns first, so ⌃[ reverifies never touch the app's Info.plist.
    private static func appIdentity(for pid: pid_t) -> (bundleID: String?, versions: Versions) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return (nil, Versions()) }
        let version = app.bundleURL.flatMap(Bundle.init(url:))?
            .infoDictionary?["CFBundleShortVersionString"] as? String
        // Electron ships its engine as a framework; a Chromium browser's engine changes with the app.
        let engine = app.bundleURL
            .flatMap { Bundle(url: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")) }?
            .infoDictionary?["CFBundleVersion"] as? String
        return (app.bundleIdentifier, Versions(app: version, engine: engine))
    }

    /// Has the app explicitly denied `fieldIsSession` — i.e. told us its
    /// elements are not documents?
    ///
    /// `has()` cannot distinguish "resolved and denied" from "never
    /// resolved" (an empty profile answers false to everything), and only an
    /// explicit denial carries the claim. **The single definition on
    /// purpose:** `transition` uses it to decide whether to consult `window`
    /// and `documentWindow` uses it to decide whether to resolve one. Were
    /// they to drift, the window would be nil in exactly the case that needs
    /// it, and `sameDocument` would become unreachable.
    private static func deniesFieldIsSession(_ profile: CapabilityProfile) -> Bool {
        profile.statuses[.fieldIsSession] == .unavailable
    }

    /// The `sameDocument` window, resolved only when it can actually be
    /// consulted — `transition` short-circuits on the denial above before it
    /// ever dereferences `window`. Everywhere else these one-to-two round
    /// trips bought a value nothing read.
    ///
    /// Resolved eagerly (at publish) rather than lazily (at transition) on
    /// purpose: by transition time the outgoing element may already be
    /// destroyed, and a nil there would read as "different document" and end
    /// the very block-editor session `handleAXNotification` exists to keep.
    private static func documentWindow(
        of element: AXUIElement, profile: CapabilityProfile
    ) -> AXUIElement? {
        deniesFieldIsSession(profile) ? AX.window(of: element) : nil
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
            window: nil,   // forced identity is (pid, windowID); there is no real element

            // App-only: a forced binding has no real element, so there is no
            // role and nothing to resolve an origin from.
            surface: Surface(bundleID: bundleID),
            versions: Versions(),
            capabilityReport: nil,
            beliefs: nil,
            isChromium: false
        ))
    }

    private func publish(_ new: Binding?) {
        if binding == nil, new == nil { return }
        let edge = transition(from: binding, to: new)
        epoch &+= 1
        lastDenial = nil
        // The element-destroyed registration moves with the binding; forced
        // stand-ins register nothing.
        if let old = binding, !old.isForced {
            unobserve(kAXUIElementDestroyedNotification, on: old.element)
        }
        binding = new
        if let new, !new.isForced {
            observe(kAXUIElementDestroyedNotification, on: new.element)
        }
        onRebind?(new, edge)
    }

    /// Which edge focus just traversed. Fails closed to `.newSession` — the
    /// long-standing behavior — whenever anything is unknown.
    ///
    /// The `sameDocument` case generalizes what forced bindings already do
    /// below: identity is the *document*, never the element. A block editor
    /// hands out one element per block, so element identity would call every
    /// line move a new editing session.
    private func transition(from old: Binding?, to new: Binding?) -> FocusTransition {
        guard let old, let new else { return .newSession }
        if old.isForced || new.isForced {
            return old.isForced && new.isForced && old.pid == new.pid && old.windowID == new.windowID
                ? .sameElement
                : .newSession
        }
        if CFEqual(old.element, new.element) { return .sameElement }
        // Both sides must have denied `fieldIsSession` — see the predicate
        // for why an explicit denial, not `has()`, is the test. It leads the
        // guard because it also gates whether `window` was resolved at all.
        let scoped = { (binding: Binding) in
            Self.deniesFieldIsSession(binding.capabilities)
        }
        // `site`, never the whole surface: the identifier is per-element, and a
        // block editor hands out one element per block, so comparing whole
        // surfaces would call every line move a new session — the exact failure
        // `fieldIsSession` exists to prevent. Site keeps the old role check and
        // adds the origin, so crossing from a page into the chrome (same window,
        // same role) correctly reads as a new session.
        guard scoped(old), scoped(new),
              old.pid == new.pid,
              old.surface.site == new.surface.site,
              let oldWindow = old.window, let newWindow = new.window,
              CFEqual(oldWindow, newWindow) else { return .newSession }
        return .sameDocument
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
        // A destroyed bound element does NOT unbind on its own: in a block
        // editor, deleting a block (`3dd`, `dj`) destroys the very element
        // vim is driving, and an eager `publish(nil)` would end the session
        // — dropping the user to Insert for doing exactly what vim is for.
        // Let the resolve below decide; it can still reach `sameDocument`
        // against the surviving window. Only if nothing binds does the
        // destruction actually unbind us.
        let destroyedBound = notification == kAXUIElementDestroyedNotification
            && binding.map { CFEqual($0.element, element) } == true
        resolveAndPublish(revalidateGate: false)
        if destroyedBound, let bound = binding, CFEqual(bound.element, element) {
            publish(nil)   // the resolve found nothing better; the element really is gone
        }
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
