import Foundation

/// The user's own record of what DockFixer did: how many windows it moved on
/// each UTC day, under each switch, for as long as it has been installed.
///
/// It is not the journal. The journal (`Usage.swift`) is a queue of facts
/// waiting to be sent, and a day leaves it the moment PostHog has accepted
/// it, or once it is a month old, or when the statistics switch is turned
/// off. This file keeps every day for ever, whether statistics are on or off
/// and whether anything was ever sent, because it never leaves the machine:
/// it is what a "Statistics" page will read to tell the user how many windows
/// were moved and how much time that saved them.
///
/// Only raw counts are kept, never seconds. How long a moved window saves is
/// a guess that may be revised in a later release (see `Savings`), and a
/// revision should re-read the whole history under the new guess rather than
/// leave years of old seconds next to new ones.
///
/// The file is one small JSON object, rewritten whole:
/// `{"days":{"2026-10-16":{"acrossDisplays":0,"pushedOut":3,"stuck":1}},"version":1}`.
/// Seventy bytes a day is twenty-five kilobytes a year, which is small
/// enough that rewriting it is cheaper than any cleverness about appending.
public final class UsageHistory: @unchecked Sendable {

    /// What the file's shape is. Bumped when the shape changes, so that a
    /// later release can tell an old file from its own and convert it.
    public static let version = 1

    /// How the history came to be, for one line in the log at launch.
    public enum Origin: Equatable, Sendable {
        /// Read from an existing file.
        case loaded(days: Int)
        /// There was no file: started from the days still in the journal.
        case seeded(days: Int)
        /// The file could not be read. It was moved aside, not overwritten,
        /// and the history starts again from nothing.
        case unreadable(movedTo: URL)
        /// Written by a newer release in a shape this one does not know. It
        /// is left exactly as it is: counts are still kept for this session,
        /// but nothing is written over the newer file.
        case newer(version: Int)
    }

    public let url: URL
    public let origin: Origin

    /// How long a count waits in memory before it is written. A pass moves
    /// windows in a burst — twenty at once after a display change is
    /// ordinary — and one write after the burst is better than twenty. Two
    /// seconds is also the most a crash can lose, and a quit loses nothing
    /// because the app calls `save()` on its way out.
    private let saveDelay: TimeInterval

    private let lock = NSLock()
    private var days: [String: UsageDay] = [:]
    private var dirty = false
    private var saveScheduled = false
    private let readOnly: Bool
    private let queue = DispatchQueue(label: "DockFixer.UsageHistory", qos: .utility)

    /// Opens the history at `url`. `seed` is asked only when there is no file
    /// at all, which is the first launch of the first release that keeps a
    /// history: whatever the journal still holds then becomes the start of
    /// it. Days that an earlier release had already sent were pruned from
    /// the journal at the time, so they are gone from this machine and the
    /// history of an early user starts a little later than their use.
    public init(url: URL, saveDelay: TimeInterval = 2, seed: () -> [UsageDay] = { [] }) {
        self.url = url
        self.saveDelay = saveDelay

        let fm = FileManager.default
        guard let data = fm.contents(atPath: url.path) else {
            for day in seed() where Savings.windows(in: day) > 0 {
                days[day.day] = day
            }
            origin = .seeded(days: days.count)
            readOnly = false
            // Written at once, so the next launch finds a file and does not
            // seed a second time from a journal that has moved on.
            dirty = true
            save()
            return
        }

        if let file = try? JSONDecoder().decode(File.self, from: data) {
            if file.version > Self.version {
                origin = .newer(version: file.version)
                readOnly = true
            } else {
                origin = .loaded(days: file.days.count)
                readOnly = false
            }
            for (day, counts) in file.days {
                days[day] = UsageDay(day: day, pushedOut: counts.pushedOut, stuck: counts.stuck,
                                     acrossDisplays: counts.acrossDisplays)
            }
            return
        }

        // A file that cannot be read is most likely one cut short by a full
        // disk or edited by hand. Throwing it away would lose the user's
        // whole history for good, so it is kept next to the new one, where
        // it can still be rescued, and counting carries on from nothing.
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
        try? fm.moveItem(at: url, to: aside)
        origin = .unreadable(movedTo: aside)
        readOnly = false
    }

