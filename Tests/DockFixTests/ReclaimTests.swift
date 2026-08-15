import CoreGraphics
import DockFixCore

// Same reference screen as GeometryTests: 1000x800, 38pt menu bar, 55pt Dock.
// Here the Dock is *leaving*, so the "previous" visible frame is the narrow one
// and the "current" one has the Dock strip back.
private let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let withLeftDock = CGRect(x: 55, y: 38, width: 945, height: 762)
private let withRightDock = CGRect(x: 0, y: 38, width: 945, height: 762)
private let withBottomDock = CGRect(x: 0, y: 38, width: 1000, height: 700)
private let noDock = CGRect(x: 0, y: 38, width: 1000, height: 762)

private func info(_ frame: CGRect, _ visible: CGRect, id: CGDirectDisplayID = 1) -> ScreenInfo {
    ScreenInfo(displayID: id,
               axFrame: frame,
               axVisibleFrame: visible,
               isPrimary: id == 1,
               localizedName: "display-\(id)")
}

private func space(_ previous: CGRect, _ current: CGRect) -> ReclaimedSpace? {
    reclaimedSpace(previous: info(screenFrame, previous), current: info(screenFrame, current))
}

/// The space a departing Dock leaves behind is recognised, and only that.
func reclaimDetection(_ t: TestRun) {
    guard let left = space(withLeftDock, noDock) else {
        return t.fail("a left Dock leaving should be reclaimable")
    }
    t.expect(left.gainLeft, near: 55, "left gain")
    t.expect(left.gainRight, near: 0, "right gain")
    t.expect(left.gainBottom, near: 0, "bottom gain")
    t.expect(left.edgeDescription == "55pt on the left edge",
             "edge description, got \(left.edgeDescription)")

    guard let right = space(withRightDock, noDock) else {
        return t.fail("a right Dock leaving should be reclaimable")
    }
    t.expect(right.gainRight, near: 55, "right gain")
    t.expect(right.edgeDescription == "55pt on the right edge",
             "edge description, got \(right.edgeDescription)")

    guard let bottom = space(withBottomDock, noDock) else {
        return t.fail("a bottom Dock leaving should be reclaimable")
    }
    t.expect(bottom.gainBottom, near: 62, "bottom gain")

    // The Dock arriving is the ordinary computeFix case, not a reclaim.
    t.expect(space(noDock, withLeftDock) == nil, "a Dock arriving is not a reclaim")

    // A resolution switch makes the difference between visible frames
    // meaningless.
    let scaled = ScreenInfo(displayID: 1,
                            axFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                            axVisibleFrame: CGRect(x: 0, y: 38, width: 1440, height: 862),
                            isPrimary: true,
                            localizedName: "display-1")
    t.expect(reclaimedSpace(previous: info(screenFrame, withLeftDock), current: scaled) == nil,
             "a resolution change is not a reclaim")

    // The top inset is the menu bar, never the Dock.
    t.expect(space(CGRect(x: 0, y: 38, width: 1000, height: 762),
                   CGRect(x: 0, y: 0, width: 1000, height: 800)) == nil,
             "a menu bar disappearing is not a reclaim")

    // Rounding noise is not a Dock. A whole point is: that is how much the Dock
    // changes by when an application opens, and a window is pushed out of the
    // way for a single point of overlap, so it has to be given back the same
    // way. See reclaimTracksASmallDockChange.
    t.expect(space(CGRect(x: 0.25, y: 38, width: 999.75, height: 762), noDock) == nil,
             "a quarter-point difference is rounding, not a Dock")
    t.expect(space(CGRect(x: 1, y: 38, width: 999, height: 762), noDock) != nil,
             "a one-point difference is the Dock changing size")

    // One display gains, the other is untouched and absent from the result.
    let before = [info(screenFrame, withLeftDock, id: 1),
                  info(screenFrame, noDock, id: 2)]
    let after = [info(screenFrame, noDock, id: 1),
                 info(screenFrame, noDock, id: 2)]
    let map = reclaims(previous: before, current: after)
    t.expect(map.count == 1, "only the display that gained room is reported, got \(map.count)")
    t.expect(map[1] != nil, "display 1 gained room")

    // A display that was just plugged in has no "before" to compare against.
    let plugged = reclaims(previous: [info(screenFrame, withLeftDock, id: 1)], current: after)
    t.expect(plugged[2] == nil, "a newly attached display is not reclaimed against")
}

