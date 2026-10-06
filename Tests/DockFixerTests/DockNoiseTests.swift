import CoreGraphics
import DockFixerCore

// A 2560x1440 display with a 30pt menu bar and a Dock on the left whose
// thickness wanders, which is what a side Dock does as applications open and
// quit: it scales its icons to fit them.
private let frame = CGRect(x: 0, y: 0, width: 2560, height: 1440)

private func layout(dock: CGFloat) -> [ScreenInfo] {
    [ScreenInfo(displayID: 1,
                axFrame: frame,
                axVisibleFrame: CGRect(x: dock, y: 30, width: 2560 - dock, height: 1410),
                isPrimary: true,
                localizedName: "DELL")]
}

/// A window a few points outside the usable area stays put; one further out
/// is brought all the way in.
func dockNoiseSlack(_ t: TestRun) {
    let visible = CGRect(x: 54, y: 30, width: 2506, height: 1410)

    t.expect(computeFix(window: CGRect(x: 51, y: 30, width: 1000, height: 900), visible: visible, slack: 4) == nil,
             "3pt under the Dock is left alone")
    t.expect(computeFix(window: CGRect(x: 50, y: 30, width: 2510, height: 1410), visible: visible, slack: 4) == nil,
             "a maximised window 4pt wider than the usable area is left alone")
    t.expect(computeFix(window: CGRect(x: 98, y: 1419, width: 400, height: 22), visible: visible, slack: 4) == nil,
             "a browser's status bubble 1pt below the usable area is left alone")

    let pushed = computeFix(window: CGRect(x: 49, y: 30, width: 1000, height: 900), visible: visible, slack: 4)
    t.expect(pushed?.rect.minX ?? 0, near: 54, "5pt under the Dock is pushed all the way out")

    let clamped = computeFix(window: CGRect(x: 41, y: 30, width: 2519, height: 1410), visible: visible, slack: 4)
    t.expect(clamped?.rect == visible, "a maximised window 13pt too wide is fitted exactly, got \(clamped?.rect.logDescription ?? "nil")")

    t.expect(computeFix(window: CGRect(x: 53, y: 30, width: 1000, height: 900), visible: visible) != nil,
             "without slack a single point still counts")
}

func dockNoiseMeasure(_ t: TestRun) {
    t.expect(largestEdgeShift(previous: layout(dock: 54), current: layout(dock: 55)), near: 1, "1pt thicker")
    t.expect(largestEdgeShift(previous: layout(dock: 52), current: layout(dock: 41)), near: 11, "11pt thinner")
    t.expect(largestEdgeShift(previous: layout(dock: 52), current: layout(dock: 52)), near: 0, "unchanged")

    let text = describeDockChange(previous: layout(dock: 54), current: layout(dock: 55))
    t.expect(text == "DELL left 54pt → left 55pt", "description, got \(text)")
}

/// What a day of a wandering Dock does to windows, with the watcher's rule —
/// changes are measured against the layout windows were last arranged for and
/// ignored up to `dockNoise` — and the scanner's correction.
///
/// Returns how many times each window was moved, and where the windows ended.
private func simulate(_ thicknesses: [CGFloat], windows start: [CGRect]) -> (moves: Int, windows: [CGRect]) {
    var windows = start
    var arrangedFor = layout(dock: thicknesses[0])
    var moves = 0
    for dock in thicknesses.dropFirst() {
        let now = layout(dock: dock)
        guard largestEdgeShift(previous: arrangedFor, current: now) > dockNoise else { continue }
        let reclaim = reclaims(previous: arrangedFor, current: now)[1]
        for i in windows.indices {
            if let fix = computeFix(window: windows[i], visible: now[0].axVisibleFrame,
                                    reclaim: reclaim, slack: dockNoise) {
                windows[i] = fix.rect
                moves += 1
            }
        }
        arrangedFor = now
    }
    return (moves, windows)
}

func dockNoiseDay(_ t: TestRun) {
    let maximised = CGRect(x: 54, y: 30, width: 2506, height: 1410)
    let resting = CGRect(x: 54, y: 491, width: 1471, height: 949)
    let floating = CGRect(x: 300, y: 200, width: 900, height: 600)
    let all = [maximised, resting, floating]

    // Yesterday's and today's readings of the DELL's left inset, in order.
    let jitter: [CGFloat] = [54, 55, 54, 55, 54, 53, 54, 55, 56, 55, 54, 55, 54]
    let quiet = simulate(jitter, windows: all)
    t.expect(quiet.moves == 0, "a Dock wandering by a point or two moved windows \(quiet.moves) times")
    t.expect(quiet.windows == all, "and they are where they started")

    // Small steps add up and are acted on once they pass the threshold, and
    // the way back undoes it exactly: nothing creeps.
    let growing = simulate([54, 55, 56, 57, 58, 59, 60, 61], windows: all)
    t.expect(growing.windows[0] == CGRect(x: 59, y: 30, width: 2501, height: 1410),
             "the maximised window follows once the Dock has grown 5pt, got \(growing.windows[0].logDescription)")
    t.expect(growing.windows[1].minX, near: 59, "the window resting on the Dock follows it")
    t.expect(growing.windows[2] == floating, "a window away from the Dock is never touched")

    let roundTrip = simulate([54, 55, 56, 57, 58, 59, 60, 59, 58, 57, 56, 55, 54], windows: all)
    t.expect(roundTrip.windows == all,
             "out and back again leaves windows where they were, got \(roundTrip.windows.map(\.logDescription))")

    // The unlock: 11pt thinner for two seconds. The hold means it is never
    // seen; if it were, it would be one pass each way, not a creep.
    let unlock = simulate([52, 41, 52], windows: [CGRect(x: 52, y: 30, width: 2508, height: 1410)])
    t.expect(unlock.windows == [CGRect(x: 52, y: 30, width: 2508, height: 1410)],
             "there and back ends where it began, got \(unlock.windows.map(\.logDescription))")
}
