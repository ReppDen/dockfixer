import Foundation
import DockFixerCore

private let utc = TimeZone(identifier: "UTC")!

private func date(_ text: String) -> Date {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.timeZone = utc
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.date(from: text)!
}

private func header(_ stamp: String) -> String {
    "=== DockFixer 0.1.0 (arm64) session started \(stamp) — macOS 26.5 (25F71), Mac17,7 ==="
}

/// Exactly what the server would get: the event name, both opt-outs of
/// PostHog's own enrichment, an email only when one was given, a log only
/// when it was asked for.
func bugReportEvent(_ t: TestRun) {
    func decode(_ report: BugReport) -> [String: Any] {
        let data = report.event(distinctID: "install-1", eventID: "event-1",
                                timestamp: date("2026-10-16 12:00:00"), apiKey: "phc_test")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    var report = BugReport(message: "Windows jump", email: "  me@example.com ", version: "0.1.0",
                           system: "Version 26.5 (Build 25F71)",
                           settings: ["moveFromUnderDock": true, "stickToDock": false],
                           displays: "Built-in, Dock at the bottom", log: "[12:00:00.000] INFO  ready")
    let event = decode(report)
    t.expect(event["event"] as? String == "bug_report", "event name: \(event["event"] ?? "nil")")
    t.expect(event["distinct_id"] as? String == "install-1", "distinct_id")
    t.expect(event["uuid"] as? String == "event-1", "uuid")
    t.expect(event["api_key"] as? String == "phc_test", "api_key")
    t.expect(event["timestamp"] as? String == "2026-10-16T12:00:00Z", "timestamp: \(event["timestamp"] ?? "nil")")
    let properties = event["properties"] as? [String: Any] ?? [:]
    t.expect(properties["message"] as? String == "Windows jump", "message")
    t.expect(properties["email"] as? String == "me@example.com", "email is trimmed: \(properties["email"] ?? "nil")")
    t.expect(properties["version"] as? String == "0.1.0", "version")
    t.expect(properties["macOS"] as? String == "Version 26.5 (Build 25F71)", "macOS")
    t.expect((properties["settings"] as? [String: Bool]) == ["moveFromUnderDock": true, "stickToDock": false], "settings")
    t.expect(properties["displays"] as? String == "Built-in, Dock at the bottom", "displays")
    t.expect(properties["log"] as? String == "[12:00:00.000] INFO  ready", "log")
    t.expect(properties["logAttached"] as? Bool == true, "logAttached")
    t.expect(properties["$geoip_disable"] as? Bool == true, "$geoip_disable")
    t.expect(properties["$process_person_profile"] as? Bool == false, "$process_person_profile")

    report.email = "   "
    report.log = nil
    let bare = decode(report)["properties"] as? [String: Any] ?? [:]
    t.expect(bare["email"] == nil, "a blank email is not sent")
    t.expect(bare["log"] == nil, "no log when the box is unticked")
    t.expect(bare["logAttached"] as? Bool == false, "logAttached is false without a log")

    t.expect(!BugReport.canSend(message: " \n\t "), "whitespace alone is not a report")
    t.expect(BugReport.canSend(message: " x "), "a word is a report")
}

/// The last 24 hours, found from session headers and date lines.
func bugReportLogCut(_ t: TestRun) {
    let now = date("2026-10-16 10:00:00")
    let log = """

    \(header("2026-10-14 08:00:00"))
    [08:00:01.000] INFO   two days ago
    === 2026-10-15 Thursday ===
    [09:59:59.000] INFO   just over a day ago
    [10:00:01.000] INFO   just under a day ago
    [23:00:00.000] INFO   yesterday evening

    \(header("2026-10-16 09:00:00"))
    [09:00:01.000] INFO   this morning

    """
    let cut = RecentLog.cut(log, now: now, timeZone: utc)
    t.expect(!cut.contains("two days ago") && !cut.contains("just over a day ago"),
             "older lines were kept:\n\(cut)")
    for line in ["just under a day ago", "yesterday evening", "this morning"] {
        t.expect(cut.contains(line), "lost \"\(line)\":\n\(cut)")
    }
    // The cut is mid-session, so the session's header and the date come first.
    let lines = cut.components(separatedBy: "\n")
    t.expect(lines.first == header("2026-10-14 08:00:00"), "the session header does not lead:\n\(cut)")
    t.expect(lines.count > 1 && lines[1] == "=== 2026-10-15 Thursday ===", "the date line does not follow it:\n\(cut)")
    t.expect(lines.count > 3 && lines[3] == "[10:00:01.000] INFO   just under a day ago",
             "the first kept line is wrong:\n\(cut)")

    // A cut at a session header needs nothing in front of it.
    let atHeader = RecentLog.cut(log, now: date("2026-10-17 08:00:00"), timeZone: utc)
    t.expect(atHeader.hasPrefix(header("2026-10-16 09:00:00")), "a cut at a header got a prefix:\n\(atHeader)")
    t.expect(!atHeader.contains("yesterday evening"), "a line from before the header was kept:\n\(atHeader)")

    // The same file read in another time zone: lines are local time, and the
    // cut moves with it.
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let inTokyo = RecentLog.cut(log, now: date("2026-10-16 01:00:00"), timeZone: tokyo)
    t.expect(inTokyo.contains("just under a day ago") && !inTokyo.contains("just over a day ago"),
             "the cut ignores the time zone:\n\(inTokyo)")

    t.expect(RecentLog.cut(log, now: date("2026-10-20 00:00:00"), timeZone: utc).isEmpty,
             "a log with nothing from the last day should send nothing")

    // No date anywhere: kept rather than lost.
    let undated = "[10:00:00.000] INFO  a\n[10:00:01.000] INFO  b\n"
    t.expect(RecentLog.cut(undated, now: now, timeZone: utc) == "[10:00:00.000] INFO  a\n[10:00:01.000] INFO  b",
             "an undated log was not kept whole")
}

/// Too big for one event: the newest part is kept, whole lines, under the cap.
func bugReportLogCap(_ t: TestRun) {
    var lines = [header("2026-10-16 09:00:00")]
    for i in 0..<2000 {
        lines.append(String(format: "[09:%02d:%02d.000] INFO   line %04d ", (i / 60) % 60, i % 60, i)
                     + String(repeating: "x", count: 80))
    }
    let text = lines.joined(separator: "\n")
    let cap = 20_000
    let cut = RecentLog.cut(text, now: date("2026-10-16 10:00:00"), timeZone: utc, maxBytes: cap)
    t.expect(cut.utf8.count <= cap, "over the cap: \(cut.utf8.count) bytes")
    t.expect(cut.utf8.count > cap - 200, "far under the cap: \(cut.utf8.count) bytes")
    t.expect(cut.hasSuffix(lines.last!), "the newest line was lost")
    t.expect(cut.contains("older lines left out to keep the report small"), "no word that lines were dropped")
    let kept = cut.components(separatedBy: "\n").filter { $0.hasPrefix("[") }
    t.expect(kept.allSatisfy { $0.hasSuffix(String(repeating: "x", count: 80)) }, "a line was cut in half")

    let small = RecentLog.cut(text, now: date("2026-10-16 10:00:00"), timeZone: utc)
    t.expect(small == text, "a log under the cap was changed")
}

/// The body sent with Content-Encoding: gzip has to be real gzip.
func bugReportGzip(_ t: TestRun) {
    let input = Data(String(repeating: "[09:00:00.000] INFO   the same line again\n", count: 1000).utf8)
    guard let packed = Gzip.compress(input) else { return t.fail("compression failed") }
    t.expect(packed.prefix(2) == Data([0x1f, 0x8b]), "no gzip magic number")
    t.expect(packed.count < input.count / 10, "barely compressed: \(packed.count) of \(input.count)")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dockfixer-gzip-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("body.gz")
    try? packed.write(to: file)
    let gunzip = Process()
    gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
    gunzip.arguments = ["-c", file.path]
    let pipe = Pipe()
    gunzip.standardOutput = pipe
    try? gunzip.run()
    let unpacked = pipe.fileHandleForReading.readDataToEndOfFile()
    gunzip.waitUntilExit()
    t.expect(unpacked == input, "gunzip did not give back the input (\(unpacked.count) bytes)")
}
