import CoreGraphics
import DockFixerCore

// A laptop display, 1512x982, and a 1920x1080 display to its right.
private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
private let displays = [laptop, external]

// A maximised window beside a 43pt Dock on the left, under a 33pt menu bar.
private let maximised = CGRect(x: 43, y: 33, width: 1469, height: 949)

/// Whether some part of a window is left uncovered by the windows in front.
func visibilityUncovered(_ t: TestRun) {
    func seen(_ window: CGRect, _ front: [CGRect]) -> Bool {
        Visibility.isPartlyUncovered(window, by: front, on: displays)
    }

    t.expect(seen(maximised, []), "nothing in front: in sight")

    t.expect(!seen(maximised, [maximised]), "a window of the same size in front covers it fully")
    t.expect(!seen(CGRect(x: 200, y: 200, width: 400, height: 300), [maximised]),
             "a small window under a maximised one is covered")

    t.expect(seen(maximised, [CGRect(x: 43, y: 33, width: 700, height: 949)]),
             "a half-width window in front leaves the other half")
    t.expect(seen(maximised, [CGRect(x: 300, y: 300, width: 400, height: 300)]),
             "a small window in the middle leaves the edges")

    // Two halves side by side, then three strips: covered together, by none alone.
    let left = CGRect(x: 43, y: 33, width: 735, height: 949)
    let right = CGRect(x: 778, y: 33, width: 734, height: 949)
    t.expect(seen(maximised, [left]) && seen(maximised, [right]), "either half alone leaves the other")
    t.expect(!seen(maximised, [left, right]), "the two halves together cover it")
    t.expect(!seen(maximised, [right, left]), "in either order")
    let top = CGRect(x: 0, y: 33, width: 1512, height: 300)
    let middle = CGRect(x: 0, y: 333, width: 900, height: 649)
    let corner = CGRect(x: 900, y: 333, width: 612, height: 649)
    t.expect(!seen(maximised, [middle, top, corner]), "three overlapping windows cover it together")
    let gapped = CGRect(x: 910, y: 333, width: 602, height: 649)
    t.expect(seen(maximised, [middle, top, gapped]), "a 10pt gap between them is in sight")

    // A window in front on the other display is no cover at all.
    let onExternal = CGRect(x: 1512 + 43, y: 33, width: 1469, height: 949)
    t.expect(seen(maximised, [onExternal]), "a window on the other display does not cover")
    t.expect(seen(onExternal, [maximised]), "nor the other way round")
    t.expect(!seen(onExternal, [CGRect(x: 1512, y: 0, width: 1920, height: 1080)]),
             "a window filling the other display covers one there")

    // Edges that only touch.
    t.expect(seen(maximised, [CGRect(x: 0, y: 0, width: 43, height: 982)]),
             "a window that only touches its left edge covers nothing")
    t.expect(seen(maximised, [CGRect(x: 0, y: 0, width: 1512, height: 33)]),
             "nor one that only touches its top edge")
    t.expect(!seen(maximised, [CGRect(x: 43, y: 33, width: 700, height: 949),
                               CGRect(x: 743, y: 33, width: 769, height: 949)]),
             "two windows meeting edge to edge cover it")

    // Slivers: a point or two left by a window rounding its size is not a window seen.
    t.expect(!seen(maximised, [CGRect(x: 44, y: 33, width: 1468, height: 949)]),
             "a 1pt strip left along the edge does not count")
    t.expect(seen(maximised, [CGRect(x: 46, y: 33, width: 1466, height: 949)]),
             "a 3pt strip does")

    // Only what is on a display can be seen.
    t.expect(!seen(CGRect(x: -2000, y: 100, width: 800, height: 600), []),
             "a window off every display is not in sight")
    t.expect(seen(CGRect(x: -400, y: 100, width: 800, height: 600), []),
             "half off the display, the other half is in sight")
    t.expect(!seen(CGRect(x: -400, y: 100, width: 800, height: 600), [CGRect(x: 0, y: 100, width: 400, height: 600)]),
             "half off the display and the other half covered: not in sight")
    t.expect(!Visibility.isPartlyUncovered(maximised, by: [], on: []), "with no displays nothing is in sight")
}

/// Which windows in the window server's list count as covering.
func visibilityStack(_ t: TestRun) {
    let menuBar = StackedWindow(pid: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 33), layer: 24)
    let dock = StackedWindow(pid: 2, bounds: laptop, layer: 20)
    let chrome = StackedWindow(pid: 10, bounds: maximised)
    let safari = StackedWindow(pid: 11, bounds: maximised)

    t.expect(Visibility.isPartlyVisible(at: 2, in: [menuBar, dock, chrome], displays: displays),
             "the menu bar and the Dock in front do not cover a window")
    t.expect(!Visibility.isPartlyVisible(at: 3, in: [menuBar, dock, chrome, safari], displays: displays),
             "an ordinary window in front does")
    t.expect(Visibility.isPartlyVisible(at: 2, in: [menuBar, dock, chrome, safari], displays: displays),
             "a window behind it does not")

    let panel = StackedWindow(pid: 12, bounds: maximised, layer: 3)
    t.expect(Visibility.isPartlyVisible(at: 1, in: [panel, chrome], displays: displays),
             "a floating panel is not counted as cover")
    let invisible = StackedWindow(pid: 13, bounds: laptop, alpha: 0)
    t.expect(Visibility.isPartlyVisible(at: 1, in: [invisible, chrome], displays: displays),
             "a fully transparent window is not cover")

    t.expect(!Visibility.isPartlyVisible(at: 5, in: [chrome], displays: displays),
             "a window not in the list is not in sight")
}

/// Windows matched to the window server's list by owner and bounds.
func visibilityMatching(_ t: TestRun) {
    let stack = [
        StackedWindow(pid: 10, bounds: maximised),
        StackedWindow(pid: 11, bounds: maximised),
        StackedWindow(pid: 10, bounds: maximised),
        StackedWindow(pid: 10, bounds: CGRect(x: 43, y: 33, width: 700, height: 949)),
    ]

    let found = Visibility.match([(10, maximised), (10, maximised), (10, maximised)], in: stack)
    t.expect(found == [0, 2, nil], "twins take one entry each, the third is not on screen — got \(found)")

    t.expect(Visibility.match([(11, maximised)], in: stack) == [1], "the owner decides between equal bounds")
    t.expect(Visibility.match([(10, CGRect(x: 44, y: 34, width: 699, height: 948))], in: stack) == [3],
             "a point or two off still matches")
    t.expect(Visibility.match([(10, CGRect(x: 46, y: 33, width: 700, height: 949))], in: stack) == [nil],
             "three points off does not")
    t.expect(Visibility.match([(12, maximised)], in: stack) == [nil], "another application's window does not")

    // The case the rule is for: one Dock change moves every maximised window,
    // and only the frontmost of them was in sight.
    let windows: [(pid: pid_t, frame: CGRect)] = [(10, maximised), (11, maximised), (10, maximised)]
    let counted = Visibility.match(windows, in: stack).filter { index in
        index.map { Visibility.isPartlyVisible(at: $0, in: stack, displays: displays) } ?? false
    }
    t.expect(counted.count == 1, "of three maximised windows one is counted, got \(counted.count)")
}
