import DockFixerCore
import SwiftUI

@main
struct DockFixerApp: App {
    static let mainWindowID = "main"
    static let logWindowID = "log"
    static let bugReportWindowID = "bug-report"
    /// How the settings window is told apart from the log and from AppKit's own
    /// panels. Set here, so it is known rather than guessed.
    static let mainWindowTitle = "DockFixer"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window(Self.mainWindowTitle, id: Self.mainWindowID) {
            ContentView()
                .environmentObject(state)
                // The menu-bar item hands this over too, but it may be hidden.
                .background(WindowOpener(delegate: delegate))
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            // The window is the settings, so ⌘, opens it, as in any Mac app.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.showMainWindow() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
        // The window is exactly its contents, and changes size when they do.
        //
        // Sizing it by hand does not work here: `setContentSize` is overridden by
        // whatever the scene decides a moment later, and the hosting view centres
        // the overflow, so the window silently clips its top and bottom at once
        // rather than showing something obviously wrong. `.contentSize` hands the
        // question to the one part of the system that has the final say anyway.
        .windowResizability(.contentSize)

        // The menu-bar item is what makes the app usable once the window is
        // closed — it has to stay running to catch a display being unplugged.
        Window("DockFixer Log", id: Self.logWindowID) {
            LogView(log: state.log)
                .environmentObject(state)
        }
        .defaultSize(width: 860, height: 420)

        Window("Report a Bug", id: Self.bugReportWindowID) {
            BugReportView(form: state.bugReportForm)
                .environmentObject(state)
        }
        .windowResizability(.contentSize)

        MenuBarExtra(isInserted: Binding(get: { !state.hideMenuBarIcon },
                                         set: { inserted in
                                             // Only a real change. The scene writes this back on
                                             // every update, and every write to a @Published
                                             // property redraws the app, which writes it again:
                                             // the main thread sat at 100% CPU and no timer ran.
                                             if state.hideMenuBarIcon == inserted { state.hideMenuBarIcon = !inserted }
                                         })) {
            MenuContent(delegate: delegate)
                .environmentObject(state)
        } label: {
            MenuBarIcon(delegate: delegate)
                .environmentObject(state)
        }
    }
}

/// Hands the delegate a way to rebuild the settings window, from inside it.
///
/// The menu-bar icon does the same, and was the only one doing it until the
/// icon could be hidden: with it gone, nothing else could give the delegate an
/// `openWindow`, which exists only in a view's environment.
private struct WindowOpener: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            delegate.openMainWindow = { openWindow(id: DockFixerApp.mainWindowID) }
        }
    }
}

/// The status-item icon, and the one place that is guaranteed to exist whether
/// or not the window does.
///
/// It exists to hand the delegate a way to open the window. Once a `Window`
/// scene has been closed only SwiftUI can build its window again, and
/// `openWindow` is reachable from a view and nowhere else.
private struct MenuBarIcon: View {
    let delegate: AppDelegate
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Without the grant nothing works, and the menu bar may be the only
        // part of the app on screen, so that is where it has to show.
        Image(systemName: state.isTrusted ? "macwindow" : "exclamationmark.triangle")
            .onAppear {
                delegate.openMainWindow = { openWindow(id: DockFixerApp.mainWindowID) }
            }
    }
}

private struct MenuContent: View {
    /// Handed in, never looked up. `NSApp.delegate as? AppDelegate` returns nil:
    /// with `@NSApplicationDelegateAdaptor` SwiftUI installs a delegate of its
    /// own and forwards to this one, so the delegate methods are called but the
    /// cast never succeeds. The menu item spent every earlier attempt calling
    /// methods on nil and doing nothing at all.
    let delegate: AppDelegate

    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Fix Windows Now") { state.moveWindows() }
            .disabled(state.isBusy)

        if !state.isTrusted {
            Button("Grant Accessibility Access…") { state.requestAccessibility() }
        }

        Divider()

        // Worded exactly as in the window: two names for one switch is two
        // things to learn.
        Section("Move Windows") {
            Toggle("Move Windows That Are Under the Dock", isOn: $state.moveFromUnderDock)
            Toggle("Stick Windows to the Dock When It Changes Size or Moves", isOn: $state.stickToDock)
                .disabled(!state.moveFromUnderDock)
            Toggle("Fill the Empty Space When the Dock Moves to Another Display", isOn: $state.fillAcrossDisplays)
                .disabled(!state.moveFromUnderDock)
        }

        Divider()

        Toggle("Launch at Login", isOn: $state.launchAtLogin)
        UpdateMenuItems(updater: state.updater)

        Divider()

        Button("Open DockFixer…") {
            // Two things matter here, and both were wrong before.
            //
            // Not `openWindow` directly: the app is an accessory at this point
            // and has to become an ordinary one again first, in that order.
            // `showMainWindow` owns the whole sequence.
            //
            // And not synchronously: this runs inside the menu's event-tracking
            // loop, and changing the activation policy from there is asking for
            // trouble. Hopping to the main queue defers the work until the menu
            // has closed and the run loop is back in its normal mode. Belt and
            // braces — the fault here was the nil delegate above, not this — but
            // deferring costs nothing.
            let open = { openWindow(id: DockFixerApp.mainWindowID) }
            DispatchQueue.main.async {
                delegate.openMainWindow = open
                delegate.showMainWindow()
            }
        }

