import Foundation

/// How long the app waits before acting.
///
/// Each wait once existed for a reason: a display change arrives as a burst
/// of notifications and the Dock settles seconds after the frames do, a new
/// window is announced before its application has placed it. They were
/// insurance against moving a window twice, and cost seconds under the Dock
/// every time. They are gone: a change is acted on the moment two readings
/// agree, and a Dock that goes on changing afterwards simply produces another
/// change, acted on in turn. Twice beats seconds under the Dock.
public struct Timing: Sendable, Equatable {
    /// Between the readings that have to agree. The polls stay, at the
    /// shortest interval worth the name: two readings that agree are what
    /// tells a change mid-flight from one that is done.
    public var poll: TimeInterval
    /// However the notifications keep coming, a change is handed over within
    /// this long of the first one.
    public var maxWait: TimeInterval
    /// How long a new window is left alone before it is checked: it is
    /// announced the moment it exists, before its application has finished
    /// placing it.
    public var newWindow: TimeInterval
    /// How long a window restored from the Dock is left alone. It is
    /// announced as the animation out of the Dock starts, and a frame
    /// written while the window is still flying is one the animation may
    /// land over.
    public var restoredWindow: TimeInterval

    public static let `default` = Timing(poll: 0.1, maxWait: 20, newWindow: 0.05, restoredWindow: 0.5)
}
