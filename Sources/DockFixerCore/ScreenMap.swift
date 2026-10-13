import AppKit
import CoreGraphics

/// One display, described entirely in Accessibility coordinate space.
///
/// The Accessibility API reports and accepts window positions with the origin at
/// the top-left of the primary display and y growing downwards. `NSScreen` uses
/// the opposite vertical convention. Converting once, here, keeps every other
/// file in a single coordinate space — mixing the two is the classic way to make
/// windows fly off the bottom of the screen.
public struct ScreenInfo: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    /// Full bounds of the display.
    public let axFrame: CGRect
    /// Bounds minus the Dock and the menu bar, whichever edges they occupy.
    public let axVisibleFrame: CGRect
    public let isPrimary: Bool
    public let localizedName: String

    public init(displayID: CGDirectDisplayID,
                axFrame: CGRect,
                axVisibleFrame: CGRect,
                isPrimary: Bool,
                localizedName: String) {
        self.displayID = displayID
        self.axFrame = axFrame
        self.axVisibleFrame = axVisibleFrame
        self.isPrimary = isPrimary
        self.localizedName = localizedName
    }

    /// How much each edge is eaten by the Dock and the menu bar.
    public var insets: NSEdgeInsets {
        NSEdgeInsets(top: axVisibleFrame.minY - axFrame.minY,
                     left: axVisibleFrame.minX - axFrame.minX,
                     bottom: axFrame.maxY - axVisibleFrame.maxY,
                     right: axFrame.maxX - axVisibleFrame.maxX)
    }

    /// Which edge the Dock sits on, inferred from the insets, or `nil` when
    /// it is hidden. The top inset is the menu bar, so it is never a candidate.
    public var dockSide: DockSide? {
        let i = insets
        let candidates: [(DockSide, CGFloat)] = [(.left, i.left), (.right, i.right), (.bottom, i.bottom)]
        guard let winner = candidates.max(by: { $0.1 < $1.1 }), winner.1 > 1 else { return nil }
        return winner.0
    }

    /// The Dock's edge and thickness, for the log.
    public var dockEdge: String {
        let i = insets
        guard let side = dockSide else { return "hidden" }
        let thickness: CGFloat
        switch side {
        case .left: thickness = i.left
        case .right: thickness = i.right
        case .bottom: thickness = i.bottom
        }
        return "\(side) \(Int(thickness.rounded()))pt"
    }
}

/// An edge of a display the Dock can sit on.
public enum DockSide: String, Sendable {
    case left, right, bottom
}

/// Converts a rect between Cocoa's bottom-left origin and the Accessibility
/// API's top-left origin.
///
/// The transform is its own inverse, so the same function goes both ways.
/// `primaryHeight` is the height of the display whose Cocoa frame origin is
/// `(0, 0)` — the global origin in both spaces sits on that display.
public func flipVertically(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX,
           y: primaryHeight - rect.maxY,
           width: rect.width,
           height: rect.height)
}

public enum ScreenMap {

    /// Snapshot of the current display configuration.
    ///
    /// `NSScreen` must be touched on the main thread, so callers that scan
    /// windows in the background take a snapshot here first and pass it along.
    @MainActor
    public static func current() -> [ScreenInfo] {
        let screens = NSScreen.screens
        // The display holding the global origin. Cocoa guarantees exactly one
        // screen has origin (0, 0); fall back to the first entry if a
        // reconfiguration is momentarily inconsistent.
        let primary = screens.first { $0.frame.origin == .zero } ?? screens.first
        let primaryHeight = primary?.frame.height ?? 0

        return screens.map { screen in
            ScreenInfo(
                displayID: displayID(of: screen),
                axFrame: flipVertically(screen.frame, primaryHeight: primaryHeight),
                axVisibleFrame: flipVertically(screen.visibleFrame, primaryHeight: primaryHeight),
                isPrimary: screen === primary,
                localizedName: screen.localizedName
            )
        }
    }

