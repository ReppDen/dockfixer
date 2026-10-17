import AppKit
import CoreGraphics
import DockFixerCore
import UserNotifications

/// Posts the "DockFixer saved you N hours" notifications, and opens the
/// statistics when one is clicked. What to say and when is decided by
/// `Milestones`; this is the part that talks to the system.
///
/// One object for the whole process, made by the app delegate. It has to be
/// the notification centre's delegate before launch finishes, because a click
/// on a notification while the app is not running launches it and hands the
/// click over straight away, and that is long before `AppState` — which owns
/// the history — exists. So the delegate half is ready from the start, and
/// the counting half begins when `AppState` calls `attach`.
@MainActor
final class MilestoneNotifier: NSObject {

    static let shared = MilestoneNotifier()

    /// The highest milestone announced, in hours; 0 for none. In
    /// UserDefaults, so it survives updates and reinstalls over the top.
    private static let announcedKey = "announcedMilestoneHours"
    private static let category = "milestone"
    private static let seeStatsAction = "see-stats"
    private nonisolated static let hoursKey = "hours"

    /// Brings up the window on the statistics screen. Set by the app
    /// delegate, which is what knows how to show the window.
    var openStatistics: (() -> Void)? {
        didSet {
            // A click that launched the app arrived before this was set.
            if pendingOpen, let openStatistics {
                pendingOpen = false
                openStatistics()
            }
        }
    }
    private var pendingOpen = false

    /// Sends a notification event to the usage statistics; set by
    /// `AppState`, which knows whether the statistics switch is on and does
    /// nothing when it is off. Takes the milestone in hours. A click that
    /// launched the app arrives before `AppState` exists, so it waits in
    /// `pendingClicks` until this is set.
    var reportUsage: ((UsageReport.NotificationAction, Int) -> Void)? {
        didSet {
            guard let reportUsage else { return }
            for hours in pendingClicks { reportUsage(.clicked, hours) }
            pendingClicks = []
        }
    }
    private var pendingClicks: [Int] = []

    private var history: UsageHistory?
    private var log: Log?
    /// Running sums, kept in step with the history window by window so that
    /// a moved window costs an addition and a comparison, not a read of every
    /// day ever recorded. Re-read from the history whenever a milestone looks
    /// due, which happens a handful of times in the life of an install.
    private var savedSeconds: Double = 0
    private var windows = 0
    /// A milestone is due but could not be posted yet: nobody at the computer,
    /// or the answer from the system is still on its way.
    private var waiting = false
    private var inFlight = false
    private var retryTimer: Timer?
    /// Launch counts as a wake: at login it is one.
    private var lastWake = Date()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private var announced: Int {
        get { UserDefaults.standard.integer(forKey: Self.announcedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.announcedKey) }
    }

