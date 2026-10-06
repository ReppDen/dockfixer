import CoreGraphics

/// A correction to apply to a single window.
///
/// All rects here live in Accessibility coordinate space: origin at the
/// top-left of the primary display, y growing downwards. See `ScreenMap`
/// for the conversion from Cocoa's bottom-left space.
public struct WindowFix: Equatable {
    /// Where the window should end up.
    public let rect: CGRect
    /// How far the window was moved. Reported in the log.
    public let shift: CGVector
    /// How much the window was narrowed/shortened. Reported in the log.
    public let shrink: CGSize
    /// True when the window was bigger than the usable area on some axis and
    /// had to be sized down to fit rather than merely nudged.
    public let clamped: Bool

    public init(rect: CGRect, shift: CGVector, shrink: CGSize, clamped: Bool) {
        self.rect = rect
        self.shift = shift
        self.shrink = shrink
        self.clamped = clamped
    }
}

/// Result of correcting one axis.
private struct AxisFix {
    var position: CGFloat
    var length: CGFloat
    var clamped: Bool
}

/// Pulls one axis of a window back inside `[low, high]`.
///
/// Two cases, and only two:
///
/// - The window fits in the usable extent: slide it in. The shift is exactly
///   the overlap with the Dock, so a window only half-way under the Dock moves
///   less than the Dock's full width.
/// - The window is longer than the usable extent: sliding it in would push the
///   far edge off-screen, so shorten it as well. For a window whose far edge
///   already sat at the screen edge — the common maximised case — the amount
///   shortened equals the amount moved.
private func fixAxis(position: CGFloat, length: CGFloat, low: CGFloat, high: CGFloat) -> AxisFix {
    let usable = high - low
    guard usable > 0 else {
        return AxisFix(position: position, length: length, clamped: false)
    }

    if length > usable {
        return AxisFix(position: low, length: usable, clamped: true)
    }
    return AxisFix(position: min(max(position, low), high - length), length: length, clamped: false)
}

/// Pulls a whole rect back inside `visible`, one axis at a time.
private func clamp(_ rect: CGRect, into visible: CGRect) -> (rect: CGRect, clamped: Bool) {
    let h = fixAxis(position: rect.minX, length: rect.width,
                    low: visible.minX, high: visible.maxX)
    let v = fixAxis(position: rect.minY, length: rect.height,
                    low: visible.minY, high: visible.maxY)

    return (CGRect(x: h.position, y: v.position, width: h.length, height: v.length),
            h.clamped || v.clamped)
}

/// Computes the correction for `window` against the usable area `visible`.
///
/// Returns `nil` when the window is already fully inside the usable area,
/// so callers can skip it without touching it at all.
///
/// `visible` is a screen's visible frame — it already excludes the Dock and
/// the menu bar, whichever edges they occupy, and collapses to nearly the full
/// screen when the Dock is set to auto-hide. That is why no Dock orientation or
/// tile size is consulted anywhere in this file.
///
/// `slack` is how far a window may stick out of `visible` and still be left
/// where it is — see `dockNoise`. A window that sticks out further is brought
/// all the way in, not just to within `slack`.
public func computeFix(window: CGRect,
                       visible: CGRect,
                       slack: CGFloat = 0,
                       tolerance: CGFloat = 0.5) -> WindowFix? {
    computeFix(window: window, visible: visible, reclaim: nil, slack: slack, tolerance: tolerance)
}

/// The same correction, plus the space the display regained because the Dock
/// left it.
///
/// The reclaim moves the window outwards first — stretching it if it was
/// maximised, sliding it otherwise — and the result is then clamped into
/// `visible` exactly as an untouched window would be. The reported `shift` and
/// `shrink` are measured against the original `window`, so the log describes
/// where the window actually ended up rather than the intermediate step.
public func computeFix(window: CGRect,
                       visible: CGRect,
                       reclaim: ReclaimedSpace?,
                       slack: CGFloat = 0,
                       tolerance: CGFloat = 0.5) -> WindowFix? {
    guard window.width > 0, window.height > 0,
          visible.width > 0, visible.height > 0
    else { return nil }

    let desired = reclaim.map { reclaimedRect(for: window, in: $0) } ?? window

    // Only a window the reclaim left alone gets the allowance. One that is
    // being moved anyway is moved to exactly the right place, so the slack
    // never turns into a gap that the next change would have to account for.
    if desired == window, visible.insetBy(dx: -slack, dy: -slack).contains(window) {
        return nil
    }
    let (fixed, clamped) = clamp(desired, into: visible)

    let moved = abs(fixed.minX - window.minX) > tolerance || abs(fixed.minY - window.minY) > tolerance
    let resized = abs(fixed.width - window.width) > tolerance || abs(fixed.height - window.height) > tolerance
    guard moved || resized else { return nil }

    return WindowFix(
        rect: fixed,
        shift: CGVector(dx: fixed.minX - window.minX, dy: fixed.minY - window.minY),
        shrink: CGSize(width: window.width - fixed.width, height: window.height - fixed.height),
        clamped: clamped
    )
}

public extension CGRect {
    /// Compact form used in the log: `(12,180 1400x900)`.
    var logDescription: String {
        func n(_ v: CGFloat) -> String {
            v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        }
        return "(\(n(minX)),\(n(minY)) \(n(width))x\(n(height)))"
    }
}

public extension WindowFix {
    /// `shift=+55 shrink=55` — only the non-zero parts, for a readable log.
    /// A negative shrink is a window that grew into reclaimed space, and reads
    /// better as `growW=` than as `shrinkW=-55`.
    var logDetail: String {
        var parts: [String] = []
        func n(_ v: CGFloat) -> String {
            v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        }
        func size(_ label: String, _ v: CGFloat) {
            guard v != 0 else { return }
            parts.append(v > 0 ? "shrink\(label)=\(n(v))" : "grow\(label)=\(n(-v))")
        }
        if shift.dx != 0 { parts.append("shiftX=\(n(shift.dx))") }
        if shift.dy != 0 { parts.append("shiftY=\(n(shift.dy))") }
        size("W", shrink.width)
        size("H", shrink.height)
        if clamped { parts.append("clamped") }
        return parts.joined(separator: " ")
    }
}
