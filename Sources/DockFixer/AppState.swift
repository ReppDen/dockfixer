import AppKit
import Combine
import DockFixerCore
import SwiftUI
import UserNotifications

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

    /// Whether the menu-bar icon is left out. Off by default: with the window
    /// closed it is the only visible part of the app. Opening the app again
    /// brings the window back, which is the way in once it is hidden.
    ///
    /// `StatusItemController` follows this one way and never writes it back.
    /// The `MenuBarExtra` it replaced took a binding to it that wrote back on
    /// every update; each write to a published property redraws the app,
    /// which wrote it again, and the main thread sat at 100% CPU with no timer
    /// running. Any binding here must write only a real change.
    @Published var hideMenuBarIcon: Bool {
        didSet {
            guard oldValue != hideMenuBarIcon else { return }
            UserDefaults.standard.set(hideMenuBarIcon, forKey: Self.hideMenuBarIconKey)
            log.info("menu bar icon: \(hideMenuBarIcon ? "hidden" : "shown")")
        }
    }

    /// One line a day — the random install ID, the version, the date and
    /// three counts — and one event when a milestone notification is shown
    /// or clicked, so that the project knows it is used and by how much.
    /// Off, the journal and the install ID are deleted: there is nothing
    /// left that could be sent later. See `Usage.swift` for all of it. The
    /// local history (`UsageHistory`) is not touched: it never leaves the
    /// machine, so there is nothing about it the switch has to stop.
    @Published var sendUsageStatistics: Bool {
        didSet {
            guard oldValue != sendUsageStatistics else { return }
            UserDefaults.standard.set(sendUsageStatistics, forKey: Self.sendUsageStatisticsKey)
            log.info("usage statistics: \(sendUsageStatistics ? "enabled" : "disabled")")
            if sendUsageStatistics {
                startUsage()
            } else {
                stopUsage(erasing: true)
            }
        }
    }

    /// Light or dark, or whatever the system is set to; chosen on the Debug
    /// tab, so only a development build offers it. Set on the application
    /// rather than on each window: a window with an appearance of its own
    /// stops following the application's, and setting one on the main window
    /// left its title bar and background in one look while the SwiftUI
    /// content redrew in the other. With the application's alone, every
    /// window — main, log, bug report, menus — switches whole, and `nil`
    /// hands them back to the system setting, changes to it included.
    @Published var appearance: Appearance {
        didSet {
            guard oldValue != appearance else { return }
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
            appearance.apply()
            log.info("appearance: \(appearance.rawValue)")
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        @MainActor func apply() {
            switch self {
            case .system: NSApplication.shared.appearance = nil
            case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
            case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            }
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

    /// What the system says about DockFixer's notifications; nil until it has
    /// answered the first time. Read again whenever the app comes to the
    /// front, because it is changed in System Settings, outside the app, and
    /// the Settings tab asks for what is still missing.
    @Published private(set) var notificationPermission: NotificationAccess.Permission?

    /// The first-run screens that follow the Accessibility one. Accessibility
    /// itself is not a step here: it is shown whenever the grant is missing,
    /// on the first run and any time it is revoked later, so it is decided by
    /// `isTrusted` alone.
    @Published private(set) var onboardingStep: OnboardingStep

    enum OnboardingStep {
        /// Why notifications are worth allowing, with the button that asks.
        case notifications
        /// "We're ready" for a moment, then the Stats tab.
        case ready
        case finished
    }

    /// Accessibility access can be granted or revoked outside the app, so this
    /// is polled rather than read once.
    @Published private(set) var isTrusted: Bool
    @Published private(set) var isBusy = false
    /// The current displays, for the window to describe one per row.
    @Published private(set) var screens: [ScreenInfo] = []
    /// What the last press of Fix Windows Now did, in words, for the foot of
    /// the window. Only the button's own passes: a line there that changed
    /// after a pass nobody asked for, or that was already filled when the
    /// window opened, read as the answer to a press that never happened.
    /// Kept until the next press, so the answer does not vanish while read.
    @Published private(set) var fixNowResult: Activity?
    /// The tab the main window shows. Here rather than in the view, so that
    /// something outside the window — a notification about the statistics —
    /// can open it on the right tab, and so a hidden window comes back where
    /// it was left.
    @Published var page: Page = .stats
    /// Every day of the local history, oldest first, for the Stats tab.
    /// Refreshed after each pass that moved something; the history itself is
    /// not observable, and reading it from a view on every redraw would take
    /// its lock on every frame.
    @Published private(set) var usageDays: [UsageDay] = []

    /// Switches the main window to the Stats tab: what a click on a
    /// milestone notification leads to. Only a real change is written: every
    /// write to a published property redraws the window, even an equal one.
    /// Showing the window itself is the app delegate's job.
    func showStatistics() {
        if page != .stats { page = .stats }
    }

    /// Switches the main window to the Settings tab, for ⌘, and the
    /// "Settings…" menu item. The same rule as `showStatistics`.
    func showSettings() {
        if page != .settings { page = .settings }
    }

    enum Page: String, CaseIterable, Identifiable {
        /// `debug` exists in every build but is reachable only in a
        /// development one: the tab that leads to it is drawn only there.
        case stats, rules, settings, debug
        var id: String { rawValue }
    }

    struct Activity: Equatable {
        let text: String
        let date: Date
        /// Something could not be moved, and the log says why.
        let needsAttention: Bool
    }

    let log: Log

    /// Sparkle, behind the "Updates" row and the menu item.
    let updater: Updater

    /// The bug report window's contents, kept while the window is closed.
    let bugReportForm: BugReportForm

    /// The live instance, for the app delegate: it runs before this is built and
    /// has no way to be handed a reference, but it has decisions worth logging.
    private(set) static weak var current: AppState?

    private static let moveFromUnderDockKey = "moveWindowsUnderDock"
    private static let stickToDockKey = "stickWindowsToDock"
    private static let ignoreSmallDockChangesKey = "ignoreSmallDockChanges"
    private static let fillAcrossDisplaysKey = "fillAcrossDisplays"
    private static let hideMenuBarIconKey = "hideMenuBarIcon"
    private static let sendUsageStatisticsKey = "sendUsageStatistics"
    private static let appearanceKey = "appearance"
    private static let usageInstallIDKey = "usageInstallID"
    /// Set once the first-run screens have been gone through, so they are
    /// not shown again. The Accessibility screen does not look at it.
    private static let onboardingFinishedKey = "onboardingFinished"
    /// Set once Launch at login has been turned on by the app itself, so a
    /// user who turns it off later is never overruled.
    private static let launchAtLoginTurnedOnKey = "launchAtLoginTurnedOnOnce"
    /// How long to wait before repeating a pass that could not read the windows.
    private static let retryDelays: [TimeInterval] = [0.75, 1.5, 3]
    private let scanner = WindowScanner()
    private var watcher: DisplayWatcher?
    private var windowWatcher: WindowWatcher?
    private var pollTimer: Timer?
    private var isSyncingLoginItem = false
    private var usageJournal: UsageJournal?
    /// Counted whatever the statistics switch says, and kept for ever: the
    /// user's own record of what the app did. See `UsageHistory.swift`.
    let usageHistory: UsageHistory
    private var historyObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var askedOnNotificationsStep = false
    private var usage: UsageReporter?
    private var usageTimer: Timer?
    private var usageObservers: [NSObjectProtocol] = []

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
        updater = Updater(log: log)
        bugReportForm = BugReportForm(log: log)
        usageHistory = UsageHistory(url: Self.usageDirectory.appendingPathComponent("usage-history.json")) {
            // Read only when there is no history file yet. The journal is
            // opened just to be read: it exists, if at all, from a time the
            // statistics were on, and reading it changes nothing.
            UsageJournal(url: Self.usageDirectory.appendingPathComponent("usage.jsonl")).allDays()
        }
        UserDefaults.standard.register(defaults: [
            Self.moveFromUnderDockKey: true,
            Self.stickToDockKey: true,
            Self.ignoreSmallDockChangesKey: false,
            Self.fillAcrossDisplaysKey: true,
            Self.hideMenuBarIconKey: false,
            Self.sendUsageStatisticsKey: true,
        ])
        moveFromUnderDock = UserDefaults.standard.bool(forKey: Self.moveFromUnderDockKey)
        stickToDock = UserDefaults.standard.bool(forKey: Self.stickToDockKey)
        ignoreSmallDockChanges = UserDefaults.standard.bool(forKey: Self.ignoreSmallDockChangesKey)
        fillAcrossDisplays = UserDefaults.standard.bool(forKey: Self.fillAcrossDisplaysKey)
        hideMenuBarIcon = UserDefaults.standard.bool(forKey: Self.hideMenuBarIconKey)
        sendUsageStatistics = UserDefaults.standard.bool(forKey: Self.sendUsageStatisticsKey)
        let appearance = UserDefaults.standard.string(forKey: Self.appearanceKey)
            .flatMap(Appearance.init(rawValue:)) ?? .system
        self.appearance = appearance
        // Here, not in the app delegate: this object is made when the first
        // scene is, so its window is drawn in the right colours from the
        // start rather than switching a moment after it appears.
        appearance.apply()
        launchAtLogin = LoginItem.isEnabled
        isTrusted = WindowScanner.isTrusted
        onboardingStep = UserDefaults.standard.bool(forKey: Self.onboardingFinishedKey) ? .finished : .notifications

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

        windowWatcher = WindowWatcher(log: log) { [weak self] window, pid, appName, event in
            // A window is announced the moment it exists, which is before its
            // application has finished placing and sizing it; a restored one
            // as it starts out of the Dock.
            let delay: TimeInterval
            switch event {
            case .appeared: delay = Timing.default.newWindow
            case .restored: delay = Timing.default.restoredWindow
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    self?.fixWindow(window, pid: pid, appName: appName, event: event)
                }
            }
        }

        Self.current = self
        StatusItemController.shared.attach(state: self)

        refreshDisplays()
        log.info("DockFixer ready — \(displaysSummary)")
        log.info("launch at login: \(LoginItem.statusDescription)")
        log.info("move windows under the Dock: \(onOff(moveFromUnderDock)), stick to the Dock: \(onOff(stickToDock))"
            + " (skipping \(Int(dockNoise))pt or less: \(onOff(ignoreSmallDockChanges)))"
            + ", fill the space on another display: \(onOff(fillAcrossDisplays))"
            + ", usage statistics: \(onOff(sendUsageStatistics))")
        switch usageHistory.origin {
        case .loaded(let days): log.info("usage history: \(days) day\(days == 1 ? "" : "s")")
        case .seeded(let days): log.info("usage history: started, \(days) day\(days == 1 ? "" : "s") taken from the journal")
        case .unreadable(let aside): log.info("usage history: could not be read, moved to \(aside.lastPathComponent)")
        case .newer(let version): log.info("usage history: written by a newer DockFixer (version \(version)), left as it is")
        }
        usageDays = usageHistory.allDays
        // After the history is open: the notifier starts from its totals.
        MilestoneNotifier.shared.attach(history: usageHistory, log: log)
        // The counts of the last couple of seconds are still in memory when
        // the app quits; this is the moment to write them.
        historyObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [usageHistory] _ in
            usageHistory.save()
        }
        if sendUsageStatistics {
            startUsage()
        }
        // After the reporter is made: a click that launched the app may be
        // waiting to be sent. `usage` exists only while the statistics switch
        // is on and the build has a key, so off means nothing goes out. The
        // local history never hears of it: a notification is not a window.
        MilestoneNotifier.shared.reportUsage = { [weak self] action, hours in
            guard let usage = self?.usage else { return }
            Task { await usage.sendNotification(action, hours: hours) }
        }

        refreshNotificationStatus()
        // Coming back from System Settings is the moment notifications may
        // have been turned on or off there.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNotificationStatus() }
        }

        if isTrusted {
            turnOnLaunchAtLoginOnce()
        } else {
            // The system prompt itself is asked for by the app delegate, once
            // the window is up: see `askForAccessibility`.
            log.info("Accessibility access not granted yet; approve DockFixer in the system prompt or in System Settings")
        }
        updateWatchers()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
    }

    // MARK: - Actions

    /// Counted as a click on the button, whatever happens on the page after:
    /// a payment is Buy Me a Coffee's to count. Sent only while the
    /// statistics switch is on, as every other event.
    func buyMeACoffeeClicked() {
        log.info("Buy Me a Coffee opened")
        guard let usage else { return }
        Task { await usage.sendBuyMeACoffee() }
    }

    func moveWindows() {
        // A press that changes nothing still needs an answer, or the button
        // looks broken. Automatic passes that change nothing stay quiet.
        answerNextPass = true
        run(trigger: "Fix Windows Now")
    }

    /// The onboarding button. Opens the pane and nothing more: the system
    /// prompt was already shown at launch, and asking for it again would only
    /// queue another dialog behind System Settings.
    func openAccessibilitySettings() {
        log.info("opening Accessibility settings — grant DockFixer there, then come back")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Onboarding and notifications

    /// "Allow Notifications", on the step and in the Permissions row: both
    /// open DockFixer's page in System Settings → Notifications, where the
    /// switch is. The step has already shown the system's prompt, which the
    /// system shows once ever. On the step, the step stays put and moves on
    /// by itself when the user comes back with notifications allowed.
    func allowNotifications() {
        if onboardingStep == .notifications {
            stepEvent(.allowPressed)
        } else {
            openNotificationSettings()
        }
    }

    /// The notifications step is on screen, right after the Accessibility
    /// grant. Once per launch, and not before the system has said where
    /// things stand.
    func notificationsStepAppeared() {
        guard !askedOnNotificationsStep, onboardingStep == .notifications,
              let permission = notificationPermission else { return }
        askedOnNotificationsStep = true
        log.info("onboarding: notifications step opened, permission \(permission)")
        stepEvent(.opened(permission))
    }

    /// "Not Now" on the notifications step. The quiet kind was taken when
    /// the step opened, so there is nothing to ask.
    func skipNotifications() {
        log.info("onboarding: Not Now")
        stepEvent(.notNowPressed)
    }

    /// One event on the notifications step, and what it leads to. What
    /// leads to what is decided, and tested, in `NotificationAccess.Step`;
    /// this only carries it out.
    private func stepEvent(_ event: NotificationAccess.Step.Event) {
        guard onboardingStep == .notifications else { return }
        for action in NotificationAccess.Step.actions(for: event) {
            switch action {
            case .takeQuiet:
                log.info("onboarding: taking quiet notifications")
                MilestoneNotifier.shared.requestAuthorization(provisional: true) { [weak self] _ in
                    self?.refreshNotificationStatus()
                    self?.stepEvent(.quietTaken)
                }
            case .showPrompt:
                log.info("onboarding: showing the notifications prompt")
                MilestoneNotifier.shared.requestAuthorization(provisional: false) { [weak self] _ in
                    self?.refreshNotificationStatus()
                    self?.stepEvent(.promptAnswered)
                }
            case .openSettings:
                openNotificationSettings()
            case .finish:
                onboardingReady()
            }
        }
    }

    /// System Settings → Notifications, on DockFixer's own page rather than
    /// the list of every app: the switch that turns notifications on fully,
    /// or back on after a refusal.
    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            log.info("notifications: opening System Settings → Notifications → DockFixer")
            NSWorkspace.shared.open(url)
        }
    }

    /// The red dot on the Settings tab; see `NotificationAccess.wantsAttention`.
    var notificationsWantAttention: Bool {
        notificationPermission.map(NotificationAccess.wantsAttention) ?? false
    }

    /// The end of the "We're ready" screen: the tabs, on the Stats one.
    func finishOnboarding() {
        guard onboardingStep == .ready else { return }
        onboardingStep = .finished
        showStatistics()
    }

    /// Recorded as finished here, when the last screen appears, rather than
    /// when it goes: quitting during those two seconds should not bring the
    /// notifications step back.
    private func onboardingReady() {
        guard onboardingStep == .notifications else { return }
        UserDefaults.standard.set(true, forKey: Self.onboardingFinishedKey)
        log.info("onboarding: finished")
        onboardingStep = .ready
    }

    private func refreshNotificationStatus() {
        readNotificationPermission { [weak self] permission in
            guard let self else { return }
            if notificationPermission != permission {
                notificationPermission = permission
                log.info("notifications: permission \(permission)")
            }
            // Back from System Settings, perhaps with the switch turned on.
            if askedOnNotificationsStep { stepEvent(.permissionRead(permission)) }
        }
    }

    /// What the system says right now, on the main actor.
    private func readNotificationPermission(_ then: @escaping @MainActor (NotificationAccess.Permission) -> Void) {
        guard MilestoneNotifier.canUseNotifications else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let permission = MilestoneNotifier.permission(settings.authorizationStatus)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { then(permission) }
            }
        }
    }

    /// Turns Launch at login on the first time the app has the grant. The
    /// app is no use unless it is running when a display goes away, and a
    /// switch left for the user to find is a switch most never find. Once
    /// only: whatever the user does with the switch afterwards stands. macOS
    /// says "Login item added" in a notification of its own, which is the
    /// user being told, not something to hide.
    private func turnOnLaunchAtLoginOnce() {
        guard !UserDefaults.standard.bool(forKey: Self.launchAtLoginTurnedOnKey) else { return }
        if !launchAtLogin {
            do {
                try LoginItem.set(true)
            } catch {
                // Most often an app not in /Applications. Not marked done,
                // so a later launch from the right place tries again.
                log.add(level: .fail, app: "DockFixer", title: "",
                        detail: "could not turn on launch at login: \(error.localizedDescription)")
                return
            }
            isSyncingLoginItem = true
            launchAtLogin = LoginItem.isEnabled
            isSyncingLoginItem = false
            log.info("launch at login: turned on at first launch — \(LoginItem.statusDescription)")
        }
        UserDefaults.standard.set(true, forKey: Self.launchAtLoginTurnedOnKey)
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

    /// Not a pass: only the window that opened, or came back from the Dock,
    /// is looked at, so it neither waits for one that is running nor uses up
    /// the layout a display change left behind. Silent when the window was
    /// fine, which is nearly always.
    ///
    /// A restored window follows the Dock under the same switches as a pass,
    /// against the layout it was minimised in; a new one follows nothing.
    private func fixWindow(_ window: AXUIElement, pid: pid_t, appName: String, event: WindowWatcher.Event) {
        guard isTrusted else { return }
        let what: String
        let minimizedIn: [ScreenInfo]?
        let follow: WindowScanner.Follow
        switch event {
        case .appeared:
            (what, minimizedIn, follow) = ("new window", nil, [])
        case .restored(let screens):
            (what, minimizedIn, follow) = ("restored window", screens, self.follow)
        }
        scanner.run(window: window, pid: pid, appName: appName,
                    previousScreens: minimizedIn, follow: follow,
                    slack: slack, debugDetail: log.isDebug) { [weak self] summary in
            guard let self else { return }
            record(summary)
            if summary.candidates > 0 {
                log.info("\(what) — \(summary.headline)")
            }
        }
    }

    private func run(trigger: String, attempt: Int = 0) {
        guard isTrusted else {
            log.add(level: .fail, app: "DockFixer", title: "",
                    detail: "cannot scan windows without Accessibility access")
            // Only logged. A pass starts on its own, on a Dock or display
            // change, and must not throw System Settings at the user for it.
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
            if answerNextPass { answer(summary) }
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

    /// The pass that answers the button, in the words someone looking at the
    /// window would use: how many, not which — an application's name is not
    /// something to wait for or to fit into a line. The details stay in the log.
    /// The same count as the Stats tab: a window moved under others is in
    /// neither.
    private func answer(_ summary: ScanSummary) {
        let moved = summary.counted
        let text: String
        if summary.failed > 0 {
            text = summary.failed == 1
                ? "Couldn't fix a window — see the log"
                : "Couldn't fix \(summary.failed) windows — see the log"
        } else if moved.count == 1 {
            text = "Fixed 1 window"
        } else if moved.count > 1 {
            text = "Fixed \(moved.count) windows"
        } else {
            text = "Nothing to fix"
        }
        fixNowResult = Activity(text: text, date: Date(), needsAttention: summary.failed > 0)
    }

    /// Every move goes into the log; only the moves of windows the user could
    /// see go into the statistics, the usage event and the milestones. A full
    /// Dock changing by a point moves every maximised window on the Mac, and
    /// counting the ones buried under others would credit DockFixer with
    /// work nobody saw it do.
    private func record(_ summary: ScanSummary) {
        // Once per pass, not per window: a pass after a display change moves
        // twenty windows, and twenty redraws of the Stats tab say nothing more.
        defer {
            if !summary.counted.isEmpty {
                usageDays = usageHistory.allDays
            }
        }
        for outcome in summary.counted {
            if let kind = outcome.kind {
                usageJournal?.record(kind)
                usageHistory.record(kind)
                MilestoneNotifier.shared.windowMoved(kind)
            }
        }
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
            if trusted { turnOnLaunchAtLoginOnce() }
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

    // MARK: - Usage statistics

    // MARK: - Bug reports

    /// The switches of the settings page, for a bug report: half the reports
    /// are about something a switch decides, and asking afterwards takes a day.
    var settingsForReport: [String: Bool] {
        [
            "moveFromUnderDock": moveFromUnderDock,
            "stickToDock": stickToDock,
            "ignoreSmallDockChanges": ignoreSmallDockChanges,
            "fillAcrossDisplays": fillAcrossDisplays,
            "hideMenuBarIcon": hideMenuBarIcon,
            "launchAtLogin": launchAtLogin,
            "installUpdatesAutomatically": updater.automaticallyUpdates,
            "sendUsageStatistics": sendUsageStatistics,
        ]
    }

    /// A fresh random ID for every report. The usage statistics' install ID
    /// would let a report, which may carry an email address, be put next to
    /// that Mac's daily counts; what helps with a bug is in the report itself.
    var distinctIDForReport: String {
        UUID().uuidString.lowercased()
    }

    /// The project key, baked into the bundle by the Makefile. A build without
    /// one — a fork, a plain `swift build` — keeps the switch but sends
    /// nothing, and says so once. Bug reports go to the same project, and a
    /// build without the key sends people to GitHub instead.
    static var usageKey: String? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "DockFixerUsageKey") as? String,
              !key.isEmpty, !key.hasPrefix("__")
        else { return nil }
        return key
    }

    /// Where the journal and the local history live.
    private static var usageDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DockFixer", isDirectory: true)
    }

    private func startUsage() {
        guard usage == nil else { return }
        guard let key = Self.usageKey else {
            log.info("usage statistics: this build has no project key — nothing is sent")
            return
        }
        let installID: String
        if let saved = UserDefaults.standard.string(forKey: Self.usageInstallIDKey) {
            installID = saved
        } else {
            installID = UUID().uuidString.lowercased()
            UserDefaults.standard.set(installID, forKey: Self.usageInstallIDKey)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let journal = UsageJournal(url: Self.usageDirectory.appendingPathComponent("usage.jsonl"))
        usageJournal = journal
        usage = UsageReporter(journal: journal, installID: installID, version: version, apiKey: key,
                              log: log) { data in
            await PostHog.send(data, version: version)
        }

        // No moment is safe to count on — the machine may be shut, asleep or
        // offline at midnight — so the unsent days go whenever there is a
        // chance: a little after launch, on every wake, and once an hour.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated { self?.flushUsage() }
        }
        usageTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushUsage() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            usageObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushUsage() }
            })
        }
    }

    private func stopUsage(erasing: Bool) {
        usageTimer?.invalidate()
        usageTimer = nil
        for observer in usageObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        usageObservers = []
        usage = nil
        if erasing {
            usageJournal?.erase()
            UserDefaults.standard.removeObject(forKey: Self.usageInstallIDKey)
        }
        usageJournal = nil
    }

    private func flushUsage() {
        guard let usage else { return }
        Task { await usage.flush() }
    }

    private func refreshDisplays() {
        let current = ScreenMap.current()
        // Polled every two seconds; only publish when something actually moved, so
        // the window is not relaid out for nothing.
        guard current != screens else { return }
        screens = current
    }

    var displaysSummary: String { ScreenMap.summary(screens) }
}
