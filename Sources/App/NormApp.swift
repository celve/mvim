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

    @Published private(set) var mode: ModeIndicator = .off
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var tapInstalled = false
    @Published private(set) var frontApp: FrontApp?
    @Published private(set) var frontAppPolicy: VimPolicy = .auto
    @Published var vimEnabled = true {
        didSet { controller.enabled = vimEnabled }
    }

    private let controller: Controller
    private var token: InputHub.Token?

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
        token = InputHub.shared.register(.editor) { event in
            MainActor.assumeIsolated { controller.handle(event) }
        }
        refresh()
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
    }

    func setFrontAppPolicy(_ policy: VimPolicy) {
        guard let frontApp else { return }
        Prefs.setPolicy(policy, for: frontApp.bundleID)
        frontAppPolicy = policy
        controller.refreshPolicy()
    }

    func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
