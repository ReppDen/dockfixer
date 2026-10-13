import AppKit

/// Notices when the display configuration changes and reports it once things
/// have settled.
///
/// Unplugging a display does not produce one tidy event. The notification
/// arrives several times in a burst, and WindowServer goes on relocating windows
/// by itself afterwards. Correcting windows during that window of time fights
/// the system and misses windows that have not moved yet, so this waits for the
/// layout to stop changing before handing over. A fixed sleep is not enough on
/// slower rebuilds — a Thunderbolt dock or a GPU switch can take a while.
///
/// Stopping changing is not the same as being finished, though. After an
/// unlock the Dock reported itself 11pt thinner for two seconds and then went
/// back; after a display was unplugged it kept the external display's size for
/// four seconds before shrinking to the laptop's. Each reading was stable for
/// long enough to pass the polls below, and windows were moved one way and then
/// straight back. So a display change, a wake and an unlock each also open a
/// hold during which nothing is handed over, and what is handed over at the
/// end is the difference between the layout windows were last arranged for and
/// the layout now — whatever happened in between.
@MainActor
public final class DisplayWatcher {

    /// The note for the log, and the layout as it was *before* the change.
    /// The previous visible frames are the only record of where the Dock used
    /// to be, which is what tells `reclaims` how much space a display regained.
    /// Called with a short name for what changed — "Dock change" or "display
    /// change", for the pass to name its trigger — and the layout before it.
    public typealias Handler = (String, [ScreenInfo]) -> Void

    /// Two identical readings in a row mean the layout has settled.
    private let requiredStableReadings = 2
    private let maxPolls = 10
    /// The waits, as a preset. Read at each use, so a change takes effect on
    /// the next notification.
    public var timing: Timing = .default

    /// Whether a Dock change of `dockNoise` or less is ignored. On, a Dock on
    /// the side of the display that breathes by a point or two as applications
    /// open and quit moves nothing; off, every change is handed over, however
    /// small, and windows follow the Dock's exact edge.
    public var ignoreSmallDockChanges = true

    private let log: Log
    private let handler: Handler

    private var observer: NSObjectProtocol?
    private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pending: Task<Void, Never>?

    /// The layout windows were last arranged for. Advanced only when a change
    /// is handed over: a Dock change too small to act on leaves it where it
    /// was, so the next change is measured from the same place and small
    /// steps add up instead of each being forgotten.
    private var lastScreens: [ScreenInfo]

    /// Nothing is handed over before this.
    private var holdUntil = Date.distantPast
    /// When the current burst of notifications began, and whether it has
    /// already been given its hold for a display change.
    private var burstStarted: Date?
    private var displayHoldGiven = false
    /// Whether any reading during the burst differed from `lastScreens`. Kept
    /// here rather than in one wait because every notification starts a new
    /// one, and a Dock that went and came back spans several.
    private var burstSawAChange = false

    public private(set) var isRunning = false

