import Foundation
import DockFixerCore

/// Which milestone is due: the highest one reached, and only once.
func milestonesDue(_ t: TestRun) {
    let hour = 3600.0

    t.expect(Milestones.due(savedSeconds: 0, announced: 0) == nil, "nothing saved, nothing due")
    t.expect(Milestones.due(savedSeconds: hour - 1, announced: 0) == nil, "a second short of an hour")
    t.expect(Milestones.due(savedSeconds: hour, announced: 0) == 1, "exactly an hour")
    t.expect(Milestones.due(savedSeconds: 2 * hour - 1, announced: 1) == nil, "1 h already announced, 2 h not reached")
    t.expect(Milestones.due(savedSeconds: 2 * hour, announced: 1) == 2, "every whole hour: 2 h after 1 h")
    t.expect(Milestones.due(savedSeconds: 3 * hour + 10, announced: 2) == 3, "3 h after 2 h")
    t.expect(Milestones.due(savedSeconds: 3.9 * hour, announced: 3) == nil, "a part of an hour is not an hour")

    // An existing user upgrading with twelve and a half hours of history:
    // only 12 h, and every lower hour is done with it.
    t.expect(Milestones.due(savedSeconds: 12.5 * hour, announced: 0) == 12,
             "several crossed at once: only the highest")
    t.expect(Milestones.due(savedSeconds: 12.5 * hour, announced: 12) == nil, "the lower ones went with it")
    t.expect(Milestones.due(savedSeconds: 500 * hour, announced: 100) == 500, "no last one")

    // A higher value stored than the history now reaches (history reset, or
    // the trigger used in development): nothing is announced a second time.
    t.expect(Milestones.due(savedSeconds: 20 * hour, announced: 50) == nil, "never below what was announced")

    // Through the real arithmetic: 1,029 windows pushed out is 3,601.5 s.
    let day = UsageDay(day: "2026-10-16", pushedOut: 1029)
    t.expect(Milestones.due(savedSeconds: Savings.seconds(for: [day]), announced: 0) == 1,
             "the same seconds as the statistics screen")

    t.expect(Milestones.nextThreshold(after: 0) == hour, "first threshold")
    t.expect(Milestones.nextThreshold(after: 10) == 11 * hour, "after 10 h comes 11 h")
    t.expect(Milestones.nextThreshold(after: 100) == 101 * hour, "there is always a next one")
}

/// The words, in English and with the user's way of writing numbers.
func milestonesText(_ t: TestRun) {
    t.expect(Milestones.title(hours: 1) == "DockFixer saved you 1 hour", Milestones.title(hours: 1))
    t.expect(Milestones.title(hours: 10) == "DockFixer saved you 10 hours", Milestones.title(hours: 10))

    let us = Locale(identifier: "en_US")
    t.expect(Milestones.body(windows: 1240, locale: us)
                == "It moved 1,240 windows out of your way. Click to see your stats.",
             Milestones.body(windows: 1240, locale: us))
    t.expect(Milestones.body(windows: 1, locale: us)
                == "It moved 1 window out of your way. Click to see your stats.",
             Milestones.body(windows: 1, locale: us))
    let german = Milestones.body(windows: 1240, locale: Locale(identifier: "de_DE"))
    t.expect(german.contains("1.240 windows"), "the locale's grouping: \(german)")
}

/// Posted only to someone at the computer, and not right after a wake.
func milestonesPresence(_ t: TestRun) {
    func p(idle: TimeInterval = 5, locked: Bool = false, asleep: Bool = false, wake: TimeInterval = 600) -> Milestones.Presence {
        Milestones.presence(idle: idle, screenLocked: locked, displaysAsleep: asleep, sinceWake: wake)
    }
    t.expect(p() == .here, "active, long after wake")
    t.expect(p(idle: 120) == .here, "two minutes idle is still here")
    t.expect(p(idle: 121) != .here, "over two minutes idle is away")
    t.expect(p(locked: true) != .here, "locked")
    t.expect(p(asleep: true) != .here, "displays asleep")
    t.expect(p(wake: 10) != .here, "just woke")
    t.expect(p(wake: 60) == .here, "settled after a minute")
    if case .away(let reason) = p(idle: 900) {
        t.expect(reason.contains("900"), "the reason says how long: \(reason)")
    } else {
        t.fail("idle 900 s should be away")
    }
}
