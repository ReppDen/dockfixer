import CryptoKit
import Foundation

/// Usage statistics: what is counted, where it is kept, and how it is sent.
///
/// One event a day per installation — a random install ID, the app version,
/// the day, and how many windows were moved under each of the three switches.
/// Nothing else: not the system, not the windows, not the applications. The
/// whole of what leaves the machine is built in `UsageReport.event`, and the
/// README shows it.
///
/// The only other thing that goes to the same project is a bug report, and
/// only when someone writes one and presses Send: see `BugReport.swift` for
/// what it carries. It is not governed by the statistics switch, and with
/// statistics off it carries no install ID either.
///
/// Facts are written as they happen, to a small journal of their own, and
/// the sums are made when it is time to send. The log would have been the
/// obvious source, but it is written for people — titles cut short, lines
/// rotated away at a size limit, a format that moves — and a machine reading
/// it would break the first time it changed. The journal is forty bytes a
/// window and cleans itself up once a day has been sent.

/// What a moved window counts as. One per switch, plus a mark that the app
/// was running at all, so an installation that moved nothing that day is
/// still a day of use.
public enum UsageKind: String, Sendable, CaseIterable {
    /// Moved out from under the Dock (the first switch).
    case pushedOut
    /// Followed the Dock on the same display, or was put against it (the second).
    case stuck
    /// Stretched into the strip a Dock left on its way to another display (the third).
    case acrossDisplays
    /// The app was running on that day.
    case alive
}

/// One day's sums, in UTC. The day is the same everywhere, so two machines
/// in two time zones count the same hours under the same date, and a day
/// that ends at midnight UTC is over at the same moment for everyone.
public struct UsageDay: Equatable, Sendable {
    public let day: String
    public var pushedOut = 0
    public var stuck = 0
    public var acrossDisplays = 0

    public init(day: String, pushedOut: Int = 0, stuck: Int = 0, acrossDisplays: Int = 0) {
        self.day = day
        self.pushedOut = pushedOut
        self.stuck = stuck
        self.acrossDisplays = acrossDisplays
    }

    /// `11 pushed out, 40 stuck, 3 across displays`, for the log.
    public var summary: String {
        "\(pushedOut) pushed out, \(stuck) stuck, \(acrossDisplays) across displays"
    }
}

/// An append-only file of facts, one JSON object a line:
/// `{"t":"2026-10-13T20:11:02Z","k":"pushedOut"}`. Read whole when the sums
/// are made, which is once a day for a file of a few kilobytes.
public final class UsageJournal: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// The UTC day a moment falls on.
    public static func day(of date: Date) -> String {
        dayFormat.string(from: date)
    }

    public func record(_ kind: UsageKind, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let line = "{\"t\":\"\(Self.timestamp.string(from: date))\",\"k\":\"\(kind.rawValue)\"}\n"
        append(line)
    }

    /// Writes an `alive` mark unless the day already has a line of any kind.
    public func markAlive(at date: Date = Date()) {
        let today = Self.day(of: date)
        guard !lines().contains(where: { $0.day == today }) else { return }
        record(.alive, at: date)
    }

    /// The sums of every day before `today`, oldest first. Today is still
    /// being written and is not a day yet.
    public func days(before today: String) -> [UsageDay] {
        var sums: [String: UsageDay] = [:]
        for line in lines() where line.day < today {
            var day = sums[line.day] ?? UsageDay(day: line.day)
            switch line.kind {
            case .pushedOut: day.pushedOut += 1
            case .stuck: day.stuck += 1
            case .acrossDisplays: day.acrossDisplays += 1
            case .alive: break
            }
            sums[line.day] = day
        }
        return sums.values.sorted { $0.day < $1.day }
    }

    /// Drops a day that has been sent. Rewrites the file: it is small, and
    /// the lines of the other days are kept exactly as they were.
    public func prune(day: String) {
        lock.lock(); defer { lock.unlock() }
        let kept = rawLines().filter { Self.parse($0)?.day != day }
        let text = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    public func erase() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - File

    private struct Line {
        let day: String
        let kind: UsageKind
    }

    private func lines() -> [Line] {
        lock.lock(); defer { lock.unlock() }
        return rawLines().compactMap(Self.parse)
    }

    private func rawLines() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// A line that cannot be read is skipped rather than failing the day: a
    /// crash mid-write leaves half a line, and one lost window is nothing.
    private static func parse(_ raw: String) -> Line? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let t = object["t"] as? String,
              let k = object["k"] as? String,
              let kind = UsageKind(rawValue: k),
              let date = timestamp.date(from: t)
        else { return nil }
        return Line(day: day(of: date), kind: kind)
    }

    private func append(_ text: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}

/// The event as PostHog receives it. Kept apart from the sending so a test
/// can look at exactly what would go out.
public enum UsageReport {

