import AppKit

/// Notices when the display configuration changes and reports it once things
/// have settled.
///
/// Unplugging a display does not produce one tidy event. The notification
/// arrives several times in a burst, and WindowServer goes on relocating windows
/// by itself afterwards. Correcting windows during that window of time fights
/// the system and misses windows that have not moved yet, so this waits for the
/// layout to stop changing before handing over. A fixed sleep is not enough on
/// slower rebuilds — a Thunderbolt dock or a GPU switch can take a while.
@MainActor
public final class DisplayWatcher {

    /// The note for the log, and the layout as it was *before* the change.
    /// The previous visible frames are the only record of where the Dock used
    /// to be, which is what tells `reclaims` how much space a display regained.
    public typealias Handler = (String, [ScreenInfo]) -> Void

    private let debounceNanos: UInt64 = 600_000_000
    private let pollNanos: UInt64 = 300_000_000
    /// Two identical readings in a row mean the layout has settled.
    private let requiredStableReadings = 2
    private let maxPolls = 10

    private let log: Log
    private let handler: Handler

    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private var lastScreens: [ScreenInfo]

    public private(set) var isRunning = false

    public init(log: Log, handler: @escaping Handler) {
        self.log = log
        self.handler = handler
        lastScreens = ScreenMap.current()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        // The snapshot may have gone stale while the watcher was off.
        lastScreens = ScreenMap.current()

        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensChanged()
            }
        }
        log.info("auto-fix on display change: enabled")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        pending?.cancel()
        pending = nil
        log.info("auto-fix on display change: disabled")
    }

    /// The same notification fires when the Dock moves or changes size, so a
    /// Dock rearrangement is handled for free.
    private func screensChanged() {
        pending?.cancel()
        pending = Task { [weak self] in
            await self?.waitForStableLayout()
        }
    }

    private func waitForStableLayout() async {
        let previousScreens = lastScreens
        let previousFingerprint = ScreenMap.fingerprint(previousScreens)

        try? await Task.sleep(nanoseconds: debounceNanos)
        if Task.isCancelled { return }

        var stableReadings = 1
        var fingerprint = ScreenMap.fingerprint(ScreenMap.current())
        var polls = 0

        while stableReadings < requiredStableReadings, polls < maxPolls {
            try? await Task.sleep(nanoseconds: pollNanos)
            if Task.isCancelled { return }
            polls += 1

            let current = ScreenMap.fingerprint(ScreenMap.current())
            if current == fingerprint {
                stableReadings += 1
            } else {
                stableReadings = 1
                fingerprint = current
            }
        }

        let screens = ScreenMap.current()
        lastScreens = screens

        guard fingerprint != previousFingerprint else {
            // Woken by something that left the layout identical.
            return
        }

        let settled = stableReadings >= requiredStableReadings
        var note = "displays changed: \(previousScreens.count) -> \(screens.count)"
        note += settled ? ", settled after \(polls) polls" : ", still changing after \(polls) polls — going ahead anyway"
        log.info(note)

        handler(note, previousScreens)
    }
}