    /// Counts one moved window on the UTC day of `date`. `alive` is not a
    /// moved window and is ignored: the history is about what was done.
    public func record(_ kind: UsageKind, at date: Date = Date()) {
        let key = UsageJournal.day(of: date)
        lock.lock()
        var day = days[key] ?? UsageDay(day: key)
        switch kind {
        case .pushedOut: day.pushedOut += 1
        case .stuck: day.stuck += 1
        case .acrossDisplays: day.acrossDisplays += 1
        case .alive:
            lock.unlock()
            return
        }
        days[key] = day
        dirty = true
        let schedule = !saveScheduled
        saveScheduled = true
        lock.unlock()

        if schedule {
            queue.asyncAfter(deadline: .now() + saveDelay) { [weak self] in
                self?.save()
            }
        }
    }

    /// Every day with at least one moved window, oldest first.
    public var allDays: [UsageDay] {
        lock.lock(); defer { lock.unlock() }
        return days.values.sorted { $0.day < $1.day }
    }

    /// One UTC day, with zero counts if nothing was moved on it.
    public func day(_ key: String) -> UsageDay {
        lock.lock(); defer { lock.unlock() }
        return days[key] ?? UsageDay(day: key)
    }

    /// Writes whatever has been counted since the last write. Called by the
    /// timer `record` sets, and by the app when it quits.
    public func save() {
        lock.lock(); defer { lock.unlock() }
        saveScheduled = false
        guard dirty, !readOnly else { return }
        var file = File(version: Self.version, days: [:])
        for (key, day) in days {
            file.days[key] = Counts(pushedOut: day.pushedOut, stuck: day.stuck, acrossDisplays: day.acrossDisplays)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Atomic, so a crash mid-write leaves the previous file rather than
        // half of a new one.
        if (try? data.write(to: url, options: .atomic)) != nil {
            dirty = false
        }
    }

    /// Forgets every day. The file is written empty rather than deleted: a
    /// missing file means "first launch" and would seed the history again
    /// from the journal, bringing back days the user asked to forget.
    public func reset() {
        lock.lock()
        days = [:]
        dirty = true
        lock.unlock()
        save()
    }

    // MARK: - File

    private struct File: Codable {
        var version: Int
        var days: [String: Counts]
    }

    /// A missing count reads as zero, so a file from a release that kept
    /// fewer kinds, or one edited by hand, still loads.
    private struct Counts: Codable {
        var pushedOut = 0
        var stuck = 0
        var acrossDisplays = 0

        init(pushedOut: Int, stuck: Int, acrossDisplays: Int) {
            self.pushedOut = pushedOut
            self.stuck = stuck
            self.acrossDisplays = acrossDisplays
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pushedOut = try c.decodeIfPresent(Int.self, forKey: .pushedOut) ?? 0
            stuck = try c.decodeIfPresent(Int.self, forKey: .stuck) ?? 0
            acrossDisplays = try c.decodeIfPresent(Int.self, forKey: .acrossDisplays) ?? 0
        }
    }
}

/// How much time a moved window is taken to save, and the sums built on it.
///
/// These coefficients must match the insights on the PostHog dashboard,
/// which compute `pushedOut * 3.5 + stuck * 1 + acrossDisplays * 2` seconds:
/// the app and the public dashboard should tell the same story about the
/// same windows. They live only here, never in the stored history, so a
/// release that changes them re-reads every day ever recorded under the new
/// values. That is intended: the guess gets better, and the whole history
/// follows it. Change the dashboard insights in the same release.
public enum Savings {
    /// Dragging a window out from under the Dock by hand.
    public static let pushedOut: Double = 3.5
    /// Lining a window up against the Dock again after the Dock changed.
    public static let stuck: Double = 1
    /// Stretching a window into the room a departed Dock left behind.
    public static let acrossDisplays: Double = 2

    /// Seconds one window of a kind is taken to save. `alive` is not a window.
    public static func seconds(per kind: UsageKind) -> Double {
        switch kind {
        case .pushedOut: return pushedOut
        case .stuck: return stuck
        case .acrossDisplays: return acrossDisplays
        case .alive: return 0
        }
    }

    public static func seconds(for day: UsageDay) -> Double {
        Double(day.pushedOut) * pushedOut + Double(day.stuck) * stuck + Double(day.acrossDisplays) * acrossDisplays
    }

    public static func seconds(for days: [UsageDay]) -> Double {
        seconds(for: totals(of: days))
    }

    /// The counts of many days added up, under the label `total`.
    public static func totals(of days: [UsageDay]) -> UsageDay {
        var sum = UsageDay(day: "total")
        for day in days {
            sum.pushedOut += day.pushedOut
            sum.stuck += day.stuck
            sum.acrossDisplays += day.acrossDisplays
        }
        return sum
    }

    /// How many windows a day moved, of every kind.
    public static func windows(in day: UsageDay) -> Int {
        day.pushedOut + day.stuck + day.acrossDisplays
    }
}
