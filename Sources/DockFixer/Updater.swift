import AppKit
import Combine
import DockFixerCore
import Sparkle

/// Keeps DockFixer up to date through Sparkle, quietly.
///
/// The feed is `appcast.xml` attached to the latest GitHub release (`SUFeedURL`
/// in Info.plist). Sparkle checks it once a day, verifies the download against
/// the EdDSA key in `SUPublicEDKey`, and replaces the bundle in place. The
/// bundle keeps its code-signing identity from release to release — a
/// self-signed certificate, see the README — and that is what keeps the
/// Accessibility grant: macOS ties it to the designated requirement, which
/// names the certificate, not the code hash.
///
/// Every update is installed without asking, whatever the version number says.
/// The one thing Sparkle leaves to the app is *when*: by default it waits for
/// the app to quit, and DockFixer never quits — it has to be running to catch
/// a display being unplugged. So the update is installed straight away and the
/// app restarted, unless a window of the app is open: someone is looking at
/// it, and it should not vanish under the pointer. Then it waits until the
/// window is closed.
@MainActor
final class Updater: NSObject, ObservableObject {

    /// "Install updates automatically". Sparkle's own setting, stored by
    /// Sparkle under `SUAutomaticallyUpdate`; on by default from Info.plist.
    /// Off, Sparkle still checks every day but shows its window and asks.
    @Published var automaticallyUpdates: Bool {
        didSet {
            guard oldValue != automaticallyUpdates else { return }
            controller.updater.automaticallyDownloadsUpdates = automaticallyUpdates
            log.info("install updates automatically: \(automaticallyUpdates ? "enabled" : "disabled")")
        }
    }

    /// False while a check is already running, so the button cannot start
    /// a second one.
    @Published private(set) var canCheckForUpdates = false

    /// Set just before an automatic install restarts the app, read once by the
    /// next launch so it comes up in the menu bar, as at login, rather than
    /// opening its window at someone who did not ask for it.
    private static let relaunchedAfterUpdateKey = "relaunchedAfterUpdate"

    /// How often a waiting update looks again for the window to be gone. The
    /// close button hides the window rather than closing it, so there is no
    /// notification to wait for, and a minute either way does not matter.
    private static let pendingInstallRetry: TimeInterval = 30

    private let log: Log
    private var controller: SPUStandardUpdaterController!
    private var canCheckObservation: NSKeyValueObservation?
    private var pendingInstall: (() -> Void)?
    private var pendingTimer: Timer?

    init(log: Log) {
        self.log = log
        self.automaticallyUpdates = true
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: self)
        let updater = controller.updater
        automaticallyUpdates = updater.automaticallyDownloadsUpdates
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Only a real change: see the note on MenuBarExtra in DockFixerApp.
                    if self?.canCheckForUpdates != canCheck { self?.canCheckForUpdates = canCheck }
                }
            }
        }

        // A build without a feed — a plain `swift build`, a fork that has not
        // set one up — has nothing to check, and Sparkle would only complain.
        let info = Bundle.main.infoDictionary ?? [:]
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty
        else {
            log.info("updates: no feed in this build, not checking")
            return
        }
        do {
            try updater.start()
        } catch {
            log.info("updates: could not start — \(error.localizedDescription)")
            return
        }
        log.info("updates: checking \(updater.feedURL?.absoluteString ?? "?") every \(Int(updater.updateCheckInterval / 3600))h"
            + ", install automatically: \(automaticallyUpdates ? "on" : "off")")
    }

    /// The button and the menu item: a check someone asked for, with Sparkle's
    /// window to answer it either way.
    func checkForUpdates() {
        log.info("updates: check requested")
        // Sparkle's window needs an app that can come to the front; the app is
        // an accessory while its own window is closed.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// True once, on the first launch after an automatic update restarted the
    /// app. Clears itself.
    static func takeRelaunchedAfterUpdate() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: relaunchedAfterUpdateKey) else { return false }
        defaults.removeObject(forKey: relaunchedAfterUpdateKey)
        return true
    }

    /// Any window of the app's own on screen — settings, log, or Sparkle's.
    /// The untitled panels AppKit keeps for the status item do not count.
    private static var someoneIsLooking: Bool {
        NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
    }

    /// Installs the waiting update now if nothing is on screen, or looks again
    /// shortly. Also called by the app delegate as soon as the last window
    /// goes, so the wait is not a whole retry period long.
    func installWhenIdle() {
        guard let install = pendingInstall else { return }
        guard !Self.someoneIsLooking else {
            guard pendingTimer == nil else { return }
            log.info("updates: ready, waiting for the window to be closed")
            pendingTimer = Timer.scheduledTimer(withTimeInterval: Self.pendingInstallRetry, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.installWhenIdle() }
            }
            return
        }
        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingInstall = nil
        log.info("updates: installing and restarting")
        UserDefaults.standard.set(true, forKey: Self.relaunchedAfterUpdateKey)
        install()
    }

    nonisolated private static func describe(_ item: SUAppcastItem) -> String {
        "\(item.displayVersionString) (\(item.versionString))"
    }
}

extension Updater: SPUUpdaterDelegate {

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = Self.describe(item)
        MainActor.assumeIsolated { log.info("updates: found \(version)") }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { log.debug("updates: up to date") }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // "No update" arrives here too, as an error, when the check was asked
        // for by hand; it is not a failure.
        let nsError = error as NSError
        guard !(nsError.domain == SUSparkleErrorDomain && nsError.code == Int(SUError.noUpdateError.rawValue)) else { return }
        let message = error.localizedDescription
        MainActor.assumeIsolated { log.info("updates: failed — \(message)") }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let version = Self.describe(item)
        MainActor.assumeIsolated { log.info("updates: installing \(version)") }
    }

    /// The update is downloaded, checked and unpacked, and Sparkle offers to
    /// install it at quit. Taking the offer of an immediate install instead is
    /// what makes updates happen for an app that never quits.
    nonisolated func updater(_ updater: SPUUpdater,
                             willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = Self.describe(item)
        MainActor.assumeIsolated {
            log.info("updates: \(version) downloaded")
            pendingInstall = immediateInstallationBlock
            installWhenIdle()
        }
        return true
    }
}

extension Updater: SPUStandardUserDriverDelegate {

    /// The app spends most of its life as a menu-bar accessory. Sparkle asks
    /// such apps to say they can handle a reminder that does not steal focus;
    /// it only matters when automatic installs are off and Sparkle has to ask.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
