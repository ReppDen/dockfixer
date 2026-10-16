import Foundation
import zlib

/// A bug report sent from inside the app, with no account and no browser.
///
/// The GitHub issue form was the only way before, and it lost most reports:
/// someone without a GitHub account, or not signed in, gave up at the login
/// page, and the ones who got through rarely pasted the log. So the report goes
/// to the same PostHog project the usage statistics go to, as one event, and
/// the author is told about each one from there.
///
/// What leaves the machine is built here and nowhere else, so a test can look
/// at exactly that: the words the person typed, the email address if they gave
/// one, the app and macOS versions, the switches on the settings page, the
/// displays, and — only when the "Attach the log" box is ticked, which it is
/// to begin with — the last day of the log. The log names applications and
/// cuts window titles to thirty characters; the form says so next to the box,
/// and "See What's Sent" shows the exact text before anything goes.
///
/// It is sent only when the person presses Send. The usage statistics switch
/// does not govern it: turning statistics off says "do not count me", not "do
/// not let me write to you".
public struct BugReport: Sendable {
    public var message: String
    public var email: String?
    public var version: String
    /// `ProcessInfo.operatingSystemVersionString`: `Version 26.5 (Build 25F71)`.
    public var system: String
    /// The switches on the settings page, by the names the code uses for them.
    public var settings: [String: Bool]
    public var displays: String
    /// Nil when the box was unticked; empty when it was ticked and the log had
    /// nothing from the last day.
    public var log: String?

    public init(message: String, email: String?, version: String, system: String,
                settings: [String: Bool], displays: String, log: String?) {
        self.message = message
        self.email = email
        self.version = version
        self.system = system
        self.settings = settings
        self.displays = displays
        self.log = log
    }

