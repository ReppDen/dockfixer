import Foundation
import DockFixerCore

/// A release build logs at `info`: debug lines reach neither the file nor the
/// window, everything else reaches both. A local build logs at `debug` and
/// keeps them all.
@MainActor
func logLevels(_ t: TestRun) {
    func written(at level: LogLevel) -> (file: String, buffer: [LogEntry]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockfixer-log-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = Log(directory: dir, level: level)
        log.debug("a debug line")
        log.info("an info line")
        log.add(level: .moved, app: "App", title: "Window", detail: "a moved line")
        log.add(level: .skip, app: "App", title: "Window", detail: "a skip line")
        log.add(level: .fail, app: "App", title: "Window", detail: "a fail line")

        // The file is written on a background queue; give it a moment.
        Thread.sleep(forTimeInterval: 0.2)
        let file = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        return (file, log.entries)
    }

    let release = written(at: .info)
    t.expect(!release.file.contains("DEBUG") && !release.file.contains("a debug line"),
             "an info log wrote a debug line:\n\(release.file)")
    t.expect(!release.buffer.contains { $0.level == .debug }, "an info log kept a debug line in the window")
    for line in ["an info line", "a moved line", "a skip line", "a fail line"] {
        t.expect(release.file.contains(line), "an info log lost \"\(line)\"")
    }
    t.expect(release.buffer.count == 4, "an info log should show 4 lines, shows \(release.buffer.count)")
    t.expect(!release.file.contains("(debug logging)"), "the session header of an info log claims debug logging")

    let local = written(at: .debug)
    t.expect(local.file.contains("DEBUG") && local.file.contains("a debug line"),
             "a debug log dropped its debug line:\n\(local.file)")
    t.expect(local.buffer.count == 5, "a debug log should show 5 lines, shows \(local.buffer.count)")
    t.expect(local.file.contains("(debug logging)"), "the session header of a debug log does not say so")
}
