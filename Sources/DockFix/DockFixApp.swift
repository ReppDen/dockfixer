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

        // The menu-bar item is what makes the app usable once the window is
        // closed — it has to stay running to catch a display being unplugged.
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
        // Started by launchd at login and already granted access: come up quietly
        // with just the Dock and menu-bar icons, since there is nothing to say and
        // nothing to do. Any other launch shows the window — the user opened the
        // app and expects to see it.
        guard launchedAtLogin, WindowScanner.isTrusted else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        DispatchQueue.main.async {
            for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
                window.close()
            }
        }
    }

    /// Clicking the Dock icon with the window closed has to bring it back —
    /// otherwise the icon looks dead, since closing the window does not quit.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func showMainWindow() {
        // The Window scene keeps its NSWindow around after a close, so ordering it
        // back in is enough.
        if let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// launchd sets `XPC_SERVICE_NAME` for the processes it starts; a launch from
    /// Finder, Spotlight or `open` leaves it unset or `0`.
    private var launchedAtLogin: Bool {
        let name = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? ""
        return !name.isEmpty && name != "0"
    }
}
