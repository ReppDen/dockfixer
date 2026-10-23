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
/// Two more events go out under the same switch, the moment they happen: a
/// "DockFixer saved you N hours" notification was shown, or clicked, built in
/// `UsageReport.notificationEvent`; and the Buy Me a Coffee button was
/// pressed, with which of its words it showed (`DonateLabel`), built in
/// `UsageReport.buyMeACoffeeEvent`. Both are rare, and the
/// one question each answers — does anybody click it — is better answered by
/// each click than by a daily sum. What happens on the page after the click
/// is Buy Me a Coffee's to count, not ours.
///
/// The only other thing that goes to the same project is a bug report, and
/// only when someone writes one and presses Send: see `BugReport.swift` for
/// what it carries. It is not governed by the statistics switch, and it
/// never carries the install ID.
///
/// Facts are written as they happen, to a small journal of their own, and
/// the sums are made when it is time to send. The log would have been the
/// obvious source, but it is written for people — titles cut short, lines
/// rotated away at a size limit, a format that moves — and a machine reading
/// it would break the first time it changed. The journal is forty bytes a
/// window and cleans itself up once a day has been sent — or, when sending
/// keeps failing, once a day is more than a month behind.

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

    /// The sums of every day in the journal, today included, oldest first:
    /// what the local history is started from on its first launch.
    public func allDays() -> [UsageDay] {
        days(before: "9999-12-31")
    }

    /// Drops a day that has been sent. Rewrites the file: it is small, and
    /// the lines of the other days are kept exactly as they were.
    public func prune(day: String) {
        lock.lock(); defer { lock.unlock() }
        let kept = rawLines().filter { Self.parse($0)?.day != day }
        let text = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Drops every day before `day`, sent or not. What keeps the journal
    /// from growing for ever on a machine that can never reach the server.
    public func prune(before day: String) {
        lock.lock(); defer { lock.unlock() }
        let kept = rawLines().filter { (Self.parse($0)?.day ?? "") >= day }
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
            ] as [String: Any],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// What happened to a milestone notification.
    public enum NotificationAction: String, Sendable {
        /// It reached the user: a banner, an alert, or a quiet entry in
        /// Notification Center. One the system dropped is not sent.
        case shown
        /// The user clicked it, in the banner or in Notification Center, or
        /// its See Stats button. Closing it is not a click.
        case clicked
    }

    private static let moment: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// The notification event, as JSON. The same install ID as the day
    /// event, so the two can be read together; a random event ID of its own,
    /// made once, so a retry of the same event is still one event. `hours`
    /// is the milestone the notification announced.
    public static func notificationEvent(action: NotificationAction, hours: Int, installID: String,
                                         version: String, apiKey: String,
                                         uuid: String = UUID().uuidString.lowercased(),
                                         at date: Date = Date()) -> Data {
        let object: [String: Any] = [
            "api_key": apiKey,
            "event": "notification",
            "distinct_id": installID,
            "uuid": uuid,
            "timestamp": moment.string(from: date),
            "properties": [
                "action": action.rawValue,
                "hours": hours,
                "version": version,
            ] as [String: Any],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// The Buy Me a Coffee button was pressed, as JSON, with the words it
    /// showed. Built like the notification event: the same install ID, so a
    /// click can be read beside the days of use before it, and a random
    /// event ID made once. The event keeps its old name whatever the words,
    /// so the clicks before the words changed stay in the same series.
    public static func buyMeACoffeeEvent(label: DonateLabel, installID: String, version: String, apiKey: String,
                                         uuid: String = UUID().uuidString.lowercased(),
                                         at date: Date = Date()) -> Data {
        let object: [String: Any] = [
            "api_key": apiKey,
            "event": "buy_me_a_coffee",
            "distinct_id": installID,
            "uuid": uuid,
            "timestamp": moment.string(from: date),
            "properties": [
                "label": label.rawValue,
                "version": version,
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

    /// Notification and Buy Me a Coffee events that could not be sent, oldest
    /// first, each built once so a retry carries the same ID and time.
    /// Retried by every flush — on launch, on wake, once an hour — before the
    /// days.
    ///
    /// In memory only, on purpose. There are a few such events a year; a quit
    /// while offline losing one costs little, where a file would need a format,
    /// pruning, and erasing with the switch, as the journal has. Capped, so
    /// that nothing can pile up should the server refuse them for good.
    private var pendingEvents: [(data: Data, what: String)] = []
    public static let maxPendingEvents = 50
    public var pendingEventCount: Int { pendingEvents.count }

    /// How many finished days wait to be sent at most. A machine behind a
    /// firewall that never lets the request through would otherwise keep
    /// every day it was ever used; a month is enough to ride out a long
    /// stretch offline, and a day older than that says little anyway.
    public static let maxUnsentDays = 31

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

        while let first = pendingEvents.first {
            switch await send(first.data) {
            case .accepted:
                pendingEvents.removeFirst()
                log.info("usage: \(first.what) sent on retry")
            case .failed(let why):
                lastFailure = now
                log.info("usage: \(first.what) still not sent: \(why) — will try again later")
                return
            }
        }

        var finished = journal.days(before: UsageJournal.day(of: now))
        if finished.count > Self.maxUnsentDays {
            let dropped = finished.count - Self.maxUnsentDays
            finished.removeFirst(dropped)
            journal.prune(before: finished[0].day)
            log.info("usage: \(dropped) unsent day\(dropped == 1 ? "" : "s") older than \(finished[0].day) dropped")
        }

        for day in finished {
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

    /// Sends a notification event now, and keeps it for the next flush if it
    /// does not go through.
    public func sendNotification(_ action: UsageReport.NotificationAction, hours: Int, at date: Date = Date()) async {
        let data = UsageReport.notificationEvent(action: action, hours: hours, installID: installID,
                                                 version: version, apiKey: apiKey, at: date)
        await sendNow(data, what: "notification \(action.rawValue) (\(hours) h)")
    }

    /// Sends a Buy Me a Coffee click now, and keeps it for the next flush if
    /// it does not go through.
    public func sendBuyMeACoffee(label: DonateLabel, at date: Date = Date()) async {
        let data = UsageReport.buyMeACoffeeEvent(label: label, installID: installID, version: version,
                                                 apiKey: apiKey, at: date)
        await sendNow(data, what: "Buy Me a Coffee click (\(label.rawValue))")
    }

    private func sendNow(_ data: Data, what: String) async {
        switch await send(data) {
        case .accepted:
            log.info("usage: \(what) sent")
        case .failed(let why):
            pendingEvents.append((data, what))
            if pendingEvents.count > Self.maxPendingEvents {
                let dropped = pendingEvents.removeFirst()
                log.info("usage: \(dropped.what) dropped — too many waiting")
            }
            log.info("usage: \(what) not sent: \(why) — will try again later")
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

/// The words on the donate button. One is picked at random each time the
/// window stops being seen (`DonateRotation`), so every time it appears again
/// it may show another, and the click
/// carries which one it was: the statistics then tell which words are
/// clicked most. Picked uniformly, each is shown about as often as the
/// others, so the clicks alone compare them and nothing is sent on showing.
///
/// The raw value is what is sent, and it names the words rather than their
/// place in the list, so it keeps its meaning when one is added or removed.
/// Change the words of a case and give it a new name, or the old clicks
/// count for the new words.
public enum DonateLabel: String, CaseIterable, Sendable {
    case coffee, support, thanks, tip, author, project

    public var title: String {
        switch self {
        case .coffee: return "Buy Me a Coffee"
        case .support: return "Support DockFixer"
        case .thanks: return "Say Thanks"
        case .tip: return "Leave a Tip"
        case .author: return "Thank the Author"
        case .project: return "Support the Project"
        }
    }

    /// An SF Symbol name.
    public var symbol: String {
        switch self {
        case .coffee: return "cup.and.saucer.fill"
        case .support: return "heart.fill"
        case .thanks: return "hands.clap.fill"
        case .tip: return "gift.fill"
        case .author: return "face.smiling"
        case .project: return "star.fill"
        }
    }

    /// Any of them, the one on show included: a draw that must differ
    /// would no longer give each the same share.
    public static func random() -> DonateLabel {
        allCases.randomElement()!
    }
}

/// When the donate button gets new words: the moment the window stops being
/// seen, however that happens — closed, hidden with Command-H, covered whole
/// by another window, left on another Space. Drawn then rather than when it
/// appears, so the words never change in front of anyone, and every
/// appearance, by whatever way, shows words drawn since the last one.
public struct DonateRotation: Sendable {
    private var visible = false

    public init() {}

    /// The window's visibility as the system reports it. True when new words
    /// are to be drawn: only on the change from seen to unseen, so a report
    /// repeated while it stays hidden draws nothing.
    public mutating func windowVisibilityChanged(to visible: Bool) -> Bool {
        defer { self.visible = visible }
        return self.visible && !visible
    }
}

/// The Statistics line on the Settings tab: a sentence with no checkbox,
/// which turns the statistics off or on when clicked. Off is asked about
/// first, since the numbers are what bugs and improvements are judged by;
/// on is not, since nothing is lost by it.
public enum StatisticsSwitch {

    public enum Click: Equatable, Sendable {
        /// Ask "Are you sure…", and turn them off only on Disable.
        case askBeforeDisabling
        /// Turn them on straight away.
        case enable
    }

    public static func click(sending: Bool) -> Click {
        sending ? .askBeforeDisabling : .enable
    }

    /// The reason goes only with "sends": after "doesn't send" it would say
    /// the app is kept good by not sending, the opposite of what is meant.
    public static func sentence(sending: Bool) -> String {
        sending ? "The app sends anonymous statistics to help make it better"
                : "The app doesn't send anonymous statistics"
    }
}
