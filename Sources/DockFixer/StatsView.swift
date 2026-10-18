import Charts
import DockFixerCore
import SwiftUI

/// The numbers the Stats tab shows, worked out once from the local history.
///
/// Every second here comes from `Savings`: the tab multiplies nothing itself,
/// so a change to the coefficients there is a change here too.
struct StatsData {
    /// Days with at least one moved window, oldest first.
    let days: [UsageDay]
    let totals: UsageDay
    let seconds: Double
    let windows: Int
    /// The first day in the history, as a local date for display.
    let firstDay: Date?
    /// Calendar days from the first day in the history to today, both
    /// counted. Every day, not only the days something was moved: an average
    /// over active days alone would grow the less the Dock is touched, and
    /// "a day" in "4 minutes a day" means any day the user had DockFixer.
    let daysWithDockFixer: Int
    /// Today's UTC day, the one the history is counting into now.
    let todayKey: String

    private let byKey: [String: UsageDay]

    init(days: [UsageDay], now: Date = Date()) {
        self.days = days
        totals = Savings.totals(of: days)
        seconds = Savings.seconds(for: days)
        windows = Savings.windows(in: totals)
        todayKey = UsageJournal.day(of: now)
        byKey = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        if let first = days.first, let start = Self.utc.date(from: first.day),
           let today = Self.utc.date(from: todayKey) {
            firstDay = Self.local.date(from: first.day)
            let span = Self.utcCalendar.dateComponents([.day], from: start, to: today).day ?? 0
            daysWithDockFixer = max(span, 0) + 1
        } else {
            firstDay = nil
            daysWithDockFixer = 0
        }
    }

    var isEmpty: Bool { windows == 0 }

    /// One day of the chart: its local date, the seconds saved on it, and
    /// the windows moved or resized that saved them.
    struct Point: Identifiable {
        let date: Date
        let seconds: Double
        let windows: Int
        var id: Date { date }
    }

    /// The last `count` days up to today, with nothing-moved days as zeros:
    /// a chart that skipped them would draw a busy week and a quiet month
    /// the same width.
    func lastDays(_ count: Int) -> [Point] {
        guard let today = Self.utc.date(from: todayKey) else { return [] }
        return (0..<count).reversed().compactMap { back in
            guard let date = Self.utcCalendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let key = Self.utc.string(from: date)
            return point(key)
        }
    }

    private func point(_ key: String) -> Point? {
        guard let date = Self.local.date(from: key) else { return nil }
        let day = byKey[key]
        return Point(date: date,
                     seconds: day.map(Savings.seconds(for:)) ?? 0,
                     windows: day.map(Savings.windows(in:)) ?? 0)
    }

    // History keys are UTC days. Arithmetic on them is done in UTC; for
    // display each key becomes the same date at local midnight, so "Oct 16"
    // stays Oct 16 west of Greenwich too.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let utc = keyFormatter(TimeZone(identifier: "UTC")!)
    private static let local = keyFormatter(.current)

