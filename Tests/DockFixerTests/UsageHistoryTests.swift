import Foundation
import DockFixerCore

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dockfixer-history-test-\(UUID().uuidString)", isDirectory: true)
}

private func utc(_ text: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: text)!
}

/// The history counts by UTC day, ignores `alive`, and reads back what it wrote.
func usageHistoryRecording(_ t: TestRun) {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("usage-history.json")

    // A long delay: these writes happen through `save()`, not the timer.
    let history = UsageHistory(url: url, saveDelay: 3600)
    t.expect(history.origin == .seeded(days: 0), "no file and nothing to seed: \(history.origin)")
    t.expect(FileManager.default.fileExists(atPath: url.path), "the first launch writes a file at once")

    // 23:30 in New York on the 12th is already the 13th in UTC.
    history.record(.pushedOut, at: utc("2026-10-13T03:30:00Z"))
    history.record(.pushedOut, at: utc("2026-10-13T23:59:59Z"))
    history.record(.stuck, at: utc("2026-10-13T10:00:00Z"))
    history.record(.acrossDisplays, at: utc("2026-10-14T00:00:00Z"))
    history.record(.alive, at: utc("2026-10-15T08:00:00Z"))

    t.expect(history.allDays.map(\.day) == ["2026-10-13", "2026-10-14"],
             "days are UTC days, oldest first, and alive makes no day: \(history.allDays.map(\.day))")
    t.expect(history.day("2026-10-13") == UsageDay(day: "2026-10-13", pushedOut: 2, stuck: 1),
             "the 13th: \(history.day("2026-10-13"))")
    t.expect(history.day("2026-10-14") == UsageDay(day: "2026-10-14", acrossDisplays: 1),
             "a window at midnight UTC belongs to the new day")
    t.expect(history.day("2026-10-20") == UsageDay(day: "2026-10-20"), "a day with nothing reads as zeros")

    history.save()
    let reopened = UsageHistory(url: url)
    t.expect(reopened.origin == .loaded(days: 2), "reopened: \(reopened.origin)")
    t.expect(reopened.allDays == history.allDays, "the file reads back what was written")

    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    t.expect(text.contains("\"version\":1") && text.contains("\"2026-10-13\":{\"acrossDisplays\":0,\"pushedOut\":2,\"stuck\":1}"),
             "raw counts per day, with a version: \(text)")
    t.expect(!text.contains("3.5") && !text.lowercased().contains("second"), "no seconds are stored")

    // The timer writes on its own, without a `save()`.
    let quick = UsageHistory(url: dir.appendingPathComponent("quick.json"), saveDelay: 0.05)
    quick.record(.stuck, at: utc("2026-10-13T10:00:00Z"))
    let deadline = Date().addingTimeInterval(2)
    var written = false
    while !written, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
        written = UsageHistory(url: quick.url).day("2026-10-13").stuck == 1
    }
    t.expect(written, "a recorded window is written within the delay")

    reopened.reset()
    t.expect(reopened.allDays.isEmpty, "reset forgets every day")
    t.expect(UsageHistory(url: url).origin == .loaded(days: 0), "reset leaves an empty file, so nothing is seeded again")
}

