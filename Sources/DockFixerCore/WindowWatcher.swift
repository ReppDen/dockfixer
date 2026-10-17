import AppKit
import ApplicationServices

/// Notices windows as they open, so one that lands under the Dock is pulled out
/// straight away rather than at the next display change.
///
/// macOS keeps a new window clear of the menu bar but not of the Dock. An
/// application that restores a remembered frame, or opens a window against a
/// screen edge the way Notes does with Quick Note, puts it underneath the Dock,
/// and nothing about the display layout changes to set off a pass.
///
/// Only the new window is handed over. Every other window is where the user
/// left it, and opening an unrelated one is no reason to move it.
///
/// Two more moments count as a window appearing, because Accessibility does
/// not list a window while it cannot be seen: an application hidden with ⌘H
/// being shown again, and a switch to another Space. A display change that
/// happens while a window is out of sight is handled by nobody — macOS drops
/// the window on the remaining display, under the Dock if that is where its
/// corner lands, and the pass for that change never saw it. When it comes back
/// into view it is handed over like a window that has just opened.
///
/// And one that is not quite a window appearing: a window restored from the
/// Dock. A pass skips minimised windows, so one comes back exactly where it
/// was minimised, whatever the Dock did meanwhile — and on a full Dock it
/// changes width every time an application opens or quits, and with every
/// window minimised or restored. The window lands under a Dock that grew, or
/// with a gap beside one that shrank, and with nothing about the layout left
/// to change, nothing set off a pass. So the layout is remembered when the
/// window is minimised, and the window is handed over with it when it comes
/// back.
@MainActor
public final class WindowWatcher {

    /// What brought a window to the handler.
    public enum Event {
        /// Opened, or back in view after ⌘H or a Space switch.
        case appeared
        /// Restored from the Dock. `minimizedIn` is the layout when it was
        /// minimised, or `nil` when that happened before the watcher was
        /// running.
        case restored(minimizedIn: [ScreenInfo]?)
    }

    public typealias Handler = (_ window: AXUIElement, _ pid: pid_t, _ appName: String, _ event: Event) -> Void

    /// Layouts kept for minimised windows. A window closed while minimised
    /// never says so, so the oldest ones are let go past this many.
    private static let minimizedLimit = 200

    /// How often to try again to observe an application that has only just
    /// launched: its accessibility tree is not always up yet when the launch is
    /// announced.
    private static let attachDelays: [TimeInterval] = [0.5, 1, 2]

    private let log: Log
    private let handler: Handler

    private var observers: [pid_t: AXObserver] = [:]
    /// The layout each minimised window was minimised in. A list, because an
    /// `AXUIElement` is only comparable with `CFEqual`.
    private var minimized: [(window: AXUIElement, pid: pid_t, screens: [ScreenInfo])] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    public private(set) var isRunning = false

