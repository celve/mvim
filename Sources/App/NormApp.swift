import AppKit
import LoomCore
import LoomVim
import SwiftUI

/// Norm's composition root: a menu-bar agent (LSUIElement) whose only UI is
/// the status menu. The tap feeds the `Controller`; everything else is
/// permission plumbing.
@main
struct NormApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            Toggle("Vim Mode", isOn: $model.vimEnabled)
            if let front = model.frontApp {
                Picker("Vim in \(front.name)", selection: Binding(
                    get: { model.frontAppPolicy },
                    set: { model.setFrontAppPolicy($0) }
                )) {
                    Text("Auto").tag(VimPolicy.auto)
                    Text("Off").tag(VimPolicy.off)
                    Text("Force").tag(VimPolicy.forced)
                }
                // Scope is structural, not a setting: every item below is a
                // complete sentence naming the rung it writes, so there is no
                // mode to misread and exactly one item is ever checked.
                Menu("Capabilities in \(model.surfaceLabel)") {
                    ForEach(model.capabilityRows) { row in
                        Menu("\(row.title) — \(row.badge)") {
                            Button(row.choice == .auto ? "✓ Auto — inherit" : "Auto — inherit") {
                                model.setCapabilityOverride(nil, at: nil, for: row.capability)
                            }
                            Divider()
                            ForEach(row.onOptions) { option in
                                Button(option.label) {
                                    model.setCapabilityOverride(
                                        option.override, at: option.rung, for: row.capability
                                    )
                                }
                            }
                            Divider()
                            ForEach(row.offOptions) { option in
                                Button(option.label) {
                                    model.setCapabilityOverride(
                                        option.override, at: option.rung, for: row.capability
                                    )
                                }
                            }
                        }
                    }
                    if !model.clearActions.isEmpty {
                        Divider()
                        ForEach(model.clearActions) { action in
                            Button(action.label) { model.clearOverrides(at: action.rung) }
                        }
                    }
                }
            }
            Divider()
            Text(model.tapInstalled ? "Input tap: running" : "Input tap: not installed")
                .onAppear { model.refresh() }
            Text(model.accessibilityTrusted ? "Accessibility: granted" : "Accessibility: not granted")
            Text(model.inputMonitoringGranted
                ? "Input Monitoring: granted"
                : "Input Monitoring: not granted — grant, then relaunch")
            Divider()
            Button("Open Accessibility Settings") { model.openPrivacyPane("Privacy_Accessibility") }
            Button("Open Input Monitoring Settings") { model.openPrivacyPane("Privacy_ListenEvent") }
            Divider()
            Button("Quit Norm") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: model.mode.symbolName)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct FrontApp: Equatable {
        let name: String
        let bundleID: String
    }

    /// The menu-bar icon IS the mode display — forced fields have no block
    /// cursor, so this is the only telltale.
    enum ModeIndicator {
        case off, insert, normal, visual, replace

        var symbolName: String {
            switch self {
            case .off: return "keyboard"
            case .insert: return "i.square.fill"
            case .normal: return "n.square.fill"
            case .visual: return "v.square.fill"
            case .replace: return "r.square.fill"
            }
        }
    }

    /// One On/Off action inside an atom's submenu: a full sentence and the
    /// rung it writes. Checked when it is the entry currently in force.
    struct ScopeOption: Identifiable, Equatable {
        let label: String
        let rung: String
        let override: CapabilityConfig.Override
        var id: String { rung + "|" + override.rawValue }
    }

    /// One capabilities-menu row: the atom, its resolved verdict for the
    /// bound field (badge), and every scope the user may write it at.
    struct CapabilityRow: Identifiable, Equatable {
        let capability: Capability
        let title: String
        let badge: String
        let choice: OverrideChoice
        /// Kept apart so the menu can rule between them — a flat list of eight
        /// near-identical sentences is unreadable.
        let onOptions: [ScopeOption]
        let offOptions: [ScopeOption]
        var id: String { capability.rawValue }
    }

    /// A "Clear overrides…" item: wipes every atom at a rung and below.
    struct ClearAction: Identifiable, Equatable {
        let label: String
        let rung: String
        var id: String { rung }
    }

    /// Whether an atom currently defers (`auto`) or is pinned by the user.
    enum OverrideChoice: String, CaseIterable {
        case auto, on, off
    }

    @Published private(set) var mode: ModeIndicator = .off
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var tapInstalled = false
    @Published private(set) var frontApp: FrontApp?
    @Published private(set) var frontAppPolicy: VimPolicy = .auto
    @Published private(set) var capabilityRows: [CapabilityRow] = []
    @Published private(set) var clearActions: [ClearAction] = []
    @Published var vimEnabled = true {
        didSet { controller.enabled = vimEnabled }
    }

    private let controller: Controller
    private var token: InputHub.Token?
    private var workspaceToken: NSObjectProtocol?

    init() {
        // Before any AX or binding work: seed the disable list, and bound
        // every AX call this process makes (the system default is ~6s —
        // long enough for one busy app to freeze the tap).
        Prefs.registerDefaults()
        AX.setGlobalMessagingTimeout(0.15)

        let controller = Controller()
        self.controller = controller
        controller.onModeChange = { [weak self] mode in
            guard let self else { return }
            switch mode {
            case nil: self.mode = .off
            case .insert?: self.mode = .insert
            case .normal?: self.mode = .normal
            case .visual?: self.mode = .visual
            case .replace?: self.mode = .replace
            }
        }
        // Its own channel, deliberately: mode changes do NOT ride every rebind
        // — publishMode early-returns when the indicator is unchanged, so
        // moving between two Normal-mode fields fired nothing and the rows kept
        // describing the surface focus had left.
        controller.onBindingChange = { [weak self] in
            self?.refreshCapabilityRows()
        }
        token = InputHub.shared.register(.editor) { event in
            MainActor.assumeIsolated { controller.handle(event) }
        }
        // The menu's "Vim in <app>" row must be current BEFORE the menu is
        // built — MenuBarExtra builds content eagerly, so .onAppear cannot
        // be trusted to re-fire per open. Track activation continuously.
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated { [weak self] in self?.frontAppChanged(note) }
        }
        refresh()
    }

    private func frontAppChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = app.bundleIdentifier else { return }
        frontApp = FrontApp(name: app.localizedName ?? bundleID, bundleID: bundleID)
        frontAppPolicy = Prefs.policy(for: bundleID)
        refreshCapabilityRows()
    }

    func refresh() {
        accessibilityTrusted = AX.ensureTrusted(prompt: false)
        inputMonitoringGranted = CGPreflightListenEventAccess()
        tapInstalled = InputHub.shared.isTapInstalled
        // Norm is LSUIElement, so opening the menu keeps the target app
        // frontmost; if frontmost somehow IS Norm, keep the last snapshot.
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           let bundleID = app.bundleIdentifier {
            frontApp = FrontApp(name: app.localizedName ?? bundleID, bundleID: bundleID)
        }
        frontAppPolicy = frontApp.map { Prefs.policy(for: $0.bundleID) } ?? .auto
        refreshCapabilityRows()
    }

    func setFrontAppPolicy(_ policy: VimPolicy) {
        guard let frontApp else { return }
        Prefs.setPolicy(policy, for: frontApp.bundleID)
        frontAppPolicy = policy
        controller.refreshPolicy()
    }

    /// `rung` of nil is Auto: clear the atom everywhere. Otherwise the write
    /// also clears every narrower rung, so the checkmark that lands is the one
    /// that resolves — the `Prefs.setPolicy` invariant, kept here too.
    func setCapabilityOverride(
        _ override: CapabilityConfig.Override?, at rung: String?, for capability: Capability
    ) {
        let surface = menuSurface
        CapabilityConfig.setUserOverride(
            override, at: rung, on: surface, capability: capability.rawValue
        )
        // Disposing of the learner's suggestion retires it. Promoting it (Off)
        // makes the same denial a permanent decision, and overruling it (On)
        // rejects it outright — either way the inference has served its purpose
        // and should not linger to be re-applied if the user returns to Auto.
        if override != nil, let rung = surface.roleRung {
            LearnedPriors.forget(rung: rung, capability: capability.rawValue)
        }
        controller.refreshCapabilities()
        refreshCapabilityRows()
    }

    func clearOverrides(at rung: String) {
        CapabilityConfig.clearOverrides(atAndBelow: rung, on: menuSurface)
        controller.refreshCapabilities()
        refreshCapabilityRows()
    }

    /// The surface the menu configures: the bound field's when it belongs to
    /// the front app, otherwise the app alone.
    ///
    /// The fallback is what keeps rows editable while unbound — config is
    /// config, and an app-scope choice is still meaningful with no field in
    /// hand. It also collapses the scope list to just the app, which is
    /// honest: nothing narrower is known.
    private var menuSurface: Surface {
        guard let frontApp else { return Surface() }
        if let bound = controller.boundSurface, bound.bundleID == frontApp.bundleID {
            return bound
        }
        return Surface(bundleID: frontApp.bundleID)
    }

    /// "Dia › notion.so" — the menu must name what it is about to configure,
    /// or a scoped write reads as an app-wide one.
    var surfaceLabel: String {
        guard let frontApp else { return "—" }
        guard let origin = menuSurface.origin else { return frontApp.name }
        return "\(frontApp.name) › \(origin)"
    }

    /// Rebuilt on menu open, app activation, and every rebind — cheap, and
    /// the badges must describe the field vim is actually driving. Rows
    /// exist without a binding too (overrides are config, not evidence); the
    /// badge is "—" until a field of the front app binds. An overlay's
    /// binding (other pid) must not label the front app's rows.
    private func refreshCapabilityRows() {
        guard frontApp != nil else {
            capabilityRows = []
            clearActions = []
            return
        }
        let surface = menuSurface
        let scopes = surface.writableScopes
        let report = controller.boundSurface?.bundleID == frontApp?.bundleID
            ? controller.capabilityReport : nil
        let config = CapabilityConfig.resolveAll(
            surface, capabilities: Capability.allCases.map(\.rawValue)
        )

        capabilityRows = Capability.allCases.map { capability in
            let resolution = config[capability.rawValue] ?? .auto
            let choice: OverrideChoice
            switch resolution.override {
            case .on: choice = .on
            case .off: choice = .off
            case nil: choice = .auto
            }
            let badge: String
            if let entry = report?.entries[capability] {
                let mark = entry.status == .available ? "✓" : "✗"
                switch entry.source {
                case .probed: badge = "\(mark) probed"
                case .seeded: badge = "\(mark) seeded"
                case .user: badge = "\(mark) user"
                // The learner's suggestion, made visible so it can be disposed
                // of: Off promotes it to a permanent decision, On overrules it.
                case .learned: badge = "\(mark) learned"
                }
            } else {
                badge = "—"
            }
            // Narrowest-first scope order within each group. The check marks the
            // stored entry — the *user's* choice, not the resolved verdict: an
            // `.on` that a failed probe overrules is still the choice they made,
            // and the badge is where the truth shows.
            func options(_ override: CapabilityConfig.Override) -> [ScopeOption] {
                scopes.map { scope, rung in
                    let checked = resolution.override == override && resolution.overrideRung == rung
                    return ScopeOption(
                        label: (checked ? "✓ " : "") + Self.sentence(override, scope),
                        rung: rung,
                        override: override
                    )
                }
            }
            return CapabilityRow(
                capability: capability,
                title: Self.displayName(capability),
                badge: badge,
                choice: choice,
                onOptions: options(.on),
                offOptions: options(.off)
            )
        }

        // Only the scopes that could plausibly hold something worth wiping —
        // clearing "this one field" is what Auto already does per atom.
        clearActions = scopes.compactMap { scope, rung in
            switch scope {
            case .site, .app:
                return ClearAction(label: "Clear overrides \(Self.phrase(scope))", rung: rung)
            case .field, .fieldsOfRole:
                return nil
            }
        }
    }

    /// UI strings stay in the app layer — `Surface` names rungs, not rows.
    /// Pure string work, so `nonisolated`: the row builder calls it from inside
    /// a `map` closure, which does not inherit the model's actor.
    private nonisolated static func sentence(
        _ override: CapabilityConfig.Override, _ scope: Surface.Scope
    ) -> String {
        "\(override == .on ? "On" : "Off") \(phrase(scope))"
    }

    private nonisolated static func phrase(_ scope: Surface.Scope) -> String {
        switch scope {
        case .field(let identifier): return "in field \"\(identifier)\""
        case .fieldsOfRole: return "in fields like this one"
        case .site(let origin): return "on \(origin)"
        case .app: return "in this app"
        }
    }

    /// UI strings stay in the app layer — the engine names atoms, not rows.
    private static func displayName(_ capability: Capability) -> String {
        switch capability {
        case .readText: return "Read text"
        case .readLength: return "Read length"
        case .readCaret: return "Read caret"
        case .readSelectedText: return "Read selected text"
        case .writeSelection: return "Set selection (AX)"
        case .insertText: return "Replace text (AX)"
        case .drawCursor: return "Draw block cursor"
        // Phrased so the row's *denial* is the legible half: "✗ seeded" then
        // reads as the block-editor fact.
        case .wholeDocument: return "Text covers whole document"
        case .fieldIsSession: return "New field starts a session"
        }
    }

    func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