    /// One namespace for every event ID, so that the same installation and
    /// the same day always make the same ID.
    private static let namespace = "5c1e9d0e-7b7a-4d2f-9a1c-dockfixerday0"

    /// A name-based UUID (version 5) of the install ID and the day. PostHog
    /// keeps one event per ID, so a day sent twice — the first answer lost
    /// on the way back, say — is still counted once.
    public static func eventID(installID: String, day: String) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data((namespace + installID + day).utf8))
        var bytes = Array(hash.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                hex.dropFirst(16).prefix(4), hex.dropFirst(20)].map(String.init).joined(separator: "-")
    }

    /// The whole of what is sent, as JSON. Counts are numbers, not strings:
    /// PostHog fixes a property's type on the first event it sees.
    public static func event(for day: UsageDay, installID: String, version: String, apiKey: String) -> Data {
        let object: [String: Any] = [
            "api_key": apiKey,
            "event": "day",
            "distinct_id": installID,
            "uuid": eventID(installID: installID, day: day.day),
            "timestamp": "\(day.day)T00:00:00Z",
            "properties": [
                "version": version,
                "day": day.day,
                "pushedOut": day.pushedOut,
                "stuck": day.stuck,
                "acrossDisplays": day.acrossDisplays,
                // No country or city on the server side either.
                "$geoip_disable": true,
            ] as [String: Any],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

/// Sends the finished days, in order, and forgets each one as it is accepted.
///
/// The machine may be asleep, shut, or offline at midnight, so there is no
/// moment this has to run: it is tried on launch, on wake, and once an hour,
/// and whatever is still unsent then goes. A day leaves the journal only
/// after the server has said yes; a failure stops the run, and the next try
/// starts from the same day.
@MainActor
public final class UsageReporter {

    public enum SendResult: Equatable, Sendable {
        case accepted
        case failed(String)
    }

    public typealias Send = @Sendable (Data) async -> SendResult

    private let journal: UsageJournal
    private let installID: String
    private let version: String
    private let apiKey: String
    private let log: Log
    private let send: Send
    private var isFlushing = false
    private var lastFailure: Date?

    /// A failed try is not repeated at once: the hourly timer and the next
    /// wake are the retries, and a launch straight after a wake is not two.
    private let retryAfter: TimeInterval = 10 * 60

    public init(journal: UsageJournal, installID: String, version: String, apiKey: String,
                log: Log, send: @escaping Send) {
        self.journal = journal
        self.installID = installID
        self.version = version
        self.apiKey = apiKey
        self.log = log
        self.send = send
    }

    public func flush(now: Date = Date()) async {
        journal.markAlive(at: now)
        guard !isFlushing else { return }
        if let lastFailure, now.timeIntervalSince(lastFailure) < retryAfter { return }
        isFlushing = true
        defer { isFlushing = false }

        for day in journal.days(before: UsageJournal.day(of: now)) {
            let data = UsageReport.event(for: day, installID: installID, version: version, apiKey: apiKey)
            switch await send(data) {
            case .accepted:
                journal.prune(day: day.day)
                log.info("usage sent — \(day.day): \(day.summary)")
            case .failed(let why):
                lastFailure = now
                log.info("usage not sent — \(day.day): \(why) — will try again later")
                return
            }
        }
    }
}

/// The one place the app talks to PostHog: the daily usage event, and a bug
/// report when someone sends one (see `BugReport.swift`).
public enum PostHog {
    public static let endpoint = URL(string: "https://eu.i.posthog.com/capture/")!

    /// What came back: the HTTP status, or why there was none.
    public enum Delivery: Equatable, Sendable {
        case status(Int)
        case error(String)

        public var isAccepted: Bool {
            if case .status(let code) = self { return (200..<300).contains(code) }
            return false
        }

        /// `HTTP 200`, or the system's words for a failure, for the log and the form.
        public var description: String {
            switch self {
            case .status(let code): return "HTTP \(code)"
            case .error(let why): return why
            }
        }
    }

    public static func send(_ data: Data, version: String) async -> UsageReporter.SendResult {
        let delivery = await deliver(data, version: version)
        return delivery.isAccepted ? .accepted : .failed(delivery.description)
    }

    /// Posts one event. `compress` gzips the body: the capture endpoint reads
    /// `Content-Encoding: gzip` (checked against it: a gzipped body is decoded,
    /// a broken one is refused with "invalid GZIP data"), which matters for a
    /// report carrying a log and not at all for a daily event of a few hundred bytes.
    public static func deliver(_ data: Data, version: String, compress: Bool = false) async -> Delivery {
        var request = URLRequest(url: endpoint, timeoutInterval: compress ? 60 : 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DockFixer/\(version)", forHTTPHeaderField: "User-Agent")
        if compress, let gzipped = Gzip.compress(data) {
            request.httpBody = gzipped
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        } else {
            request.httpBody = data
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .error("no HTTP response") }
            return .status(http.statusCode)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
