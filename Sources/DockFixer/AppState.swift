import AppKit
import Combine
import DockFixerCore
import SwiftUI

/// Glue between the window and the scanner.
@MainActor
final class AppState: ObservableObject {

    /// On by default: correcting windows after a display change is the entire
    /// point, and a user who does not want it can switch it off.
    @Published var autoFixEnabled: Bool {
        didSet {
            guard oldValue != autoFixEnabled else { return }
            UserDefaults.standard.set(autoFixEnabled, forKey: Self.autoFixKey)
            autoFixEnabled ? startWatching() : stopWatching()
        }
    }

    /// Whether to also follow the Dock when it leaves a display — stretching
    /// windows into the strip it vacated instead of only pushing them out of
    /// its way. Separate from `autoFixEnabled` because it moves windows that
    /// nothing is currently overlapping, which is a bigger liberty to take.
    @Published var reclaimEnabled: Bool {
        didSet {
            guard oldValue != reclaimEnabled else { return }
            UserDefaults.standard.set(reclaimEnabled, forKey: Self.reclaimKey)
            log.info("follow the Dock off a display: \(reclaimEnabled ? "enabled" : "disabled")")
        }
    }

    /// Whether the log pane is on show. Off by default: the window is a place to
    /// press a button, and the log is for when something looked wrong.
    @Published var showLogs: Bool {
        didSet {
            guard oldValue != showLogs else { return }
            UserDefaults.standard.set(showLogs, forKey: Self.showLogsKey)
        }
    }

