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
@MainActor
public final class WindowWatcher {

    public typealias Handler = (_ window: AXUIElement, _ pid: pid_t, _ appName: String) -> Void

    /// How often to try again to observe an application that has only just
    /// launched: its accessibility tree is not always up yet when the launch is
    /// announced.
    private static let attachDelays: [TimeInterval] = [0.5, 1, 2]

    private let log: Log
    private let handler: Handler

    private var observers: [pid_t: AXObserver] = [:]
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
        ]

        for app in NSWorkspace.shared.runningApplications {
            attach(app, handOverExisting: false)
        }
        log.debug("watching \(observers.count) apps for new windows")
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
        guard AXObserverCreate(pid, windowCallback, &created) == .success, let observer = created else {
            log.debug("\(name): could not create an accessibility observer")
            return
        }

        let element = AX.application(pid: pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverAddNotification(observer, element,
                                               kAXWindowCreatedNotification as CFString, refcon)
        guard result == .success else {
            guard attempt < Self.attachDelays.count else {
                log.debug("\(name): not watching for new windows — \(AX.describe(result))")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.attachDelays[attempt]) { [weak self] in
                MainActor.assumeIsolated {
                    self?.attach(app, handOverExisting: handOverExisting, attempt: attempt + 1)
                }
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer

        if handOverExisting {
            for window in AX.windows(of: element) ?? [] {
                handler(window, pid, name)
            }
        }
    }

    private func detach(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Quick Note, for one, is a fresh window every time it opens rather than a
    /// hidden one brought back, so creation is the only event that matters.
    fileprivate func received(window: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"

        if log.isDebug {
            let title = AX.string(window, kAXTitleAttribute as String) ?? ""
            let frame = AX.frame(window)?.logDescription ?? "unreadable"
            log.debug("window opened — \(name) \"\(title)\" \(frame)")
        }
        handler(window, pid, name)
    }
}

/// A C function pointer cannot capture, so the watcher travels as the refcon.
/// Delivered on the main run loop, which is where the sources are added.
private let windowCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon else { return }
    let watcher = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        watcher.received(window: element)
    }
}