    public init(log: Log, handler: @escaping Handler) {
        self.log = log
        self.handler = handler
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else { return }
                MainActor.assumeIsolated {
                    // Its first windows may well be open before the observer
                    // is, so they are handed over as new too.
                    self?.attach(app, handOverExisting: true)
                }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else { return }
                MainActor.assumeIsolated {
                    self?.detach(app.processIdentifier)
                }
            },
            center.addObserver(forName: NSWorkspace.didUnhideApplicationNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else { return }
                MainActor.assumeIsolated {
                    self?.handOver(windowsOf: [app], reason: "shown again")
                }
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handOver(windowsOf: NSWorkspace.shared.runningApplications,
                                   reason: "Space changed")
                }
            },
        ]

        for app in NSWorkspace.shared.runningApplications {
            attach(app, handOverExisting: false)
        }
        log.info("watching \(observers.count) apps for new windows")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
        for pid in Array(observers.keys) {
            detach(pid)
        }
    }

    // MARK: - Per application

    private func attach(_ app: NSRunningApplication, handOverExisting: Bool, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard isRunning,
              !app.isTerminated,
              app.activationPolicy == .regular,
              pid != ProcessInfo.processInfo.processIdentifier,
              observers[pid] == nil
        else { return }
        let name = app.localizedName ?? "pid \(pid)"

        var created: AXObserver?
        // In the ordinary log: a new window of this application will not be
        // looked at, and that is exactly what a report about one would ask.
        guard AXObserverCreate(pid, windowCallback, &created) == .success, let observer = created else {
            log.info("\(name): not watching for new windows — could not create an accessibility observer")
            return
        }

        let element = AX.application(pid: pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverAddNotification(observer, element,
                                               kAXWindowCreatedNotification as CFString, refcon)
        guard result == .success else {
            guard attempt < Self.attachDelays.count else {
                log.info("\(name): not watching for new windows — \(AX.describe(result))")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.attachDelays[attempt]) { [weak self] in
                MainActor.assumeIsolated {
                    self?.attach(app, handOverExisting: handOverExisting, attempt: attempt + 1)
                }
            }
            return
        }
        // Once creation is being watched the application answers, so these
        // are expected to succeed; one that does not only costs the restored
        // case, and is said so.
        for notification in [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            let added = AXObserverAddNotification(observer, element, notification as CFString, refcon)
            if added != .success {
                log.info("\(name): not watching for \(notification) — \(AX.describe(added))")
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer

        if handOverExisting {
            for window in AX.windows(of: element) ?? [] {
                handler(window, pid, name, .appeared)
            }
        }
    }

    /// Every window these applications show right now goes to the handler,
    /// which moves only the ones under the Dock and says nothing about the rest.
    /// Only applications already being watched: the filter on what is worth
    /// watching was applied when they were attached.
    ///
    /// The notification that an application was shown again arrives before
    /// Accessibility lists its windows — the first look found none, every
    /// time — so an empty answer is tried again after the same delays as a
    /// launch. An application that genuinely has no windows costs three looks.
    private func handOver(windowsOf apps: [NSRunningApplication], reason: String, attempt: Int = 0) {
        guard isRunning else { return }
        var windows: [(AXUIElement, pid_t, String)] = []
        var appsSeen = 0
        for app in apps {
            let pid = app.processIdentifier
            let name = app.localizedName ?? "pid \(pid)"
            guard observers[pid] != nil else { continue }
            // Accessibility lists only the windows on the current Space, so an
            // application shown again whose windows are elsewhere answers with
            // none here; the switch to its Space, if macOS makes one, is the
            // event that finds them.
            guard let found = AX.windows(of: AX.application(pid: pid)), !found.isEmpty else { continue }
            appsSeen += 1
            for window in found {
                windows.append((window, pid, name))
            }
        }
        if windows.isEmpty, attempt < Self.attachDelays.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.attachDelays[attempt]) { [weak self] in
                MainActor.assumeIsolated {
                    self?.handOver(windowsOf: apps, reason: reason, attempt: attempt + 1)
                }
            }
            return
        }
        log.debug("\(reason) — \(windows.count) window\(windows.count == 1 ? "" : "s") in \(appsSeen) app\(appsSeen == 1 ? "" : "s") handed over"
            + (attempt > 0 ? " on look \(attempt + 1)" : ""))
        for (window, pid, name) in windows {
            handler(window, pid, name, .appeared)
        }
    }

    private func detach(_ pid: pid_t) {
        minimized.removeAll { $0.pid == pid }
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Quick Note, for one, is a fresh window every time it opens rather than a
    /// hidden one brought back, so creation is what matters for new windows.
    fileprivate func received(window: AXUIElement, notification: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"

        func debug(_ what: String) {
            guard log.isDebug else { return }
            let title = AX.string(window, kAXTitleAttribute as String) ?? ""
            let frame = AX.frame(window)?.logDescription ?? "unreadable"
            log.debug("\(what) — \(name) \"\(title)\" \(frame)")
        }

        switch notification {
        case kAXWindowMiniaturizedNotification:
            // Read now, while the Dock is still the width it was with the
            // window on screen: the tile the window turns into changes it.
            debug("window minimized")
            minimized.removeAll { CFEqual($0.window, window) }
            minimized.append((window, pid, ScreenMap.current()))
            if minimized.count > Self.minimizedLimit {
                minimized.removeFirst(minimized.count - Self.minimizedLimit)
            }
        case kAXWindowDeminiaturizedNotification:
            debug("window restored")
            let index = minimized.firstIndex { CFEqual($0.window, window) }
            let screens = index.map { minimized.remove(at: $0).screens }
            handler(window, pid, name, .restored(minimizedIn: screens))
        default:
            debug("window opened")
            handler(window, pid, name, .appeared)
        }
    }
}

/// A C function pointer cannot capture, so the watcher travels as the refcon.
/// Delivered on the main run loop, which is where the sources are added.
private let windowCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let watcher = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        watcher.received(window: element, notification: name)
    }
}
