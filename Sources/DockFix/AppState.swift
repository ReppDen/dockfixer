import AppKit
import Combine
import DockFixCore
import SwiftUI

/// Glue between the window and the scanner.
@MainActor
final class AppState: ObservableObject {

    /// Persisted so the setting survives a restart.
    @Published var autoFixEnabled: Bool {
        didSet {
            guard oldValue != autoFixEnabled else { return }
            UserDefaults.standard.set(autoFixEnabled, forKey: Self.autoFixKey)
            autoFixEnabled ? watcher?.start() : watcher?.stop()
        }
    }

    /// Accessibility access can be granted or revoked outside the app, so this
    /// is polled rather than read once.
    @Published private(set) var isTrusted: Bool
    @Published private(set) var isBusy = false
    @Published private(set) var displaysSummary = ""
    @Published private(set) var lastSummary: ScanSummary?

    let log: Log

    private static let autoFixKey = "autoFixOnDisplayChange"
    private let scanner = WindowScanner()
    private var watcher: DisplayWatcher?
    private var pollTimer: Timer?

    init() {
        log = Log()
        autoFixEnabled = UserDefaults.standard.bool(forKey: Self.autoFixKey)
        isTrusted = WindowScanner.isTrusted

        watcher = DisplayWatcher(log: log) { [weak self] reason in
            self?.run(dryRun: false, trigger: reason)
        }

        refreshDisplays()
        log.info("DockFix ready — \(displaysSummary)")
        if !isTrusted {
            log.info("Accessibility access not granted yet; approve DockFix in the system prompt, or press Grant")
            // Ask straight away rather than at the first button press: the grant
            // has to be in place before anything useful can happen.
            WindowScanner.requestTrust()
        }
        if autoFixEnabled {
            watcher?.start()
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
    }

    // MARK: - Actions

    /// Lists what a move would touch, without touching anything.
    func checkWindows() {
        run(dryRun: true, trigger: nil)
    }

    func moveWindows() {
        run(dryRun: false, trigger: nil)
    }

    func requestAccessibility() {
        WindowScanner.requestTrust()
        log.info("Accessibility prompt requested — grant DockFix in System Settings, then come back")
        // The System Settings pane, in case the prompt was dismissed earlier and
        // will not appear again.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func clearLog() {
        log.clear()
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

    private func run(dryRun: Bool, trigger: String?) {
        guard !isBusy else { return }

        guard isTrusted else {
            log.add(level: .fail, app: "DockFix", title: "",
                    detail: "cannot scan windows without Accessibility access")
            requestAccessibility()
            return
        }

        isBusy = true
        let label = dryRun ? "check" : "move"
        log.info(trigger.map { "\(label) triggered by \($0)" } ?? "\(label) requested")

        scanner.run(dryRun: dryRun) { [weak self] summary in
            guard let self else { return }
            for outcome in summary.outcomes {
                log.add(level: outcome.level,
                        app: outcome.app,
                        title: outcome.title,
                        detail: outcome.detail)
            }
            log.info("\(label) done — \(summary.headline)")
            lastSummary = summary
            isBusy = false
        }
    }

    private func poll() {
        let trusted = WindowScanner.isTrusted
        if trusted != isTrusted {
            isTrusted = trusted
            log.info("Accessibility access \(trusted ? "granted" : "revoked")")
        }
        refreshDisplays()
    }

    private func refreshDisplays() {
        let screens = ScreenMap.current()
        let parts = screens.map { screen in
            "\(screen.localizedName) \(Int(screen.axFrame.width))x\(Int(screen.axFrame.height))"
                + " dock \(screen.dockEdge)"
                + (screen.isPrimary && screens.count > 1 ? " (primary)" : "")
        }
        displaysSummary = parts.joined(separator: "   ·   ")
    }
}