/// The real case this was written for: attaching a display that becomes the
/// primary one. The Dock leaves the built-in display, and every rect in
/// Accessibility space is renumbered at the same time because the origin moved
/// to the new primary. The built-in display has not changed shape, so its
/// freed strip must still be recognised.
func reclaimAcrossAPrimaryChange(_ t: TestRun) {
    // Built-in alone: it holds the origin, Dock on the left.
    let before = info(screenFrame, withLeftDock, id: 1)
    // Second display attached and made primary: the built-in now sits to the
    // right of and above the origin, and the Dock has gone with the primary.
    let offset = CGPoint(x: 1920, y: -800)
    let after = info(screenFrame.offsetBy(dx: offset.x, dy: offset.y),
                     noDock.offsetBy(dx: offset.x, dy: offset.y),
                     id: 1)

    guard let space = reclaimedSpace(previous: before, current: after) else {
        return t.fail("a Dock leaving is still a reclaim when the origin moves with it")
    }
    t.expect(space.gainLeft, near: 55, "left gain across a primary change")
    t.expect(space.gainRight, near: 0, "right gain across a primary change")
    t.expect(space.gainBottom, near: 0, "bottom gain across a primary change")

    // Windows are renumbered by exactly the same amount, so the geometry lands
    // where it would have without the primary change.
    let resting = CGRect(x: 55, y: 200, width: 300, height: 200).offsetBy(dx: offset.x, dy: offset.y)
    guard let fix = computeFix(window: resting, visible: after.axVisibleFrame, reclaim: space) else {
        return t.fail("a window resting against the departed Dock should follow it")
    }
    t.expect(fix.rect == CGRect(x: 0, y: 200, width: 300, height: 200).offsetBy(dx: offset.x, dy: offset.y),
             "expected a 55pt slide, got \(fix.rect.logDescription)")

    // A display that moved *and* changed resolution is still not comparable.
    let rescaled = info(CGRect(x: offset.x, y: offset.y, width: 1440, height: 900),
                        CGRect(x: offset.x, y: offset.y + 38, width: 1440, height: 862),
                        id: 1)
    t.expect(reclaimedSpace(previous: before, current: rescaled) == nil,
             "a resolution change is not a reclaim, wherever the display sits")
}

/// Maximised windows stretch into the freed strip; the rest slide into it.
func reclaimGeometry(_ t: TestRun) {
    guard let left = space(withLeftDock, noDock) else {
        return t.fail("left Dock reclaim missing")
    }

    // The screenshot case: a window filling the old usable width. It widens by
    // the Dock's thickness and its right edge does not move.
    let maximised = CGRect(x: 55, y: 38, width: 945, height: 762)
    guard let fix = computeFix(window: maximised, visible: noDock, reclaim: left) else {
        return t.fail("a maximised window should be stretched into the freed strip")
    }
    t.expect(fix.rect == noDock, "expected \(noDock.logDescription), got \(fix.rect.logDescription)")
    t.expect(fix.shift.dx, near: -55, "stretched window moves its left edge only")
    t.expect(fix.shrink.width, near: -55, "stretched window grows by the Dock width")
    t.expect(fix.logDetail == "shiftX=-55 growW=55",
             "a stretch reads as a grow, got \(fix.logDetail)")

    // Maximised on the Dock axis only — the height is irrelevant, so a window
    // full-width but half-height still stretches.
    let halfHeight = CGRect(x: 55, y: 38, width: 945, height: 300)
    guard let short = computeFix(window: halfHeight, visible: noDock, reclaim: left) else {
        return t.fail("width-maximised window should stretch regardless of its height")
    }
    t.expect(short.rect == CGRect(x: 0, y: 38, width: 1000, height: 300),
             "expected width-only stretch, got \(short.rect.logDescription)")

    // A window that was resting against the Dock — its left edge exactly the
    // Dock's width from the screen edge — slides across to rest against the
    // new edge, keeping its size.
    let resting = CGRect(x: 55, y: 200, width: 300, height: 200)
    guard let slid = computeFix(window: resting, visible: noDock, reclaim: left) else {
        return t.fail("a window resting against the Dock should follow it")
    }
    t.expect(slid.rect == CGRect(x: 0, y: 200, width: 300, height: 200),
             "expected a 55pt slide, got \(slid.rect.logDescription)")
    t.expect(slid.shrink == .zero, "a slide never resizes")

    // A right Dock frees the right edge, so the slide is the other way.
    guard let right = space(withRightDock, noDock),
          let slidRight = computeFix(window: CGRect(x: 645, y: 200, width: 300, height: 200),
                                     visible: noDock, reclaim: right) else {
        return t.fail("right Dock reclaim missing")
    }
    t.expect(slidRight.rect == CGRect(x: 700, y: 200, width: 300, height: 200),
             "expected a 55pt slide right, got \(slidRight.rect.logDescription)")

    // A bottom Dock frees the bottom edge: a window sitting on it drops, and a
    // full-height one grows downwards.
    guard let bottom = space(withBottomDock, noDock) else {
        return t.fail("bottom Dock reclaim missing")
    }
    guard let grown = computeFix(window: CGRect(x: 100, y: 38, width: 300, height: 700),
                                 visible: noDock, reclaim: bottom) else {
        return t.fail("a full-height window should stretch downwards")
    }
    t.expect(grown.rect == CGRect(x: 100, y: 38, width: 300, height: 762),
             "expected a downward stretch, got \(grown.rect.logDescription)")
    guard let dropped = computeFix(window: CGRect(x: 100, y: 538, width: 300, height: 200),
                                   visible: noDock, reclaim: bottom) else {
        return t.fail("a window sitting on the Dock should follow it down")
    }
    t.expect(dropped.rect == CGRect(x: 100, y: 600, width: 300, height: 200),
             "expected a 62pt slide down, got \(dropped.rect.logDescription)")

    // A window that overlapped the Dock strip was not being held by the edge,
    // and the strip is now free anyway, so there is nothing left to correct.
    t.expect(computeFix(window: CGRect(x: 12, y: 180, width: 200, height: 100),
                        visible: noDock, reclaim: left) == nil,
             "a window that overlapped the old Dock needs no correction once it is gone")
}

