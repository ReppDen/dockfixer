import DockFixCore
import SwiftUI

@main
struct DockFixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("DockFix", id: "main") {
            ContentView(log: state.log)
                .environmentObject(state)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window must not quit the app: the display-change watcher has
    /// to keep running with the window shut. Quitting is an explicit action —
    /// the Quit button or ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
