import AppKit
import SwiftUI
import UserNotifications

/// DEV ONLY. The Debug tab: what the system says about DockFixer's
/// notifications, and buttons to move between the permission states and
/// see a milestone notification in each of them.
///
/// Shown only in a build made with `make dev` — see `isAvailable` — so it
/// can stay in the repository; a release never draws it.
struct DebugView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openURL) private var openURL

    @State private var snapshot: Snapshot?
    /// What the last button did, in words: most of them change nothing on
    /// screen, and that alone told nothing about what the system did.
    @State private var lastResult: String?

    /// Whether this is a development build. The same signal that turns on
    /// debug logging, but read from the bundle alone: `make dev` bakes
    /// `DockFixerLogLevel = debug` into Info.plist, a release leaves it at
    /// `info`. The `DOCKFIXER_LOG_LEVEL` variable that the log also listens
    /// to is left out on purpose, so a release started from a terminal with
    /// it set still has no Debug tab.
    static let isAvailable: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "DockFixerLogLevel") as? String)?.lowercased() == "debug"

    /// System Settings → Notifications, opened on DockFixer's own page.
    /// `id=` picks the app in the list; a bundle the system does not know
    /// yet just leaves the list at the top.
    private static var notificationSettings: URL {
        let id = Bundle.main.bundleIdentifier ?? ""
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
            ?? URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Development build only — this tab is not in releases.", systemImage: "hammer")
                .font(.caption)
                .foregroundStyle(.orange)
            header
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 16) {
                // For checking every tab in both looks without changing
                // the whole Mac over.
                ContentView.row("Appearance") {
                    Picker("Appearance", selection: $state.appearance) {
                        ForEach(AppState.Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                ContentView.row("Request") {
                    HStack(spacing: 6) {
                        Button { request(provisional: true) } label: {
                            Label("Request Provisional", systemImage: "bell.badge")
                        }
                        .buttonStyle(SoftButtonStyle())
                        Button { request(provisional: false) } label: {
                            Label("Request Full", systemImage: "bell")
                        }
                        .buttonStyle(SoftButtonStyle())
                    }
                }
                ContentView.row("Send") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            send("Send Passive", icon: "tray", level: .passive)
                            send("Send Active", icon: "paperplane", level: .active)
                        }
                        HStack(spacing: 6) {
                            send("Send Active + Sound", icon: "speaker.wave.2", level: .active, sound: true)
                            send("Send Time Sensitive", icon: "clock.badge.exclamationmark", level: .timeSensitive)
                        }
                    }
                }
                ContentView.row("Badge") {
                    // The dot a posted notification leaves on the menu-bar
                    // icon, without posting one. Opening the window by any
                    // way clears it too, but this window is already open.
                    HStack(spacing: 6) {
                        Button {
                            StatusItemController.shared.setBadge(true)
                            lastResult = Self.stamp("Badge shown")
                        } label: {
                            Label("Show Badge", systemImage: "circle.fill")
                        }
                        .buttonStyle(SoftButtonStyle())
                        Button {
                            StatusItemController.shared.setBadge(false)
                            lastResult = Self.stamp("Badge cleared")
                        } label: {
                            Label("Clear Badge", systemImage: "circle")
                        }
                        .buttonStyle(SoftButtonStyle())
                    }
                }
                ContentView.row("System") {
                    Button {
                        openURL(Self.notificationSettings)
                        refreshSoon()
                    } label: {
                        Label("Open Notification Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(SoftButtonStyle())
                }
                ContentView.row("Details") { details }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        // The user changes the permission in System Settings, often with
        // this window still in view and DockFixer not the active app, so
        // activation alone would miss it. The timer lives only while the tab
        // is drawn.
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    /// The permission in words, large, and what the last button did.
    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let snapshot {
                Text(snapshot.headline)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(snapshot.tint)
                    .fixedSize(horizontal: false, vertical: true)
                if snapshot.isDenied {
                    Text("To allow again: System Settings → Notifications → DockFixer. \"Not asked yet\" comes back only with a new bundle ID: make dev BUNDLE_ID=com.github.reppden.dockfixer.n1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(MilestoneNotifier.canUseNotifications ? "…" : "Not an app bundle — notifications are off")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text("Last result: " + (lastResult ?? "—"))
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var details: some View {
        if let snapshot {
            // A VStack, not a Group: inside a GridRow a Group's children
            // become cells of their own, and four of them pushed the grid
            // far wider than the window.
            VStack(alignment: .leading, spacing: 2) {
                Text("status: \(snapshot.authorization) · alert style: \(snapshot.alertStyle)")
                Text("alerts: \(snapshot.alerts) · sound: \(snapshot.sound)")
                Text("notification center: \(snapshot.notificationCenter) · lock screen: \(snapshot.lockScreen)")
                Text("time sensitive: \(snapshot.timeSensitive)")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    /// One button that posts the real milestone text for 10 h at `level`.
    private func send(_ title: String, icon: String,
                      level: UNNotificationInterruptionLevel, sound: Bool = false) -> some View {
        Button {
            lastResult = "\(title)…"
            MilestoneNotifier.shared.postTest(hours: 10, level: level, sound: sound) { result in
                lastResult = Self.stamp(Self.describe(result))
                refresh()
            }
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(SoftButtonStyle())
    }

    /// Asks for permission and says what came of it. The status before the
    /// request decides the words: after the first answer the system never
    /// asks again and just returns that answer, which looks exactly like a
    /// button that does nothing.
    private func request(provisional: Bool) {
        guard MilestoneNotifier.canUseNotifications else { return }
        lastResult = provisional ? "Requesting provisional…" : "Requesting full…"
        Self.fetch { before in
            MilestoneNotifier.shared.requestAuthorization(provisional: provisional) { granted in
                Self.fetch { after in
                    snapshot = after
                    lastResult = Self.stamp(Self.describeRequest(provisional: provisional, granted: granted,
                                                                 before: before, after: after))
                }
            }
        }
    }

    private static func describeRequest(provisional: Bool, granted: Bool,
                                        before: Snapshot, after: Snapshot) -> String {
        if provisional {
            switch before.status {
            case .notDetermined:
                return granted
                    ? "Provisional granted (no prompt is shown — that's how provisional works)"
                    : "Provisional refused — now: \(after.headline)"
            default:
                return "Nothing changed, no prompt — already \(before.headline). Provisional is only given to an app never asked."
            }
        }
        switch before.status {
        case .notDetermined, .provisional:
            return granted ? "Prompt answered: allowed — now: \(after.headline)"
                           : "Prompt answered: not allowed — now: \(after.headline)"
        default:
            return "No prompt — the system asks only once; it returned the old answer: \(after.headline)"
        }
    }

    private static func describe(_ r: MilestoneNotifier.PostResult) -> String {
        if let error = r.error { return "Not sent — \(error)" }
        var text = switch r.reach {
        case .notAsked: "Sent — will be dropped: notifications were never asked for"
        case .denied: "Sent — will be dropped: notifications are denied"
        case .provisional: "Sent as a quiet notification (provisional) — look in Notification Center"
        case .listOnly:
            r.level == .passive
                ? "Sent as a quiet notification (Passive never shows a banner) — look in Notification Center"
                : "Sent as a quiet notification (alert style is None) — look in Notification Center"
        case .banner: "Sent — banner"
        case .alert: "Sent — alert (stays until closed)"
        case .nowhere: "Sent — but alerts and Notification Center are both off, so nothing shows it"
        }
        if r.reach == .banner || r.reach == .alert {
            text += r.level == .timeSensitive ? "" : " (a Focus holds it back)"
        }
        if r.level == .timeSensitive {
            text += ". Time Sensitive in settings: \(r.timeSensitiveSetting); without the entitlement check usernoted's log for what it did"
        }
        if r.sound {
            text += r.soundSetting == "enabled" ? ". Sound: on" : ". Sound: \(r.soundSetting) in settings, so silent"
        }
        return text
    }

    /// The time, so two presses with the same outcome can be told apart.
    private static func stamp(_ text: String) -> String {
        let time = Date().formatted(date: .omitted, time: .standard)
        return "\(text)  [\(time)]"
    }

    /// After a trip to System Settings the answer is not ready at once;
    /// coming back to the app refreshes too.
    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refresh() }
    }

    private func refresh() {
        guard MilestoneNotifier.canUseNotifications else { return }
        Self.fetch { next in
            // Only a real change: every write to state redraws the tab, and
            // this runs every two seconds.
            if snapshot != next { snapshot = next }
        }
    }

    private static func fetch(_ then: @escaping @MainActor (Snapshot) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let next = Snapshot(settings)
            DispatchQueue.main.async { MainActor.assumeIsolated { then(next) } }
        }
    }

    /// The parts of `UNNotificationSettings` worth seeing, as text, made on
    /// the callback's queue so nothing of the settings object crosses over.
    private struct Snapshot: Sendable, Equatable {
        let status: UNAuthorizationStatus
        let style: UNAlertStyle
        let authorization: String
        let alertStyle: String
        let alerts: String
        let sound: String
        let notificationCenter: String
        let lockScreen: String
        let timeSensitive: String

        init(_ s: UNNotificationSettings) {
            status = s.authorizationStatus
            style = s.alertStyle
            authorization = switch s.authorizationStatus {
            case .notDetermined: "notDetermined"
            case .denied: "denied"
            case .authorized: "authorized"
            case .provisional: "provisional"
            case .ephemeral: "ephemeral"
            @unknown default: "unknown (\(s.authorizationStatus.rawValue))"
            }
            alertStyle = switch s.alertStyle {
            case .none: "none"
            case .banner: "banner"
            case .alert: "alert"
            @unknown default: "unknown (\(s.alertStyle.rawValue))"
            }
            alerts = MilestoneNotifier.describe(s.alertSetting)
            sound = MilestoneNotifier.describe(s.soundSetting)
            notificationCenter = MilestoneNotifier.describe(s.notificationCenterSetting)
            lockScreen = MilestoneNotifier.describe(s.lockScreenSetting)
            timeSensitive = MilestoneNotifier.describe(s.timeSensitiveSetting)
        }

        var isDenied: Bool { status == .denied }

        /// The status in words, the way System Settings would put it.
        var headline: String {
            switch status {
            case .notDetermined: "Not asked yet"
            case .denied: "Denied"
            case .provisional: "Quiet (provisional) — goes to Notification Center only"
            case .ephemeral: "Ephemeral (App Clip only)"
            case .authorized:
                switch style {
                case .banner: "Allowed — banners (style: Temporary)"
                case .alert: "Allowed — alerts (style: Persistent)"
                case .none: "Allowed — no banners (style: None), Notification Center only"
                @unknown default: "Allowed — style \(alertStyle)"
                }
            @unknown default: "Unknown status \(authorization)"
            }
        }

        var tint: Color {
            switch status {
            case .authorized: style == .none ? .orange : .green
            case .provisional: .orange
            case .denied: .red
            default: .secondary
            }
        }
    }
}