/// Applying the same reclaim twice must be a no-op.
///
/// The display-change trigger is not a promise of exactly one pass — a change
/// arriving mid-pass is queued and re-run — so a correction that moved a window
/// a second time would send it drifting. It settles because "was touching the
/// old edge" stops being true once the window has been moved to the new one.
func reclaimIdempotence(_ t: TestRun) {
    let spaces = [space(withLeftDock, noDock), space(withRightDock, noDock), space(withBottomDock, noDock)]
    // Every gain from a whole Dock down to the single point it changes by when
    // an application opens: the small ones are where a fixed "still touching"
    // tolerance stops being smaller than the gain and starts re-reclaiming.
    let narrowing: [ReclaimedSpace?] = [1, 2, 3, 7, 21].flatMap { gain -> [ReclaimedSpace?] in
        [space(CGRect(x: gain, y: 38, width: 1000 - gain, height: 762), noDock),
         space(CGRect(x: 0, y: 38, width: 1000 - gain, height: 762), noDock),
         space(CGRect(x: 0, y: 38, width: 1000, height: 762 - gain), noDock)]
    }
    let windows = [
        // Maximised, in each of the three orientations.
        CGRect(x: 55, y: 38, width: 945, height: 762),
        CGRect(x: 0, y: 38, width: 945, height: 762),
        CGRect(x: 0, y: 38, width: 1000, height: 700),
        // Resting against one edge or another.
        CGRect(x: 55, y: 300, width: 200, height: 150),
        CGRect(x: 745, y: 300, width: 200, height: 150),
        CGRect(x: 400, y: 538, width: 200, height: 200),
        // Free-floating, and overlapping the strip the Dock used to occupy.
        CGRect(x: 400, y: 300, width: 200, height: 150),
        CGRect(x: 12, y: 180, width: 200, height: 100),
        CGRect(x: -200, y: -100, width: 2000, height: 2000),
    ]
    for s in spaces + narrowing {
        guard let s else { return t.fail("reclaim missing") }
        for w in windows {
            guard let first = computeFix(window: w, visible: noDock, reclaim: s) else { continue }
            let second = computeFix(window: first.rect, visible: noDock, reclaim: s)
            t.expect(second == nil,
                     "second pass moved \(first.rect.logDescription) to \(second?.rect.logDescription ?? "nil")")
        }
    }
}