        Button("Report a Bug…") {
            // As with the window above: an accessory app cannot own an
            // ordinary window, and the menu's tracking loop is no place to
            // change that, so it waits for the menu to close.
            let open = { openWindow(id: DockFixerApp.bugReportWindowID) }
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                open()
            }
        }

        Divider()

        Button("Quit DockFixer") { state.quit() }
            .keyboardShortcut("q")
    }
}

/// "Check for Updates…", and "Restart to Update" while a downloaded update
/// waits for the window to close. Observes the updater itself: a change
/// inside it does not redraw a view that only watches `AppState`.
private struct UpdateMenuItems: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if updater.updateIsWaiting {
            Button("Restart to Update") {
                // Off the menu's tracking loop first, as with the window below.
                DispatchQueue.main.async { updater.installNow() }
            }
        }
        Button("Check for Updates…") {
            DispatchQueue.main.async { updater.checkForUpdates() }
        }
        // Disabled rather than silent: a build without a feed never starts
        // Sparkle, and a check already running cannot start another.
        .disabled(!updater.canCheckForUpdates)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var pendingLoginHide: DispatchWorkItem?

    /// Supplied by the menu-bar item: the only way to rebuild the window scene
    /// after it has been closed. See `MenuBarIcon`.
    var openMainWindow: (() -> Void)?

    /// Closing the window must not quit the app: the display-change watcher has
    /// to keep running with the window shut. Quitting is explicit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Deliberately no command-line entry points.
    //
    // Starting the binary from a shell instead of launching the bundle makes
    // macOS attribute Accessibility requests to the *responsible process* — the
    // terminal emulator — rather than to DockFixer. The prompt then asks for the
    // terminal, the request is recorded against it, and DockFixer's own grant stops
    // matching. Debugging that cost several rounds before the cause was found.
    //
    // Everything is driven from the window and the menu-bar item instead.

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The log and Report a Bug windows close for real, unlike the main
        // window, whose close button only hides it. When one of them was the
        // last window up — opened from the menu with the main window away —
        // the app would keep a Dock icon with nothing behind it. A turn later
        // the closing window is no longer visible and the check is accurate.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.retreatToMenuBar() }
            }
        }

        // Restarted by an automatic update, with the grant intact: nobody
        // opened the app, so it goes straight back to the menu bar, as it was.
        // Without the grant the window is the one thing that can say so, and
        // falls through to being shown below.
        if Updater.takeRelaunchedAfterUpdate(), WindowScanner.isTrusted {
            stayInMenuBarAfterUpdate()
            return
        }

        // Showing the window has to be explicit. Activating alone leaves the
        // decision to window restoration, which is entitled to bring the app up
        // with its window closed — the app then flashes and vanishes, which is
        // exactly what opening it was meant not to do.
        showMainWindow(activate: false)
        // The scene may not have built its NSWindow yet, and restoration can
        // still close it after the first attempt lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.showMainWindow(activate: false)
        }

        // Started by launchd at login and already granted access: there is
        // nothing to say and nothing to do, so it should come up quietly in the
        // menu bar instead. But a login launch is not directly observable —
        // see `scheduleLoginHide` — so the window is shown first and taken away
        // only once nothing has claimed it.
        guard LoginItem.isEnabled, WindowScanner.isTrusted else { return }
        scheduleLoginHide()
    }

    /// Hides the window shortly after launch unless something activated the app.
    ///
    /// There is no supported way to ask macOS why a process was started.
    /// `XPC_SERVICE_NAME` used to stand in for it, and it does not work: a launch
    /// from Spotlight or Finder sets it to exactly the same
    /// `application.<bundle-id>.<n>.<n>` as a login launch does, so the app hid
    /// itself from users who had just opened it.
    ///
    /// What *is* observable is activation. Opening an app — Spotlight, Finder,
    /// the Dock — brings it to the front; launchd starting it at login does not,
    /// because the session's front application is something else. So the window
    /// is shown either way and withdrawn only if nobody comes for it.
    ///
    /// The ambiguity is resolved towards showing the window on purpose. Getting
    /// it wrong at login costs a window flashing past while the user is still
    /// logging in; getting it wrong the other way hides the app from someone who
    /// deliberately opened it.
    private func scheduleLoginHide() {
        let hide = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !NSApp.isActive else { return }
                AppState.current?.log.info("started at login — staying in the menu bar")
                for window in NSApp.windows where window.isVisible && Self.isMainWindow(window) {
                    window.close()
                }
                self.retreatToMenuBar()
            }
        }
        pendingLoginHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: hide)
    }

    /// Takes away the window the scene may have put up on its own, without
    /// waiting to see whether someone wanted it: unlike a login start, nobody
    /// could have. Not cancelled by activation either, since Sparkle's relaunch
    /// may activate the app. Twice, because the scene builds its window a turn
    /// or two late and restoration may bring it back once more.
    private func stayInMenuBarAfterUpdate() {
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if delay == 1.0 {
                        AppState.current?.log.info("restarted after an update — staying in the menu bar")
                    }
                    for window in NSApp.windows where window.isVisible && Self.isMainWindow(window) {
                        window.close()
                    }
                    self.retreatToMenuBar()
                }
            }
        }
    }

    /// Someone brought the app to the front, so it was not a silent login start.
    func applicationDidBecomeActive(_ notification: Notification) {
        pendingLoginHide?.cancel()
        pendingLoginHide = nil
    }

    /// Opening an app that is already running — clicking its Dock icon, picking
    /// it in Spotlight — has to bring the window back, otherwise the icon looks
    /// dead, since closing the window does not quit.
    ///
    /// The window is shown whether or not macOS thinks one is visible: an app
    /// with a menu-bar item always has windows of some kind, so `flag` is not a
    /// reliable answer to "can the user see anything".
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// Brings the main window up, whether it still exists or has to be rebuilt.
    ///
    /// The order is the whole point:
    ///
    /// 1. back to `.regular` — an accessory application cannot own an ordinary
    ///    window, and asking SwiftUI for one while it is still an accessory is
    ///    what left the menu item doing nothing;
    /// 2. activate, so the window has somewhere to come to the front of;
    /// 3. show the existing window, or ask SwiftUI to build one. A `Window`
    ///    scene lets go of its `NSWindow` when it is closed, and nothing in
    ///    AppKit can bring back what SwiftUI owns.
    /// - Parameter activate: whether to pull the app to the front as well. False
    ///   at launch, and only there: activation is the signal that distinguishes
    ///   a launch someone asked for from one launchd made at login, and an app
    ///   that activates itself destroys the evidence. Launch Services activates
    ///   an app it was told to open, so the answer arrives on its own.
    func showMainWindow(activate: Bool = true, retries: Int = 20) {
        NSApp.setActivationPolicy(.regular)
        if activate { NSApp.activate(ignoringOtherApps: true) }

        // SwiftUI's own route first: it re-adopts the scene, and it is a no-op
        // when the window is already open. Ordering the NSWindow in afterwards
        // covers the case where the scene thinks it is open and the window is
        // merely behind something.
        openMainWindow?()

        if let window = NSApp.windows.first(where: { Self.isMainWindow($0) }) {
            adopt(window)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Building the scene takes a turn of the run loop, sometimes more.
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.showMainWindow(activate: activate, retries: retries - 1)
        }
    }

    /// Makes the close button hide the window instead of closing it.
    ///
    /// A closed SwiftUI `Window` scene is gone: the `NSWindow` stays in
    /// `NSApp.windows` but reports `canBecomeMain == false` and cannot be
    /// ordered back in, and only SwiftUI can build a replacement. That put the
    /// whole restore path at the mercy of `openWindow`, which is reachable from
    /// a view and nowhere else.
    ///
    /// Hiding sidesteps all of it. The window object survives, so bringing it
    /// back is an `orderFront` and nothing more — no scene rebuild, no SwiftUI
    /// in the path at all. To the user it looks identical: the window goes away
    /// and the app leaves the Dock.
    private func adopt(_ window: NSWindow) {
        // Minimise and zoom are hidden: this is one small window of controls.
        // Minimising it puts it in the Dock, which is precisely the place the
        // app leaves when the window goes away, and zooming a fixed set of
        // checkboxes to full screen is nothing anyone wants. Close is the only
        // one that means something. Dragging the edges still resizes it.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        guard let button = window.standardWindowButton(.closeButton),
              button.target !== self
        else { return }
        button.target = self
        button.action = #selector(hideMainWindow)
    }

    /// What the close button does now: put the window away, keep the object.
    @objc func hideMainWindow() {
        for window in NSApp.windows where Self.isMainWindow(window) {
            window.orderOut(nil)
        }
        retreatToMenuBar()
    }

    /// Drops the Dock icon and the app-switcher entry, leaving only the
    /// menu-bar item. Called once the last real window is gone: an entry in the
    /// switcher that switches to nothing visible is worse than no entry.
    private func retreatToMenuBar() {
        guard !NSApp.windows.contains(where: { Self.isAppWindow($0) && $0.isVisible }) else { return }
        NSApp.setActivationPolicy(.accessory)
        // An update held back while the window was open can go in now.
        MainActor.assumeIsolated { AppState.current?.updater.installWhenIdle() }
    }

    /// A window of the app's own — settings or log — as opposed to the panels
    /// AppKit and SwiftUI keep around for the status item and other machinery.
    /// Those are not titled.
    ///
    /// Titled is the whole test, and `canBecomeMain` must not be added to it:
    /// a SwiftUI `Window` that has been closed reports `canBecomeMain == false`
    /// while still sitting in `NSApp.windows`, so requiring it made the one
    /// window this needs to find invisible to it.
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled)
    }

    /// The settings window in particular: the one the app shows, hides and
    /// withdraws at login. The log is only ever opened by hand.
    private static func isMainWindow(_ window: NSWindow) -> Bool {
        isAppWindow(window) && window.title == DockFixerApp.mainWindowTitle
    }

}
