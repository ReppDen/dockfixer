import AppKit
import ApplicationServices

/// What happened to one window during a pass.
public struct WindowOutcome: Sendable {
    public let app: String
    public let title: String
    public let level: LogLevel
    public let detail: String
    /// Set for findings that recur identically on every pass — the Finder
    /// desktop, for instance. Logged once per session so they do not bury the
    /// entries that change.
    public var logOncePerSession = false
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
    public var skipped = 0

    /// One-line tally for the log.
    public var headline: String {
        "\(windowsSeen) windows in \(appsScanned) apps, \(candidates) need fixing"
            + (moved > 0 ? ", \(moved) moved" : "")
            + (failed > 0 ? ", \(failed) failed" : "")
            + (skipped > 0 ? ", \(skipped) skipped" : "")
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
    private let queue = DispatchQueue(label: "com.github.drepp.dockfix.scanner", qos: .userInitiated)

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
    @MainActor
    public func run(dryRun: Bool, completion: @escaping (ScanSummary) -> Void) {
        let screens = ScreenMap.current()
        let apps = Self.regularApps()
        queue.async { [weak self] in
            guard let self else { return }
            let summary = self.scan(apps: apps, screens: screens, dryRun: dryRun)
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

    private func scan(apps: [AppRef], screens: [ScreenInfo], dryRun: Bool) -> ScanSummary {
        var summary = ScanSummary()
        guard AX.isTrusted else {
            summary.outcomes.append(WindowOutcome(
                app: "DockFix", title: "",
                level: .fail,
                detail: "Accessibility access not granted — cannot see or move windows"))
            return summary
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
                process(window: window, app: app, screens: screens, dryRun: dryRun, into: &summary)
            }
        }
        return summary
    }

    private func process(window: AXUIElement,
                         app: AppRef,
                         screens: [ScreenInfo],
                         dryRun: Bool,
                         into summary: inout ScanSummary) {
        let title = AX.string(window, kAXTitleAttribute as String) ?? ""
        let subrole = AX.string(window, kAXSubroleAttribute as String) ?? "no subrole"

        func skip(_ reason: String, logOncePerSession: Bool = false) {
            summary.skipped += 1
            summary.outcomes.append(WindowOutcome(app: app.name, title: title, level: .skip,
                                                  detail: "\(reason) [\(subrole)]",
                                                  logOncePerSession: logOncePerSession))
        }

        if AX.bool(window, kAXMinimizedAttribute as String) == true {
            return skip("minimized")
        }
        if AX.bool(window, AX.fullScreenAttribute) == true {
            return skip("fullscreen")
        }
        guard let frame = AX.frame(window) else {
            return skip("position or size unreadable")
        }
        guard frame.width > 1, frame.height > 1 else {
            return skip("zero-size window \(frame.logDescription)")
        }
        guard let screen = ScreenMap.screen(for: frame, in: screens) else {
            return skip("no display to place it on")
        }

        // The Finder desktop is exposed as a read-only window covering a whole
        // display. It overlaps the Dock by definition and can never be moved, so
        // without this it would be reported on every single pass.
        if frame == screen.axFrame,
           title.isEmpty,
           !AX.isSettable(window, kAXPositionAttribute as String) {
            return skip("read-only window covering the whole display — desktop or system layer",
                        logOncePerSession: true)
        }

        guard let fix = computeFix(window: frame, visible: screen.axVisibleFrame) else {
            return  // Already inside the usable area. Not logged: this is most windows.
        }

        summary.candidates += 1

        // A window can be in the way and still be immovable — a fixed-size
        // dialog, for instance. Report it rather than silently failing later.
        let needsMove = fix.rect.origin != frame.origin
        let needsResize = fix.rect.size != frame.size
        if needsMove, !AX.isSettable(window, kAXPositionAttribute as String) {
            return skip("would move to \(fix.rect.logDescription) but position is not settable")
        }
        if needsResize, !AX.isSettable(window, kAXSizeAttribute as String) {
            return skip("would resize to \(fix.rect.logDescription) but size is not settable")
        }

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
