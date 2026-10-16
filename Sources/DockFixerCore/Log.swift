import Foundation
import Combine

public enum LogLevel: String, Sendable {
    /// Everything a pass looked at, whether or not anything came of it. Off in
    /// a release build: the point of the ordinary log is that every line is
    /// something that happened, and debug undoes that on purpose.
    case debug = "DEBUG"
    case info = "INFO"
    case moved = "MOVED"
    case skip = "SKIP"
    case fail = "FAIL"

    /// Only `debug` is ever filtered out; the rest are all worth keeping.
    var isDebug: Bool { self == .debug }
}

public struct LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let time: Date
    public let level: LogLevel
    /// Owning application, when the entry is about a specific window.
    public let app: String?
    public let title: String?
    public let detail: String

    public init(time: Date, level: LogLevel, app: String?, title: String?, detail: String) {
        self.time = time
        self.level = level
        self.app = app
        self.title = title
        self.detail = detail
    }
}

/// Log with two destinations: a file to read after the fact, and an in-memory
/// buffer the window renders live.
///
/// Windows that could not be moved are the whole point of the log — every skip
/// and every failure records why, so a stubborn application can be identified
/// without attaching a debugger.
@MainActor
public final class Log: ObservableObject {

    /// Newest entries last. Bounded so a long-running session cannot grow
    /// without limit; the file keeps the full history.
    @Published public private(set) var entries: [LogEntry] = []

    public let fileURL: URL

    /// Whether `debug` entries are kept. Read from the bundle rather than from
    /// a preference: which build this is is not something to change by
    /// accident, and a local build is exactly where the extra detail is wanted.
    public let isDebug: Bool

    private let bufferLimit = 500
    private let file: LogFile
    /// The day of the last line written. Lines carry only the time, and the app
    /// runs for days on end, so a line of its own marks each new day.
    private var lastDay: String

    private static let lineTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd EEEE"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let sessionHeaderTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// The configured level, lowest first. `debug` comes from `DockFixerLogLevel`
    /// in the bundle — `make dev` sets it, a release build leaves it at `info`
    /// — or from `DOCKFIXER_LOG_LEVEL` for a binary run straight from the
    /// terminal, which has no bundle to read.
    public static func configuredLevel() -> LogLevel {
        let raw = ProcessInfo.processInfo.environment["DOCKFIXER_LOG_LEVEL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "DockFixerLogLevel") as? String
        // Anything unrecognised, the unsubstituted placeholder included, means
        // the quiet level: extra logging is opted into, never fallen into.
        return raw?.lowercased() == "debug" ? .debug : .info
    }

    /// - Parameter rotateAtBytes: the size at which the file is set aside as
    ///   `dockfixer.log.1` and a new one started. Only a test changes it.
    public init(directory: URL? = nil, level: LogLevel? = nil, rotateAtBytes: Int = 5 * 1024 * 1024) {
        isDebug = (level ?? Self.configuredLevel()) == .debug
        let dir = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DockFixer", isDirectory: true)
        fileURL = dir.appendingPathComponent("dockfixer.log")

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lastDay = Self.dayFormat.string(from: Date())
        file = LogFile(url: fileURL, rotateAtBytes: rotateAtBytes)

        // The first thing a report is read for is which build on which
        // system, and the person sending it should not have to be asked.
        let stamp = Self.sessionHeaderTime.string(from: Date())
        appendToFile("\n=== DockFixer \(Self.buildDescription()) session started \(stamp)"
            + "\(isDebug ? " (debug logging)" : "") — \(Self.systemDescription()) ===\n")
    }

    /// `0.1.0 (arm64)`, or `unversioned` for a binary run outside a bundle.
    static func buildDescription() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "\(version ?? "unversioned") (\(arch))"
    }

    /// `macOS 15.1 (24B83), MacBookPro18,3`.
    static func systemDescription() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
            .replacingOccurrences(of: "Version ", with: "")
            .replacingOccurrences(of: "(Build ", with: "(")
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        let model = String(cString: bytes)
        return "macOS \(os)" + (model.isEmpty ? "" : ", \(model)")
    }

    // MARK: - Writing

    public func info(_ detail: String) {
        add(LogEntry(time: Date(), level: .info, app: nil, title: nil, detail: detail))
    }

    /// Autoclosed so a release build does not pay to build a message it is
    /// about to throw away.
    public func debug(_ detail: @autoclosure () -> String) {
        guard isDebug else { return }
        add(LogEntry(time: Date(), level: .debug, app: nil, title: nil, detail: detail()))
    }

    public func add(level: LogLevel, app: String?, title: String?, detail: String) {
        add(LogEntry(time: Date(), level: level, app: app, title: title, detail: detail))
    }

    public func add(_ entry: LogEntry) {
        guard !entry.level.isDebug || isDebug else { return }
        entries.append(entry)
        if entries.count > bufferLimit {
            entries.removeFirst(entries.count - bufferLimit)
        }
        let day = Self.dayFormat.string(from: entry.time)
        if day != lastDay {
            lastDay = day
            appendToFile("\n=== \(day) ===\n")
        }
        appendToFile(Self.format(entry) + "\n")
    }

    public func clear() {
        entries.removeAll()
    }

    // MARK: - Formatting

    /// `[14:22:07.113] MOVED  Warp            "main"  (12,180 1400x900) -> …`
    ///
    /// Columns are padded so a wall of entries stays scannable, which matters
    /// more here than compactness — this is read by eye, not parsed.
    public static func format(_ entry: LogEntry) -> String {
        var line = "[\(lineTime.string(from: entry.time))] "
        line += entry.level.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)
        if let app = entry.app {
            line += " " + app.prefix(18).padding(toLength: 18, withPad: " ", startingAt: 0)
        }
        if let title = entry.title, !title.isEmpty {
            line += " \"\(title.prefix(30))\""
        }
        return line + "  " + entry.detail
    }

    /// The whole buffer as text, for the copy button.
    public var bufferText: String {
        entries.map(Self.format).joined(separator: "\n")
    }

    // MARK: - File

    private func appendToFile(_ text: String) {
        file.append(Data(text.utf8))
    }
}

/// The file behind the log, written on a queue of its own so that a pass
/// logging a line per window never waits on the disk.
///
/// Keeps one previous log around and starts afresh once the current one grows
/// past the limit. That is checked on every write, not only at launch: the
/// app runs for weeks without restarting, and a debug build writes a line per
/// window per pass. Counting the bytes written costs nothing, so there is no
/// reason to check less often. Everything here is touched on `queue` only.
private final class LogFile: @unchecked Sendable {
    private let url: URL
    private let rotateAtBytes: Int
    private let queue = DispatchQueue(label: "com.github.reppden.dockfixer.log", qos: .utility)
    private var handle: FileHandle?
    private var size = 0

    init(url: URL, rotateAtBytes: Int) {
        self.url = url
        self.rotateAtBytes = rotateAtBytes
        queue.sync { open() }
    }

    func append(_ data: Data) {
        queue.async { [self] in
            guard let handle else { return }
            try? handle.write(contentsOf: data)
            size += data.count
            if size > rotateAtBytes { rotate() }
        }
    }

    private func open() {
        let fm = FileManager.default
        if let current = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, current > rotateAtBytes {
            rotate()
            return
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let rotated = url.appendingPathExtension("1")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: url, to: rotated)
        fm.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        size = 0
    }
}