/// The Dock changing size by a point, which it does whenever an application
/// opens or quits, is corrected in both directions and only for the windows the
/// Dock was actually holding.
///
/// The failure this pins down was a ratchet. Pushing a window out from under a
/// Dock that grew has no threshold — a single point of overlap moves it — so a
/// reclaim that ignored small changes meant windows crept inwards a point at a
/// time and nothing ever gave the point back. Logged: 33 one-point pushes, not
/// one one-point return.
func reclaimTracksASmallDockChange(_ t: TestRun) {
    // Each case: the Dock's edge, then the same layout with the Dock one point
    // thinner, a window resting against it, and where that window belongs.
    let cases: [(name: String, before: CGRect, after: CGRect, window: CGRect, expected: CGRect)] = [
        ("left",
         CGRect(x: 52, y: 38, width: 948, height: 762),
         CGRect(x: 51, y: 38, width: 949, height: 762),
         CGRect(x: 52, y: 300, width: 300, height: 200),
         CGRect(x: 51, y: 300, width: 300, height: 200)),
        ("right",
         CGRect(x: 0, y: 38, width: 948, height: 762),
         CGRect(x: 0, y: 38, width: 949, height: 762),
         CGRect(x: 648, y: 300, width: 300, height: 200),
         CGRect(x: 649, y: 300, width: 300, height: 200)),
        ("bottom",
         CGRect(x: 0, y: 38, width: 1000, height: 700),
         CGRect(x: 0, y: 38, width: 1000, height: 701),
         CGRect(x: 100, y: 538, width: 300, height: 200),
         CGRect(x: 100, y: 539, width: 300, height: 200)),
    ]

    for c in cases {
        guard let space = space(c.before, c.after) else {
            return t.fail("a one-point \(c.name) Dock change should still be a reclaim")
        }

        guard let fix = computeFix(window: c.window, visible: c.after, reclaim: space) else {
            return t.fail("a window resting against the \(c.name) Dock should follow a one-point change")
        }
        t.expect(fix.rect == c.expected,
                 "\(c.name): expected \(c.expected.logDescription), got \(fix.rect.logDescription)")

        // And it stops there. With a gain this small the window ends up only a
        // point from where the old edge was, which is exactly the situation a
        // fixed 10pt "still touching" tolerance would misread as another window
        // to slide.
        t.expect(computeFix(window: fix.rect, visible: c.after, reclaim: space) == nil,
                 "\(c.name): a second pass moved the window again")

        // A maximised window grows into the point instead of sliding.
        let maximised = c.before
        guard let stretched = computeFix(window: maximised, visible: c.after, reclaim: space) else {
            return t.fail("\(c.name): a maximised window should grow into a one-point change")
        }
        t.expect(stretched.rect == c.after,
                 "\(c.name): expected \(c.after.logDescription), got \(stretched.rect.logDescription)")
        t.expect(computeFix(window: stretched.rect, visible: c.after, reclaim: space) == nil,
                 "\(c.name): a second pass stretched the window again")
    }

    // The other half of the ratchet, and the reason the tolerance has to shrink
    // with the change: a window the user parked a few points clear of the Dock
    // is not being held by it. Sliding it on every shrink while leaving it alone
    // on every growth would walk it across the screen.
    guard let small = space(CGRect(x: 52, y: 38, width: 948, height: 762),
                            CGRect(x: 51, y: 38, width: 949, height: 762)) else {
        return t.fail("one-point reclaim missing")
    }
    for gap in [CGFloat(3), 5, 8] {
        let parked = CGRect(x: 52 + gap, y: 300, width: 300, height: 200)
        let fix = computeFix(window: parked, visible: CGRect(x: 51, y: 38, width: 949, height: 762), reclaim: small)
        t.expect(fix == nil,
                 "a window \(Int(gap))pt clear of the Dock moved to \(fix?.rect.logDescription ?? "nil")")
    }
}

/// A window the Dock was not holding in place stays exactly where it is.
func reclaimLeavesFloatingWindowsAlone(_ t: TestRun) {
    let floating = [
        CGRect(x: 400, y: 300, width: 200, height: 150),
        CGRect(x: 200, y: 100, width: 300, height: 400),
        CGRect(x: 600, y: 400, width: 100, height: 100),
    ]
    for s in [space(withLeftDock, noDock), space(withRightDock, noDock), space(withBottomDock, noDock)] {
        guard let s else { return t.fail("reclaim missing") }
        for w in floating {
            let fix = computeFix(window: w, visible: noDock, reclaim: s)
            t.expect(fix == nil,
                     "\(w.logDescription) was not against the Dock but moved to \(fix?.rect.logDescription ?? "nil")")
        }
    }

    // A window touching an edge that did *not* free up is equally untouched:
    // with a left Dock, resting against the right screen edge means nothing.
    guard let left = space(withLeftDock, noDock) else { return t.fail("reclaim missing") }
    let againstTheFarEdge = CGRect(x: 800, y: 300, width: 200, height: 150)
    let fix = computeFix(window: againstTheFarEdge, visible: noDock, reclaim: left)
    t.expect(fix == nil, "the edge opposite the Dock is not a reason to move, got \(fix?.rect.logDescription ?? "nil")")
}

/// However a window is reclaimed, it still ends up inside the usable area.
func reclaimAlwaysInside(_ t: TestRun) {
    guard let s = space(withLeftDock, noDock) else { return t.fail("reclaim missing") }
    let step: CGFloat = 137
    for x in stride(from: CGFloat(-300), through: 1300, by: step) {
        for y in stride(from: CGFloat(-300), through: 1100, by: step) {
            for w in [CGFloat(50), 400, 945, 1400] {
                for h in [CGFloat(50), 300, 762, 1200] {
                    let win = CGRect(x: x, y: y, width: w, height: h)
                    guard let fix = computeFix(window: win, visible: noDock, reclaim: s) else { continue }
                    let r = fix.rect
                    let inside = r.minX >= noDock.minX - 0.01
                        && r.minY >= noDock.minY - 0.01
                        && r.maxX <= noDock.maxX + 0.01
                        && r.maxY <= noDock.maxY + 0.01
                    t.expect(inside, "\(win.logDescription) -> \(r.logDescription) escapes the usable area")
                }
            }
        }
    }
}
