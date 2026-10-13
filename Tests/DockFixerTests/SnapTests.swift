import CoreGraphics
import DockFixerCore

// A laptop display, 1512x982, menu bar 33pt, Dock on the left 45pt.
private let visible = CGRect(x: 45, y: 33, width: 1467, height: 949)

/// A window a few points from the Dock is put against it; stretched when it
/// was maximised along that axis, slid otherwise.
func snapToDock(_ t: TestRun) {
    // Carried over from a display whose Dock was 58pt thick.
    let wide = CGRect(x: 58, y: 33, width: 1454, height: 949)
    let stretched = snappedToDock(wide, visible: visible, side: .left, within: 16)
    t.expect(stretched == visible, "a maximised window is stretched to the Dock, got \(stretched.logDescription)")

    let half = CGRect(x: 58, y: 33, width: 700, height: 949)
    let slid = snappedToDock(half, visible: visible, side: .left, within: 16)
    t.expect(slid == CGRect(x: 45, y: 33, width: 700, height: 949), "a half-width window slides, got \(slid.logDescription)")

    let far = CGRect(x: 62, y: 33, width: 700, height: 949)
    t.expect(snappedToDock(far, visible: visible, side: .left, within: 16) == far, "17pt away is where the user put it")

    let against = CGRect(x: 45, y: 33, width: 700, height: 949)
    t.expect(snappedToDock(against, visible: visible, side: .left, within: 16) == against, "already against the Dock")

    let under = CGRect(x: 40, y: 33, width: 700, height: 949)
    t.expect(snappedToDock(under, visible: visible, side: .left, within: 16) == under, "under the Dock is the clamp's job, not the snap's")

    // The other sides.
    let bottomVisible = CGRect(x: 0, y: 33, width: 1512, height: 876)
    let tall = CGRect(x: 100, y: 33, width: 800, height: 870)
    t.expect(snappedToDock(tall, visible: bottomVisible, side: .bottom, within: 16) == CGRect(x: 100, y: 33, width: 800, height: 876),
             "a window reaching the menu bar is stretched down to a bottom Dock")
    let short = CGRect(x: 100, y: 200, width: 800, height: 700)
    t.expect(snappedToDock(short, visible: bottomVisible, side: .bottom, within: 16) == CGRect(x: 100, y: 209, width: 800, height: 700),
             "a floating window slides down to a bottom Dock")
    let rightVisible = CGRect(x: 0, y: 33, width: 1467, height: 949)
    let nearRight = CGRect(x: 600, y: 33, width: 860, height: 949)
    t.expect(snappedToDock(nearRight, visible: rightVisible, side: .right, within: 16) == CGRect(x: 607, y: 33, width: 860, height: 949),
             "a window slides right to a right Dock")

    // Through computeFix, as the scanner uses it.
    let fix = computeFix(window: wide, visible: visible, reclaim: nil, slack: 0, snap: 16, dockSide: .left)
    t.expect(fix?.rect == visible, "computeFix snaps, got \(fix?.rect.logDescription ?? "nil")")
    t.expect(computeFix(window: far, visible: visible, reclaim: nil, slack: 0, snap: 16, dockSide: .left) == nil,
             "computeFix leaves a window 17pt away alone")
    t.expect(computeFix(window: wide, visible: visible, reclaim: nil, slack: 0, snap: 0, dockSide: .left) == nil,
             "no snap, no move")
    // Idempotent: the snapped window snaps to itself.
    let again = computeFix(window: fix!.rect, visible: visible, reclaim: nil, slack: 0, snap: 16, dockSide: .left)
    t.expect(again == nil, "snapping twice changes nothing")
}

func snapDockSide(_ t: TestRun) {
    let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    func screen(_ v: CGRect) -> ScreenInfo {
        ScreenInfo(displayID: 1, axFrame: frame, axVisibleFrame: v, isPrimary: true, localizedName: "Built-in")
    }
    t.expect(screen(visible).dockSide == .left, "left")
    t.expect(screen(CGRect(x: 0, y: 33, width: 1512, height: 876)).dockSide == .bottom, "bottom")
    t.expect(screen(CGRect(x: 0, y: 33, width: 1467, height: 949)).dockSide == .right, "right")
    t.expect(screen(CGRect(x: 0, y: 33, width: 1512, height: 949)).dockSide == nil, "hidden")
    t.expect(screen(visible).dockEdge == "left 45pt", "log form, got \(screen(visible).dockEdge)")
}