    /// Mirrors `SMAppService`; kept in sync rather than trusted blindly, because
    /// macOS can hold the registration back pending approval.
    @Published var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin, !isSyncingLoginItem else { return }
            applyLaunchAtLogin()
        }
    }

    /// Accessibility access can be granted or revoked outside the app, so this
    /// is polled rather than read once.
    @Published private(set) var isTrusted: Bool
    @Published private(set) var isBusy = false
    /// The current displays, for the window to describe one per row.
    @Published private(set) var screens: [ScreenInfo] = []
    @Published private(set) var lastSummary: ScanSummary?

    let log: Log

    /// The live instance, for the app delegate: it runs before this is built and
    /// has no way to be handed a reference, but it has decisions worth logging.
    private(set) static weak var current: AppState?

    private static let autoFixKey = "autoFixOnDisplayChange"
    private static let reclaimKey = "followDockOffDisplay"
    private static let showLogsKey = "showLogs"
    /// How long to wait before repeating a pass that could not read the windows.
    private static let retryDelays: [TimeInterval] = [0.75, 1.5, 3]
    /// How long a new window is left alone before it is checked. It is
    /// announced the moment it exists, which is before its application has
    /// finished placing and sizing it.
    private static let newWindowDelay: TimeInterval = 0.3
    private let scanner = WindowScanner()
    private var watcher: DisplayWatcher?
    private var windowWatcher: WindowWatcher?
    private var pollTimer: Timer?
    private var isSyncingLoginItem = false

    /// A pass requested while another was running. Display changes must not be
    /// dropped just because a pass happened to be in flight.
    private var queuedRun: String?

    /// The display layout as it was before the last change: what tells the
    /// scanner how much room the Dock gave back. Kept only until a pass has
    /// used it, because it describes one event — the correction itself is
    /// idempotent, but a snapshot from ten minutes ago says nothing about
    /// windows the user has moved since.
    private var pendingReclaim: [ScreenInfo]?

    /// Findings that repeat identically on every pass, already logged once.
    private var noticesLogged = Set<String>()

    init() {
        log = Log()
        UserDefaults.standard.register(defaults: [
            Self.autoFixKey: true,
            Self.reclaimKey: true,
            Self.showLogsKey: false,
        ])
        autoFixEnabled = UserDefaults.standard.bool(forKey: Self.autoFixKey)
        reclaimEnabled = UserDefaults.standard.bool(forKey: Self.reclaimKey)
        showLogs = UserDefaults.standard.bool(forKey: Self.showLogsKey)
        launchAtLogin = LoginItem.isEnabled
        isTrusted = WindowScanner.isTrusted

        watcher = DisplayWatcher(log: log) { [weak self] reason, previousScreens in
            guard let self else { return }
            // Two changes in a row before a pass gets to run: the older
            // snapshot is the truer "before", so it is the one kept.
            if pendingReclaim == nil {
                pendingReclaim = previousScreens
            }
            run(trigger: reason)
        }

        windowWatcher = WindowWatcher(log: log) { [weak self] window, pid, appName in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.newWindowDelay) {
                MainActor.assumeIsolated {
                    self?.fixNewWindow(window, pid: pid, appName: appName)
                }
            }
        }

        Self.current = self

        refreshDisplays()
        log.info("DockFixer ready — \(displaysSummary)")
        log.info("launch at login: \(LoginItem.statusDescription)")
        log.info("follow the Dock off a display: \(reclaimEnabled ? "enabled" : "disabled")")

        if !isTrusted {
            log.info("Accessibility access not granted yet; approve DockFixer in the system prompt, or press Grant")
            // Ask straight away rather than at the first button press: the grant
            // has to be in place before anything useful can happen.
            WindowScanner.requestTrust()
        }
        if autoFixEnabled {
            startWatching()
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
    }

    // MARK: - Actions

    func moveWindows() {
        run(trigger: "Fix Windows Now")
    }

    func requestAccessibility() {
        WindowScanner.requestTrust()
        log.info("Accessibility prompt requested — grant DockFixer in System Settings, then come back")
        // The System Settings pane, in case the prompt was dismissed earlier and
        // will not appear again.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func clearLog() {
        log.clear()
        noticesLogged.removeAll()
    }

    func openLogFile() {
        NSWorkspace.shared.selectFile(log.fileURL.path,
                                      inFileViewerRootedAtPath: log.fileURL.deletingLastPathComponent().path)
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.bufferText, forType: .string)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Internals

    private func startWatching() {
        watcher?.start()
        windowWatcher?.start()
    }

    private func stopWatching() {
        watcher?.stop()
        windowWatcher?.stop()
    }

    /// Not a pass: only the window that opened is looked at, so it neither
    /// waits for one that is running nor uses up the layout a display change
    /// left behind. Silent when the window was fine, which is nearly always.
    private func fixNewWindow(_ window: AXUIElement, pid: pid_t, appName: String) {
        guard isTrusted else { return }
        scanner.run(window: window, pid: pid, appName: appName,
                    debugDetail: log.isDebug) { [weak self] summary in
            guard let self else { return }
            record(summary)
            if summary.candidates > 0 {
                log.info("new window — \(summary.headline)")
            }
        }
    }

    private func run(trigger: String, attempt: Int = 0) {
        guard isTrusted else {
            log.add(level: .fail, app: "DockFixer", title: "",
                    detail: "cannot scan windows without Accessibility access")
            requestAccessibility()
            return
        }

        // A display change arriving mid-pass is remembered rather than lost. The
        // newest request wins; running the same pass twice would be pointless.
        if isBusy {
            queuedRun = trigger
            log.info("\(trigger) queued — a pass is already running")
            return
        }

        isBusy = true

        // Consumed whether or not the reclaim is switched on: a snapshot kept
        // across a change nobody acted on would only go stale.
        let previousScreens = reclaimEnabled ? pendingReclaim : nil
        pendingReclaim = nil
        log.debug("\(trigger): pass starting"
            + (attempt > 0 ? ", attempt \(attempt + 1)" : "")
            + (previousScreens == nil ? ", no layout to compare against" : ", comparing against the layout before the change"))

        scanner.run(previousScreens: previousScreens, debugDetail: log.isDebug) { [weak self] summary in
            guard let self else { return }
            record(summary)
            // One line per pass, at the end, when there is something to report.
            // The trigger is not repeated: a display change was already logged
            // by the watcher, and a button press was made by the person reading
            // this.
            log.info("pass — \(summary.headline)")
            lastSummary = summary
            isBusy = false

            if let queued = queuedRun {
                queuedRun = nil
                return run(trigger: queued)
            }
            retryIfNothingWasReadable(summary,
                                      previousScreens: previousScreens,
                                      trigger: trigger,
                                      attempt: attempt)
        }
    }

    /// Applications stop answering while the window server rebuilds the display
    /// layout, and a display change is precisely when this app runs. A pass that
    /// lands in that gap reads no windows at all, and the harm is not the wasted
    /// pass: it consumed the snapshot of the layout before the change, which is
    /// the only record of where the Dock used to be. That snapshot describes one
    /// event and cannot be taken again afterwards, so it goes back and the pass
    /// is repeated.
    ///
    /// Bounded, with the waits growing: a display that never comes back to life
    /// is not something to poll forever, and a Thunderbolt dock can take several
    /// seconds to settle.
    private func retryIfNothingWasReadable(_ summary: ScanSummary,
                                           previousScreens: [ScreenInfo]?,
                                           trigger: String,
                                           attempt: Int) {
        let unreadable = summary.skips[.unreadable] ?? 0
        guard unreadable > 0 else { return }
        guard attempt < Self.retryDelays.count else {
            log.info("\(unreadable) \(unreadable == 1 ? "window" : "windows") still could not be read — giving up on this change")
            return
        }

        // The older snapshot is the truer "before", the same rule the watcher's
        // handler follows, and this one predates anything that has arrived since.
        if let previousScreens {
            pendingReclaim = previousScreens
        }

        let delay = Self.retryDelays[attempt]
        log.info("\(unreadable) \(unreadable == 1 ? "window" : "windows") could not be read — trying again in \(Int(delay * 1000))ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.run(trigger: trigger, attempt: attempt + 1)
            }
        }
    }

    private func record(_ summary: ScanSummary) {
        for outcome in summary.outcomes {
            if outcome.logOncePerSession {
                let key = "\(outcome.app)|\(outcome.detail)"
                guard noticesLogged.insert(key).inserted else { continue }
            }
            log.add(level: outcome.level,
                    app: outcome.app,
                    title: outcome.title,
                    detail: outcome.detail)
        }
    }

    private func poll() {
        let trusted = WindowScanner.isTrusted
        if trusted != isTrusted {
            isTrusted = trusted
            log.info("Accessibility access \(trusted ? "granted" : "revoked")")
            // Observers cannot be registered without the grant, so the ones
            // attempted before it was given all failed.
            if trusted, autoFixEnabled {
                windowWatcher?.stop()
                windowWatcher?.start()
            }
        }

        // Approving a login item happens in System Settings, outside the app.
        let registered = LoginItem.isEnabled
        if registered != launchAtLogin {
            isSyncingLoginItem = true
            launchAtLogin = registered
            isSyncingLoginItem = false
        }

        refreshDisplays()
    }

    private func applyLaunchAtLogin() {
        do {
            try LoginItem.set(launchAtLogin)
            log.info("launch at login: \(LoginItem.statusDescription)")
        } catch {
            log.add(level: .fail, app: "DockFixer", title: "",
                    detail: "could not \(launchAtLogin ? "enable" : "disable") launch at login: \(error.localizedDescription)")
            isSyncingLoginItem = true
            launchAtLogin = LoginItem.isEnabled
            isSyncingLoginItem = false
        }
    }

    private func refreshDisplays() {
        let current = ScreenMap.current()
        // Polled twice a second; only publish when something actually moved, so
        // the window is not relaid out for nothing.
        guard current != screens else { return }
        screens = current
    }

    /// One line for the log, where a list of rows would not fit.
    var displaysSummary: String {
        screens.map { screen in
            "\(screen.localizedName) \(Int(screen.axFrame.width))x\(Int(screen.axFrame.height))"
                + " dock \(screen.dockEdge)"
                + (screen.isPrimary && screens.count > 1 ? " (primary)" : "")
        }
        .joined(separator: "   ·   ")
    }
}