    /// `UNUserNotificationCenter.current()` raises an Objective-C exception,
    /// which takes the process down, when the process is not a proper app
    /// bundle — a binary started straight from `.build`, for instance. The
    /// app is always run from its bundle, but a crash is a poor way to learn
    /// that it was not.
    static var canUseNotifications: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Becomes the notification centre's delegate. Called from
    /// `applicationWillFinishLaunching`, before any click can be delivered.
    func install() {
        guard Self.canUseNotifications else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // The button macOS shows when the pointer is over the banner. It does
        // the same as a click on the banner itself; it is there because a
        // notification with nothing to press does not look like it leads
        // anywhere.
        let seeStats = UNNotificationAction(identifier: Self.seeStatsAction, title: "See Stats",
                                            options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [seeStats], intentIdentifiers: []),
        ])
    }

    /// Starts counting, from the history as it stands, and checks once at
    /// launch: a user who upgrades with weeks of history is due a milestone
    /// before a single window moves.
    func attach(history: UsageHistory, log: Log) {
        self.history = history
        self.log = log
        reloadTotals()
        observeWakes()
        guard Self.canUseNotifications else {
            log.info("milestones: not running from an app bundle, notifications are off")
            return
        }
        if Milestones.due(savedSeconds: savedSeconds, announced: announced) != nil {
            // Not now: a launch is a wake, and `check` would only say so.
            waiting = true
            scheduleRetry(after: Milestones.settleTime + 5)
        }
    }

    /// One window moved, already counted in the history.
    func windowMoved(_ kind: UsageKind) {
        guard kind != .alive else { return }
        savedSeconds += Savings.seconds(per: kind)
        windows += 1
        if waiting {
            check()
        } else if savedSeconds >= Milestones.nextThreshold(after: announced) {
            check()
        }
    }

    private func reloadTotals() {
        guard let history else { return }
        let total = Savings.totals(of: history.allDays)
        savedSeconds = Savings.seconds(for: total)
        windows = Savings.windows(in: total)
    }

    // MARK: - Deciding

    /// Announces the milestone that is due, if there is one and the user is
    /// there to see it; otherwise tries again later.
    private func check() {
        guard Self.canUseNotifications, !inFlight else { return }
        reloadTotals()
        guard let hours = Milestones.due(savedSeconds: savedSeconds, announced: announced) else {
            waiting = false
            return
        }

        let presence = Milestones.presence(idle: Self.idleSeconds,
                                           screenLocked: Self.screenIsLocked,
                                           displaysAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
                                           sinceWake: Date().timeIntervalSince(lastWake))
        if case .away(let reason) = presence {
            if !waiting {
                log?.info("milestones: \(hours) h reached, waiting to post — \(reason)")
            }
            waiting = true
            scheduleRetry(after: 5 * 60)
            return
        }

        waiting = false
        retryTimer?.invalidate()
        inFlight = true
        let windows = windows
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.decide(hours: hours, windows: windows, status: status)
                }
            }
        }
    }

    /// Never shows a prompt; what each answer leads to is
    /// `NotificationAccess.milestonePlan`. Only an app that was never asked
    /// asks here, and only for the quiet, provisional kind.
    private func decide(hours: Int, windows: Int, status: UNAuthorizationStatus) {
        // Each milestone is marked done when the decision about it is made,
        // not when a notification appears. Whatever happens below — refused,
        // turned off, an error — it is not tried again, and the lower ones
        // go with it.
        announced = max(announced, hours)

        switch NotificationAccess.milestonePlan(Self.permission(status)) {
        case .askQuietlyThenPost:
            log?.info("milestones: \(hours) h reached, asking for provisional permission to notify")
            requestAuthorization(provisional: true) { granted in
                if granted {
                    self.post(hours: hours, windows: windows)
                } else {
                    self.log?.info("milestones: \(hours) h not announced")
                    self.inFlight = false
                }
            }
        case .skip:
            log?.info("milestones: notifications are turned off — \(hours) h not announced")
            inFlight = false
        case .post:
            post(hours: hours, windows: windows)
        }
    }

    /// The system's answer in Core's words. Ephemeral is an App Clip's and
    /// never seen on the Mac; it may post, so it reads as allowed.
    nonisolated static func permission(_ status: UNAuthorizationStatus) -> NotificationAccess.Permission {
        switch status {
        case .notDetermined: return .notAsked
        case .denied: return .denied
        case .provisional: return .provisional
        default: return .allowed
        }
    }

    /// Asks for permission to show alerts, and logs the answer. An alert, no
    /// sound and no badge: a sound for good news nobody asked for is too
    /// much, and the system's badge, on an app that lives in the menu bar,
    /// has nowhere to go. The dot on the menu-bar icon is DockFixer's own
    /// and needs no permission. `provisional` asks for the quiet kind, which never shows a
    /// prompt; without it the system asks the user, once ever — after an
    /// answer, either way, a second request returns that answer silently.
    func requestAuthorization(provisional: Bool, then: @escaping @MainActor (Bool) -> Void) {
        guard Self.canUseNotifications else { return then(false) }
        let options: UNAuthorizationOptions = provisional ? [.alert, .provisional] : [.alert]
        let kind = provisional ? "provisional" : "full"
        UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, error in
            let message = error.map { "\($0.localizedDescription)" }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.log?.info("notifications: \(kind) permission \(granted ? "granted" : "refused")"
                                   + (message.map { " (\($0))" } ?? ""))
                    then(granted)
                }
            }
        }
    }

    /// Posts the notification for `hours` right now, whatever the presence
    /// check or the record of what was announced says, with the windows
    /// counted so far, at the interruption level and with the sound given.
    /// For the Debug tab of a development build, so the notification can be
    /// seen in each permission state and in each style the API offers; a
    /// milestone posted this way is not recorded, and the real one still
    /// comes when due. It is posted even when the system will drop it, so
    /// the Debug tab can show that it was.
    func postTest(hours: Int, level: UNNotificationInterruptionLevel, sound: Bool,
                  then: @escaping @MainActor (PostResult) -> Void) {
        guard Self.canUseNotifications else { return }
        reloadTotals()
        log?.info("milestones: test notification for \(hours) h, \(Self.describe(level))\(sound ? " + sound" : "")")
        post(hours: hours, windows: windows, identifier: "milestone-test-\(UUID().uuidString)",
             level: level, sound: sound, evenIfDropped: true, then: then)
    }

    /// Where a notification posted now ends up; see `NotificationAccess`.
    typealias Reach = NotificationAccess.Reach

    /// What happened to one post, for the log and the Debug tab.
    struct PostResult: Sendable {
        let reach: Reach
        /// Whether `add` was called at all.
        let posted: Bool
        let error: String?
        let level: UNNotificationInterruptionLevel
        let sound: Bool
        /// The settings for the parts a level or a sound depends on, as text.
        let soundSetting: String
        let timeSensitiveSetting: String
    }

    /// The one way a notification is posted, for the real milestone and for
    /// the Debug tab alike. The settings are read first: the log says where
    /// the notification went, and the real milestone (`evenIfDropped`
    /// false) is not posted at all when the system would only drop it.
    private func post(hours: Int, windows: Int, identifier: String? = nil,
                      level: UNNotificationInterruptionLevel = .active, sound: Bool = false,
                      evenIfDropped: Bool = false,
                      then: (@MainActor (PostResult) -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let reach = Self.reach(settings, level: level)
            let soundSetting = Self.describe(settings.soundSetting)
            let timeSensitiveSetting = Self.describe(settings.timeSensitiveSetting)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let finish = { (posted: Bool, error: String?) in
                        let result = PostResult(reach: reach, posted: posted, error: error, level: level,
                                                sound: sound, soundSetting: soundSetting,
                                                timeSensitiveSetting: timeSensitiveSetting)
                        let line = NotificationAccess.logLine(reach, posted: posted, error: error)
                        self.log?.info("milestones: \(line) — \(hours) h (\(windows) windows)")
                        if NotificationAccess.reachedTheUser(reach, posted: posted, failed: error != nil) {
                            // The dot on the icon is for whoever missed the
                            // banner, which is gone in a few seconds; a test
                            // from the Debug tab puts it there too, so it can
                            // be seen. Only the real one is counted: the
                            // statistics are about what users get.
                            StatusItemController.shared.setBadge(true)
                            if identifier == nil { self.reportUsage?(.shown, hours) }
                        }
                        // A test runs beside the real path and must not end a
                        // real check that is still waiting for its answer.
                        if identifier == nil { self.inFlight = false }
                        then?(result)
                    }
                    if NotificationAccess.isDropped(reach) && !evenIfDropped { return finish(false, nil) }
                    UNUserNotificationCenter.current().add(Self.request(hours: hours, windows: windows, identifier: identifier,
                                            level: level, sound: sound)) { error in
                        let message = error.map { "\($0.localizedDescription)" }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { finish(true, message) }
                        }
                    }
                }
            }
        }
    }

    private static func request(hours: Int, windows: Int, identifier: String?,
                                level: UNNotificationInterruptionLevel, sound: Bool) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = Milestones.title(hours: hours)
        content.body = Milestones.body(windows: windows)
        content.categoryIdentifier = category
        // For the click, which has only the notification to go on.
        content.userInfo = [Self.hoursKey: hours]
        // The real milestone is `.active`, the ordinary level, on purpose. A
        // Focus or Do Not Disturb holds it back and delivers it to
        // Notification Center, which is right for something that is pleasant
        // to know and never urgent; `.timeSensitive` would break through a
        // Focus for it, which nothing here deserves. `.passive` would skip
        // the banner altogether, and a notification posted once ever that
        // nobody sees has failed. The other levels exist for the Debug tab.
        content.interruptionLevel = level
        // No sound for the real one: good news nobody asked for should not
        // make a noise. The permission asked for does not include sound
        // either, so a sound here plays only if the user turned it on.
        if sound { content.sound = .default }
        // A test gets an identifier of its own each time: one that repeats
        // replaces the notification already there, quietly, and a second
        // press would seem to do nothing.
        return UNNotificationRequest(identifier: identifier ?? "milestone-\(hours)",
                                     content: content, trigger: nil)
    }

    private nonisolated static func reach(_ s: UNNotificationSettings,
                                          level: UNNotificationInterruptionLevel) -> Reach {
        let style: NotificationAccess.Delivery.Style = switch s.alertStyle {
        case .alert: .alert
        case .banner: .banner
        default: .none
        }
        let delivery = NotificationAccess.Delivery(alertsOn: s.alertSetting == .enabled, style: style,
                                                   inNotificationCenter: s.notificationCenterSetting == .enabled)
        return NotificationAccess.reach(permission(s.authorizationStatus), delivery, passive: level == .passive)
    }

    nonisolated static func describe(_ level: UNNotificationInterruptionLevel) -> String {
        switch level {
        case .passive: "passive"
        case .active: "active"
        case .timeSensitive: "time-sensitive"
        case .critical: "critical"
        @unknown default: "level \(level.rawValue)"
        }
    }

    nonisolated static func describe(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported: "notSupported"
        case .disabled: "disabled"
        case .enabled: "enabled"
        @unknown default: "unknown (\(setting.rawValue))"
        }
    }

    private func scheduleRetry(after seconds: TimeInterval) {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { self.check() }
        }
    }

    // MARK: - Is anyone there

    /// Seconds since the last keyboard, mouse or trackpad event in this login
    /// session. Reading it needs no permission. `~0` is
    /// `kCGAnyInputEventType`, which Swift has no name for.
    private static var idleSeconds: TimeInterval {
        let any = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// Whether the login window is up over this session: the screen is
    /// locked, or another user is in front.
    private static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        if let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool, !onConsole { return true }
        return false
    }

    /// Wakes and unlocks reset the settling time. A deferred milestone is
    /// looked at again a little after each, rather than waiting for the next
    /// retry or the next moved window.
    private func observeWakes() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, name) in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    self.lastWake = Date()
                    if self.waiting { self.scheduleRetry(after: Milestones.settleTime + 5) }
                }
            }
            observers.append((center, token))
        }
    }
}

