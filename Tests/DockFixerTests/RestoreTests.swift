import CoreGraphics
import DockFixerCore

// A laptop display, 1512x982, menu bar 33pt, a full Dock on the left whose
// width changes with what is in it.
private let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)

private func layout(dock: CGFloat) -> [ScreenInfo] {
    [ScreenInfo(displayID: 1, axFrame: frame,
                axVisibleFrame: CGRect(x: dock, y: 33, width: 1512 - dock, height: 949),
                isPrimary: true, localizedName: "Built-in")]
}

/// Where a window lands when it is handed over: restored from the Dock with
/// the layout it was minimised in, or new, following nothing.
private func land(_ window: CGRect,
                  minimizedIn: [ScreenInfo]?,
                  now: [ScreenInfo],
                  follow: WindowScanner.Follow) -> CGRect {
    let following = WindowScanner.following(previous: minimizedIn, current: now, follow: follow)
    return WindowScanner.correction(for: window, on: now[0], following: following, slack: 0)?.rect ?? window
}

/// A window restored from the Dock is moved as a pass would have moved it
/// had it been on screen while the Dock changed: the case of 2026-10-17,
/// Chrome windows coming back at x=46 beside a Dock 43pt wide.
func restoredWindows(_ t: TestRun) {
    let stick: WindowScanner.Follow = .all

    // Minimised against a 46pt Dock, restored beside a 43pt one.
    let resting = CGRect(x: 46, y: 33, width: 700, height: 949)
    t.expect(land(resting, minimizedIn: layout(dock: 46), now: layout(dock: 43), follow: stick)
                == CGRect(x: 43, y: 33, width: 700, height: 949),
             "a window resting against the Dock comes back against it")

    let maximised = CGRect(x: 46, y: 33, width: 1466, height: 949)
    t.expect(land(maximised, minimizedIn: layout(dock: 46), now: layout(dock: 43), follow: stick)
                == CGRect(x: 43, y: 33, width: 1469, height: 949),
             "a maximised window is stretched back to the Dock")

    // The Dock grew while it was away.
    t.expect(land(resting, minimizedIn: layout(dock: 46), now: layout(dock: 50), follow: stick)
                == CGRect(x: 50, y: 33, width: 700, height: 949),
             "out from under a Dock that grew")
    t.expect(land(maximised, minimizedIn: layout(dock: 46), now: layout(dock: 50), follow: stick)
                == CGRect(x: 50, y: 33, width: 1462, height: 949),
             "a maximised window under a Dock that grew is moved and narrowed")

    // What the remembered layout buys over the magnet: a Dock that shrank
    // by more than the magnet reaches.
    let farFromNewEdge = CGRect(x: 76, y: 33, width: 700, height: 949)
    t.expect(land(farFromNewEdge, minimizedIn: layout(dock: 76), now: layout(dock: 43), follow: stick)
                == CGRect(x: 43, y: 33, width: 700, height: 949),
             "a Dock that shrank by 33pt is followed all the way")
    t.expect(land(farFromNewEdge, minimizedIn: nil, now: layout(dock: 43), follow: stick) == farFromNewEdge,
             "minimised before DockFixer ran: 33pt away is where the user put it")

    // Minimised before DockFixer ran: the magnet still closes a small gap.
    t.expect(land(resting, minimizedIn: nil, now: layout(dock: 43), follow: stick)
                == CGRect(x: 43, y: 33, width: 700, height: 949),
             "no layout, a 3pt gap: put against the Dock")

    // A window the user had put away from the Dock stays there.
    let floating = CGRect(x: 300, y: 120, width: 700, height: 600)
    t.expect(land(floating, minimizedIn: layout(dock: 46), now: layout(dock: 43), follow: stick) == floating,
             "a floating window is left where it was")

    // "Stick to the Dock" off: only the Dock's own space is cleared.
    t.expect(land(resting, minimizedIn: layout(dock: 46), now: layout(dock: 43), follow: []) == resting,
             "stick off: the gap stays")
    t.expect(land(resting, minimizedIn: layout(dock: 46), now: layout(dock: 50), follow: [])
                == CGRect(x: 50, y: 33, width: 700, height: 949),
             "stick off: still out from under the Dock")

    // Restored twice over the same change — a Dock pass right after — is
    // still one move.
    let once = land(resting, minimizedIn: layout(dock: 46), now: layout(dock: 43), follow: stick)
    t.expect(land(once, minimizedIn: layout(dock: 43), now: layout(dock: 43), follow: stick) == once,
             "a second look changes nothing")

    // A new window is unchanged by all this: it follows nothing.
    t.expect(land(resting, minimizedIn: nil, now: layout(dock: 43), follow: []) == resting,
             "a new window 3pt from the Dock is where its application put it")
}
