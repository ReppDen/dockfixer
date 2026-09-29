import CoreGraphics
import DockFixerCore

// All coordinates are in Accessibility space: origin top-left of the primary
// display, y growing downwards.
//
// The reference screen is 1000x800 with a 38pt menu bar and a 55pt Dock on the
// left, which is the configuration this tool was written for.
private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let visibleLeftDock = CGRect(x: 55, y: 38, width: 945, height: 762)

private struct Case {
    let name: String
    let window: CGRect
    let visible: CGRect
    let expected: CGRect?
    var expectedShift: CGVector?
    var expectedShrink: CGSize?
    var expectedClamped: Bool = false
}

func geometryTable(_ t: TestRun) {
    let cases: [Case] = [
        Case(name: "already inside — untouched",
             window: CGRect(x: 100, y: 100, width: 400, height: 300),
             visible: visibleLeftDock,
             expected: nil),

        Case(name: "flush against both usable edges — untouched",
             window: CGRect(x: 55, y: 38, width: 945, height: 762),
             visible: visibleLeftDock,
             expected: nil),

        // The case from the bug report: window partly under a left Dock, narrow
        // enough that it fits once nudged. The shift is the actual overlap (43),
        // not the Dock width (55).
        Case(name: "partly under left Dock, fits — shift only",
             window: CGRect(x: 12, y: 180, width: 200, height: 100),
             visible: visibleLeftDock,
             expected: CGRect(x: 55, y: 180, width: 200, height: 100),
             expectedShift: CGVector(dx: 43, dy: 0),
             expectedShrink: .zero),

        // Full-width window: nudging alone would push the right edge off-screen,
        // so it narrows too — by exactly the shift amount.
        Case(name: "full-width under left Dock — shift equals shrink",
             window: CGRect(x: 0, y: 38, width: 1000, height: 762),
             visible: visibleLeftDock,
             expected: CGRect(x: 55, y: 38, width: 945, height: 762),
             expectedShift: CGVector(dx: 55, dy: 0),
             expectedShrink: CGSize(width: 55, height: 0),
             expectedClamped: true),

        Case(name: "under the menu bar — pushed down",
             window: CGRect(x: 100, y: 0, width: 300, height: 200),
             visible: visibleLeftDock,
             expected: CGRect(x: 100, y: 38, width: 300, height: 200),
             expectedShift: CGVector(dx: 0, dy: 38),
             expectedShrink: .zero),

        Case(name: "hanging off the right edge — pulled left",
             window: CGRect(x: 900, y: 100, width: 300, height: 100),
             visible: visibleLeftDock,
             expected: CGRect(x: 700, y: 100, width: 300, height: 100),
             expectedShift: CGVector(dx: -200, dy: 0),
             expectedShrink: .zero),

        // Dock moved to the bottom — same code path, no orientation logic.
        Case(name: "bottom Dock — pulled up",
             window: CGRect(x: 100, y: 600, width: 200, height: 200),
             visible: CGRect(x: 0, y: 38, width: 1000, height: 700),
             expected: CGRect(x: 100, y: 538, width: 200, height: 200),
             expectedShift: CGVector(dx: 0, dy: -62),
             expectedShrink: .zero),

        // Dock moved to the right.
        Case(name: "right Dock — pulled left",
             window: CGRect(x: 700, y: 100, width: 300, height: 200),
             visible: CGRect(x: 0, y: 38, width: 945, height: 762),
             expected: CGRect(x: 645, y: 100, width: 300, height: 200),
             expectedShift: CGVector(dx: -55, dy: 0),
             expectedShrink: .zero),

        Case(name: "bigger than usable on both axes — sized to fit",
             window: CGRect(x: -200, y: -100, width: 2000, height: 2000),
             visible: visibleLeftDock,
             expected: visibleLeftDock,
             expectedClamped: true),

        // Auto-hidden Dock: visibleFrame reclaims the Dock strip, so a window
        // sitting over where the Dock used to be is left alone.
        Case(name: "auto-hidden Dock — nothing to do",
             window: CGRect(x: 0, y: 38, width: 1000, height: 762),
             visible: CGRect(x: 0, y: 38, width: 1000, height: 762),
             expected: nil),

        Case(name: "sub-pixel overlap below tolerance — untouched",
             window: CGRect(x: 54.7, y: 38, width: 200, height: 100),
             visible: visibleLeftDock,
             expected: nil),

        // An external display placed to the left of the built-in one gets a
        // negative x origin in global space.
        Case(name: "negative-origin display — still corrected",
             window: CGRect(x: -1930, y: 100, width: 500, height: 300),
             visible: CGRect(x: -1920, y: 25, width: 1865, height: 1055),
             expected: CGRect(x: -1920, y: 100, width: 500, height: 300),
             expectedShift: CGVector(dx: 10, dy: 0),
             expectedShrink: .zero),

        Case(name: "zero-size window — ignored",
             window: CGRect(x: 0, y: 0, width: 0, height: 0),
             visible: visibleLeftDock,
             expected: nil),
    ]

    for c in cases {
        let fix = computeFix(window: c.window, visible: c.visible)

        guard let expected = c.expected else {
            t.expect(fix == nil, "\(c.name): expected no correction, got \(fix?.rect.logDescription ?? "nil")")
            continue
        }
        guard let fix else {
            t.fail("\(c.name): expected \(expected.logDescription), got no correction")
            continue
        }

        t.expect(fix.rect == expected,
                 "\(c.name): expected \(expected.logDescription), got \(fix.rect.logDescription)")
        t.expect(fix.clamped == c.expectedClamped, "\(c.name): clamped should be \(c.expectedClamped)")
        if let shift = c.expectedShift {
            t.expect(fix.shift.dx, near: shift.dx, "\(c.name): shift.dx")
            t.expect(fix.shift.dy, near: shift.dy, "\(c.name): shift.dy")
        }
        if let shrink = c.expectedShrink {
            t.expect(fix.shrink.width, near: shrink.width, "\(c.name): shrink.width")
            t.expect(fix.shrink.height, near: shrink.height, "\(c.name): shrink.height")
        }
    }
}

