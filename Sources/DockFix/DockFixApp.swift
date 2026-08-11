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

    // Deliberately no command-line entry points.
    //
    // Starting the binary from a shell instead of launching the bundle makes
    // macOS attribute Accessibility requests to the *responsible process* — the
    // terminal emulator — rather than to DockFix. The prompt then asks for the
    // terminal, the request is recorded against it, and DockFix's own grant stops
    // matching. Debugging that cost several rounds; see todo_permissions.md.
    //
    // Everything is driven from the window and the menu-bar item instead.

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
