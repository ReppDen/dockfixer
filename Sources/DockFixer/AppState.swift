import AppKit
import Combine
import DockFixerCore
import SwiftUI

/// Glue between the window and the scanner.
@MainActor
final class AppState: ObservableObject {

    // Two switches for what may be done to windows, both on by default, and
    // one for the external display. Cut by what happens to a window rather
    // than by what set it off: the user cares what will be done to their
    // windows, not which notification it was.

    /// Windows under the Dock are moved out of it — a window that opens or
    /// comes back there, a Dock that grew, a display that was plugged in or
    /// out. Off, nothing watches and nothing moves: the other switches only
    /// add to this one.
    @Published var moveFromUnderDock: Bool {
        didSet {
            guard oldValue != moveFromUnderDock else { return }
            UserDefaults.standard.set(moveFromUnderDock, forKey: Self.moveFromUnderDockKey)
            log.info("move windows that are under the Dock: \(moveFromUnderDock ? "enabled" : "disabled")")
            updateWatchers()
        }
    }

    /// Windows next to the Dock stay next to it as it shrinks or moves to
    /// another edge, and a window within a few points of it is put against
    /// it. Its own switch because it moves windows nothing is overlapping.
    @Published var stickToDock: Bool {
        didSet {
            guard oldValue != stickToDock else { return }
            UserDefaults.standard.set(stickToDock, forKey: Self.stickToDockKey)
            log.info("stick windows to the Dock: \(stickToDock ? "enabled" : "disabled")")
        }
    }

    /// A Dock on the side of the display breathes by a point or two as
    /// applications open and quit. On, such changes move nothing and a window
    /// within the same distance of the Dock is left alone; off, every change
    /// is acted on and windows follow the Dock's exact edge. Off by default:
    /// the exact edge is what "stick" promises.
    @Published var ignoreSmallDockChanges: Bool {
        didSet {
            guard oldValue != ignoreSmallDockChanges else { return }
            UserDefaults.standard.set(ignoreSmallDockChanges, forKey: Self.ignoreSmallDockChangesKey)
            log.info("skip Dock changes of \(Int(dockNoise))pt or less: \(ignoreSmallDockChanges ? "enabled" : "disabled")")
            watcher?.ignoreSmallDockChanges = ignoreSmallDockChanges
        }
    }

    /// Whether a display the Dock has left for another one gets its windows
    /// stretched into the strip it vacated.
    @Published var fillAcrossDisplays: Bool {
        didSet {
            guard oldValue != fillAcrossDisplays else { return }
            UserDefaults.standard.set(fillAcrossDisplays, forKey: Self.fillAcrossDisplaysKey)
            log.info("fill the space the Dock leaves on another display: \(fillAcrossDisplays ? "enabled" : "disabled")")
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

    private static let moveFromUnderDockKey = "moveWindowsUnderDock"
    private static let stickToDockKey = "stickWindowsToDock"
    private static let ignoreSmallDockChangesKey = "ignoreSmallDockChanges"
    private static let fillAcrossDisplaysKey = "fillAcrossDisplays"
    private static let hideMenuBarIconKey = "hideMenuBarIcon"
    /// How long to wait before repeating a pass that could not read the windows.
    private static let retryDelays: [TimeInterval] = [0.75, 1.5, 3]
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
            Self.moveFromUnderDockKey: true,
            Self.stickToDockKey: true,
            Self.ignoreSmallDockChangesKey: false,
            Self.fillAcrossDisplaysKey: true,
            Self.hideMenuBarIconKey: false,
        ])
        moveFromUnderDock = UserDefaults.standard.bool(forKey: Self.moveFromUnderDockKey)
        stickToDock = UserDefaults.standard.bool(forKey: Self.stickToDockKey)
        ignoreSmallDockChanges = UserDefaults.standard.bool(forKey: Self.ignoreSmallDockChangesKey)
        fillAcrossDisplays = UserDefaults.standard.bool(forKey: Self.fillAcrossDisplaysKey)
        hideMenuBarIcon = UserDefaults.standard.bool(forKey: Self.hideMenuBarIconKey)
        launchAtLogin = LoginItem.isEnabled
        isTrusted = WindowScanner.isTrusted

        watcher = DisplayWatcher(log: log) { [weak self] reason, previousScreens in
            guard let self else { return }
            // Two changes in a row before a pass gets to run: the older
            // snapshot is the truer "before", so it is the one kept. Whether
            // it may be used is decided by the switches when the pass runs.
            if pendingReclaim == nil {
                pendingReclaim = previousScreens
            }
            run(trigger: reason)
        }
        watcher?.ignoreSmallDockChanges = ignoreSmallDockChanges

        windowWatcher = WindowWatcher(log: log) { [weak self] window, pid, appName in
            // A window is announced the moment it exists, which is before its
            // application has finished placing and sizing it.
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.default.newWindow) {
                MainActor.assumeIsolated {
                    self?.fixNewWindow(window, pid: pid, appName: appName)
                }
            }
        }

        Self.current = self

        refreshDisplays()
        log.info("DockFixer ready — \(displaysSummary)")
        log.info("launch at login: \(LoginItem.statusDescription)")
        log.info("move windows under the Dock: \(onOff(moveFromUnderDock)), stick to the Dock: \(onOff(stickToDock))"
            + " (skipping \(Int(dockNoise))pt or less: \(onOff(ignoreSmallDockChanges)))"
            + ", fill the space on another display: \(onOff(fillAcrossDisplays))")

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

    /// One switch for both watchers: the other switches only change what a
    /// pass does, not whether one runs.
    private func updateWatchers() {
        moveFromUnderDock ? watcher?.start() : watcher?.stop()
        moveFromUnderDock ? windowWatcher?.start() : windowWatcher?.stop()
    }

    /// What a pass may do beyond moving windows out from under the Dock.
    private var follow: WindowScanner.Follow {
        var follow: WindowScanner.Follow = []
        if stickToDock { follow.insert(.sameDisplay) }
        if fillAcrossDisplays { follow.insert(.acrossDisplays) }
        return follow
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

        scanner.run(previousScreens: previousScreens, slack: slack, follow: follow,
                    debugDetail: log.isDebug) { [weak self] summary in
            guard let self else { return }
            record(summary)
            // One line per pass, at the end, naming what started it: the
            // person reading this is as likely the one sent the log as the one
            // who pressed the button, and the watcher's line is not always the
            // nearest one above.
            // How long it took only when that is worth noticing: after a wake
            // or a display change applications answer slowly, and a pass that
            // reads the layout at its start and writes seconds later is the
            // first thing to suspect when windows land somewhere odd.
            let took = Date().timeIntervalSince(started)
            log.info("pass (\(trigger)\(attempt > 0 ? ", try \(attempt + 1)" : "")) — \(summary.headline)"
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

    /// The pass in the words someone looking at the window would use: how
    /// many, not which — an application's name is not something to wait for
    /// or to fit into a line. The details stay in the log.
    private func describe(_ summary: ScanSummary, answering: Bool) {
        let moved = summary.outcomes.filter { $0.level == .moved }
        let text: String
        if summary.failed > 0 {
            text = summary.failed == 1
                ? "Couldn't fix a window — see the log"
                : "Couldn't fix \(summary.failed) windows — see the log"
        } else if moved.count == 1 {
            text = "Fixed 1 window"
        } else if moved.count > 1 {
            text = "Fixed \(moved.count) windows"
        } else if answering {
            text = "Nothing to fix"
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
            if trusted, moveFromUnderDock {
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

    var displaysSummary: String { ScreenMap.summary(screens) }
}
