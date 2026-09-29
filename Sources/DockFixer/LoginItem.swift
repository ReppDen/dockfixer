import ServiceManagement

/// Registers DockFixer to start at login.
///
/// The automatic pass only helps if the app is running when a display is
/// unplugged, so for this tool starting at login is the difference between
/// fixing the problem and merely offering a button.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// - Throws: whatever `SMAppService` reports — most often because the app is
    ///   not in a location macOS will launch from.
    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Human-readable status, including the case where macOS has queued the item
    /// but is waiting for the user to allow it in System Settings.
    ///
    /// `notFound` is not a failure here: for the main app service macOS reports it
    /// until the first successful registration, so it reads the same as
    /// `notRegistered`.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "waiting for approval in System Settings → General → Login Items"
        case .notRegistered, .notFound: return "not registered"
        @unknown default: return "unknown"
        }
    }
}
