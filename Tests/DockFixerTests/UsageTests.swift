import Foundation
import DockFixerCore

/// Why a window was moved, as the usage statistics count it: out from under
/// the Dock, or following the Dock (reclaim or snap).
func usageReason(_ t: TestRun) {
    // A display with the Dock on the left: 50pt gone from the left edge.
    let visible = CGRect(x: 50, y: 33, width: 1462, height: 949)

    let under = CGRect(x: 0, y: 33, width: 800, height: 600)
    t.expect(computeFix(window: under, visible: visible, reclaim: nil)?.reason == .underDock,
             "a window under the Dock is pushed out")

    let near = CGRect(x: 60, y: 33, width: 800, height: 600)
    t.expect(computeFix(window: near, visible: visible, reclaim: nil, snap: 16, dockSide: .left)?.reason == .followedDock,
             "a window snapped to the Dock followed it")

    // The Dock shrank from 60pt to 50pt; a window against the old edge follows.
    let reclaim = ReclaimedSpace(previousVisible: CGRect(x: 60, y: 33, width: 1452, height: 949), visible: visible)
    t.expect(computeFix(window: near, visible: visible, reclaim: reclaim)?.reason == .followedDock,
             "a window that reclaims the Dock's space followed it")

    // Reclaimed and still under the menu bar: the follow is why it was touched.
    let both = CGRect(x: 60, y: 10, width: 800, height: 600)
    t.expect(computeFix(window: both, visible: visible, reclaim: reclaim)?.reason == .followedDock,
             "a reclaimed window that was also clamped counts as following the Dock")
}

private func temporaryJournal() -> UsageJournal {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dockfixer-usage-test-\(UUID().uuidString)", isDirectory: true)
    return UsageJournal(url: dir.appendingPathComponent("usage.jsonl"))
}

private func utc(_ text: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: text)!
}

/// The journal sums by UTC day, marks a day alive once, and forgets a day
/// that was sent without touching the others.
func usageJournal(_ t: TestRun) {
    let journal = temporaryJournal()
    defer { journal.erase() }

    // 23:30 in New York on the 12th is already the 13th in UTC.
    journal.record(.pushedOut, at: utc("2026-10-13T03:30:00Z"))
    journal.record(.pushedOut, at: utc("2026-10-13T10:00:00Z"))
    journal.record(.stuck, at: utc("2026-10-13T10:00:01Z"))
    journal.record(.acrossDisplays, at: utc("2026-10-14T08:00:00Z"))
    journal.record(.stuck, at: utc("2026-10-15T08:00:00Z"))  // today: not a day yet

    let days = journal.days(before: "2026-10-15")
    t.expect(days.map(\.day) == ["2026-10-13", "2026-10-14"], "days are the finished UTC days, oldest first: \(days.map(\.day))")
    t.expect(days.first == UsageDay(day: "2026-10-13", pushedOut: 2, stuck: 1, acrossDisplays: 0),
             "the 13th sums its three lines: \(String(describing: days.first))")
    t.expect(days.last == UsageDay(day: "2026-10-14", pushedOut: 0, stuck: 0, acrossDisplays: 1),
             "the 14th has its one line: \(String(describing: days.last))")

    journal.markAlive(at: utc("2026-10-14T09:00:00Z"))
    journal.markAlive(at: utc("2026-10-16T09:00:00Z"))
    journal.markAlive(at: utc("2026-10-16T10:00:00Z"))
    let text = (try? String(contentsOf: journal.url, encoding: .utf8)) ?? ""
    t.expect(text.components(separatedBy: "\"alive\"").count - 1 == 1,
             "alive is written once, and only for a day with no line yet:\n\(text)")
    t.expect(journal.days(before: "2026-10-17").map(\.day) == ["2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16"],
             "an alive day is a day of use with zero counts")

    journal.prune(day: "2026-10-13")
    t.expect(journal.days(before: "2026-10-17").map(\.day) == ["2026-10-14", "2026-10-15", "2026-10-16"],
             "pruning a day leaves the others")
    t.expect(journal.days(before: "2026-10-17").first?.acrossDisplays == 1, "pruning kept the other days' lines intact")

    // A half-written line is skipped, not fatal.
    let handle = try! FileHandle(forWritingTo: journal.url)
    _ = try! handle.seekToEnd()
    try! handle.write(contentsOf: Data("{\"t\":\"2026-10-1".utf8))
    try! handle.close()
    t.expect(journal.days(before: "2026-10-17").count == 3, "a broken line is ignored")
}