    private static func keyFormatter(_ zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

/// How the tab says amounts of time and of windows.
enum StatsFormat {
    /// A number and its unit, kept apart so the number can be set large.
    struct Amount {
        let value: String
        let unit: String
    }

    /// `45 seconds`, `4.5 minutes`, `12 minutes`, `6.4 hours`, `128 hours`.
    ///
    /// Seconds under a minute, minutes under an hour, hours above: the unit
    /// a person would pick to say it. One decimal while the number is small
    /// enough for it to matter, none once it is not.
    static func time(_ seconds: Double) -> Amount {
        if seconds.rounded() < 60 {
            let n = Int(seconds.rounded())
            return Amount(value: "\(n)", unit: n == 1 ? "second" : "seconds")
        }
        let minutes = seconds / 60
        if minutes < 59.95 {
            return Amount(value: decimal(minutes), unit: decimal(minutes) == "1" ? "minute" : "minutes")
        }
        let hours = seconds / 3600
        return Amount(value: decimal(hours), unit: decimal(hours) == "1" ? "hour" : "hours")
    }

    /// `0 s`, `45 s`, `2 min`, `1.5 h`: one day's saving, short enough for
    /// the label over a bar.
    static func shortTime(_ seconds: Double) -> String {
        if seconds.rounded() < 60 { return "\(Int(seconds.rounded())) s" }
        let minutes = seconds / 60
        if minutes.rounded() < 60 { return "\(Int(minutes.rounded())) min" }
        return "\(decimal(seconds / 3600)) h"
    }

    /// `1,240`, `48.3K`, `1.2M`. Whole up to 9,999, which still fits where a
    /// large number goes; shortened after that, so a long-time user with
    /// millions of windows does not push the layout apart.
    static func windows(_ n: Int) -> String {
        n < 10_000
            ? n.formatted()
            : n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    private static func decimal(_ x: Double) -> String {
        x < 10
            ? x.formatted(.number.precision(.fractionLength(0...1)))
            : x.formatted(.number.precision(.fractionLength(0)))
    }
}

/// The Stats tab: how much the app has done for this person.
///
/// One quiet line that starts the sentence and says how long, then its two
/// endings as two cards — "saved you 2.7 hours", "moved or resized 5,243
/// windows" — and the last thirty days as bars under a header of their own.
/// Each fact sits in a card of its own with a clear gap between them, and
/// the body uses three sizes only: words, numbers and units.
struct StatsView: View {
    @EnvironmentObject private var state: AppState

    private static let words = Font.system(size: 14)
    private static let number = Font.system(size: 46, weight: .semibold, design: .rounded)
    private static let unit = Font.system(size: 20)
    /// The cards' inner padding, which every line of text on the page keeps to.
    private static let inset: CGFloat = 16

    var body: some View {
        let data = StatsData(days: state.usageDays)
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(lead(data))
                    .font(Self.words)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    // On the cards' inner edge, not their outer one: the
                    // eye lines text up with text, and against "saved you"
                    // a line at the card's edge looked crooked.
                    .padding(.horizontal, Self.inset)
                HStack(alignment: .top, spacing: 16) {
                    card(verb: "saved you",
                         value: StatsFormat.time(data.seconds).value,
                         unit: StatsFormat.time(data.seconds).unit)
                    // "Or resized": a window narrowed to clear the Dock is
                    // counted here as much as one moved out from under it.
                    card(verb: "moved or resized",
                         value: StatsFormat.windows(data.windows),
                         unit: data.windows == 1 ? "window" : "windows")
                }
                if DebugView.isAvailable {
                    breakdown(data)
                        .padding(.horizontal, Self.inset)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Last 30 days")
                    Spacer()
                    Text("time saved per day")
                }
                .font(Self.words)
                .foregroundStyle(.secondary)
                DailyBars(points: data.lastDays(30))
                    .frame(height: 120)
            }
            // The same inner edge as the cards' text.
            .padding(.horizontal, Self.inset)
        }
    }

    /// `In 120 days, DockFixer has`, the start of what both cards finish.
    /// Counted from the first day in the history, which is the first day a
    /// window was moved; on a fresh install the line says so instead.
    private func lead(_ data: StatsData) -> String {
        guard data.firstDay != nil, !data.isEmpty else { return "DockFixer hasn't moved any windows yet." }
        let days = data.daysWithDockFixer
        return days == 1 ? "Today, DockFixer has" : "In \(days.formatted()) days, DockFixer has"
    }

    /// DEV ONLY. The two cards taken apart, in one row of five: the seconds
    /// and the windows again, then each kind of move with its count and the
    /// seconds `Savings` gives it, which is all the cards are made of. A
    /// release never shows it.
    private func breakdown(_ data: StatsData) -> some View {
        let t = data.totals
        let columns = [
            "\(StatsFormat.shortTime(data.seconds)) total",
            "\(data.windows) windows",
            "pushedOut \(t.pushedOut) × \(Self.coefficient(Savings.pushedOut))",
            "stuck \(t.stuck) × \(Self.coefficient(Savings.stuck))",
            "acrossDisplays \(t.acrossDisplays) × \(Self.coefficient(Savings.acrossDisplays))",
        ]
        return HStack(spacing: 12) {
            ForEach(columns, id: \.self) { column in
                Text(column)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// `3.5 s`, `1 s`: the seconds one move of a kind is taken to save.
    private static func coefficient(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? "\(Int(seconds)) s" : "\(seconds) s"
    }

    /// The verb that finishes the lead line, then the number large and its
    /// unit beside it. The number shrinks rather than wraps, so "128 hours"
    /// and "1.2M windows" stay on one line in half the page.
    private func card(verb: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verb)
                .font(Self.words)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(Self.number)
                    .monospacedDigit()
                Text(unit)
                    .font(Self.unit)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            // Shrinking is for width only. Without this the window's height,
            // fitted to the tab, squeezed the line and the scale factor took
            // it as leave to halve the number.
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
    }
}

/// Seconds saved per day as quiet bars, one per day, nothing-moved days
/// left as gaps. Under the pointer a day's bar comes forward and a small
/// label over it gives that day's numbers.
private struct DailyBars: View {
    let points: [StatsData.Point]

    /// Where the pointer is over the chart, as a date; nil when it is not.
    @State private var hovered: Date?

    var body: some View {
        let scale = ChartScale(max: points.map(\.seconds).max() ?? 0)
        let selected = hovered.flatMap { date in
            points.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
        }
        Chart {
            ForEach(points) { point in
                BarMark(x: .value("Day", point.date, unit: .day),
                        y: .value("Saved", point.seconds / scale.divisor))
                    // The other bars step back rather than the hovered one
                    // standing out in a new colour: still the same chart.
                    .foregroundStyle(Color.accentColor.opacity(
                        selected == nil || selected?.date == point.date ? 0.65 : 0.3))
                    .cornerRadius(2)
            }
            if let selected {
                // An invisible point on top of the hovered bar, only to hang
                // the label on: the label reads as that day's, and as the
                // last mark it is drawn over every bar, not under the ones
                // after it. Pushed inside the chart at its edges and over the
                // tallest bars rather than cut off.
                PointMark(x: .value("Day", selected.date, unit: .day),
                          y: .value("Saved", selected.seconds / scale.divisor))
                    .symbolSize(0)
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        DayLabel(point: selected)
                    }
            }
        }
        .chartXSelection(value: $hovered)
        .chartYScale(domain: 0...scale.top)
        .chartXAxis {
            // A week apart from the first day, and not the last week: a
            // label under the newest bar runs into the axis on the right
            // and gets cut short.
            AxisMarks(values: stride(from: 0, to: max(points.count - 6, 0), by: 7).map { points[$0].date }) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(v.formatted()) \(scale.unit)") }
                }
            }
        }
        // A scale of zero to one second says nothing on an empty chart.
        .chartYAxis(scale.isEmpty ? .hidden : .automatic)
        .overlay { EmptyNote(isEmpty: scale.isEmpty) }
    }
}

