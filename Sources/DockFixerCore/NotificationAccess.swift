import Foundation

/// What DockFixer does about notification permission, decided from what the
/// system says about it.
///
/// The app reads `UNNotificationSettings` and hands over the few parts that
/// matter, in the words below; everything that follows from them is here,
/// pure, and tested. The app side (`MilestoneNotifier`, `AppState`) only
/// asks these questions and talks to the system.
///
/// The rule throughout: the system's own prompt is shown in one place only,
/// the onboarding's notifications step, right after the quiet kind is
/// taken. Everywhere else the most the app asks for is the quiet,
/// provisional kind, which shows nothing: its notifications go to
/// Notification Center only, with Keep and Turn Off buttons on them. The
/// "Allow Notifications" buttons — on the step and in the Permissions row —
/// lead to DockFixer's page in System Settings.
public enum NotificationAccess {

    /// The system's answer about DockFixer. Its own copy of
    /// `UNAuthorizationStatus`, so that Core and its tests need no
    /// UserNotifications.
    public enum Permission: Equatable, Sendable {
        /// Never asked, or asked and the step skipped with "Not Now" before
        /// anything was granted.
        case notAsked
        /// The quiet kind: Notification Center only, no banner.
        case provisional
        /// The user allowed them.
        case allowed
        /// The user said no, or turned DockFixer off in System Settings. The
        /// system never asks again; only System Settings can undo it.
        case denied
    }

    // MARK: - Asking

    /// Whether the onboarding shows its notifications step: there is still
    /// a real permission to ask for. Already allowed, there is nothing to
    /// ask; already refused, the prompt cannot come back, and the
    /// Permissions row in Settings is where the way to System Settings is.
    public static func onboardingAsks(_ permission: Permission) -> Bool {
        permission == .notAsked || permission == .provisional
    }

    /// Whether the notifications step takes the quiet kind first, silently,
    /// before the system's prompt comes up. Taken first, it is in place
    /// whatever the user then does on the step — "Not Now" has nothing left
    /// to ask for. Provisional can only be had while the app was never
    /// asked, so for any other answer it is skipped.
    public static func takesQuietFirst(_ permission: Permission) -> Bool {
        permission == .notAsked
    }

    // MARK: - The onboarding step

    /// What happens on the onboarding's notifications step, as agreed:
    ///
    /// - It opens right after the Accessibility grant. If notifications
    ///   were already allowed or refused, it is skipped. Otherwise the quiet
    ///   kind is taken first, silently, and the system's prompt comes up
    ///   straight after it.
    /// - It then waits. It moves on only when the user decides: an answer
    ///   in the prompt (Allow or Don't Allow), "Not Now", or coming back
    ///   from System Settings with notifications allowed.
    /// - "Allow Notifications" opens DockFixer's page in System Settings →
    ///   Notifications and leaves the step where it is. On macOS 26.5,
    ///   opening that page while the quiet kind is held and the prompt is
    ///   up turns notifications fully on by itself, banners included;
    ///   without the prompt it does not. Seen, not documented; see
    ///   private_docs/product-decisions.md.
    public enum Step {
        public enum Event: Equatable, Sendable {
            /// The step is on screen and the permission is known.
            case opened(Permission)
            /// The answer to the silent request for the quiet kind.
            case quietTaken
            /// The user answered the system's prompt, either way.
            case promptAnswered
            case notNowPressed
            case allowPressed
            /// The permission read again, as when the app comes back to the
            /// front from System Settings. While the prompt is up macOS
            /// reports a refusal, so only an allow moves the step on.
            case permissionRead(Permission)
        }

        public enum Action: Equatable, Sendable {
            case takeQuiet
            case showPrompt
            case openSettings
            /// On to "We're ready".
            case finish
        }

        public static func actions(for event: Event) -> [Action] {
            switch event {
            case .opened(let permission):
                if !onboardingAsks(permission) { return [.finish] }
                return takesQuietFirst(permission) ? [.takeQuiet] : [.showPrompt]
            case .quietTaken:
                return [.showPrompt]
            case .promptAnswered, .notNowPressed:
                return [.finish]
            case .allowPressed:
                return [.openSettings]
            case .permissionRead(let permission):
                return permission == .allowed ? [.finish] : []
            }
        }
    }

    /// What a milestone does about permission when it is due.
    public enum MilestonePlan: Equatable, Sendable {
        /// Ask for the quiet kind, which shows no prompt, and post if it is
        /// given: the step was closed without an answer, or the app is an
        /// older install that never had one.
        case askQuietlyThenPost
        case post
        /// Refused: the system would drop it, so it is not posted.
        case skip
    }

