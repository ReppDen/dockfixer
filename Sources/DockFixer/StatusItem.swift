import AppKit
import Combine
import SwiftUI

/// The menu-bar icon: a left click opens the window, a right click (or a
/// Control-click) shows a short menu.
///
/// An AppKit `NSStatusItem` rather than SwiftUI's `MenuBarExtra`, because a
/// `MenuBarExtra` cannot tell one mouse button from the other: it either
/// opens its menu or its window on any click. Everything there is to set up
/// lives in the window, so the window is what a plain click should give; the
/// menu keeps only what is worth having without it.
///
/// One object for the whole process. `AppState` attaches itself when it is
/// built, which is what creates the item; the app delegate hands itself over
/// in `applicationWillFinishLaunching`. Which of the two comes first is up to
/// SwiftUI, so neither assumes the other is there yet.
@MainActor
final class StatusItemController: NSObject {

    static let shared = StatusItemController()

    /// Whether the icon carries the dot that says a notification came. In
    /// UserDefaults, so a dot that nobody has seen yet is still there after a
    /// restart or an update.
    private static let badgeKey = "menuBarIconBadge"

    /// Set in `applicationWillFinishLaunching`. Weak: the delegate owns the
    /// app's lifetime, not this.
    ///
    /// Handed over, never looked up. `NSApp.delegate as? AppDelegate` returns
    /// nil: with `@NSApplicationDelegateAdaptor` SwiftUI installs a delegate of
    /// its own and forwards to this one, so the delegate methods are called
    /// but the cast never succeeds. The old menu spent every early attempt
    /// calling methods on nil and doing nothing at all.
    weak var delegate: AppDelegate? {
        didSet {
            // The icon's view may have handed over `openWindow` before the
            // delegate was there to take it.
            if let pendingOpenWindow, let delegate {
                delegate.openWindow = pendingOpenWindow
                self.pendingOpenWindow = nil
            }
        }
    }
    private var pendingOpenWindow: ((String) -> Void)?

    private weak var state: AppState?
    private var item: NSStatusItem?
    private var dot: BadgeDot?
    private var subscriptions: Set<AnyCancellable> = []

    var showsBadge: Bool {
        UserDefaults.standard.bool(forKey: Self.badgeKey)
    }

    /// Puts the dot on the icon or takes it off. Only a real change is
    /// written and logged: the window becoming key clears it, and that
    /// happens many times a day with no dot to clear.
    func setBadge(_ shown: Bool) {
        guard shown != showsBadge else { return }
        UserDefaults.standard.set(shown, forKey: Self.badgeKey)
        state?.log.info("menu bar icon: badge \(shown ? "shown" : "cleared")")
        dot?.isHidden = !shown
    }

