import AppKit
import Combine
import DockFixerCore
import SwiftUI

/// Glue between the window and the scanner.
@MainActor
final class AppState: ObservableObject {

    // The three things that start a correction, each with a switch of its own,
    // all on by default: each is the app doing its job, and each can be turned
    // off without losing the other two.

    /// A window that opens under the Dock is moved out of it.
    @Published var newWindowsEnabled: Bool {
        didSet {
            guard oldValue != newWindowsEnabled else { return }
            UserDefaults.standard.set(newWindowsEnabled, forKey: Self.newWindowsKey)
            log.info("move new windows: \(newWindowsEnabled ? "enabled" : "disabled")")
            updateWatchers()
        }
    }

    /// The Dock grows, shrinks or moves to another edge: windows under it move
    /// out, and windows resting against it follow it back as it shrinks.
    /// Following it back is the reclaim, and it is part of this switch rather
    /// than of `reclaimEnabled`: without it the windows would only ever be
    /// pushed, and would drift away from a Dock that keeps changing size.
    @Published var dockChangesEnabled: Bool {
        didSet {
            guard oldValue != dockChangesEnabled else { return }
            UserDefaults.standard.set(dockChangesEnabled, forKey: Self.dockChangesKey)
            log.info("move windows when the Dock changes: \(dockChangesEnabled ? "enabled" : "disabled")")
            updateWatchers()
        }
    }

    /// A Dock on the side of the display breathes by a point or two as
    /// applications open and quit. On, such changes move nothing and a window
    /// within the same distance of the Dock is left alone; off, every change
    /// is acted on and windows follow the Dock's exact edge. Off for now, to
    /// see how the exact behaviour feels day to day.
    @Published var ignoreSmallDockChanges: Bool {
        didSet {
            guard oldValue != ignoreSmallDockChanges else { return }
            UserDefaults.standard.set(ignoreSmallDockChanges, forKey: Self.ignoreSmallDockChangesKey)
            log.info("ignore Dock changes of \(Int(dockNoise))pt or less: \(ignoreSmallDockChanges ? "enabled" : "disabled")")
            watcher?.ignoreSmallDockChanges = ignoreSmallDockChanges
        watcher?.timing = timing
        }
    }

    /// No waiting: see `Timing`. On by default — the waits were insurance
    /// against moving a window twice, and twice beats seconds under the Dock.
    @Published var turboEnabled: Bool {
        didSet {
            guard oldValue != turboEnabled else { return }
            UserDefaults.standard.set(turboEnabled, forKey: Self.turboKey)
            log.info("turbo mode: \(turboEnabled ? "enabled" : "disabled")")
            watcher?.timing = timing
        }
    }

    /// A display is connected or removed, and macOS shuffles windows under the
    /// Dock. On by default: this is what the app was first made for.
    @Published var displayChangesEnabled: Bool {
        didSet {
            guard oldValue != displayChangesEnabled else { return }
            UserDefaults.standard.set(displayChangesEnabled, forKey: Self.displayChangesKey)
            log.info("move windows when displays change: \(displayChangesEnabled ? "enabled" : "disabled")")
            updateWatchers()
        }
    }

    /// Whether a display the Dock has left gets its windows stretched into the
    /// strip it vacated, instead of only pushing windows out of the Dock's way.
    /// Its own switch because it moves windows nothing is overlapping, which is
    /// a bigger liberty to take. Display changes only: see `dockChangesEnabled`.
    @Published var reclaimEnabled: Bool {
        didSet {
            guard oldValue != reclaimEnabled else { return }
            UserDefaults.standard.set(reclaimEnabled, forKey: Self.reclaimKey)
            log.info("fill the space the Dock leaves: \(reclaimEnabled ? "enabled" : "disabled")")
        }
    }