    /// Never a prompt: a milestone turns up in the middle of someone's work.
    public static func milestonePlan(_ permission: Permission) -> MilestonePlan {
        switch permission {
        case .notAsked: return .askQuietlyThenPost
        case .provisional, .allowed: return .post
        case .denied: return .skip
        }
    }

    // MARK: - The Permissions row

    /// What the Permissions row in Settings offers for notifications. Both
    /// buttons open DockFixer's page in System Settings → Notifications;
    /// they differ only in what they are called.
    public enum Offer: Equatable, Sendable {
        /// Allowed: the row is not shown.
        case nothing
        /// "Allow Notifications".
        case allow
        /// "Notification Settings…", after a refusal.
        case openSystemSettings
    }

    public static func offer(_ permission: Permission) -> Offer {
        switch permission {
        case .allowed: return .nothing
        case .notAsked, .provisional: return .allow
        case .denied: return .openSystemSettings
        }
    }

    /// Whether the Settings tab carries a red dot: whenever notifications
    /// are not fully allowed, a refusal included — the Permissions row is
    /// there for exactly that, and the dot is what leads to it.
    public static func wantsAttention(_ permission: Permission) -> Bool {
        permission != .allowed
    }

    // MARK: - Where a notification ends up

    /// How allowed notifications are shown, as set in System Settings.
    public struct Delivery: Equatable, Sendable {
        public enum Style: Equatable, Sendable { case none, banner, alert }

        public var alertsOn: Bool
        public var style: Style
        public var inNotificationCenter: Bool

        public init(alertsOn: Bool, style: Style, inNotificationCenter: Bool) {
            self.alertsOn = alertsOn
            self.style = style
            self.inNotificationCenter = inNotificationCenter
        }
    }

    /// Where a notification posted now ends up. Worked out before each post
    /// because `add` completes without an error when notifications are
    /// turned off — the system drops the notification afterwards, and a log
    /// line that says "posted" would be a lie.
    public enum Reach: Equatable, Sendable {
        /// The app was never asked: the system drops it.
        case notAsked
        /// The user said no, or turned DockFixer off in System Settings.
        case denied
        /// Provisional permission: Notification Center only, no banner.
        case provisional
        /// Allowed, but nothing on screen: the level is passive, or the
        /// alert style is None. Notification Center only.
        case listOnly
        /// Allowed, and a banner that goes away by itself.
        case banner
        /// Allowed, and an alert that stays until it is closed.
        case alert
        /// Allowed, but alerts and Notification Center are both off.
        case nowhere
    }

    /// `passive` is the interruption level of that name, which never shows
    /// a banner whatever the settings say.
    public static func reach(_ permission: Permission, _ delivery: Delivery, passive: Bool) -> Reach {
        switch permission {
        case .notAsked: return .notAsked
        case .denied: return .denied
        case .provisional: return .provisional
        case .allowed: break
        }
        if passive || !delivery.alertsOn || delivery.style == .none {
            return delivery.inNotificationCenter ? .listOnly : .nowhere
        }
        return delivery.style == .alert ? .alert : .banner
    }

    /// Whether the system would drop it: not worth posting a real milestone.
    public static func isDropped(_ reach: Reach) -> Bool {
        reach == .notAsked || reach == .denied
    }

    /// Whether a post put something where the user can find it: a banner,
    /// an alert, or a quiet entry in Notification Center. What the dot on
    /// the menu-bar icon and the "shown" event wait for.
    public static func reachedTheUser(_ reach: Reach, posted: Bool, failed: Bool) -> Bool {
        guard posted, !failed else { return false }
        switch reach {
        case .provisional, .listOnly, .banner, .alert: return true
        case .notAsked, .denied, .nowhere: return false
        }
    }

    /// The log line for a post: what the system will do with it, not merely
    /// that `add` returned.
    public static func logLine(_ reach: Reach, posted: Bool, error: String?) -> String {
        if let error { return "could not post — \(error)" }
        let reason = switch reach {
        case .notAsked: "notifications were never allowed"
        case .denied: "notifications denied"
        default: ""
        }
        if !posted { return "not posted — \(reason)" }
        return switch reach {
        case .notAsked, .denied: "posted, but the system drops it — \(reason)"
        case .provisional, .listOnly: "posted quietly (Notification Center only)"
        case .banner: "posted (banner)"
        case .alert: "posted (alert)"
        case .nowhere: "posted, but alerts and Notification Center are both off"
        }
    }
}
