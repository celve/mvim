import AppKit
import LoomCore
import SwiftUI

/// Norm's composition root: a menu-bar agent (LSUIElement) whose only UI is
/// the status menu. Runtime bring-up step 1: the tap is installed and
/// observes-and-passes-through — no key is consumed yet.
@main
struct NormApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            Text(model.tapInstalled ? "Input tap: running (passthrough)" : "Input tap: not installed")
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

    private var token: InputHub.Token?

    init() {
        // Step 1 handler: observe everything, consume nothing. Registering
        // installs the tap (and prompts for Input Monitoring on first run).
        token = InputHub.shared.register(.editor) { _ in false }
        refresh()
    }

    func refresh() {
        accessibilityTrusted = AXIsProcessTrusted()
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