    /// Whether the menu-bar item is left out. Off by default: with the window
    /// closed it is the only visible part of the app. Opening the app again
    /// brings the window back, which is the way in once it is hidden.
    @Published var hideMenuBarIcon: Bool {
        didSet {
            guard oldValue != hideMenuBarIcon else { return }
            UserDefaults.standard.set(hideMenuBarIcon, forKey: Self.hideMenuBarIconKey)
            log.info("menu bar icon: \(hideMenuBarIcon ? "hidden" : "shown")")
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
    /// What the last pass did, in words, for the foot of the window.
    @Published private(set) var lastActivity: Activity?

    struct Activity: Equatable {
        let text: String
        let date: Date
        /// Something could not be moved, and the log says why.
        let needsAttention: Bool
    }

    let log: Log

    /// The live instance, for the app delegate: it runs before this is built and
    /// has no way to be handed a reference, but it has decisions worth logging.
    private(set) static weak var current: AppState?

    private static let newWindowsKey = "moveNewWindows"
    private static let dockChangesKey = "moveOnDockChange"
    private static let ignoreSmallDockChangesKey = "ignoreSmallDockChanges"
    private static let turboKey = "turboMode"
    private static let displayChangesKey = "autoFixOnDisplayChange"
    private static let reclaimKey = "followDockOffDisplay"
    private static let hideMenuBarIconKey = "hideMenuBarIcon"
    /// How long to wait before repeating a pass that could not read the windows.
    private static let retryDelays: [TimeInterval] = [0.75, 1.5, 3]
    private var timing: Timing { turboEnabled ? .turbo : .standard }
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

    /// Set by the button, cleared by the pass that answers it.
    private var answerNextPass = false

    /// Findings that repeat identically on every pass, already logged once.
    private var noticesLogged = Set<String>()

    init() {
        log = Log()
        UserDefaults.standard.register(defaults: [
            Self.newWindowsKey: true,
            Self.dockChangesKey: true,
            Self.ignoreSmallDockChangesKey: false,
            Self.turboKey: true,
            Self.displayChangesKey: true,
            Self.reclaimKey: true,
            Self.hideMenuBarIconKey: false,
        ])
        newWindowsEnabled = UserDefaults.standard.bool(forKey: Self.newWindowsKey)
        dockChangesEnabled = UserDefaults.standard.bool(forKey: Self.dockChangesKey)
        ignoreSmallDockChanges = UserDefaults.standard.bool(forKey: Self.ignoreSmallDockChangesKey)
        turboEnabled = UserDefaults.standard.bool(forKey: Self.turboKey)
        displayChangesEnabled = UserDefaults.standard.bool(forKey: Self.displayChangesKey)
        reclaimEnabled = UserDefaults.standard.bool(forKey: Self.reclaimKey)
        hideMenuBarIcon = UserDefaults.standard.bool(forKey: Self.hideMenuBarIconKey)
        launchAtLogin = LoginItem.isEnabled
        isTrusted = WindowScanner.isTrusted

        watcher = DisplayWatcher(log: log) { [weak self] reason, previousScreens in
            guard let self else { return }
            // The same notification for both, so which one it was is read off
            // the layouts: see `classifyLayoutChange`.
            let keepLayout: Bool
            switch classifyLayoutChange(previous: previousScreens, current: ScreenMap.current()) {
            case .dock:
                guard dockChangesEnabled else {
                    return log.debug("the Dock changed; moving windows for that is off")
                }
                keepLayout = true
            case .displays:
                guard displayChangesEnabled else {
                    return log.debug("the displays changed; moving windows for that is off")
                }
                keepLayout = reclaimEnabled
            }
            if keepLayout {
                // Two changes in a row before a pass gets to run: the older
                // snapshot is the truer "before", so it is the one kept.
                if pendingReclaim == nil {
                    pendingReclaim = previousScreens
                }
            } else {
                // Nothing may be reclaimed for this change, and an older
                // snapshot would reclaim across it.
                pendingReclaim = nil
            }
            run(trigger: reason)
        }
        watcher?.ignoreSmallDockChanges = ignoreSmallDockChanges
        watcher?.timing = timing

        windowWatcher = WindowWatcher(log: log) { [weak self] window, pid, appName in
            // A window is announced the moment it exists, which is before its
            // application has finished placing and sizing it.
            DispatchQueue.main.asyncAfter(deadline: .now() + (self?.timing.newWindow ?? 0)) {
                MainActor.assumeIsolated {
                    self?.fixNewWindow(window, pid: pid, appName: appName)
                }
            }
        }

        Self.current = self

        refreshDisplays()
        log.info("DockFixer ready — \(displaysSummary)")
        log.info("launch at login: \(LoginItem.statusDescription)")
        log.info("move windows — new windows: \(onOff(newWindowsEnabled)), Dock changes: \(onOff(dockChangesEnabled))"
            + " (ignoring \(Int(dockNoise))pt or less: \(onOff(ignoreSmallDockChanges)), turbo: \(onOff(turboEnabled)))"
            + ", display changes: \(onOff(displayChangesEnabled)), fill the space the Dock leaves: \(onOff(reclaimEnabled))")

        if !isTrusted {
            log.info("Accessibility access not granted yet; approve DockFixer in the system prompt, or press Grant")
            // Ask straight away rather than at the first button press: the grant
            // has to be in place before anything useful can happen.
            WindowScanner.requestTrust()
        }
        updateWatchers()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
    }

    // MARK: - Actions

    func moveWindows() {
        // A press that changes nothing still needs an answer, or the button
        // looks broken. Automatic passes that change nothing stay quiet.
        answerNextPass = true
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

    /// Each watcher runs while anything needs it: the display watcher serves
    /// both Dock and display changes, since macOS reports them as one.
    private func updateWatchers() {
        dockChangesEnabled || displayChangesEnabled ? watcher?.start() : watcher?.stop()
        newWindowsEnabled ? windowWatcher?.start() : windowWatcher?.stop()
    }

    private func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    /// The two filters have to agree: a window left alone because it sticks out
    /// by less than the Dock is allowed to breathe, and a Dock change ignored
    /// for being that small, are the same tolerance seen from two sides.
    private var slack: CGFloat { ignoreSmallDockChanges ? dockNoise : 0 }

    /// Not a pass: only the window that opened is looked at, so it neither
    /// waits for one that is running nor uses up the layout a display change
    /// left behind. Silent when the window was fine, which is nearly always.
    private func fixNewWindow(_ window: AXUIElement, pid: pid_t, appName: String) {
        guard isTrusted else { return }
        scanner.run(window: window, pid: pid, appName: appName,
                    slack: slack, debugDetail: log.isDebug) { [weak self] summary in
            guard let self else { return }
            record(summary)
            if summary.candidates > 0 {
                log.info("new window — \(summary.headline)")
                describe(summary, answering: false)
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
        let started = Date()

        // Whether it may be used was decided when the change arrived. Consumed
        // either way: a snapshot kept across a pass would only go stale.
        let previousScreens = pendingReclaim
        pendingReclaim = nil
        log.debug("\(trigger): pass starting"
            + (attempt > 0 ? ", attempt \(attempt + 1)" : "")
            + (previousScreens == nil ? ", no layout to compare against" : ", comparing against the layout before the change"))

        scanner.run(previousScreens: previousScreens, slack: slack, debugDetail: log.isDebug) { [weak self] summary in
            guard let self else { return }
            record(summary)
            // One line per pass, at the end, when there is something to report.
            // The trigger is not repeated: a display change was already logged
            // by the watcher, and a button press was made by the person reading
            // this.
            // How long it took only when that is worth noticing: after a wake
            // or a display change applications answer slowly, and a pass that
            // reads the layout at its start and writes seconds later is the
            // first thing to suspect when windows land somewhere odd.
            let took = Date().timeIntervalSince(started)
            log.info("pass — \(summary.headline)"
                + (took >= 1 ? " — took \(String(format: "%.1f", took))s" : ""))
            describe(summary, answering: answerNextPass)
            answerNextPass = false
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

    /// The pass in the words someone looking at the window would use: which
    /// window, not how many were minimised. The counts stay in the log.
    private func describe(_ summary: ScanSummary, answering: Bool) {
        let moved = summary.outcomes.filter { $0.level == .moved }
        let text: String
        if summary.failed > 0 {
            text = summary.failed == 1
                ? "Couldn't fix a window — see the log"
                : "Couldn't fix \(summary.failed) windows — see the log"
        } else if moved.count == 1, let app = moved.first?.app {
            text = "Fixed a \(app) window"
        } else if moved.count > 1 {
            text = "Fixed \(moved.count) windows"
        } else if answering {
            text = "Nothing to fix — every window is away from the Dock"
        } else {
            return
        }
        lastActivity = Activity(text: text, date: Date(), needsAttention: summary.failed > 0)
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
            if trusted, newWindowsEnabled {
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