/// A corrected window must never need a second correction — otherwise the
/// display-change trigger could shuffle windows on every event.
func geometryIdempotence(_ t: TestRun) {
    let windows = [
        CGRect(x: 0, y: 38, width: 1000, height: 762),
        CGRect(x: 12, y: 180, width: 200, height: 100),
        CGRect(x: -200, y: -100, width: 2000, height: 2000),
        CGRect(x: 900, y: 700, width: 400, height: 400),
    ]
    for w in windows {
        guard let first = computeFix(window: w, visible: visibleLeftDock) else { continue }
        let second = computeFix(window: first.rect, visible: visibleLeftDock)
        t.expect(second == nil,
                 "second pass changed \(first.rect.logDescription) to \(second?.rect.logDescription ?? "nil")")
    }
}

/// Whatever the input, the result lands inside the usable area — and a window
/// left uncorrected was already inside it.
func geometryAlwaysInside(_ t: TestRun) {
    let step: CGFloat = 137
    for x in stride(from: CGFloat(-300), through: 1300, by: step) {
        for y in stride(from: CGFloat(-300), through: 1100, by: step) {
            for w in [CGFloat(50), 400, 945, 1400] {
                for h in [CGFloat(50), 300, 762, 1200] {
                    let win = CGRect(x: x, y: y, width: w, height: h)
                    guard let fix = computeFix(window: win, visible: visibleLeftDock) else {
                        t.expect(visibleLeftDock.insetBy(dx: -0.5, dy: -0.5).contains(win),
                                 "no correction but \(win.logDescription) is outside the usable area")
                        continue
                    }
                    let r = fix.rect
                    let inside = r.minX >= visibleLeftDock.minX - 0.01
                        && r.minY >= visibleLeftDock.minY - 0.01
                        && r.maxX <= visibleLeftDock.maxX + 0.01
                        && r.maxY <= visibleLeftDock.maxY + 0.01
                    t.expect(inside, "\(win.logDescription) -> \(r.logDescription) escapes the usable area")
                }
            }
        }
    }
}

func geometryLogFormatting(_ t: TestRun) {
    t.expect(CGRect(x: 12, y: 180, width: 1400, height: 900).logDescription == "(12,180 1400x900)",
             "compact rect formatting")
    t.expect(CGRect(x: 0.5, y: 0, width: 10, height: 10).logDescription == "(0.5,0 10x10)",
             "fractional rect formatting")

    let fix = computeFix(window: CGRect(x: 0, y: 38, width: 1000, height: 762), visible: visibleLeftDock)
    t.expect(fix?.logDetail == "shiftX=55 shrinkW=55 clamped",
             "fix detail formatting, got \(fix?.logDetail ?? "nil")")

    // Guards the assumption behind visibleLeftDock: the usable area is the
    // screen minus a 55pt left Dock and a 38pt menu bar.
    t.expect(visibleLeftDock.maxX == screen.maxX, "reference usable area reaches the right screen edge")
    t.expect(visibleLeftDock.maxY == screen.maxY, "reference usable area reaches the bottom screen edge")
}
