import CoreGraphics

/// Usable area a display regained, in Accessibility coordinate space.
///
/// The case this exists for: plugging in a second display makes the Dock jump
/// to it, so the display it left grows its visible frame by the Dock's
/// thickness. Windows do not follow, and a strip of wallpaper exactly that wide
/// is left behind.
///
/// As everywhere else in DockFixer the Dock is never asked where it is or how big
/// it was — the reclaimed space is the difference between the display's old and
/// new visible frames.
public struct ReclaimedSpace: Equatable, Sendable {
    /// The usable area before the change.
    public let previousVisible: CGRect
    /// The usable area now.
    public let visible: CGRect

    public init(previousVisible: CGRect, visible: CGRect) {
        self.previousVisible = previousVisible
        self.visible = visible
    }

    public var gainLeft: CGFloat { previousVisible.minX - visible.minX }
    public var gainRight: CGFloat { visible.maxX - previousVisible.maxX }
    /// In Accessibility space y grows downwards, so the bottom edge is `maxY`.
    public var gainBottom: CGFloat { visible.maxY - previousVisible.maxY }

    /// Which edge freed up, for the log. Mirrors `ScreenInfo.dockEdge`.
    public var edgeDescription: String {
        let candidates = [("left", gainLeft), ("right", gainRight), ("bottom", gainBottom)]
        guard let winner = candidates.max(by: { $0.1 < $1.1 }) else { return "no edge" }
        return "\(Int(winner.1.rounded()))pt on the \(winner.0) edge"
    }
}

/// Gains smaller than this are noise — a rounding difference, not a Dock.
///
/// Low on purpose. The Dock grows and shrinks by a point at a time as
/// applications open and quit, and pushing a window out of the way has no
/// threshold at all — a single point of overlap moves it. A higher floor here
/// made the two directions disagree, and windows ratcheted inwards: every
/// growth nudged them, no shrink ever gave the point back.
public let minimumGainDefault: CGFloat = 0.5
/// Edges within this distance of each other count as touching.
private let edgeEpsilon: CGFloat = 0.5

/// The space `current` regained compared to `previous`, or `nil` if there is
/// none to reclaim.
///
/// Deliberately conservative. It returns `nil` when:
///
/// - the display's size changed — a resolution switch scales everything, so a
///   difference in visible frames says nothing about the Dock;
/// - the top edge *lost* room — a menu bar appeared, and nothing about the Dock
///   can be read from that;
/// - no Dock edge gained — that is only the Dock arriving, which the ordinary
///   `computeFix` path already handles;
/// - only the top edge gained — the top inset is the menu bar, never the Dock,
///   the same reasoning as in `ScreenInfo.dockEdge`.
public func reclaimedSpace(previous: ScreenInfo,
                           current: ScreenInfo,
                           minimumGain: CGFloat = minimumGainDefault) -> ReclaimedSpace? {
    guard previous.axFrame.size == current.axFrame.size else { return nil }

    // The display may read at different coordinates than it did before without
    // having moved an inch: Accessibility space is anchored to the top-left of
    // the *primary* display, and attaching a display often makes it the primary
    // one. Every rect in the space then shifts by the same amount — windows
    // included — so the old visible frame is brought forward by however far its
    // own display's bounds moved, and the comparison stays in the space the
    // windows are read in now. Only the size has to match: a resolution switch
    // scales everything and says nothing about the Dock.
    let previousVisible = previous.axVisibleFrame
        .offsetBy(dx: current.axFrame.minX - previous.axFrame.minX,
                  dy: current.axFrame.minY - previous.axFrame.minY)

    let space = ReclaimedSpace(previousVisible: previousVisible,
                               visible: current.axVisibleFrame)
    let gainTop = space.previousVisible.minY - space.visible.minY

    // A menu bar that appeared means this is not about the Dock.
    guard gainTop >= -edgeEpsilon else { return nil }

    // Dock edges may lose room at the same time as another one gains: that is
    // the Dock moving from one edge to another. It used to rule the reclaim
    // out, and windows left against the old edge stayed there with a gap
    // beside them. Each axis is reclaimed on its own terms (`reclaimAxis`
    // leaves an end that lost room alone) and the edge that lost room is
    // cleared the usual way, by `computeFix`.

    // The top edge is the menu bar and never counts as reclaimable on its own.
    let dockGains = [space.gainLeft, space.gainRight, space.gainBottom]
    guard dockGains.contains(where: { $0 > minimumGain }) else { return nil }

    return space
}