/// A file that is missing a count, broken, or from a newer release.
func usageHistoryTolerance(_ t: TestRun) {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("usage-history.json")

    try? Data(#"{"version":1,"days":{"2026-10-13":{"pushedOut":4}}}"#.utf8).write(to: url)
    let partial = UsageHistory(url: url, saveDelay: 3600)
    t.expect(partial.day("2026-10-13") == UsageDay(day: "2026-10-13", pushedOut: 4), "a missing count reads as zero")

    try? Data(#"{"version":1,"days":{"2026-10-1"#.utf8).write(to: url)
    let broken = UsageHistory(url: url, saveDelay: 3600) { [UsageDay(day: "2026-10-01", pushedOut: 9)] }
    guard case .unreadable(let aside) = broken.origin else {
        t.fail("a broken file is reported as unreadable: \(broken.origin)")
        return
    }
    t.expect(FileManager.default.fileExists(atPath: aside.path), "the broken file is kept aside")
    t.expect(broken.allDays.isEmpty, "a broken file is not seeded from the journal")
    broken.record(.stuck, at: utc("2026-10-14T10:00:00Z"))
    broken.save()
    t.expect(UsageHistory(url: url).day("2026-10-14").stuck == 1, "counting carries on in a fresh file")

    try? Data(#"{"version":99,"days":{"2026-10-13":{"pushedOut":4}},"more":true}"#.utf8).write(to: url)
    let newer = UsageHistory(url: url, saveDelay: 3600)
    t.expect(newer.origin == .newer(version: 99), "a newer file is recognised: \(newer.origin)")
    newer.record(.pushedOut, at: utc("2026-10-13T10:00:00Z"))
    newer.save()
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    t.expect(text.contains("\"more\":true"), "a newer release's file is not written over")
}

/// The first launch of a release with a history starts from the journal,
/// and the history outlives the journal being erased.
func usageHistorySeeding(_ t: TestRun) {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let journal = UsageJournal(url: dir.appendingPathComponent("usage.jsonl"))
    journal.record(.pushedOut, at: utc("2026-10-13T10:00:00Z"))
    journal.record(.stuck, at: utc("2026-10-13T11:00:00Z"))
    journal.record(.alive, at: utc("2026-10-14T09:00:00Z"))   // a day of use with no windows
    journal.record(.acrossDisplays, at: utc("2026-10-15T09:00:00Z"))  // today, unsent

    let url = dir.appendingPathComponent("usage-history.json")
    let history = UsageHistory(url: url, saveDelay: 3600) { journal.allDays() }
    t.expect(history.origin == .seeded(days: 2), "seeded with the two days that moved windows: \(history.origin)")
    t.expect(history.day("2026-10-13") == UsageDay(day: "2026-10-13", pushedOut: 1, stuck: 1), "sent-or-not days carry over")
    t.expect(history.day("2026-10-15").acrossDisplays == 1, "today's unsent windows carry over")

    var asked = false
    _ = UsageHistory(url: url) { asked = true; return [] }
    t.expect(!asked, "an existing file is never seeded again")

    // Turning statistics off erases the journal; the history does not care.
    history.record(.pushedOut, at: utc("2026-10-15T10:00:00Z"))
    journal.erase()
    history.save()
    let after = UsageHistory(url: url)
    t.expect(after.day("2026-10-13").pushedOut == 1 && after.day("2026-10-15").pushedOut == 1,
             "the history survives the journal being erased: \(after.allDays)")
}

/// The seconds match the dashboard: 3.5 s, 1 s and 2 s a window.
func usageSavings(_ t: TestRun) {
    let a = UsageDay(day: "2026-10-13", pushedOut: 11, stuck: 40, acrossDisplays: 3)
    let b = UsageDay(day: "2026-10-14", pushedOut: 2, stuck: 0, acrossDisplays: 1)
    t.expect(Savings.seconds(for: a) == 11 * 3.5 + 40 + 3 * 2, "a day: \(Savings.seconds(for: a))")
    t.expect(Savings.seconds(for: [a, b]) == Savings.seconds(for: a) + Savings.seconds(for: b), "days add up")
    t.expect(Savings.seconds(for: []) == 0, "no days, no seconds")
    t.expect(Savings.totals(of: [a, b]) == UsageDay(day: "total", pushedOut: 13, stuck: 40, acrossDisplays: 4),
             "totals per kind")
    t.expect(Savings.windows(in: a) == 54, "windows in a day")
    t.expect(UsageKind.allCases.map(Savings.seconds(per:)) == [3.5, 1, 2, 0], "the coefficients, and none for alive")
}