    /// Something has to be said for a report to be worth sending; whitespace
    /// is not saying something.
    public static func canSend(message: String) -> Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The event as PostHog receives it.
    ///
    /// `distinct_id` is the install ID of the usage statistics when there is
    /// one, so a report can be put next to that installation's days; with
    /// statistics off there is none, and a random ID made for this one report
    /// is used and not kept. `$process_person_profile: false` stops PostHog
    /// from making a person out of it either way, and `$geoip_disable` keeps
    /// the country and city off it, as with the daily event.
    public func event(distinctID: String, eventID: String, timestamp: Date, apiKey: String) -> Data {
        var properties: [String: Any] = [
            "message": message,
            "version": version,
            "macOS": system,
            "settings": settings,
            "displays": displays,
            "logAttached": log != nil,
            "$geoip_disable": true,
            "$process_person_profile": false,
        ]
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            properties["email"] = email
        }
        if let log {
            properties["log"] = log
        }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let object: [String: Any] = [
            "api_key": apiKey,
            "event": "bug_report",
            "distinct_id": distinctID,
            "uuid": eventID,
            "timestamp": stamp.string(from: timestamp),
            "properties": properties,
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

/// The part of the log a report carries: the last day, and no more than fits.
///
/// Lines carry only the time of day (`[14:22:07.113]`), but the file says
/// which day it is in two places: every session starts with a header holding
/// the full date and time, and a running app writes `=== 2026-10-15 Thursday
/// ===` when the date changes. Read in order, those two give every line its
/// date, so the cut is made at the first line written less than 24 hours ago
/// — an exact rule, not a guess from the number of launches.
///
/// A day rather than the whole file: a report is nearly always about something
/// that has just happened, and a debug build writes megabytes a day that would
/// only bury it. The size is capped as well, keeping the newest part, because
/// PostHog drops an event of a megabyte or more and a busy day can be bigger.
public enum RecentLog {

    /// Well under PostHog's limit of about 1 MB an event, leaving room for
    /// the rest of the event and for JSON's escaping of quotes and newlines.
    public static let maxBytes = 600 * 1024
    public static let window: TimeInterval = 24 * 60 * 60

    /// The current log and the one rotated before it, oldest first. The older
    /// file is read too because rotation happens whenever the file passes its
    /// size limit, and most of the last day may sit in the older one. Read in
    /// this order the two are one log: the dates written in the older file
    /// still date the first lines of the newer.
    public static func read(directory: URL, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let current = directory.appendingPathComponent("dockfixer.log")
        let previous = current.appendingPathExtension("1")
        let text = [previous, current]
            .compactMap { try? Data(contentsOf: $0) }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")
        return cut(text, now: now, timeZone: timeZone)
    }

    /// The lines of `text` from the last `window` before `now`, at most
    /// `maxBytes` of UTF-8, newest kept.
    ///
    /// When the cut lands inside a session, that session's header goes first,
    /// and the last date line after it, so the version and the date of the
    /// lines that follow are still there to read.
    ///
    /// A file in which no date can be read at all — written by some future
    /// format, or in a locale whose digits are not ASCII — is not thrown away:
    /// it is kept whole, and the size cap still keeps the newest part. Losing
    /// the log would cost more than sending a little too much of it.
    public static func cut(_ text: String, now: Date, timeZone: TimeZone = .current,
                           window: TimeInterval = window, maxBytes: Int = maxBytes) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let cutoff = now.addingTimeInterval(-window)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var day: DateComponents?
        var anyDate = false
        var header: Int?
        var dayLine: Int?
        var start: Int?

        for (index, line) in lines.enumerated() {
            var time: Date?
            if line.hasPrefix("=== ") {
                if let range = line.range(of: "session started "),
                   let stamp = parseStamp(line[range.upperBound...]) {
                    day = DateComponents(year: stamp.year, month: stamp.month, day: stamp.day)
                    time = calendar.date(from: stamp)
                    header = index
                    dayLine = nil
                } else if let date = parseDay(line.dropFirst(4)) {
                    day = date
                    time = calendar.date(from: date)
                    dayLine = index
                }
            } else if line.hasPrefix("["), var components = day, let clock = parseClock(line.dropFirst()) {
                components.hour = clock.hour
                components.minute = clock.minute
                components.second = clock.second
                components.nanosecond = clock.nanosecond
                time = calendar.date(from: components)
            }
            guard let time else { continue }
            anyDate = true
            if time >= cutoff {
                start = index
                break
            }
        }

        var kept: [Substring]
        var context: [Substring] = []
        if let start {
            kept = Array(lines[start...])
            if let header, header < start {
                context.append(lines[header])
                if let dayLine, dayLine < start { context.append(lines[dayLine]) }
                context.append("… older lines left out: only the last 24 hours are sent …")
            }
        } else if anyDate {
            // Dated, and every date older than the window: nothing recent.
            return ""
        } else {
            kept = lines
        }
        // A file ends with a newline, which leaves an empty last element.
        while let last = kept.last, last.isEmpty { kept.removeLast() }
        while let first = kept.first, first.isEmpty { kept.removeFirst() }

        let tooBig = "… older lines left out to keep the report small …"
        let contextBytes = context.reduce(0) { $0 + $1.utf8.count + 1 }
        let total = kept.reduce(0) { $0 + $1.utf8.count + 1 } + contextBytes
        if total > maxBytes {
            let budget = maxBytes - contextBytes - tooBig.utf8.count - 1
            var used = 0
            var first = kept.count
            while first > 0, used + kept[first - 1].utf8.count + 1 <= budget {
                used += kept[first - 1].utf8.count + 1
                first -= 1
            }
            if first == kept.count, let last = kept.last {
                // One line bigger than the whole budget: its end is the newest part.
                kept = [Substring(String(decoding: last.utf8.suffix(max(budget, 0)), as: UTF8.self))]
            } else {
                kept = Array(kept[first...])
            }
            context.append(Substring(tooBig))
        }
        return (context + kept).joined(separator: "\n")
    }

    // MARK: - Reading dates

    /// `2026-10-15 13:16:34`, the start of a session header's date.
    private static func parseStamp(_ text: Substring) -> DateComponents? {
        guard let date = parseDay(text) else { return nil }
        let rest = text.dropFirst(10)
        guard rest.first == " ", let clock = parseClockDigits(rest.dropFirst(), fraction: false) else { return nil }
        var stamp = date
        stamp.hour = clock.hour
        stamp.minute = clock.minute
        stamp.second = clock.second
        return stamp
    }

    /// `2026-10-15`, at the start of the text.
    private static func parseDay(_ text: Substring) -> DateComponents? {
        let chars = Array(text.prefix(10))
        guard chars.count == 10, chars[4] == "-", chars[7] == "-",
              let year = number(chars[0..<4]), let month = number(chars[5..<7]), let day = number(chars[8..<10]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// `14:22:07.113]`, what follows the opening bracket of a line.
    private static func parseClock(_ text: Substring) -> DateComponents? {
        guard text.dropFirst(12).first == "]" else { return nil }
        return parseClockDigits(text, fraction: true)
    }

    private static func parseClockDigits(_ text: Substring, fraction: Bool) -> DateComponents? {
        let chars = Array(text.prefix(fraction ? 12 : 8))
        guard chars.count == (fraction ? 12 : 8), chars[2] == ":", chars[5] == ":",
              let hour = number(chars[0..<2]), let minute = number(chars[3..<5]), let second = number(chars[6..<8]),
              hour < 24, minute < 60, second < 61
        else { return nil }
        var clock = DateComponents(hour: hour, minute: minute, second: second)
        if fraction {
            guard chars[8] == ".", let millis = number(chars[9..<12]) else { return nil }
            clock.nanosecond = millis * 1_000_000
        }
        return clock
    }

    private static func number(_ chars: ArraySlice<Character>) -> Int? {
        guard chars.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(String(chars))
    }
}

/// gzip, for the request body: PostHog's capture endpoint reads
/// `Content-Encoding: gzip`, and a log compresses to a tenth of its size.
public enum Gzip {
    public static func compress(_ data: Data) -> Data? {
        var stream = z_stream()
        // 15 window bits, plus 16 for a gzip header and trailer instead of zlib's.
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return nil }
        defer { deflateEnd(&stream) }

        var output = Data(count: Int(deflateBound(&stream, UInt(data.count))))
        let status: Int32 = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(out.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { return nil }
        output.count = Int(stream.total_out)
        return output
    }
}
