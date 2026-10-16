import Foundation

/// When to tell the user how much time DockFixer has saved them, and what to
/// say.
///
/// DockFixer is meant to go unnoticed: once it has been set up, most people
/// never open it again, and so never learn that it is doing anything. A
/// notification for every whole hour saved is the one way to tell them. An
/// hour takes weeks of ordinary use to save — a thousand windows pulled out
/// from under the Dock — so even the busiest user hears from it rarely, and
/// each hour is announced at most once for the lifetime of the install.
///
/// The hours are the ones the statistics screen shows: `Savings` applied to
/// `UsageHistory`. A notification that said "10 hours" next to a screen that
/// said nine would undo the point of both.
///
/// Everything here is pure, so it is tested; the app side (`MilestoneNotifier`)
/// only asks these questions and acts on the answers.
public enum Milestones {

    /// The milestone to announce now, in whole hours, or nil.
    ///
    /// `announced` is the highest milestone already announced, 0 for none.
    /// When several hours have been passed since — an existing user upgrading
    /// to the release that brings this, with a history already at twelve
    /// hours — only the highest one is returned. Announcing "1 hour" to
    /// someone who has saved twelve would be wrong, and announcing every hour
    /// up to twelve would be a dozen notifications for one moment. The caller
    /// then records the returned value as announced, which marks every lower
    /// one done as well.
    public static func due(savedSeconds: Double, announced: Int) -> Int? {
        let reached = Int((savedSeconds / 3600).rounded(.down))
        guard reached >= 1, reached > announced else { return nil }
        return reached
    }

    /// The saved time at which the next milestone after `announced` falls:
    /// the next whole hour. Lets the app compare one number per moved window
    /// instead of re-reading the whole history.
    public static func nextThreshold(after announced: Int) -> Double {
        Double(max(announced, 0) + 1) * 3600
    }

    /// The notification's title: "DockFixer saved you 10 hours".
    public static func title(hours: Int) -> String {
        "DockFixer saved you \(hours) hour\(hours == 1 ? "" : "s")"
    }

    /// The notification's body, with the real number of moved windows written
    /// the way the user's locale writes numbers ("1,240", "1 240", "1.240").
    ///
    /// A banner shows two lines or so, so it is kept short, and it ends by
    /// saying that a click leads somewhere: a notification from an app the
    /// user never looks at gives no other hint that it can be clicked.
    public static func body(windows: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: windows)) ?? "\(windows)"
        return "It moved \(number) window\(windows == 1 ? "" : "s") out of your way. Click to see your stats."
    }

    // MARK: - Is anyone there

    /// The longest the user may have left the keyboard and mouse alone and
    /// still be taken to be at the computer. A notification posted to an
    /// empty room is read hours later in a pile of others, or not at all, and
    /// this one is posted once ever.
    public static let maxIdle: TimeInterval = 120

    /// How long to wait after a wake, an unlock or a launch. The first moments
    /// after any of them are when the user is busiest finding their place,
    /// and when every other app posts whatever it held back; a launch counts
    /// because at login it is one.
    public static let settleTime: TimeInterval = 60

    public enum Presence: Equatable, Sendable {
        case here
        /// Not now; the reason is for the log.
        case away(String)
    }

    /// Whether the user is at the computer and it is a good moment to post.
    public static func presence(idle: TimeInterval, screenLocked: Bool, displaysAsleep: Bool,
                                sinceWake: TimeInterval) -> Presence {
        if screenLocked { return .away("the screen is locked") }
        if displaysAsleep { return .away("the displays are asleep") }
        if sinceWake < settleTime { return .away("only \(Int(sinceWake))s since launch or wake") }
        if idle > maxIdle { return .away("idle for \(Int(idle))s") }
        return .here
    }
}
