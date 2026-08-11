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

    /// Which edge the Dock sits on, inferred from the insets. The top inset is
    /// the menu bar, so it is never a candidate.
    public var dockEdge: String {
        let i = insets
        let candidates = [("left", i.left), ("right", i.right), ("bottom", i.bottom)]
        guard let winner = candidates.max(by: { $0.1 < $1.1 }), winner.1 > 1 else {
            return "hidden"
        }
        return "\(winner.0) \(Int(winner.1.rounded()))pt"
    }
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
    public static func fingerprint(_ screens: [ScreenInfo]) -> String {
        screens
            .sorted { $0.displayID < $1.displayID }
            .map { "\($0.displayID):\($0.axFrame.logDescription):\($0.axVisibleFrame.logDescription)" }
            .joined(separator: "|")
    }
}
