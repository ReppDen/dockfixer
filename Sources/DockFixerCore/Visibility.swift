import CoreGraphics

/// One window as the window server lists it: front to back, with its owner,
/// its bounds and the layer it sits in. Everything here is given freely, with
/// no Screen Recording access; only titles and contents are not.
///
/// Bounds are in the window server's global space, which is the
/// Accessibility one: origin at the top-left of the primary display, y down.
public struct StackedWindow: Equatable, Sendable {
    public let pid: pid_t
    public let bounds: CGRect
    /// 0 for ordinary application windows. The menu bar, the Dock, floating
    /// panels and the system's overlays all sit in layers of their own.
    public let layer: Int
    public let alpha: CGFloat

    public init(pid: pid_t, bounds: CGRect, layer: Int = 0, alpha: CGFloat = 1) {
        self.pid = pid
        self.bounds = bounds
        self.layer = layer
        self.alpha = alpha
    }
}

/// Whether the user could see a window, for the usage statistics.
///
/// A full Dock changes width by a point every time an application opens or
/// quits, and every pass after that moves every maximised window and every
/// window resting against the Dock — twenty or forty of them on a busy Mac,
/// one or two of which are in sight. The statistics are meant to say what
/// DockFixer did for the person at the computer, so a move counts only when
/// some part of the window was on show: not entirely covered by the windows
/// in front of it, on a display, on the Space being shown. The log still
/// names every window moved.
///
/// Pure: the stacking order is read by the scanner and handed in.
public enum Visibility {

    /// A strip of window narrower than this, left uncovered, is not a window
    /// anyone saw. Two maximised windows of different applications can end a
    /// point apart, because one rounds its size to its own grid, and the
    /// window behind would otherwise count for the line of pixels along its
    /// edge. The same tolerance as a window that "landed" where it was sent.
    public static let sliver: CGFloat = 2

    /// Whether any part of `window` that lies on one of `displays` is left
    /// uncovered by `front`, the windows in front of it.
    ///
    /// The window is cut into the pieces each covering window leaves, one
    /// covering window at a time, so a window covered by several windows
    /// together, though by none of them alone, comes out covered. A covering
    /// window that only touches an edge covers nothing.
    public static func isPartlyUncovered(_ window: CGRect,
                                         by front: [CGRect],
                                         on displays: [CGRect]) -> Bool {
        // Only what lies on a display can be seen. Displays do not overlap,
        // so the pieces start as the window's share of each.
        var pieces = displays.compactMap { display -> CGRect? in
            let share = window.intersection(display)
            return isSeeable(share) ? share : nil
        }
        for cover in front {
            pieces = pieces.flatMap { subtract(cover, from: $0) }
            if pieces.isEmpty { return false }
        }
        return !pieces.isEmpty
    }

    /// Whether the window at `index` in `stack` is partly visible: only
    /// ordinary windows in front of it cover it. The menu bar and the Dock
    /// are in front of everything and in a layer of their own, and a window
    /// under them is the very thing being moved; floating panels are small
    /// and come and go. A fully transparent window covers nothing.
    public static func isPartlyVisible(at index: Int,
                                       in stack: [StackedWindow],
                                       displays: [CGRect]) -> Bool {
        guard stack.indices.contains(index) else { return false }
        let front = stack[..<index]
            .filter { $0.layer == 0 && $0.alpha > 0 }
            .map(\.bounds)
        return isPartlyUncovered(stack[index].bounds, by: front, on: displays)
    }

    /// Where each window sits in `stack`, matched by owner and bounds, or
    /// `nil` when it is not on screen: minimised, on another Space, or not
    /// yet shown.
    ///
    /// Each entry of the stack goes to one window only, in the order the
    /// windows are given. Two maximised windows of one application have the
    /// same owner and the same bounds and cannot be told apart; matched
    /// independently, both would take the front one and both would count as
    /// seen. Claimed one each, one of them is the front entry and the other
    /// is behind it — which one is which does not matter to a count, and
    /// the write order only puts one ahead of its twin.
    public static func match(_ windows: [(pid: pid_t, frame: CGRect)],
                             in stack: [StackedWindow],
                             tolerance: CGFloat = sliver) -> [Int?] {
        var claimed = Set<Int>()
        return windows.map { window in
            let found = stack.indices.first { index in
                !claimed.contains(index)
                    && stack[index].pid == window.pid
                    && stack[index].bounds.isClose(to: window.frame, tolerance: tolerance)
            }
            if let found { claimed.insert(found) }
            return found
        }
    }

    /// What is left of `piece` once `cover` is taken out: up to four rects,
    /// the bands above and below the cut across the whole width, and the two
    /// sides beside it. Strips too thin to be seen are dropped as they come.
    static func subtract(_ cover: CGRect, from piece: CGRect) -> [CGRect] {
        let cut = piece.intersection(cover)
        guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [piece] }
        let rest = [
            CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY),
            CGRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY),
            CGRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height),
            CGRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height),
        ]
        return rest.filter(isSeeable)
    }

    private static func isSeeable(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.width >= sliver && rect.height >= sliver
    }
}

extension CGRect {
    /// Within `tolerance` points on every edge: how a window read back through
    /// Accessibility is compared with where it was sent, and with what the
    /// window server lists.
    func isClose(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
