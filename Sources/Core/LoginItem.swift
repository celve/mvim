import Foundation
import ServiceManagement

/// Start-at-login via `SMAppService.mainApp`; the system owns the bit, not `Prefs`.
public enum LoginItem {
    public enum State {
        case on, off
        /// Registered, but consent was revoked in System Settings — only it can undo that.
        case blocked
    }

    public static var state: State { state(of: SMAppService.mainApp.status) }

    /// Blocks on `smd` — call it off the main thread, where InputHub's tap runs.
    public static func setEnabled(_ enabled: Bool) -> State {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Both throw when the wanted state already holds; the re-read is the verdict.
            Log.system.error(
                """
                login item \(enabled ? "register" : "unregister", privacy: .public) failed — \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
        return state
    }

    public static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func state(of status: SMAppService.Status) -> State {
        switch status {
        case .enabled: return .on
        case .requiresApproval: return .blocked
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }
}