    public init(log: Log, handler: @escaping Handler) {
        self.log = log
        self.handler = handler
        lastScreens = ScreenMap.current()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        // The snapshot may have gone stale while the watcher was off.
        lastScreens = ScreenMap.current()

        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensChanged()
            }
        }
        observeSystemEvents()
        log.info("watching for Dock and display changes")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        for (center, token) in systemObservers {
            center.removeObserver(token)
        }
        systemObservers = []
        pending?.cancel()
        pending = nil
        burstStarted = nil
        displayHoldGiven = false
        burstSawAChange = false
        log.info("stopped watching for Dock and display changes")
    }

    // MARK: - System events

    /// Sleep, wake, lock and unlock: logged because they are what the Dock and
    /// display changes around them turn out to follow, and the log is the only
    /// account of a day there is.
    ///
    /// Applications opening and quitting are logged at debug level for the
    /// same reason — they are what makes a side Dock change its thickness.
    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        func on(_ center: NotificationCenter, _ name: Notification.Name,
                _ body: @escaping @MainActor (Notification) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { body(note) }
            }
            systemObservers.append((center, token))
        }

        on(workspace, NSWorkspace.willSleepNotification) { [weak self] _ in
            self?.log.info("system: going to sleep")
        }
        on(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.logSystem( "system: woke from sleep")
        }
        on(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] _ in
            self?.log.info("system: displays went to sleep")
        }
        on(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] _ in
            self?.logSystem( "system: displays woke")
        }
        on(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in
            self?.log.info("system: switched to another user")
        }
        on(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in
            self?.logSystem( "system: switched back to this user")
        }
        on(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in
            self?.log.info("system: screen locked")
        }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in
            self?.logSystem( "system: screen unlocked")
        }
        on(workspace, NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
            self?.logApplication(note, "opened")
        }
        on(workspace, NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            self?.logApplication(note, "quit")
        }
    }

    private func logApplication(_ note: Notification, _ what: String) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular
        else { return }
        log.debug("\(app.localizedName ?? "pid \(app.processIdentifier)") \(what)")
    }

    private func logSystem(_ event: String) {
        log.info(event)
    }

    // MARK: - Waiting

    /// The same notification fires when the Dock moves or changes size, so a
    /// Dock rearrangement is handled for free.
    private func screensChanged() {
        log.debug("screen parameters changed — restarting the wait for the layout to settle")
        if burstStarted == nil {
            burstStarted = Date()
        }
        pending?.cancel()
        pending = Task { [weak self] in
            await self?.waitForStableLayout()
        }
    }

    /// Polls until two readings in a row agree. `nil` when cancelled by a newer
    /// notification, which starts a wait of its own.
    private func readUntilStable() async -> (screens: [ScreenInfo], settled: Bool, polls: Int)? {
        let baseline = ScreenMap.fingerprint(lastScreens)
        var stableReadings = 1
        var fingerprint = ScreenMap.fingerprint(ScreenMap.current())
        var polls = 0
        if fingerprint != baseline { burstSawAChange = true }

        while stableReadings < requiredStableReadings, polls < maxPolls {
            try? await Task.sleep(nanoseconds: UInt64(timing.poll * 1_000_000_000))
            if Task.isCancelled { return nil }
            polls += 1

            let current = ScreenMap.fingerprint(ScreenMap.current())
            if current != baseline { burstSawAChange = true }
            if current == fingerprint {
                stableReadings += 1
            } else {
                stableReadings = 1
                fingerprint = current
            }
            log.debug("poll \(polls): \(stableReadings) identical reading\(stableReadings == 1 ? "" : "s") — \(current)")
        }
        return (ScreenMap.current(), stableReadings >= requiredStableReadings, polls)
    }

    private func waitForStableLayout() async {
        let previousScreens = lastScreens
        let previousFingerprint = ScreenMap.fingerprint(previousScreens)
        let started = burstStarted ?? Date()



        var screens: [ScreenInfo]
        var settled: Bool
        var polls = 0
        while true {
            guard let reading = await readUntilStable() else { return }
            screens = reading.screens
            settled = reading.settled
            polls += reading.polls

            // A display change is not over when the frames stop changing: the
            // Dock follows it seconds later. One hold per burst, from when it
            // was first seen.
            if !displayHoldGiven,
               classifyLayoutChange(previous: previousScreens, current: screens) == .displays {
                displayHoldGiven = true
                holdUntil = max(holdUntil, Date())
            }

            let remaining = holdUntil.timeIntervalSinceNow
            guard remaining > 0, Date().timeIntervalSince(started) < timing.maxWait else { break }
            log.debug("holding for \(String(format: "%.1f", remaining))s before looking again")
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            if Task.isCancelled { return }
        }

        let waited = String(format: "%.1f", Date().timeIntervalSince(started))
        let sawAChange = burstSawAChange
        burstStarted = nil
        displayHoldGiven = false
        burstSawAChange = false

        guard ScreenMap.fingerprint(screens) != previousFingerprint else {
            // Either woken by something that left the layout identical, or —
            // the case worth a line in the ordinary log — it changed and came
            // back before anything was done about it.
            if sawAChange {
                log.info("the layout changed and came back within \(waited)s — nothing to do")
            } else {
                log.debug("layout unchanged — \(previousFingerprint)")
            }
            return
        }
        log.debug("layout before: \(previousFingerprint)")
        log.debug("layout after:  \(ScreenMap.fingerprint(screens))")

        // macOS reports both with one notification; the log says which it was.
        var note: String
        let trigger: String
        switch classifyLayoutChange(previous: previousScreens, current: screens) {
        case .dock:
            trigger = "Dock change"
            let shift = largestEdgeShift(previous: previousScreens, current: screens)
            let what = describeDockChange(previous: previousScreens, current: screens)
            guard shift > dockNoise || !ignoreSmallDockChanges else {
                // `lastScreens` stays where it was on purpose: see its comment.
                log.info("the Dock changed by \(Int(shift.rounded()))pt (\(what)) — "
                    + "\(Int(dockNoise))pt or less, windows left alone")
                return
            }
            note = "the Dock changed by \(Int(shift.rounded()))pt (\(what))"
        case .displays:
            trigger = "display change"
            note = "displays changed: \(previousScreens.count) -> \(screens.count)"
        }
        lastScreens = screens

        note += settled ? ", settled after \(polls) polls" : ", still changing after \(polls) polls — going ahead anyway"
        note += ", \(waited)s after the first notification"
        log.info(note)
        if trigger == "display change" {
            // The Dock's edge and thickness on each display is what every
            // decision of the pass that follows rests on.
            log.info("now: \(ScreenMap.summary(screens))")
        }

        handler(trigger, previousScreens)
    }
}
