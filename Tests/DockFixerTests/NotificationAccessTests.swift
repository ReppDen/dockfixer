import Foundation
import DockFixerCore

/// What each answer from the system leads to: the onboarding step, "Not
/// Now", a milestone, the Permissions row and its red dot.
func notificationAccessAsking(_ t: TestRun) {
    typealias A = NotificationAccess

    // The onboarding step asks only while there is a real permission left to
    // ask for; a refusal cannot be asked again, an allowance needs nothing.
    t.expect(A.onboardingAsks(.notAsked), "never asked: the step is shown")
    t.expect(A.onboardingAsks(.provisional), "only the quiet kind: the step is shown")
    t.expect(!A.onboardingAsks(.allowed), "allowed: the step is skipped")
    t.expect(!A.onboardingAsks(.denied), "refused: the step is skipped")

    // The step takes the quiet kind, which only an app never asked can get.
    t.expect(A.takesQuietFirst(.notAsked), "never asked: provisional")
    t.expect(!A.takesQuietFirst(.provisional), "already provisional: nothing to take")
    t.expect(!A.takesQuietFirst(.allowed), "already allowed: nothing to take")
    t.expect(!A.takesQuietFirst(.denied), "refused: provisional cannot be had")

    // A milestone never brings up the prompt.
    t.expect(A.milestonePlan(.notAsked) == .askQuietlyThenPost, "never asked: quiet permission, then post")
    t.expect(A.milestonePlan(.provisional) == .post, "provisional: post")
    t.expect(A.milestonePlan(.allowed) == .post, "allowed: post")
    t.expect(A.milestonePlan(.denied) == .skip, "refused: nothing posted")

    // The Permissions row: the prompt while it can still be shown, System
    // Settings after a refusal, nothing once allowed.
    t.expect(A.offer(.notAsked) == .allow, "never asked: Allow Notifications")
    t.expect(A.offer(.provisional) == .allow, "provisional: Allow Notifications")
    t.expect(A.offer(.denied) == .openSystemSettings, "refused: Notification Settings…")
    t.expect(A.offer(.allowed) == .nothing, "allowed: no button")

    // The dot: until notifications are fully allowed.
    t.expect(A.wantsAttention(.notAsked), "never asked: dot")
    t.expect(A.wantsAttention(.provisional), "provisional: dot")
    t.expect(A.wantsAttention(.denied), "refused: dot")
    t.expect(!A.wantsAttention(.allowed), "allowed: no dot")
}

/// Where a notification ends up, and what the log and the dot make of it.
func notificationAccessReach(_ t: TestRun) {
    typealias A = NotificationAccess
    let banner = A.Delivery(alertsOn: true, style: .banner, inNotificationCenter: true)
    let alert = A.Delivery(alertsOn: true, style: .alert, inNotificationCenter: true)
    let styleNone = A.Delivery(alertsOn: true, style: .none, inNotificationCenter: true)
    let alertsOff = A.Delivery(alertsOn: false, style: .banner, inNotificationCenter: true)
    let nothing = A.Delivery(alertsOn: false, style: .banner, inNotificationCenter: false)

    // The permission decides before the delivery settings do.
    t.expect(A.reach(.notAsked, banner, passive: false) == .notAsked, "never asked: dropped")
    t.expect(A.reach(.denied, banner, passive: false) == .denied, "refused: dropped")
    t.expect(A.reach(.provisional, banner, passive: false) == .provisional, "provisional: quiet")

    t.expect(A.reach(.allowed, banner, passive: false) == .banner, "allowed, banners: banner")
    t.expect(A.reach(.allowed, alert, passive: false) == .alert, "allowed, alerts: alert")
    t.expect(A.reach(.allowed, banner, passive: true) == .listOnly, "passive never shows a banner")
    t.expect(A.reach(.allowed, styleNone, passive: false) == .listOnly, "style None: list only")
    t.expect(A.reach(.allowed, alertsOff, passive: false) == .listOnly, "alerts off: list only")
    t.expect(A.reach(.allowed, nothing, passive: false) == .nowhere, "alerts and the list off: nowhere")

    t.expect(A.isDropped(.notAsked) && A.isDropped(.denied), "never asked and refused are dropped")
    t.expect(!A.isDropped(.provisional) && !A.isDropped(.nowhere), "the rest are delivered, if unseen")

    // The dot and the "shown" event only for something the user can find.
    for reach: A.Reach in [.provisional, .listOnly, .banner, .alert] {
        t.expect(A.reachedTheUser(reach, posted: true, failed: false), "\(reach) reaches the user")
        t.expect(!A.reachedTheUser(reach, posted: false, failed: false), "\(reach) not posted: does not")
        t.expect(!A.reachedTheUser(reach, posted: true, failed: true), "\(reach) with an error: does not")
    }
    for reach: A.Reach in [.notAsked, .denied, .nowhere] {
        t.expect(!A.reachedTheUser(reach, posted: true, failed: false), "\(reach) does not reach the user")
    }

    // The log says where it went, not merely that it was handed over.
    t.expect(A.logLine(.banner, posted: true, error: nil) == "posted (banner)", "banner line")
    t.expect(A.logLine(.provisional, posted: true, error: nil) == "posted quietly (Notification Center only)",
             "quiet line")
    t.expect(A.logLine(.denied, posted: false, error: nil) == "not posted — notifications denied", "refused line")
    t.expect(A.logLine(.notAsked, posted: true, error: nil)
             == "posted, but the system drops it — notifications were never allowed", "test post when never asked")
    t.expect(A.logLine(.banner, posted: true, error: "boom") == "could not post — boom", "an error wins")
}

/// The onboarding's notifications step, event by event, as agreed with the
/// user: the quiet kind silently, no system prompt; wait for a decision; the
/// Allow button goes to System Settings and stays.
func notificationAccessStep(_ t: TestRun) {
    typealias S = NotificationAccess.Step

    t.expect(S.actions(for: .opened(.notAsked)) == [.takeQuiet], "never asked: the quiet kind, silently")
    t.expect(S.actions(for: .opened(.provisional)).isEmpty, "already quiet: nothing to take, wait")
    t.expect(S.actions(for: .opened(.allowed)) == [.finish], "already allowed: skipped")
    t.expect(S.actions(for: .opened(.denied)) == [.finish], "already refused: skipped")

    t.expect(S.actions(for: .notNowPressed) == [.finish], "Not Now: on")

    t.expect(S.actions(for: .allowPressed) == [.openSettings],
             "Allow Notifications opens System Settings and does not move on")

    t.expect(S.actions(for: .permissionRead(.allowed)) == [.finish], "back from System Settings allowed: on")
    t.expect(S.actions(for: .permissionRead(.denied)).isEmpty,
             "denied: wait — the Allow button leads to System Settings")
    t.expect(S.actions(for: .permissionRead(.provisional)).isEmpty, "quiet only: wait")
    t.expect(S.actions(for: .permissionRead(.notAsked)).isEmpty, "not asked: wait")
}