/// The event as sent: the fields, numeric counts, and an ID that is the same
/// for the same installation and day.
func usageEvent(_ t: TestRun) {
    let day = UsageDay(day: "2026-10-13", pushedOut: 11, stuck: 40, acrossDisplays: 3)
    let data = UsageReport.event(for: day, installID: "abc", version: "0.1.0", apiKey: "phc_test")
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    let properties = object["properties"] as? [String: Any] ?? [:]

    t.expect(object["event"] as? String == "day", "event name")
    t.expect(object["distinct_id"] as? String == "abc", "distinct_id is the install ID")
    t.expect(object["api_key"] as? String == "phc_test", "api_key")
    t.expect(object["timestamp"] as? String == "2026-10-13T00:00:00Z", "timestamp is the day at midnight UTC")
    t.expect(properties["pushedOut"] as? Int == 11 && properties["stuck"] as? Int == 40
             && properties["acrossDisplays"] as? Int == 3, "counts are numbers: \(properties)")
    t.expect(properties["version"] as? String == "0.1.0" && properties["day"] as? String == "2026-10-13", "version and day")
    t.expect(Set(properties.keys) == ["version", "day", "pushedOut", "stuck", "acrossDisplays"],
             "nothing else is sent: \(properties.keys.sorted())")
    t.expect(Set(object.keys) == ["api_key", "event", "distinct_id", "uuid", "timestamp", "properties"],
             "nothing else is sent at the top level: \(object.keys.sorted())")

    let id = UsageReport.eventID(installID: "abc", day: "2026-10-13")
    t.expect(id == UsageReport.eventID(installID: "abc", day: "2026-10-13"), "the event ID is deterministic")
    t.expect(id != UsageReport.eventID(installID: "abc", day: "2026-10-14"), "another day, another ID")
    t.expect(id != UsageReport.eventID(installID: "abd", day: "2026-10-13"), "another installation, another ID")
    t.expect(UUID(uuidString: id) != nil && id.count == 36, "the ID is a UUID: \(id)")
    t.expect(id.dropFirst(14).first == "5", "a version 5 UUID: \(id)")
    t.expect(object["uuid"] as? String == id, "the event carries the ID")
}

