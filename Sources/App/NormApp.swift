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
                Menu("Capabilities in \(front.name)") {
                    ForEach(model.capabilityRows) { row in
                        Picker("\(row.title) — \(row.badge)", selection: Binding(
                            get: { row.choice },
                            set: { model.setCapabilityOverride($0, for: row.capability) }
                        )) {
                            Text("Auto").tag(AppModel.OverrideChoice.auto)
                            Text("On").tag(AppModel.OverrideChoice.on)
                            Text("Off").tag(AppModel.OverrideChoice.off)
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

    /// One capabilities-menu row: the atom, its resolved verdict for the
    /// bound field (badge), and the user's stored choice for the front app.
    struct CapabilityRow: Identifiable, Equatable {
        let capability: Capability
        let title: String
        let badge: String
        let choice: OverrideChoice
        var id: String { capability.rawValue }
    }

    /// The picker's projection of `CapabilityConfig.Override?`.
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
            // Mode changes ride every rebind, so the badge rows track the
            // binding without their own channel.
            self.refreshCapabilityRows()
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

    func setCapabilityOverride(_ choice: OverrideChoice, for capability: Capability) {
        guard let frontApp else { return }
        let stored: CapabilityConfig.Override?
        switch choice {
        case .auto: stored = nil
        case .on: stored = .on
        case .off: stored = .off
        }
        CapabilityConfig.setUserOverride(stored, for: frontApp.bundleID, capability: capability.rawValue)
        controller.refreshCapabilities()
        refreshCapabilityRows()
    }

    /// Rebuilt on menu open, app activation, and every rebind — cheap, and
    /// the badges must describe the field vim is actually driving. Rows
    /// exist without a binding too (overrides are per-app config); the
    /// badge is "—" until a field of the front app binds. An overlay's
    /// binding (other pid) must not label the front app's rows.
    private func refreshCapabilityRows() {
        guard let frontApp else {
            capabilityRows = []
            return
        }
        let report = controller.boundBundleID == frontApp.bundleID ? controller.capabilityReport : nil
        capabilityRows = Capability.allCases.map { capability in
            let choice: OverrideChoice
            switch CapabilityConfig.userOverride(for: frontApp.bundleID, capability: capability.rawValue) {
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
                }
            } else {
                badge = "—"
            }
            return CapabilityRow(
                capability: capability,
                title: Self.displayName(capability),
                badge: badge,
                choice: choice
            )
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
        }
    }

    func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