    @MainActor
    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    /// The display a window belongs to: the one it overlaps most.
    ///
    /// A window can straddle two displays; the larger share wins, which matches
    /// how macOS itself decides which screen a window is "on". Windows that
    /// overlap nothing — fully off-screen after a display was unplugged — are
    /// assigned to the primary display so they still get pulled back.
    public static func screen(for window: CGRect, in screens: [ScreenInfo]) -> ScreenInfo? {
        guard !screens.isEmpty else { return nil }

        var best: ScreenInfo?
        var bestArea: CGFloat = 0
        for screen in screens {
            let overlap = screen.axFrame.intersection(window)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        if let best { return best }
        return screens.first { $0.isPrimary } ?? screens.first
    }

    /// Stable fingerprint of a configuration, used to tell whether the display
    /// layout has settled after an unplug. Includes the visible frames so a
    /// Dock move counts as a change too.
    /// One line for the log, where a list of rows would not fit:
    /// `Built-in Retina Display 1512x982 dock left 52pt   ·   DELL 2560x1440 dock hidden (primary)`.
    public static func summary(_ screens: [ScreenInfo]) -> String {
        screens.map { screen in
            "\(screen.localizedName) \(Int(screen.axFrame.width))x\(Int(screen.axFrame.height))"
                + " dock \(screen.dockEdge)"
                + (screen.isPrimary && screens.count > 1 ? " (primary)" : "")
        }
        .joined(separator: "   ·   ")
    }

    public static func fingerprint(_ screens: [ScreenInfo]) -> String {
        screens
            .sorted { $0.displayID < $1.displayID }
            .map { "\($0.displayID):\($0.axFrame.logDescription):\($0.axVisibleFrame.logDescription)" }
            .joined(separator: "|")
    }
}

/// What a change of screen parameters was, told from the layout before and
/// after it. macOS sends the same notification for both.
public enum LayoutChange: Equatable, Sendable {
    /// The same displays at the same places, and only a visible frame changed:
    /// the Dock grew, shrank or moved to another edge.
    case dock
    /// A display came, went, moved, changed resolution or became the primary
    /// one. The Dock moving to another display is one of these too: it only
    /// does that when the displays change.
    case displays
}

public func classifyLayoutChange(previous: [ScreenInfo], current: [ScreenInfo]) -> LayoutChange {
    let before = Dictionary(previous.map { ($0.displayID, $0.axFrame) }, uniquingKeysWith: { a, _ in a })
    let after = Dictionary(current.map { ($0.displayID, $0.axFrame) }, uniquingKeysWith: { a, _ in a })
    return before == after ? .dock : .displays
}

/// How far the Dock may grow or shrink, in points, before windows are moved
/// for it.
///
/// A Dock on the side of a display changes its thickness by a point or two
/// whenever an application opens or quits, because it scales its icons to fit
/// them all. Following every such change moved every window that touches the
/// Dock by a point, twenty times a day — and after an unlock macOS reports a
/// Dock of the wrong size for a couple of seconds, so windows went one way and
/// came back. A strip this thin under the Dock is not worth a visible jolt.
///
/// The same allowance applies in both directions, which is what keeps windows
/// from creeping: a change is measured against the layout windows were last
/// arranged for, not against the previous reading, so small steps add up and
/// are acted on together once they pass the threshold. A window that overlaps
/// the usable area by no more than this is left alone too (`computeFix`), so a
/// Dock that is a few points thicker than the last arrangement does not get
/// windows pushed by the next pass either.
public let dockNoise: CGFloat = 4

/// A window whose edge is this close to the Dock, on the Dock's side, is
/// put against it. A gap this small is not where anyone puts a window: it
/// is a window that was against a thicker Dock — on a display just unplugged,
/// or on this one before an application quit and the Dock shrank — and was
/// carried over with the same coordinates. Found in the log after a TV was
/// unplugged: windows 2–15pt from the laptop's Dock, every one of them at the
/// thickness of the TV's.
public let dockSnap: CGFloat = 16

/// The furthest any edge of a visible frame moved between two layouts, over
/// the displays present in both.
///
/// Only meaningful for a Dock change (`classifyLayoutChange` returned `.dock`):
/// for anything else the frames themselves moved, and the answer would be the
/// distance the display moved.
public func largestEdgeShift(previous: [ScreenInfo], current: [ScreenInfo]) -> CGFloat {
    var before: [CGDirectDisplayID: CGRect] = [:]
    for screen in previous { before[screen.displayID] = screen.axVisibleFrame }

    var largest: CGFloat = 0
    for screen in current {
        guard let old = before[screen.displayID] else { continue }
        let new = screen.axVisibleFrame
        largest = max(largest,
                      abs(new.minX - old.minX), abs(new.maxX - old.maxX),
                      abs(new.minY - old.minY), abs(new.maxY - old.maxY))
    }
    return largest
}

/// What the Dock did, in words for the log: `DELL U2722D left 54pt → left 55pt`.
/// Displays whose visible frame did not change are left out.
public func describeDockChange(previous: [ScreenInfo], current: [ScreenInfo]) -> String {
    var before: [CGDirectDisplayID: ScreenInfo] = [:]
    for screen in previous { before[screen.displayID] = screen }

    let changes = current.compactMap { screen -> String? in
        guard let old = before[screen.displayID],
              old.axVisibleFrame != screen.axVisibleFrame
        else { return nil }
        return "\(screen.localizedName) \(old.dockEdge) → \(screen.dockEdge)"
    }
    return changes.isEmpty ? "no visible frame changed" : changes.joined(separator: ", ")
}
