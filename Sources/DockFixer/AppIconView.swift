import AppKit
import SwiftUI

/// The app's own icon, drawn sharp at `size` points.
///
/// Taken from `NSWorkspace`, not `NSApp.applicationIconImage`. The latter is a
/// single 256-pixel snapshot, and squeezed into 48 points it broke the light
/// rim macOS draws round app icons into steps. The workspace icon is the one
/// Finder and Quick Look show: the system renders it for whatever size is
/// asked, so the size is set first and nothing is scaled afterwards.
struct AppIconView: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: Self.icon(size))
            .frame(width: size, height: size)
    }

    private static func icon(_ size: CGFloat) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        image.size = NSSize(width: size, height: size)
        return image
    }
}
