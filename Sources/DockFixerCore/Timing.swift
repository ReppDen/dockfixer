import Foundation

/// How long the app waits before acting, as one of two presets.
///
/// The waits exist for a reason each: a display change arrives as a burst of
/// notifications and the Dock settles seconds after the frames do, a new
/// window is announced before its application has placed it. The cost is
/// that windows sit under the Dock for the whole wait. Turbo gives the waits
/// up: a change is acted on the moment two readings agree, and a Dock that
/// goes on changing afterwards simply produces another change, which is acted
/// on in turn — so the price of turbo is a window moved twice now and then,
/// never one left where it was.
public struct Timing: Sendable, Equatable {
    /// Quiet time after a screen-parameters notification before reading.
    public var debounce: TimeInterval
    /// Between the readings that have to agree.
    public var poll: TimeInterval
    /// How long the layout is left alone after a display change, a wake or an
    /// unlock. The Dock took four seconds to settle after an unplug.
    public var hold: TimeInterval
    /// However the notifications keep coming, a change is handed over within
    /// this long of the first one.
    public var maxWait: TimeInterval
    /// How long a new window is left alone before it is checked.
    public var newWindow: TimeInterval

    public static let standard = Timing(debounce: 0.6, poll: 0.3, hold: 5, maxWait: 20, newWindow: 0.3)
    /// The polls stay, at the shortest interval worth the name: two readings
    /// that agree are what tells a change mid-flight from one that is done.
    public static let turbo = Timing(debounce: 0, poll: 0.1, hold: 0, maxWait: 20, newWindow: 0.05)
}