/// Sending: finished days go oldest first, each is forgotten once accepted,
/// a failure stops the run and keeps the journal, and the next try resumes.
@MainActor
func usageReporter(_ t: TestRun) {
    let journal = temporaryJournal()
    defer { journal.erase() }
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dockfixer-usage-log-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = Log(directory: dir, level: .info)

    journal.record(.pushedOut, at: utc("2026-10-13T10:00:00Z"))
    journal.record(.stuck, at: utc("2026-10-14T10:00:00Z"))

    final class Fake: @unchecked Sendable {
        var sent: [String] = []
        var failing = false
    }
    let fake = Fake()
    let reporter = UsageReporter(journal: journal, installID: "abc", version: "0.1.0", apiKey: "k", log: log) { data in
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let day = (object["properties"] as? [String: Any])?["day"] as? String ?? "?"
        if fake.failing { return .failed("offline") }
        fake.sent.append(day)
        return .accepted
    }

    func flush(at time: String) {
        var done = false
        Task { @MainActor in
            await reporter.flush(now: utc(time))
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    fake.failing = true
    flush(at: "2026-10-15T09:00:00Z")
    t.expect(fake.sent.isEmpty, "nothing counted as sent while offline")
    t.expect(journal.days(before: "2026-10-15").count == 2, "a failed send keeps the journal")
    t.expect(log.entries.contains { $0.detail.hasPrefix("usage not sent — 2026-10-13") }, "a failure is logged with the day")

    fake.failing = false
    flush(at: "2026-10-15T09:05:00Z")
    t.expect(fake.sent.isEmpty, "a failed try is not repeated within ten minutes")

    flush(at: "2026-10-15T10:00:00Z")
    t.expect(fake.sent == ["2026-10-13", "2026-10-14"], "finished days are sent oldest first: \(fake.sent)")
    t.expect(journal.days(before: "2026-10-15").isEmpty, "sent days leave the journal")
    t.expect(journal.days(before: "2026-10-16").map(\.day) == ["2026-10-15"], "today was marked alive and stays")
    t.expect(log.entries.contains { $0.detail == "usage sent — 2026-10-13: 1 pushed out, 0 stuck, 0 across displays" },
             "a sent day is logged with its sums")

    flush(at: "2026-10-15T11:00:00Z")
    t.expect(fake.sent.count == 2, "nothing is sent twice")
}

/// A journal that can never be sent keeps the last month of days and lets
/// the older ones go, so it does not grow for ever.
@MainActor
func usageReporterCap(_ t: TestRun) {
    let journal = temporaryJournal()
    defer { journal.erase() }
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dockfixer-usage-log-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = Log(directory: dir, level: .info)

    // Forty days in September and October, each with one window.
    let start = utc("2026-09-01T12:00:00Z")
    for offset in 0..<40 {
        journal.record(.pushedOut, at: start.addingTimeInterval(Double(offset) * 86_400))
    }
    let all = journal.days(before: "2026-10-11")
    t.expect(all.count == 40, "forty days recorded: \(all.count)")

    let reporter = UsageReporter(journal: journal, installID: "abc", version: "0.1.0", apiKey: "k", log: log) { _ in
        .failed("offline")
    }
    var done = false
    Task { @MainActor in
        await reporter.flush(now: utc("2026-10-11T09:00:00Z"))
        done = true
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

    let kept = journal.days(before: "2026-10-11")
    t.expect(kept.count == UsageReporter.maxUnsentDays, "the journal keeps \(UsageReporter.maxUnsentDays) days, keeps \(kept.count)")
    t.expect(kept.first?.day == all[40 - UsageReporter.maxUnsentDays].day && kept.last?.day == "2026-10-10",
             "the newest days are the ones kept: \(kept.first?.day ?? "-") … \(kept.last?.day ?? "-")")
    t.expect(kept.allSatisfy { $0.pushedOut == 1 }, "the kept days are intact")
    t.expect(log.entries.contains { $0.detail.hasPrefix("usage: 9 unsent days older than") },
             "dropping is logged: \(log.entries.map(\.detail))")
}

/// The notification event as sent: what happened, to which milestone, and
/// nothing else; the day event is untouched by it.
func usageNotificationEvent(_ t: TestRun) {
    let data = UsageReport.notificationEvent(action: .clicked, hours: 3, installID: "abc", version: "0.1.0",
                                             apiKey: "phc_test", uuid: "u-1", at: utc("2026-10-16T14:05:09Z"))
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    let properties = object["properties"] as? [String: Any] ?? [:]

    t.expect(object["event"] as? String == "notification", "event name")
    t.expect(object["distinct_id"] as? String == "abc", "the same install ID as the day event")
    t.expect(object["uuid"] as? String == "u-1", "the event ID given")
    t.expect(object["timestamp"] as? String == "2026-10-16T14:05:09Z", "the moment, in UTC: \(object["timestamp"] ?? "-")")
    t.expect(properties["action"] as? String == "clicked", "the action")
    t.expect(properties["hours"] as? Int == 3, "the milestone is a number: \(properties)")
    t.expect(Set(properties.keys) == ["action", "hours", "version"],
             "nothing else is sent: \(properties.keys.sorted())")
    t.expect(Set(object.keys) == ["api_key", "event", "distinct_id", "uuid", "timestamp", "properties"],
             "nothing else at the top level: \(object.keys.sorted())")

    let shown = UsageReport.notificationEvent(action: .shown, hours: 1, installID: "abc", version: "0.1.0", apiKey: "k")
    let shownObject = (try? JSONSerialization.jsonObject(with: shown)) as? [String: Any] ?? [:]
    t.expect((shownObject["properties"] as? [String: Any])?["action"] as? String == "shown", "shown")
    t.expect(UUID(uuidString: shownObject["uuid"] as? String ?? "") != nil, "a fresh UUID by default")
}

/// The Buy Me a Coffee click as sent: the version, and nothing else.
func usageBuyMeACoffeeEvent(_ t: TestRun) {
    let data = UsageReport.buyMeACoffeeEvent(installID: "abc", version: "1.0.0", apiKey: "phc_test",
                                             uuid: "u-2", at: utc("2026-10-19T09:30:00Z"))
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    let properties = object["properties"] as? [String: Any] ?? [:]

    t.expect(object["event"] as? String == "buy_me_a_coffee", "event name")
    t.expect(object["distinct_id"] as? String == "abc", "the same install ID as the day event")
    t.expect(object["uuid"] as? String == "u-2", "the event ID given")
    t.expect(object["timestamp"] as? String == "2026-10-19T09:30:00Z", "the moment, in UTC: \(object["timestamp"] ?? "-")")
    t.expect(Set(properties.keys) == ["version"], "nothing else is sent: \(properties.keys.sorted())")
    t.expect(Set(object.keys) == ["api_key", "event", "distinct_id", "uuid", "timestamp", "properties"],
             "nothing else at the top level: \(object.keys.sorted())")
}

/// A notification event goes out at once; one that fails waits for the next
/// flush, goes before the days, and the queue is capped.
@MainActor
func usageNotificationRetry(_ t: TestRun) {
    let journal = temporaryJournal()
    defer { journal.erase() }
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dockfixer-usage-log-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = Log(directory: dir, level: .info)

    final class Fake: @unchecked Sendable {
        var sent: [String] = []
        var failing = false
    }
    let fake = Fake()
    let reporter = UsageReporter(journal: journal, installID: "abc", version: "0.1.0", apiKey: "k", log: log) { data in
        if fake.failing { return .failed("offline") }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let properties = object["properties"] as? [String: Any] ?? [:]
        let name = object["event"] as? String ?? "?"
        switch name {
        case "notification": fake.sent.append("\(properties["action"] ?? "?") \(properties["hours"] ?? "?")")
        case "day": fake.sent.append("day \(properties["day"] ?? "?")")
        default: fake.sent.append(name)
        }
        return .accepted
    }
    func wait(_ work: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in
            await work()
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    wait { await reporter.sendNotification(.shown, hours: 1) }
    t.expect(fake.sent == ["shown 1"], "sent at once: \(fake.sent)")
    t.expect(reporter.pendingEventCount == 0, "nothing waits")

    fake.failing = true
    wait { await reporter.sendNotification(.clicked, hours: 1) }
    t.expect(reporter.pendingEventCount == 1, "a failed one waits")
    t.expect(log.entries.contains { $0.detail.hasPrefix("usage: notification clicked (1 h) not sent") }, "and says so")
    wait { await reporter.sendBuyMeACoffee() }
    t.expect(reporter.pendingEventCount == 2, "a failed Buy Me a Coffee click waits in the same queue")

    journal.record(.pushedOut, at: utc("2026-10-13T10:00:00Z"))
    fake.failing = false
    wait { await reporter.flush(now: utc("2026-10-14T09:00:00Z")) }
    t.expect(fake.sent == ["shown 1", "clicked 1", "buy_me_a_coffee", "day 2026-10-13"],
             "the waiting ones go first, in order, then the days: \(fake.sent)")
    t.expect(reporter.pendingEventCount == 0, "and is forgotten once sent")

    fake.failing = true
    for hours in 1...(UsageReporter.maxPendingEvents + 5) {
        wait { await reporter.sendNotification(.shown, hours: hours) }
    }
    t.expect(reporter.pendingEventCount == UsageReporter.maxPendingEvents,
             "the queue is capped: \(reporter.pendingEventCount)")
    t.expect(log.entries.contains { $0.detail == "usage: notification shown (1 h) dropped — too many waiting" },
             "the oldest is dropped, and logged")
}

/// What a pass counts: the moves of windows the user could see. The Stats tab
/// and the answer under Fix Windows Now both read this one rule.
func usageCountedMoves(_ t: TestRun) {
    t.expect(ScanSummary.counts(kind: .stuck, visible: true), "a visible move counts")
    t.expect(!ScanSummary.counts(kind: .stuck, visible: false), "a move under other windows does not")
    t.expect(!ScanSummary.counts(kind: nil, visible: true), "a visible window that was not moved does not")
}
