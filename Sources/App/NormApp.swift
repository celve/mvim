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
            Image(systemName: model.tapInstalled ? "keyboard.fill" : "keyboard")
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var tapInstalled = false
    @Published var vimEnabled = true {
        didSet { controller.enabled = vimEnabled }
    }

    private let controller = Controller()
    private var token: InputHub.Token?

    init() {
        let controller = self.controller
        token = InputHub.shared.register(.editor) { event in
            MainActor.assumeIsolated { controller.handle(event) }
        }
        refresh()
    }

    func refresh() {
        accessibilityTrusted = AX.ensureTrusted(prompt: false)
        inputMonitoringGranted = CGPreflightListenEventAccess()
        tapInstalled = InputHub.shared.isTapInstalled
    }

    func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