// MARK: - Clicks

extension MilestoneNotifier: UNUserNotificationCenterDelegate {

    /// Shown even while DockFixer is the front app — the window happens to be
    /// open — since otherwise the system drops it silently and the milestone,
    /// already marked done, is never seen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    /// A click on the banner, on its entry in Notification Center, and on the
    /// "See Stats" button all open the statistics, and each counts as a click
    /// in the usage statistics. Closing the banner is not reported: the
    /// category does not ask for it.
    ///
    /// The window this opens takes the dot off the menu-bar icon on its own,
    /// as any way of opening it does (see `AppDelegate`).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        // Debug-tab tests are posted under identifiers of their own and are
        // not counted, as they are not when shown.
        let request = response.notification.request
        let isTest = request.identifier.hasPrefix("milestone-test-")
        // The milestone it announced: in the notification since it carried
        // one, read from the identifier `milestone-<hours>` otherwise.
        let hours = request.content.userInfo[Self.hoursKey] as? Int
            ?? Int(request.identifier.replacingOccurrences(of: "milestone-", with: "")) ?? 0
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let notifier = MilestoneNotifier.shared
                if category == Self.category,
                   action == UNNotificationDefaultActionIdentifier || action == Self.seeStatsAction {
                    notifier.log?.info("milestones: notification clicked — opening the statistics")
                    if !isTest {
                        if let report = notifier.reportUsage {
                            report(.clicked, hours)
                        } else {
                            notifier.pendingClicks.append(hours)
                        }
                    }
                    if let open = notifier.openStatistics {
                        open()
                    } else {
                        notifier.pendingOpen = true
                    }
                }
            }
        }
        completionHandler()
    }
}