/// Per-display reclaimed space, keyed by display ID.
///
/// Displays present on only one side of the change are dropped: a display that
/// was just plugged in has no "before", and one that was unplugged has no
/// "after".
public func reclaims(previous: [ScreenInfo],
                     current: [ScreenInfo],
                     minimumGain: CGFloat = minimumGainDefault) -> [CGDirectDisplayID: ReclaimedSpace] {
    var before: [CGDirectDisplayID: ScreenInfo] = [:]
    for screen in previous { before[screen.displayID] = screen }

    var result: [CGDirectDisplayID: ReclaimedSpace] = [:]
    for screen in current {
        guard let old = before[screen.displayID],
              let space = reclaimedSpace(previous: old, current: screen, minimumGain: minimumGain)
        else { continue }
        result[screen.displayID] = space
    }
    return result
}

/// Result of reclaiming one axis.
private struct AxisReclaim {
    var position: CGFloat
    var length: CGFloat
}

/// Reclaims one axis of a window.
///
/// Everything hangs off one observation: a window that was touching an edge of
/// the old usable area was being held there *by* that edge. That is a fact
/// about the window's geometry, so it can be checked rather than assumed:
///
/// - Touching both ends — it was maximised along this axis. Stretch it to the
///   new extent, which is what closes the gap.
/// - Touching only the end that freed up — it was resting against the Dock.
///   Slide it by the amount freed so it rests against the new edge instead.
/// - Touching neither — it was sitting where the user put it, nothing to do.
///
/// This is also what makes the correction idempotent, and idempotence is not a
/// nicety here: the same display change can reach the scanner more than once.
/// After the correction the window touches the *new* edge and is a full Dock's
/// width away from the old one, so the tests above no longer hold and a second
/// pass leaves it alone. An unconditional "slide everything by the amount
/// freed" would have no such stopping condition.
///
/// `gainLow`/`gainHigh` are how much each end of the axis moved outwards; for
/// the vertical axis `gainLow` is always zero because the top edge is the menu
/// bar, not the Dock.
private func reclaimAxis(position: CGFloat,
                         length: CGFloat,
                         previousLow: CGFloat,
                         previousHigh: CGFloat,
                         low: CGFloat,
                         high: CGFloat,
                         gainLow: CGFloat,
                         gainHigh: CGFloat,
                         tolerance: CGFloat) -> AxisReclaim {
    // An axis that gained nothing is left alone entirely, so the tolerance
    // below can never snap a window to an edge that did not move.
    guard gainLow > edgeEpsilon || gainHigh > edgeEpsilon else {
        return AxisReclaim(position: position, length: length)
    }

    // What idempotence actually rests on. A slid window ends up exactly `gain`
    // from where the old edge was, so an edge that moved by less than twice the
    // tolerance would recognise its own work on the next pass and slide the
    // window again — and the Dock moves by a single point routinely. The end
    // that did not gain has no such constraint: it never slides anything, it
    // only helps tell a maximised window from a resting one.
    let lowTolerance = gainLow > edgeEpsilon ? min(tolerance, gainLow / 2) : tolerance
    let highTolerance = gainHigh > edgeEpsilon ? min(tolerance, gainHigh / 2) : tolerance

    let atLow = abs(position - previousLow) <= lowTolerance
    let atHigh = abs(position + length - previousHigh) <= highTolerance

    // Both ends: maximised. Checked without regard to which end gained — a
    // full-width window under a left Dock touches the right screen edge too,
    // and stretching it is the whole point.
    if atLow, atHigh {
        return AxisReclaim(position: low, length: high - low)
    }
    if atLow, gainLow > edgeEpsilon {
        return AxisReclaim(position: position - gainLow, length: length)
    }
    if atHigh, gainHigh > edgeEpsilon {
        return AxisReclaim(position: position + gainHigh, length: length)
    }
    return AxisReclaim(position: position, length: length)
}

/// Where `window` should go now that `space` has freed up.
///
/// Pure geometry, and not clamped to the screen — `computeFix` does that, so a
/// window that this pushes past an edge is still pulled back the usual way.
///
/// `tolerance` is the *most* a window may be from an edge and still count as
/// having been held by it; a small change to the Dock tightens it further, see
/// `reclaimAxis`.
public func reclaimedRect(for window: CGRect,
                          in space: ReclaimedSpace,
                          tolerance: CGFloat = 10) -> CGRect {
    let old = space.previousVisible
    let new = space.visible

    let h = reclaimAxis(position: window.minX, length: window.width,
                        previousLow: old.minX, previousHigh: old.maxX,
                        low: new.minX, high: new.maxX,
                        gainLow: space.gainLeft, gainHigh: space.gainRight,
                        tolerance: tolerance)
    let v = reclaimAxis(position: window.minY, length: window.height,
                        previousLow: old.minY, previousHigh: old.maxY,
                        low: new.minY, high: new.maxY,
                        // The top edge is the menu bar; only the bottom can be
                        // the Dock, so the low end never contributes a shift.
                        gainLow: 0, gainHigh: space.gainBottom,
                        tolerance: tolerance)

    return CGRect(x: h.position, y: v.position, width: h.length, height: v.length)
}
