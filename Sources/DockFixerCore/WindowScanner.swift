import AppKit
import ApplicationServices

/// What happened to one window during a pass.
public struct WindowOutcome: Sendable {
    public let app: String
    public let title: String
    public let level: LogLevel
    public let detail: String
    /// Set for findings that are a standing property of a window rather than
    /// something that happened — a dialog that cannot be resized, say. Logged
    /// once per session, because repeating them every pass buries the entries
    /// that do change.
    public var logOncePerSession = false
    /// What the move counts as in the usage statistics; set on `moved` only.
    public var kind: UsageKind? = nil
    /// Whether the user could see the window when it was moved; only such
    /// moves go into the usage statistics. See `Visibility`.
    public var visible = false
}

/// Why a window was passed over.
///
/// These are counted rather than logged one by one. A window being minimised is
/// not an event, and there is nothing for anyone to do about it; seeing that
/// two of thirty windows were minimised is enough.
public enum SkipReason: Sendable, CaseIterable {
    case minimized
    case fullScreen
    /// The desktop and other layers Finder and the system own. They cover a
    /// display, so they always look like they overlap the Dock, and they can
    /// never be moved.
    case systemWindow
    /// Position or size is not settable — a fixed dialog, or an application
    /// that refuses to be arranged.
    case immovable
    case unreadable
    case noDisplay

    func label(_ count: Int) -> String {
        switch self {
        case .minimized: return "minimized"
        case .fullScreen: return "full screen"
        case .systemWindow: return count == 1 ? "system window" : "system windows"
        case .immovable: return "fixed in place"
        case .unreadable: return "unreadable"
        case .noDisplay: return "on no display"
        }
    }
}

/// Result of a whole pass, both for the log and for the counts in the window.
public struct ScanSummary: Sendable {
    public var outcomes: [WindowOutcome] = []
    public var appsScanned = 0
    /// Applications that would not list their windows, even when asked again.
    /// Their windows are the ones a pass can neither see nor move, so the
    /// count belongs in the headline next to the windows that were seen.
    public var appsSilent = 0
    public var windowsSeen = 0
    /// Windows that overlap the Dock or the menu bar and need correcting.
    public var candidates = 0
    public var moved = 0
    public var failed = 0
    public var skips: [SkipReason: Int] = [:]

    public var skipped: Int { skips.values.reduce(0, +) }

    /// Adds one application's results to the whole pass.
    public mutating func merge(_ other: ScanSummary) {
        outcomes += other.outcomes
        appsScanned += other.appsScanned
        appsSilent += other.appsSilent
        windowsSeen += other.windowsSeen
        candidates += other.candidates
        moved += other.moved
        failed += other.failed
        for (reason, count) in other.skips {
            skips[reason, default: 0] += count
        }
    }

    /// One-line tally for the log and for the footer of the window.
    ///
    /// Reads as an account of the pass: what was done first, then what needed
    /// nothing, then what could not be touched and why.
    public var headline: String {
        var parts: [String] = []
        if moved > 0 { parts.append("\(moved) moved") }
        if failed > 0 { parts.append("\(failed) could not be moved") }
        // On a dry run nothing is moved, so the candidates are still pending.
        let pending = candidates - moved - failed
        if pending > 0 { parts.append("\(pending) to fix") }

        let settled = windowsSeen - skipped - candidates
        if settled > 0 { parts.append("\(settled) already in place") }

        for reason in SkipReason.allCases {
            let count = skips[reason] ?? 0
            if count > 0 { parts.append("\(count) \(reason.label(count))") }
        }

        if appsSilent > 0 { parts.append(appsSilent == 1 ? "1 app did not answer" : "\(appsSilent) apps did not answer") }

        let body = parts.isEmpty ? "nothing to do" : parts.joined(separator: ", ")
        let windows = windowsSeen == 1 ? "1 window" : "\(windowsSeen) windows"
        let apps = appsScanned == 1 ? "1 app" : "\(appsScanned) apps"
        return "\(windows) in \(apps) — \(body)"
    }
}

