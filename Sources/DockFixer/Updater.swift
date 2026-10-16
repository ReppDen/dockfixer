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
/// window is closed, or until someone presses "Restart to Update".
///
/// With "Install updates automatically" off, Sparkle does not download on its
/// own: it shows its window and asks. An update that was already downloaded
/// when the switch went off is no longer installed when the window closes,
/// but Sparkle still installs it when the app quits — that part is Sparkle's
/// and cannot be turned off from here (`SPUUpdaterDelegate.h`, on
/// `willInstallUpdateOnQuit`).
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
            // Switched off while an update waits for the window to close: the
            // waiting is what "automatically" meant, so it stops here. Turning
            // the switch back on does not bring it back; Sparkle has the
            // update and installs it at quit either way.
            if !automaticallyUpdates, pendingInstall != nil {
                cancelPendingInstall()
                log.info("updates: the downloaded update will not be installed now — Sparkle installs it when DockFixer quits")
            }
        }
    }

    /// False while a check is already running, and in a build without a
    /// feed, where Sparkle is never started: the button is disabled rather
    /// than doing nothing.
    @Published private(set) var canCheckForUpdates = false

    /// An update is downloaded and waits for the window to be closed. The
    /// window offers to install it right away instead.
    @Published private(set) var updateIsWaiting = false

    /// The version an automatic install is about to restart into, written
    /// just before the install and read once by the next launch, so that it
    /// comes up in the menu bar, as at login, rather than opening its window
    /// at someone who did not ask for it.
    ///
    /// A version rather than a flag: if the install fails, a flag would stay
    /// behind and hide the window of whatever launch came next, perhaps days
    /// later. A version only matches the launch that is that version.
    private static let relaunchVersionKey = "relaunchedAfterUpdateToVersion"

    /// How often a waiting update looks again for the window to be gone. The
    /// close button hides the window rather than closing it, so there is no
    /// notification to wait for, and a minute either way does not matter.
    private static let pendingInstallRetry: TimeInterval = 30

    private let log: Log
    private var controller: SPUStandardUpdaterController!
    private var canCheckObservation: NSKeyValueObservation?
    private var pendingInstall: (() -> Void)?
    private var pendingVersion: String?
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

        // A build without a feed — a plain `swift build`, a contributor's
        // `make app`, a fork that has not set one up — has nothing to check,
        // and Sparkle would only complain.
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
        // Observed only once started: an updater that never started still
        // says it can check, and a check would then end in an error window.
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let canCheck = updater.canCheckForUpdates
                    // Only a real change: see the note on `hideMenuBarIcon` in AppState.
                    if self?.canCheckForUpdates != canCheck { self?.canCheckForUpdates = canCheck }
                }
            }
        }
        log.info("updates: checking \(updater.feedURL?.absoluteString ?? "?") every \(Int(updater.updateCheckInterval / 3600))h"
            + ", install automatically: \(automaticallyUpdates ? "on" : "off")")
    }

    /// The button: a check someone asked for, with Sparkle's
    /// window to answer it either way.
    func checkForUpdates() {
        log.info("updates: check requested")
        // Sparkle's window needs an app that can come to the front; the app is
        // an accessory while its own window is closed.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// True once, on the first launch after an automatic update restarted the
    /// app into the version it was installing. Clears itself either way.
    static func takeRelaunchedAfterUpdate() -> Bool {
        let defaults = UserDefaults.standard
        guard let target = defaults.string(forKey: relaunchVersionKey) else { return false }
        defaults.removeObject(forKey: relaunchVersionKey)
        let running = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return target == running
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
        let version = pendingVersion
        cancelPendingInstall()
        log.info("updates: installing and restarting")
        UserDefaults.standard.set(version, forKey: Self.relaunchVersionKey)
        install()
    }

    /// "Restart to Update": installs the waiting update with the window still
    /// open, because someone asked. The next launch shows the window again,
    /// as it was, so no version is written down for it.
    func installNow() {
        guard let install = pendingInstall else { return }
        cancelPendingInstall()
        log.info("updates: installing and restarting, as asked")
        install()
    }

    private func cancelPendingInstall() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingInstall = nil
        pendingVersion = nil
        if updateIsWaiting { updateIsWaiting = false }
    }

    private static func describe(_ item: SUAppcastItem) -> String {
        "\(item.displayVersionString) (\(item.versionString))"
    }
}

// Sparkle calls both delegates on the main thread. SPUUpdaterDelegate says so
// in its declaration (NS_SWIFT_UI_ACTOR); SPUStandardUserDriverDelegate does
// not, but the standard user driver that calls it is main-actor bound as a
// whole, so that conformance is `@preconcurrency`: checked at run time
// instead of a `nonisolated` hop on every method.
extension Updater: SPUUpdaterDelegate {

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log.info("updates: found \(Self.describe(item))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        log.debug("updates: up to date")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // An install that was about to restart the app did not happen, so
        // the next launch is not a restart after an update.
        UserDefaults.standard.removeObject(forKey: Self.relaunchVersionKey)
        // "No update" arrives here too, as an error, when the check was asked
        // for by hand; it is not a failure.
        let nsError = error as NSError
        guard !(nsError.domain == SUSparkleErrorDomain && nsError.code == Int(SUError.noUpdateError.rawValue)) else { return }
        log.info("updates: failed — \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        log.info("updates: installing \(Self.describe(item))")
    }

    /// The update is downloaded, checked and unpacked, and Sparkle offers to
    /// install it at quit. Taking the offer of an immediate install instead is
    /// what makes updates happen for an app that never quits.
    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        log.info("updates: \(Self.describe(item)) downloaded")
        pendingInstall = immediateInstallationBlock
        pendingVersion = item.versionString
        updateIsWaiting = true
        installWhenIdle()
        return true
    }
}

extension Updater: @preconcurrency SPUStandardUserDriverDelegate {

    /// The app spends most of its life as a menu-bar accessory, and Sparkle
    /// wants such apps to handle a scheduled update themselves: left alone, it
    /// may put its window up behind whatever is in front, where nobody sees
    /// it. That only happens with automatic installs off — on, Sparkle shows
    /// nothing and the update goes through `willInstallUpdateOnQuit`.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// The reminder is not a quiet one: the window Sparkle is about to show
    /// is brought to the front. At most once a day, and only for someone who
    /// turned automatic installs off and so asked to be asked.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        log.info("updates: \(Self.describe(update)) is available — bringing Sparkle's window to the front")
        // After Sparkle has put its window up, which it does once this
        // returns. `checkForUpdates` during a session that is showing an
        // update brings that window into focus rather than checking again
        // (SPUStandardUserDriverDelegate.h).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                self?.controller.checkForUpdates(nil)
            }
        }
    }
}
