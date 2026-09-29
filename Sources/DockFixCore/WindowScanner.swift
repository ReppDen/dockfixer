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
    public var windowsSeen = 0
    /// Windows that overlap the Dock or the menu bar and need correcting.
    public var candidates = 0
    public var moved = 0
    public var failed = 0
    public var skips: [SkipReason: Int] = [:]

    public var skipped: Int { skips.values.reduce(0, +) }

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
    private let queue = DispatchQueue(label: "com.github.reppden.dockfix.scanner", qos: .userInitiated)

    public init() {}

    public static var isTrusted: Bool { AX.isTrusted }
    public static func requestTrust() { AX.requestTrust() }

    private struct AppRef: Sendable {
        let pid: pid_t
        let name: String
    }

    /// Snapshot of the display layout and the running applications, both of
    /// which must be read on the main thread, followed by the Accessibility work
    /// on a background queue.
    ///
    /// - Parameter dryRun: when true, nothing is written — this backs the
    ///   "Check Windows" button, which must list exactly what "Move Windows"
    ///   would touch without touching it.
    /// - Parameter previousScreens: the layout before the display change that
    ///   triggered this pass, if there was one. The difference against the
    ///   snapshot taken here is the space the Dock vacated. The comparison is
    ///   deliberately made against a *fresh* snapshot rather than one the
    ///   watcher took earlier, so a layout that moved again in between cannot
    ///   produce a correction against a stale visible frame.
    /// - Parameter debugDetail: adds an outcome for every window the pass looked
    ///   at, including the ones it did nothing about. The scan runs off the main
    ///   thread and the log is main-actor bound, so debug lines travel back in
    ///   the summary like every other outcome; the flag keeps a release build
    ///   from building strings nothing will print.
    @MainActor
    public func run(dryRun: Bool = false,
                    previousScreens: [ScreenInfo]? = nil,
                    debugDetail: Bool = false,
                    completion: @escaping (ScanSummary) -> Void) {
        let screens = ScreenMap.current()
        let apps = Self.regularApps()
        queue.async { [weak self] in
            guard let self else { return }
            let summary = self.scan(apps: apps,
                                    screens: screens,
                                    previousScreens: previousScreens,
                                    dryRun: dryRun,
                                    debugDetail: debugDetail)
            DispatchQueue.main.async { completion(summary) }
        }
    }

    /// The same correction for one window that has just opened.
    ///
    /// Nothing is reclaimed: the space the Dock leaves behind belongs to a
    /// display change, and a new window was not being held anywhere by it.
    /// Runs on the same queue as a whole pass, so the two never write to one
    /// window at the same time.
    @MainActor
    public func run(window: AXUIElement,
                    pid: pid_t,
                    appName: String,
                    debugDetail: Bool = false,
                    completion: @escaping (ScanSummary) -> Void) {
        let screens = ScreenMap.current()
        let app = AppRef(pid: pid, name: appName)
        queue.async { [weak self] in
            guard let self else { return }
            var summary = ScanSummary()
            if AX.isTrusted {
                summary.appsScanned = 1
                summary.windowsSeen = 1
                self.process(window: window, app: app, screens: screens,
                             reclaim: [:], dryRun: false,
                             debugDetail: debugDetail, into: &summary)
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

    private func scan(apps: [AppRef],
                      screens: [ScreenInfo],
                      previousScreens: [ScreenInfo]?,
                      dryRun: Bool,
                      debugDetail: Bool = false) -> ScanSummary {
        var summary = ScanSummary()

        func note(_ app: String, _ title: String, _ detail: String) {
            guard debugDetail else { return }
            summary.outcomes.append(WindowOutcome(
                app: app, title: title, level: .debug, detail: detail))
        }

        guard AX.isTrusted else {
            summary.outcomes.append(WindowOutcome(
                app: "DockFix", title: "",
                level: .fail,
                detail: "Accessibility access not granted — cannot see or move windows"))
            return summary
        }

        let reclaim = previousScreens.map { reclaims(previous: $0, current: screens) } ?? [:]
        if debugDetail {
            note("DockFix", "", "pass — dry run: \(dryRun), previous layout: \(previousScreens == nil ? "none" : "known")")
            for screen in screens {
                note("DockFix", "", "now  \(Self.describe(screen))")
            }
            for screen in previousScreens ?? [] {
                note("DockFix", "", "was  \(Self.describe(screen))")
            }
            // Why a display is not in the reclaim map is the question the whole
            // feature turns on, and the numbers above are what answers it.
            for screen in screens where reclaim[screen.displayID] == nil {
                note("DockFix", "", "no reclaim on \(screen.localizedName)")
            }
        }
        for screen in screens {
            guard let space = reclaim[screen.displayID] else { continue }
            summary.outcomes.append(WindowOutcome(
                app: "DockFix", title: "", level: .info,
                detail: "\(screen.localizedName) regained \(space.edgeDescription)"))
        }

        for app in apps {
            let appElement = AX.application(pid: app.pid)
            guard let windows = AX.windows(of: appElement) else {
                // Normal for agents with no windows and for apps that refuse to
                // expose a tree; worth recording because it is also how a
                // missing window would look.
                continue
            }
            summary.appsScanned += 1

            for window in windows {
                summary.windowsSeen += 1
                process(window: window, app: app, screens: screens,
                        reclaim: reclaim, dryRun: dryRun,
                        debugDetail: debugDetail, into: &summary)
            }
        }
        return summary
    }

    private static func describe(_ screen: ScreenInfo) -> String {
        "\(screen.localizedName)\(screen.isPrimary ? " (primary)" : "")"
            + " frame \(screen.axFrame.logDescription)"
            + " visible \(screen.axVisibleFrame.logDescription)"
    }

    private func process(window: AXUIElement,
                         app: AppRef,
                         screens: [ScreenInfo],
                         reclaim: [CGDirectDisplayID: ReclaimedSpace],
                         dryRun: Bool,
                         debugDetail: Bool,
                         into summary: inout ScanSummary) {
        let title = AX.string(window, kAXTitleAttribute as String) ?? ""
        let subrole = AX.string(window, kAXSubroleAttribute as String)

        func note(_ detail: String) {
            guard debugDetail else { return }
            summary.outcomes.append(WindowOutcome(
                app: app.name, title: title, level: .debug, detail: detail))
        }

        /// Counted, not logged. Nothing here is an event, and none of it is
        /// actionable — the log is for what a pass did.
        func skip(_ reason: SkipReason) {
            summary.skips[reason, default: 0] += 1
            note("skipped: \(reason.label(1))")
        }

        /// Counted *and* logged once per session: a window that is in the way
        /// and refuses to move is worth naming, but only the first time.
        func report(_ reason: SkipReason, _ detail: String) {
            skip(reason)
            summary.outcomes.append(WindowOutcome(
                app: app.name, title: title, level: .skip,
                detail: "\(detail) [\(subrole ?? "no subrole")]",
                logOncePerSession: true))
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

        guard let fix = computeFix(window: frame,
                                   visible: screen.axVisibleFrame,
                                   reclaim: reclaim[screen.displayID]) else {
            // Already inside the usable area, with nothing to reclaim.
            // Not logged: this is most windows.
            note("\(frame.logDescription) on \(screen.localizedName) — nothing to correct"
                + (reclaim[screen.displayID] == nil ? "" : ", and it was not held by the Dock"))
            return
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

        summary.candidates += 1

        let transition = "\(frame.logDescription) -> \(fix.rect.logDescription) \(fix.logDetail)"

        if dryRun {
            summary.outcomes.append(WindowOutcome(
                app: app.name, title: title, level: .info, detail: "would fix  \(transition)"))
            return
        }

        let landed = apply(fix.rect, to: window)
        switch landed {
        case .success:
            summary.moved += 1
            summary.outcomes.append(WindowOutcome(
                app: app.name, title: title, level: .moved, detail: transition))
        case .mismatch(let actual, let attempts):
            summary.failed += 1
            summary.outcomes.append(WindowOutcome(
                app: app.name, title: title, level: .fail,
                detail: "want \(fix.rect.logDescription) got \(actual.logDescription) after \(attempts) tries"))
        case .unreadable:
            summary.failed += 1
            summary.outcomes.append(WindowOutcome(
                app: app.name, title: title, level: .fail,
                detail: "wrote \(fix.rect.logDescription) but could not read the window back"))
        }
    }

    // MARK: - Applying

    private enum ApplyResult {
        case success
        case mismatch(actual: CGRect, attempts: Int)
        case unreadable
    }

    /// Writes the target rect and verifies it stuck.
    ///
    /// Size is written, then position, then size again: an application may clamp
    /// the position against its old size, and may clamp the size against its old
    /// position. Doing both in that order gets the common cases in one pass, and
    /// the readback catches the rest.
    private func apply(_ target: CGRect, to window: AXUIElement) -> ApplyResult {
        var lastRead: CGRect?

        for attempt in 1...maxAttempts {
            AX.setSize(window, target.size)
            AX.setPosition(window, target.origin)
            AX.setSize(window, target.size)

            guard let actual = AX.frame(window) else { return .unreadable }
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

        guard let actual = lastRead else { return .unreadable }
        return .mismatch(actual: actual, attempts: maxAttempts)
    }
}