/// Finds windows that overlap the Dock or the menu bar and, when asked, moves
/// them back into the usable area.
///
/// The Accessibility API is the only way to move another application's window,
/// which is why the app needs to be granted Accessibility access.
public final class WindowScanner: Sendable {

    /// A window is considered to have landed if it is within this many points of
    /// the requested rect. Some applications round to their own grid.
    private let tolerance: CGFloat = 2
    private let maxAttempts = 3
    private let queue = DispatchQueue(label: "com.github.reppden.dockfixer.scanner", qos: .userInitiated)

    public init() {}

    public static var isTrusted: Bool { AX.isTrusted }
    public static func requestTrust() { AX.requestTrust() }

    private struct AppRef: Sendable {
        let pid: pid_t
        let name: String
    }

    /// Which windows a pass may move towards the Dock, as opposed to out from
    /// under it. Moving a window nothing overlaps is the bigger liberty, so
    /// each kind answers to a switch of its own.
    public struct Follow: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Windows on the same display as the Dock: against it when it
        /// shrinks or moves to another edge, and the magnet (`dockSnap`).
        public static let sameDisplay = Follow(rawValue: 1)
        /// Windows on a display the Dock has left for another one, into the
        /// strip it vacated.
        public static let acrossDisplays = Follow(rawValue: 2)
        public static let all: Follow = [.sameDisplay, .acrossDisplays]
    }

    /// What a correction may do besides clearing the Dock, worked out once
    /// from two layouts and the switches: the space each display regained,
    /// which displays the Dock left altogether, and how far the magnet
    /// reaches. A pass and a single window go through the same function, so
    /// a window restored from the Dock is treated exactly as a pass would
    /// have treated it.
    public struct Following: Sendable {
        public let reclaim: [CGDirectDisplayID: ReclaimedSpace]
        /// The displays the Dock left altogether: the third switch's case,
        /// and the third count in the usage statistics.
        public let departed: Set<CGDirectDisplayID>
        public let snap: CGFloat
    }

    /// - Parameter previous: the layout to compare against — the one before
    ///   a display change, or the one a window was minimised in — or `nil`
    ///   when there is none, which leaves only the magnet.
    public static func following(previous: [ScreenInfo]?,
                                 current: [ScreenInfo],
                                 follow: Follow) -> Following {
        // A display the Dock left altogether is the across-displays case; a
        // Dock still on the display, thinner or on another edge, the same-
        // display one.
        var departed = Set<CGDirectDisplayID>()
        let reclaim = (previous.map { reclaims(previous: $0, current: current) } ?? [:])
            .filter { displayID, _ in
                let hadDock = previous?.first { $0.displayID == displayID }?.dockSide != nil
                let hasDock = current.first { $0.displayID == displayID }?.dockSide != nil
                if hadDock && !hasDock {
                    departed.insert(displayID)
                    return follow.contains(.acrossDisplays)
                }
                return follow.contains(.sameDisplay)
            }
        return Following(reclaim: reclaim,
                         departed: departed,
                         snap: follow.contains(.sameDisplay) ? dockSnap : 0)
    }

    /// Where one window on `screen` should go, or `nil` to leave it. Pure:
    /// everything the Accessibility side read is passed in.
    public static func correction(for frame: CGRect,
                                  on screen: ScreenInfo,
                                  following: Following,
                                  slack: CGFloat) -> WindowFix? {
        computeFix(window: frame,
                   visible: screen.axVisibleFrame,
                   reclaim: following.reclaim[screen.displayID],
                   slack: slack,
                   snap: following.snap,
                   dockSide: screen.dockSide)
    }

    /// Snapshot of the display layout and the running applications, both of
    /// which must be read on the main thread, followed by the Accessibility work
    /// on a background queue.
    ///
    /// - Parameter previousScreens: the layout before the display change that
    ///   triggered this pass, if there was one. The difference against the
    ///   snapshot taken here is the space the Dock vacated. The comparison is
    ///   deliberately made against a *fresh* snapshot rather than one the
    ///   watcher took earlier, so a layout that moved again in between cannot
    ///   produce a correction against a stale visible frame.
    /// - Parameter slack: how far a window may stick out of the usable area
    ///   and still be left alone; `dockNoise` while small Dock changes are
    ///   ignored, so that the filter on changes and the one on windows agree,
    ///   and zero when they are not.
    /// - Parameter debugDetail: adds an outcome for every window the pass looked
    ///   at, including the ones it did nothing about. The scan runs off the main
    ///   thread and the log is main-actor bound, so debug lines travel back in
    ///   the summary like every other outcome; the flag keeps a release build
    ///   from building strings nothing will print.
    @MainActor
    public func run(previousScreens: [ScreenInfo]? = nil,
                    slack: CGFloat = dockNoise,
                    follow: Follow = .all,
                    debugDetail: Bool = false,
                    completion: @escaping (ScanSummary) -> Void) {
        let screens = ScreenMap.current()
        let apps = Self.regularApps()
        queue.async { [weak self] in
            guard let self else { return }
            let summary = self.scan(apps: apps,
                                    screens: screens,
                                    previousScreens: previousScreens,
                                    slack: slack,
                                    follow: follow,
                                    debugDetail: debugDetail)
            DispatchQueue.main.async { completion(summary) }
        }
    }

    /// The same correction for one window: one that has just opened, or one
    /// restored from the Dock.
    ///
    /// A new window follows nothing — `follow` empty, no layout: the space
    /// the Dock leaves behind belongs to a display change, a new window was
    /// not being held anywhere by it, and a gap its application chose is not
    /// a Dock's leftover. A restored window is the opposite case: it comes
    /// back exactly where it was minimised, and the Dock may have changed
    /// size since — on a full Dock it does every time an application opens
    /// or quits, and minimising adds a tile of its own. Compared against the
    /// layout it was minimised in, it is moved as a pass would have moved it
    /// had it been on screen: out from under a Dock that grew, back against
    /// one that shrank.
    ///
    /// Runs on the same queue as a whole pass, so the two never write to one
    /// window at the same time.
    @MainActor
    public func run(window: AXUIElement,
                    pid: pid_t,
                    appName: String,
                    previousScreens: [ScreenInfo]? = nil,
                    follow: Follow = [],
                    slack: CGFloat = dockNoise,
                    debugDetail: Bool = false,
                    completion: @escaping (ScanSummary) -> Void) {
        let screens = ScreenMap.current()
        let following = Self.following(previous: previousScreens, current: screens, follow: follow)
        let app = AppRef(pid: pid, name: appName)
        queue.async { [weak self] in
            guard let self else { return }
            var summary = ScanSummary()
            if AX.isTrusted {
                summary.appsScanned = 1
                summary.windowsSeen = 1
                if let plan = self.decide(window: window, app: app, screens: screens,
                                          following: following, slack: slack,
                                          debugDetail: debugDetail, into: &summary) {
                    summary.candidates += 1
                    summary.merge(self.write(plans: [plan], screens: screens, debugDetail: debugDetail))
                }
            }
            DispatchQueue.main.async { completion(summary) }
        }
    }

    @MainActor
    private static func regularApps() -> [AppRef] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .map { AppRef(pid: $0.processIdentifier, name: $0.localizedName ?? "pid \($0.processIdentifier)") }
    }

    // MARK: - Scanning

    /// A window that has to move, decided but not yet written.
    private struct Plan {
        let window: AXUIElement
        let app: AppRef
        let title: String
        let frame: CGRect
        let screen: ScreenInfo
        let fix: WindowFix
        let kind: UsageKind
        /// Where the window sits in the stacking order, front first; windows
        /// not on screen go last.
        var depth = Int.max
        /// Whether some part of it was in sight before it was moved.
        var visible = false

        var transition: String {
            "\(frame.logDescription) -> \(fix.rect.logDescription) \(fix.logDetail)"
        }
    }

    /// One application's share of a pass: what was decided about its windows,
    /// and the windows still to be written.
    private struct AppScan {
        var summary = ScanSummary()
        var plans: [Plan] = []
    }

    /// A pass in three phases.
    ///
    /// Every window is read and decided about first, nothing is written until
    /// all decisions are in, then every write goes out as fast as the calls
    /// can be made, and only then is anything read back. Before, each window
    /// was written and read back and, when it had not landed, written again
    /// after a pause, before the next window of the same application was
    /// touched; with Chrome spending 300ms on its first window the other three
    /// started a third of a second later, and the whole pass looked like
    /// windows moving one after another. With the writes together they all
    /// start within a few tens of milliseconds and the applications animate
    /// them side by side.
    private func scan(apps: [AppRef],
                      screens: [ScreenInfo],
                      previousScreens: [ScreenInfo]?,
                      slack: CGFloat,
                      follow: Follow,
                      debugDetail: Bool = false) -> ScanSummary {
        var summary = ScanSummary()

        func note(_ app: String, _ title: String, _ detail: String) {
            guard debugDetail else { return }
            summary.outcomes.append(WindowOutcome(
                app: app, title: title, level: .debug, detail: detail))
        }

        guard AX.isTrusted else {
            summary.outcomes.append(WindowOutcome(
                app: "DockFixer", title: "",
                level: .fail,
                detail: "Accessibility access not granted — cannot see or move windows"))
            return summary
        }

        let following = Self.following(previous: previousScreens, current: screens, follow: follow)
        let reclaim = following.reclaim
        if debugDetail {
            note("DockFixer", "", "pass — previous layout: \(previousScreens == nil ? "none" : "known")")
            for screen in screens {
                note("DockFixer", "", "now  \(Self.describe(screen))")
            }
            for screen in previousScreens ?? [] {
                note("DockFixer", "", "was  \(Self.describe(screen))")
            }
            // Why a display is not in the reclaim map is the question the whole
            // feature turns on, and the numbers above are what answers it.
            for screen in screens where reclaim[screen.displayID] == nil {
                note("DockFixer", "", "no reclaim on \(screen.localizedName)")
            }
        }
        for screen in screens {
            guard let space = reclaim[screen.displayID] else { continue }
            summary.outcomes.append(WindowOutcome(
                app: "DockFixer", title: "", level: .info,
                detail: "\(screen.localizedName) regained \(space.edgeDescription)"))
        }

        // Phase 1: read and decide. One application at a time, every
        // Accessibility call a round trip to that application, made this as
        // long as the sum of them, so each application is read on its own
        // thread. The results are merged in the order the applications were
        // listed, which keeps the log in the same order as before.
        var perApp = [AppScan?](repeating: nil, count: apps.count)
        perApp.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: apps.count) { index in
                buffer[index] = decide(app: apps[index], screens: screens, following: following,
                                       slack: slack, debugDetail: debugDetail)
            }
        }

        // An application that did not answer is asked once more, after the
        // others are done. Google Calendar and Google Maps — Chrome's app
        // windows, served by the browser process — went missing from a pass
        // while the browser was busy, and were back in the next one; the two
        // in question were left under the Dock.
        for index in perApp.indices where perApp[index] == nil {
            usleep(100_000)
            perApp[index] = decide(app: apps[index], screens: screens, following: following,
                                   slack: slack, debugDetail: debugDetail, retry: true)
        }

        var plans: [Plan] = []
        for own in perApp.compactMap({ $0 }) {
            summary.merge(own.summary)
            plans += own.plans
        }
        summary.candidates += plans.count

        summary.merge(write(plans: plans, screens: screens, debugDetail: debugDetail))
        return summary
    }

    /// Phases 2 and 3: every write, then every readback.
    ///
    /// The windows the user is looking at go first — the stacking order from
    /// the window server, front to back, which needs no permission for the
    /// bounds and the owner it is matched on. Applications are written to in
    /// parallel, each one's windows in that order, so the frontmost window
    /// of every application is its first write and the frontmost application
    /// is not waiting on any other.
    ///
    /// The same list says which windows the user could see, for the usage
    /// statistics. Read before the first write, it is the screen the user was
    /// looking at; a window counts when some of it was in sight there. A
    /// window not in it at all — one that has just opened or is coming back
    /// from the Dock, which the window server may not have put on screen yet
    /// when Accessibility reports it — is given a second chance once every
    /// window has landed: if some of it is in sight where it ended up, the
    /// user saw it arrive there.
    private func write(plans: [Plan], screens: [ScreenInfo], debugDetail: Bool) -> ScanSummary {
        var plans = plans
        let displays = screens.map(\.axFrame)
        Self.place(&plans, displays: displays)

        var groups: [pid_t: [Plan]] = [:]
        for plan in plans {
            groups[plan.app.pid, default: []].append(plan)
        }
        let order = groups.keys.sorted { lhs, rhs in
            (groups[lhs]!.map(\.depth).min() ?? .max) < (groups[rhs]!.map(\.depth).min() ?? .max)
        }
        let ordered = order.map { pid in groups[pid]!.sorted { $0.depth < $1.depth } }

        let started = Date()
        var results = [(summary: ScanSummary, moved: [(plan: Plan, outcome: Int)])?](repeating: nil, count: ordered.count)
        results.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: ordered.count) { index in
                // All of this application's writes, then all of its readbacks:
                // nothing is read until every window has been told where to
                // go, and no application waits on another at any point.
                var writes: [(at: TimeInterval, took: TimeInterval)] = []
                for plan in ordered[index] {
                    let at = Date()
                    firstWrite(plan)
                    writes.append((at.timeIntervalSince(started), Date().timeIntervalSince(at)))
                }
                var own = ScanSummary()
                var moved: [(plan: Plan, outcome: Int)] = []
                for (plan, write) in zip(ordered[index], writes) {
                    settle(plan, write: write, into: &own)
                    // `settle` adds exactly one outcome per window.
                    if own.outcomes.last?.level == .moved {
                        moved.append((plan, own.outcomes.count - 1))
                    }
                }
                buffer[index] = (own, moved)
            }
        }
        var summary = ScanSummary()
        var moved: [(plan: Plan, outcome: Int)] = []
        for own in results.compactMap({ $0 }) {
            moved += own.moved.map { ($0.plan, $0.outcome + summary.outcomes.count) }
            summary.merge(own.summary)
        }

        // Matched again in the order of the first look, front first, so that
        // of two windows with the same owner and the same bounds the one that
        // was in front takes the front entry again; the windows already seen
        // are matched too, only so that a hidden twin cannot take theirs.
        if moved.contains(where: { !$0.plan.visible }), let after = Self.windowStack() {
            moved.sort { $0.plan.depth < $1.plan.depth }
            let found = Visibility.match(moved.map { ($0.plan.app.pid, $0.plan.fix.rect) }, in: after)
            for (entry, index) in zip(moved, found) where !entry.plan.visible {
                if let index, Visibility.isPartlyVisible(at: index, in: after, displays: displays) {
                    summary.outcomes[entry.outcome].visible = true
                }
            }
        }
        // Every move gets a verdict, the counted ones too: reading which
        // window a number on the Stats tab came from by elimination, from the
        // list of the ones that did not count, was how the first question
        // about it had to be answered.
        if debugDetail {
            for entry in moved {
                let detail: String
                if summary.outcomes[entry.outcome].visible {
                    detail = "counted as \(entry.plan.kind.rawValue) (\(Savings.seconds(per: entry.plan.kind).formatted()) s)"
                } else if entry.plan.depth == .max {
                    detail = "not counted — not on screen"
                } else {
                    detail = "not counted — covered by the windows in front of it"
                }
                summary.outcomes.append(WindowOutcome(
                    app: entry.plan.app.name, title: entry.plan.title, level: .debug, detail: detail))
            }
        }
        return summary
    }

    /// The first write to a window: position, then size, each only when it
    /// changes.
    ///
    /// Position first. A window reaching the far edge of the display that has
    /// to shrink used to be written size, position, size, with the step below
    /// first on a retry (see `stepBelow`) — four writes at 40–70ms each in
    /// Chrome. The failure that step works around was seen on windows whose
    /// origin did not move; moved first, every such window in a pass of
    /// thirty took the direct size write, none was written again, and
    /// Chrome's first window went from 165ms to 11ms. The readback keeps
    /// watch: "written again" in the log is a window this did not hold for.
    private func firstWrite(_ plan: Plan) {
        let target = plan.fix.rect
        let frame = plan.frame
        if target.origin != frame.origin { AX.setPosition(plan.window, target.origin) }
        if target.size != frame.size { AX.setSize(plan.window, target.size) }
    }

    /// Reads a window back after its first write and, if it is not where it
    /// should be, writes again the slow way.
    ///
    /// Every moved line carries when in the pass its write went out and how
    /// long the application took to accept it — the write returns once the
    /// application has applied it, so that is when the window moved — and
    /// whether it had to be written again. The log is the only way to see a
    /// pass from where the user sits, and "one after another" and "all at
    /// once" look the same in a list of outcomes without the times.
    private func settle(_ plan: Plan, write: (at: TimeInterval, took: TimeInterval), into summary: inout ScanSummary) {
        let target = plan.fix.rect
        let landed: ApplyResult
        var retried = false
        if let actual = AX.frame(plan.window), Self.isClose(actual, to: target, tolerance: tolerance) {
            landed = .success
        } else {
            retried = true
            landed = apply(target, to: plan.window)
        }
        let timing = String(format: " [+%.0fms, %.0fms%@]", write.at * 1000, write.took * 1000,
                            retried ? ", written again" : "")
        switch landed {
        case .success:
            summary.moved += 1
            summary.outcomes.append(WindowOutcome(
                app: plan.app.name, title: plan.title, level: .moved, detail: plan.transition + timing,
                kind: plan.kind, visible: plan.visible))
        case .mismatch(let actual, let attempts, let error):
            summary.failed += 1
            summary.outcomes.append(WindowOutcome(
                app: plan.app.name, title: plan.title, level: .fail,
                detail: "want \(target.logDescription) got \(actual.logDescription) after \(attempts) tries"
                    + (error.map { " — \($0)" } ?? " — every write was accepted") + timing))
        case .unreadable(let error):
            summary.failed += 1
            summary.outcomes.append(WindowOutcome(
                app: plan.app.name, title: plan.title, level: .fail,
                detail: "wrote \(target.logDescription) but could not read the window back — "
                    + (error ?? AX.readFailure(plan.window, kAXPositionAttribute as String)) + timing))
        }
    }

    /// Where each planned window sits in the stacking order, and whether any
    /// of it is in sight, from the window server's list of on-screen windows,
    /// matched by owner and bounds. The list carries no titles without Screen
    /// Recording access, but the bounds and the owner are enough, and are
    /// given freely.
    private static func place(_ plans: inout [Plan], displays: [CGRect]) {
        guard let stack = windowStack() else { return }
        let found = Visibility.match(plans.map { ($0.app.pid, $0.frame) }, in: stack)
        for (index, depth) in zip(plans.indices, found) {
            guard let depth else { continue }
            plans[index].depth = depth
            plans[index].visible = Visibility.isPartlyVisible(at: depth, in: stack, displays: displays)
        }
    }

    /// The windows on screen, front to back. Only the current Space's are
    /// listed, so a window on another Space is simply not there.
    private static func windowStack() -> [StackedWindow]? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return list.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"]
            else { return nil }
            return StackedWindow(pid: pid,
                                 bounds: CGRect(x: x, y: y, width: w, height: h),
                                 layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                                 alpha: entry[kCGWindowAlpha as String] as? CGFloat ?? 1)
        }
    }

    private static func isClose(_ a: CGRect, to b: CGRect, tolerance: CGFloat) -> Bool {
        a.isClose(to: b, tolerance: tolerance)
    }

    /// One application's windows, or `nil` when it did not list any — normal
    /// for an application with no windows, but also how a missing window
    /// looks, so the error is recorded when the pass is being detailed.
    private func decide(app: AppRef,
                        screens: [ScreenInfo],
                        following: Following,
                        slack: CGFloat,
                        debugDetail: Bool,
                        retry: Bool = false) -> AppScan? {
        let appElement = AX.application(pid: app.pid)
        guard let windows = AX.windows(of: appElement) else {
            // Only on the retry, so that the first miss does not fill the log
            // on every pass. Named in the ordinary log, once per session: an
            // application whose windows a pass cannot see is the first thing
            // to look for when one of them was left under the Dock.
            guard retry else { return nil }
            var own = AppScan()
            own.summary.appsSilent = 1
            own.summary.outcomes.append(WindowOutcome(
                app: app.name, title: "", level: .skip,
                detail: "did not list its windows, even when asked again — "
                    + AX.readFailure(appElement, kAXWindowsAttribute as String),
                logOncePerSession: true))
            return own
        }
        var own = AppScan()
        own.summary.appsScanned = 1
        if retry, debugDetail {
            own.summary.outcomes.append(WindowOutcome(
                app: app.name, title: "", level: .debug,
                detail: "listed its windows on the second ask"))
        }
        for window in windows {
            own.summary.windowsSeen += 1
            if let plan = decide(window: window, app: app, screens: screens,
                                 following: following, slack: slack,
                                 debugDetail: debugDetail, into: &own.summary) {
                own.plans.append(plan)
            }
        }
        return own
    }

    private static func describe(_ screen: ScreenInfo) -> String {
        "\(screen.localizedName)\(screen.isPrimary ? " (primary)" : "")"
            + " frame \(screen.axFrame.logDescription)"
            + " visible \(screen.axVisibleFrame.logDescription)"
    }

    /// What to do about one window: a plan to move it, or nothing, with the
    /// reason recorded in the summary.
    private func decide(window: AXUIElement,
                        app: AppRef,
                        screens: [ScreenInfo],
                        following: Following,
                        slack: CGFloat,
                        debugDetail: Bool,
                        into summary: inout ScanSummary) -> Plan? {
        let title = AX.string(window, kAXTitleAttribute as String) ?? ""
        let subrole = AX.string(window, kAXSubroleAttribute as String)

        func note(_ detail: String) {
            guard debugDetail else { return }
            summary.outcomes.append(WindowOutcome(
                app: app.name, title: title, level: .debug, detail: detail))
        }

        /// Counted, not logged. Nothing here is an event, and none of it is
        /// actionable — the log is for what a pass did.
        func skip(_ reason: SkipReason) -> Plan? {
            summary.skips[reason, default: 0] += 1
            note("skipped: \(reason.label(1))")
            return nil
        }

        /// Counted *and* logged once per session: a window that is in the way
        /// and refuses to move is worth naming, but only the first time.
        func report(_ reason: SkipReason, _ detail: String) -> Plan? {
            _ = skip(reason)
            summary.outcomes.append(WindowOutcome(
                app: app.name, title: title, level: .skip,
                detail: "\(detail) [\(subrole ?? "no subrole")]",
                logOncePerSession: true))
            return nil
        }

        if AX.bool(window, kAXMinimizedAttribute as String) == true {
            return skip(.minimized)
        }
        if AX.bool(window, AX.fullScreenAttribute) == true {
            return skip(.fullScreen)
        }
        guard let frame = AX.frame(window) else {
            if debugDetail {
                note("could not read its geometry — "
                    + AX.readFailure(window, kAXPositionAttribute as String) + ", "
                    + AX.readFailure(window, kAXSizeAttribute as String))
            }
            return skip(.unreadable)
        }
        guard frame.width > 1, frame.height > 1 else {
            note("degenerate frame \(frame.logDescription)")
            return skip(.unreadable)
        }

        // The desktop and the system's own layers: no subrole, and read-only.
        // They cover a whole display, so they overlap the Dock by definition and
        // would otherwise be reported as an immovable candidate on every pass.
        // Identified by what they are rather than by their size, because the
        // desktop does not always match the display frame exactly.
        if subrole == nil, !AX.isSettable(window, kAXPositionAttribute as String) {
            return skip(.systemWindow)
        }

        guard let screen = ScreenMap.screen(for: frame, in: screens) else {
            return skip(.noDisplay)
        }

        guard let fix = Self.correction(for: frame, on: screen, following: following, slack: slack) else {
            // Already inside the usable area, with nothing to reclaim.
            // Not logged: this is most windows.
            let inside = screen.axVisibleFrame.contains(frame)
            note("\(frame.logDescription) on \(screen.localizedName) — "
                + (inside ? "nothing to correct" : "sticks out by \(Int(slack))pt or less, left alone")
                + (following.reclaim[screen.displayID] == nil ? "" : ", and it was not held by the Dock"))
            return nil
        }

        // A window can be in the way and still be immovable — a fixed-size
        // dialog, for instance. Counted as a skip rather than a candidate: it
        // is not something this pass, or any pass, is going to fix.
        let needsMove = fix.rect.origin != frame.origin
        let needsResize = fix.rect.size != frame.size
        if needsMove, !AX.isSettable(window, kAXPositionAttribute as String) {
            return report(.immovable, "in the way but its position is fixed — would move to \(fix.rect.logDescription)")
        }
        if needsResize, !AX.isSettable(window, kAXSizeAttribute as String) {
            return report(.immovable, "in the way but its size is fixed — would resize to \(fix.rect.logDescription)")
        }

        let kind: UsageKind
        switch fix.reason {
        case .underDock: kind = .pushedOut
        case .followedDock: kind = following.departed.contains(screen.displayID) ? .acrossDisplays : .stuck
        }
        return Plan(window: window, app: app, title: title, frame: frame, screen: screen, fix: fix, kind: kind)
    }


    // MARK: - Applying

    /// A size under `target` on each side that has to shrink, as the first of
    /// two writes.
    ///
    /// A window as wide as the whole display could not be narrowed straight to
    /// the width the Dock leaves: the write returned success and the window
    /// stayed exactly where it was, in every application alike — Chrome,
    /// Safari, Finder, PyCharm — so the limit is the system's, not theirs. The
    /// same window narrowed further first and then widened to the target
    /// landed on it. Written up front for the windows known to need it — the
    /// ones reaching the far edge of the display, see `firstWrite` — and on a
    /// retry for any other, so windows that take the direct write never see
    /// the extra step.
    public static func stepBelow(_ target: CGSize, from current: CGSize) -> CGSize {
        let margin: CGFloat = 50
        return CGSize(width: target.width < current.width - 0.5 ? max(target.width - margin, 1) : target.width,
                      height: target.height < current.height - 0.5 ? max(target.height - margin, 1) : target.height)
    }

    private enum ApplyResult {
        case success
        /// `error` is the last write the application rejected, if any; a
        /// window that accepted every write and still did not move is a
        /// mismatch with no error, which is its own kind of answer.
        case mismatch(actual: CGRect, attempts: Int, error: String?)
        case unreadable(error: String?)
    }

    /// Writes the target rect and verifies it stuck.
    ///
    /// Size is written, then position, then size again: an application may clamp
    /// the position against its old size, and may clamp the size against its old
    /// position. Doing both in that order gets the common cases in one pass, and
    /// the readback catches the rest.
    private func apply(_ target: CGRect, to window: AXUIElement) -> ApplyResult {
        var lastRead: CGRect?
        var lastError: String?
        func check(_ what: String, _ result: AXError) {
            if result != .success { lastError = "\(what): \(AX.describe(result))" }
        }

        for attempt in 1...maxAttempts {
            if attempt > 1, let last = lastRead {
                let below = Self.stepBelow(target.size, from: last.size)
                if below != target.size { check("size", AX.setSize(window, below)) }
            }
            check("size", AX.setSize(window, target.size))
            check("position", AX.setPosition(window, target.origin))
            check("size", AX.setSize(window, target.size))

            guard let actual = AX.frame(window) else { return .unreadable(error: lastError) }
            lastRead = actual

            let close = abs(actual.minX - target.minX) <= tolerance
                && abs(actual.minY - target.minY) <= tolerance
                && abs(actual.width - target.width) <= tolerance
                && abs(actual.height - target.height) <= tolerance
            if close { return .success }

            if attempt < maxAttempts {
                // Some applications animate; give them a moment to settle before
                // deciding the write did not take.
                usleep(60_000)
            }
        }

        guard let actual = lastRead else { return .unreadable(error: lastError) }
        return .mismatch(actual: actual, attempts: maxAttempts, error: lastError)
    }
}
