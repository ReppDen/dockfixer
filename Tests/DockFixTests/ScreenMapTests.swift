import CoreGraphics
import DockFixCore

// Only the pure parts are covered here: converting between Cocoa's bottom-left
// origin and the Accessibility API's top-left origin, and picking the display a
// window belongs to. `ScreenMap.current()` needs a real display configuration
// and is exercised by the manual checks in the README.

private func info(id: CGDirectDisplayID,
                  frame: CGRect,
                  visible: CGRect,
                  primary: Bool = false) -> ScreenInfo {
    ScreenInfo(displayID: id,
               axFrame: frame,
               axVisibleFrame: visible,
               isPrimary: primary,
               localizedName: "display-\(id)")
}

func screenMapConversion(_ t: TestRun) {
    // A 1000x800 primary display. A window 100pt tall sitting 38pt below the
    // top in Cocoa space has its *bottom* at y=662 counting up from the bottom.
    let primaryHeight: CGFloat = 800
    let cocoa = CGRect(x: 55, y: 662, width: 200, height: 100)
    let ax = flipVertically(cocoa, primaryHeight: primaryHeight)

    t.expect(ax == CGRect(x: 55, y: 38, width: 200, height: 100),
             "cocoa -> ax conversion, got \(ax.logDescription)")

    // The transform is its own inverse — that property is what lets the same
    // function be used when writing positions back.
    let roundTrip = flipVertically(ax, primaryHeight: primaryHeight)
    t.expect(roundTrip == cocoa, "conversion round-trips, got \(roundTrip.logDescription)")

    // A display stacked above the primary one has positive y in Cocoa space and
    // negative y in Accessibility space.
    let above = CGRect(x: 0, y: 800, width: 1000, height: 600)
    let aboveAX = flipVertically(above, primaryHeight: primaryHeight)
    t.expect(aboveAX == CGRect(x: 0, y: -600, width: 1000, height: 600),
             "display above primary gets negative ax y, got \(aboveAX.logDescription)")

    // Menu bar and Dock insets, and the edge inferred from them.
    let leftDock = info(id: 1,
                        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                        visible: CGRect(x: 55, y: 38, width: 945, height: 762),
                        primary: true)
    t.expect(leftDock.insets.left, near: 55, "left inset")
    t.expect(leftDock.insets.top, near: 38, "top inset (menu bar)")
    t.expect(leftDock.insets.bottom, near: 0, "bottom inset")
    t.expect(leftDock.insets.right, near: 0, "right inset")
    t.expect(leftDock.dockEdge == "left 55pt", "dock edge, got \(leftDock.dockEdge)")

    let bottomDock = info(id: 2,
                          frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                          visible: CGRect(x: 0, y: 38, width: 1000, height: 700))
    t.expect(bottomDock.dockEdge == "bottom 62pt", "bottom dock edge, got \(bottomDock.dockEdge)")

    // Auto-hidden Dock leaves only the menu bar inset.
    let hiddenDock = info(id: 3,
                          frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                          visible: CGRect(x: 0, y: 38, width: 1000, height: 762))
    t.expect(hiddenDock.dockEdge == "hidden", "auto-hidden dock, got \(hiddenDock.dockEdge)")

    // Display selection: built-in primary plus an external display to its left.
    let builtIn = leftDock
    let external = info(id: 9,
                        frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                        visible: CGRect(x: -1920, y: 25, width: 1920, height: 1055))
    let screens = [builtIn, external]

    let onBuiltIn = ScreenMap.screen(for: CGRect(x: 100, y: 100, width: 200, height: 200), in: screens)
    t.expect(onBuiltIn?.displayID == 1, "window inside primary picks primary")

    let onExternal = ScreenMap.screen(for: CGRect(x: -1000, y: 100, width: 200, height: 200), in: screens)
    t.expect(onExternal?.displayID == 9, "window inside external picks external")

    // Straddling: 150pt on the external, 50pt on the built-in.
    let straddling = ScreenMap.screen(for: CGRect(x: -150, y: 100, width: 200, height: 200), in: screens)
    t.expect(straddling?.displayID == 9, "straddling window picks the larger overlap")

    // Fully off-screen — the situation right after an unplug. Must still resolve
    // to a display, otherwise the window would never be rescued.
    let orphan = ScreenMap.screen(for: CGRect(x: 5000, y: 5000, width: 200, height: 200), in: screens)
    t.expect(orphan?.displayID == 1, "off-screen window falls back to primary")

    t.expect(ScreenMap.screen(for: .zero, in: []) == nil, "no displays yields nil")

    // Fingerprint is order-independent and reacts to a Dock move.
    let a = ScreenMap.fingerprint([builtIn, external])
    let b = ScreenMap.fingerprint([external, builtIn])
    t.expect(a == b, "fingerprint ignores enumeration order")

    let dockMoved = info(id: 1,
                         frame: builtIn.axFrame,
                         visible: CGRect(x: 0, y: 38, width: 1000, height: 700),
                         primary: true)
    t.expect(ScreenMap.fingerprint([dockMoved, external]) != a, "fingerprint reacts to a Dock move")
    t.expect(ScreenMap.fingerprint([builtIn]) != a, "fingerprint reacts to an unplugged display")
}