/// `Oct 8 · 112 windows · 2 min`: one day, over its bar.
private struct DayLabel: View {
    let point: StatsData.Point

    var body: some View {
        let windows = "\(point.windows.formatted()) \(point.windows == 1 ? "window" : "windows")"
        Text("\(point.date.formatted(.dateTime.month(.abbreviated).day())) · \(windows) · \(StatsFormat.shortTime(point.seconds))")
            .font(.system(size: 11))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            // Opaque, so the bars it covers do not show through the words.
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12)))
            .fixedSize()
    }
}

// MARK: - Pieces

/// The unit a chart's axis counts in, picked from the largest value so the
/// labels read `20 min` rather than `1,200 s`.
private struct ChartScale {
    let divisor: Double
    let unit: String
    let top: Double
    let isEmpty: Bool

    init(max seconds: Double) {
        isEmpty = seconds <= 0
        if seconds >= 2 * 3600 {
            divisor = 3600; unit = "h"
        } else if seconds >= 120 {
            divisor = 60; unit = "min"
        } else {
            divisor = 1; unit = "s"
        }
        // A chart of zeros still needs a scale to draw its baseline on.
        top = Swift.max(seconds / divisor, 1) * 1.1
    }
}

/// Said over an empty chart, so a fresh install shows why it is empty.
private struct EmptyNote: View {
    let isEmpty: Bool

    var body: some View {
        if isEmpty {
            Text("No windows moved yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