    /// Creates the item, once. Called from `AppState.init`.
    ///
    /// The item is made a turn later, not here. `AppState` is built while
    /// SwiftUI is evaluating the app's scenes, and the hosting view inside the
    /// icon lays itself out the moment it is added: a SwiftUI update started
    /// from inside another one is a precondition failure, and the app crashed
    /// at every launch.
    func attach(state: AppState) {
        guard self.state == nil else { return }
        self.state = state
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.createItem(state: state) }
        }
    }

    private func createItem(state: AppState) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        guard let button = item.button else {
            state.log.info("menu bar icon: the system gave no button — no icon")
            return
        }
        button.target = self
        button.action = #selector(clicked(_:))
        // Without this the action fires on the left button only, and a right
        // click does nothing at all.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let dot = BadgeDot(frame: button.bounds)
        dot.autoresizingMask = [.width, .height]
        dot.isHidden = !showsBadge
        button.addSubview(dot)
        self.dot = dot

        // Hands the delegate a way to open the scenes' windows. Zero-sized
        // and invisible; it is there for its environment, not to be seen. See
        // `StatusItemOpener`.
        let opener = NSHostingView(rootView: StatusItemOpener())
        opener.frame = .zero
        button.addSubview(opener)

        // `sink` hands over the new value before the property has it, which
        // is all that is used here. Nothing is written back to the state:
        // the `MenuBarExtra` this replaces wrote `isInserted` back on every
        // update, and that loop held the main thread at 100% CPU.
        state.$isTrusted.removeDuplicates().sink { [weak self] trusted in
            self?.setImage(trusted: trusted)
        }.store(in: &subscriptions)
        state.$hideMenuBarIcon.removeDuplicates().sink { [weak self] hidden in
            // Hidden, not removed: the item and the view inside it stay, so
            // showing it again is one assignment, and the order of the icons
            // in the menu bar is kept.
            self?.item?.isVisible = !hidden
        }.store(in: &subscriptions)

        state.log.info("menu bar icon: created, \(state.hideMenuBarIcon ? "hidden" : "shown")"
                       + (showsBadge ? ", with the badge" : ""))
    }

    /// Without the grant nothing works, and the menu bar may be the only part
    /// of the app on screen, so that is where it has to show. A template
    /// image, so the system draws it right in a light and a dark menu bar.
    private func setImage(trusted: Bool) {
        let name = trusted ? "macwindow" : "exclamationmark.triangle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "DockFixer")
        image?.isTemplate = true
        item?.button?.image = image
        dot?.imageSize = image?.size ?? .zero
    }

    // MARK: - Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // Control-click is a right click on a Mac with one button.
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        state?.log.info("menu bar icon: \(wantsMenu ? "right click — showing the menu" : "left click — opening the window")")
        if wantsMenu {
            showMenu()
        } else {
            delegate?.showMainWindow()
        }
    }

    /// The menu is built afresh for each click, so "Fix Windows Now" is
    /// disabled exactly while a pass runs, and nothing has to be kept in step.
    ///
    /// It is shown by setting it on the item and clicking the button: that is
    /// the one way to get it placed under the icon the way the system places
    /// every other menu-bar menu. Taken off again when it closes, or the next
    /// left click would open it too.
    private func showMenu() {
        guard let item, let button = item.button else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let fix = menu.addItem(withTitle: "Fix Windows Now", action: #selector(fixWindows), keyEquivalent: "")
        fix.isEnabled = !(state?.isBusy ?? true)
        menu.addItem(withTitle: "Open DockFixer", action: #selector(openWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Report a Bug", action: #selector(reportBug), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit DockFixer", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }

        item.menu = menu
        button.performClick(nil)
    }

    @objc private func fixWindows() {
        state?.moveWindows()
    }

    // The two below wait for the menu to be gone: they change the activation
    // policy, and the menu's event-tracking loop is no place for that.

    @objc private func openWindow() {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.showMainWindow()
        }
    }

    @objc private func reportBug() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // An accessory app cannot own an ordinary window.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            if let open = delegate?.openWindow {
                open(DockFixerApp.bugReportWindowID)
            } else {
                state?.log.info("menu bar icon: cannot open Report a Bug — no way to open windows yet")
            }
        }
    }

    @objc private func quit() {
        state?.quit()
    }

    /// Called by `StatusItemOpener`.
    fileprivate func handOver(_ open: @escaping (String) -> Void) {
        state?.log.debug("menu bar icon: openWindow handed over")
        if let delegate {
            delegate.openWindow = open
        } else {
            pendingOpenWindow = open
        }
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        item?.menu = nil
    }
}

/// Hands the delegate a way to open the scenes' windows, from inside the
/// menu-bar icon.
///
/// Once a `Window` scene has been closed only SwiftUI can build its window
/// again, and `openWindow` is reachable from a view and nowhere else. The
/// window has a view of its own that does the same (`WindowOpener`), but the
/// window may never have been built — restoration can start the app with it
/// closed, and a restart after an update closes it at once — and then the
/// icon is the one part of the app that is guaranteed to exist.
private struct StatusItemOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                StatusItemController.shared.handOver { id in openWindow(id: id) }
            }
    }
}

/// The dot on the icon after a notification. Drawn in a view over the
/// button rather than into the image: the image is a template, which the
/// system recolours for the menu bar, and a template cannot keep a red dot
/// red. Covers the whole button and lets every click through.
private final class BadgeDot: NSView {
    /// The icon's size, to put the dot on its top right corner.
    var imageSize: NSSize = .zero {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = 6
        // The image is centred in the button; the dot sits on its top right
        // corner, a little outside it, as an app badge does.
        let image = NSRect(x: (bounds.width - imageSize.width) / 2,
                           y: (bounds.height - imageSize.height) / 2,
                           width: imageSize.width, height: imageSize.height)
        let dot = NSRect(x: image.maxX - diameter + 2, y: image.minY - 1,
                         width: diameter, height: diameter)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}
