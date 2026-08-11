import DockFixCore
import SwiftUI

@main
struct DockFixApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("DockFix", id: Self.mainWindowID) {
            ContentView(log: state.log)
                .environmentObject(state)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // DockFix lives in the menu bar: it has to be running when a display is
        // unplugged, and a background utility should not occupy a Dock slot for
        // that. The window is opened from here when needed.
        MenuBarExtra("DockFix", systemImage: "macwindow") {
            MenuContent()
                .environmentObject(state)
        }
    }
}

private struct MenuContent: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Fix Windows Now") { state.moveWindows() }
            .disabled(state.isBusy)

        if !state.isTrusted {
            Button("Grant Accessibility Access…") { state.requestAccessibility() }
        }

        Divider()

        Toggle("Fix automatically when displays change", isOn: $state.autoFixEnabled)
        Toggle("Launch at login", isOn: $state.launchAtLogin)

        Divider()

        Button("Open DockFix…") {
            openWindow(id: DockFixApp.mainWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit DockFix") { state.quit() }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Closing the window must not quit the app: the display-change watcher has
    /// to keep running with the window shut. Quitting is explicit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        handleLoginItemCommandIfNeeded()
    }

    /// `DockFix --login-item status|register|unregister`, run straight from the
    /// bundle. Registering a login item depends on how the bundle is signed and
    /// where it lives, and the failure surfaces as a bare status enum in the UI;
    /// this prints the actual error.
    private func handleLoginItemCommandIfNeeded() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--login-item") else { return }
        let action = flag + 1 < arguments.count ? arguments[flag + 1] : "status"

        do {
            switch action {
            case "status": break
            case "register": try LoginItem.set(true)
            case "unregister": try LoginItem.set(false)
            default:
                print("usage: DockFix --login-item status|register|unregister")
                exit(2)
            }
            print("launch at login: \(LoginItem.statusDescription)")
            exit(0)
        } catch {
            print("error: \(error)")
            print("launch at login: \(LoginItem.statusDescription)")
            exit(1)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // With Accessibility already granted there is nothing to say at launch,
        // so start quietly in the menu bar — which is how the app comes up at
        // login. Without the grant the window has to be visible, because the
        // user has to act on it.
        guard WindowScanner.isTrusted else {
            // No Dock icon to click, so bring the window forward ourselves.
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        DispatchQueue.main.async {
            for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
                window.close()
            }
        }
    }
}
