import Foundation
import Combine

public enum LogLevel: String, Sendable {
    case info = "INFO"
    case moved = "MOVED"
    case skip = "SKIP"
    case fail = "FAIL"
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

    private let bufferLimit = 500
    private let rotateAtBytes = 5 * 1024 * 1024
    private let ioQueue = DispatchQueue(label: "com.github.drepp.dockfix.log", qos: .utility)
    private var handle: FileHandle?

    private static let lineTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let sessionHeaderTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DockFix", isDirectory: true)
        fileURL = dir.appendingPathComponent("dockfix.log")

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        rotateIfNeeded()
        openHandle()

        let stamp = Self.sessionHeaderTime.string(from: Date())
        appendToFile("\n=== DockFix session started \(stamp) ===\n")
    }

    // MARK: - Writing

    public func info(_ detail: String) {
        add(LogEntry(time: Date(), level: .info, app: nil, title: nil, detail: detail))
    }

    public func add(level: LogLevel, app: String?, title: String?, detail: String) {
        add(LogEntry(time: Date(), level: level, app: app, title: title, detail: detail))
    }

    public func add(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > bufferLimit {
            entries.removeFirst(entries.count - bufferLimit)
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

    private func openHandle() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    /// Keeps one previous log around and starts fresh once the current one grows
    /// past the limit.
    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > rotateAtBytes
        else { return }

        let rotated = fileURL.appendingPathExtension("1")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: fileURL, to: rotated)
    }

    private func appendToFile(_ text: String) {
        guard let handle else { return }
        let data = Data(text.utf8)
        ioQueue.async {
            try? handle.write(contentsOf: data)
        }
    }
}
