import DockFixerCore
import SwiftUI

/// A softly filled button sized to its title: the shape the controls in this
/// window take.
///
/// Sized to the text, not stretched across the row: a full-width button reads
/// as the one thing the window is for, and this window is mostly checkboxes.
struct SoftButtonStyle: ButtonStyle {
    /// A little more fill, for the action the window exists to perform.
    var emphasised = false

    func makeBody(configuration: Configuration) -> some View {
        Filled(configuration: configuration, emphasised: emphasised)
    }

    // Not named `Body`: that is the protocol's own associated type, and a nested
    // type of that name has to be as visible as the style itself.
    private struct Filled: View {
        let configuration: Configuration
        let emphasised: Bool

        // Read here rather than in `makeBody`: a style's body is not a view, so
        // it cannot see the environment, and a disabled button has to look it.
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(fill))
                )
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .fixedSize()
                .onHover { hovering = $0 }
        }

        private var fill: Double {
            guard isEnabled else { return 0.04 }
            if configuration.isPressed { return 0.22 }
            let base = emphasised ? 0.15 : 0.09
            return hovering ? base + 0.05 : base
        }
    }
}

/// Where the links at the foot of the window go. Buy Me a Coffee has no page yet, and a
/// button that goes nowhere is worse than none.
enum Links {
    static let repository = URL(string: "https://github.com/ReppDen/dockfixer")!
    static let discussions = URL(string: "https://github.com/ReppDen/dockfixer/discussions")!
    /// System Settings → Desktop & Dock. Where the Dock is moved, resized and
    /// hidden: sending people there needs no permission, where moving the Dock
    /// from here would need Automation access to System Events.
    static let dockSettings = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!
    static let buyMeACoffee: URL? = nil

    /// A new issue with the facts a report always needs already filled in, so
    /// nobody has to be asked for them afterwards. The bug report form's way
    /// out, for a build that cannot send and for anyone who prefers GitHub.
    static func bugReport(screens: [ScreenInfo]) -> URL {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let displays = screens.map { "\($0.localizedName), \(ContentView.dockDescription($0))" }
            .joined(separator: "; ")
        let body = """
                   **What happened**


                   **What you expected**


                   **Log lines** (DockFixer → About → Show Log → Copy Log)

                   ```
                   ```

                   ---
                   DockFixer \(version) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(displays)
                   """
        var components = URLComponents(url: repository.appendingPathComponent("issues/new"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        return components.url ?? repository
    }
}

/// Everything on one page: who the app is, what it sees, what it does, and the
/// way out to the log and the project.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    private static let width: CGFloat = 600
    /// Section names sit flush right in a column of their own, as in macOS
    /// settings. Fixed widths, not a `Form`, so the window sized by its
    /// contents has nothing to negotiate.
    private static let labelWidth: CGFloat = 100
    private static let controlWidth: CGFloat = 448

    var body: some View {
        Group {
            if state.isTrusted {
                page
            } else {
                OnboardingView()
            }
        }
        .padding(20)
        .frame(width: Self.width)
        .animation(.easeInOut(duration: 0.2), value: state.isTrusted)
        .onChange(of: state.isTrusted) { _, trusted in
            // The switch was turned on in System Settings, which is in front.
            // Coming forward shows that it worked, and that there is a next step.
            if trusted { NSApp.activate() }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 16) {
                row("Screens") { screens }
                row("Move windows") { dock }
                row("External display") { externalDisplay }
                row("") { fixNow }
                row("Startup") {
                    Toggle("Launch at login", isOn: $state.launchAtLogin)
                }
                row("Menu bar") {
                    option(isOn: $state.hideMenuBarIcon,
                           title: "Hide menu bar icon",
                           detail: "Open DockFixer again to show this window or quit.")
                }
                row("Updates") { UpdatesRow(updater: state.updater) }
                row("Statistics") {
                    // Literally what goes out, and nothing it does not say:
                    // see UsageReport.event.
                    option(isOn: $state.sendUsageStatistics,
                           title: "Send anonymous usage statistics",
                           detail: "One line a day: the app version, the date, and how many windows were moved. No window names, no app names.")
                }
            }
            Divider()
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            AppIconView(size: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("DockFixer")
                        .font(.system(size: 17, weight: .semibold))
                    Text(Self.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Keeps your windows away from the Dock.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Screens

    /// One row per display: its name, its size, and where its Dock is.
    private var screens: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.screens, id: \.displayID) { screen in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(screen.localizedName)
                        if screen.isPrimary, state.screens.count > 1 {
                            Text("PRIMARY")
                                .font(.system(size: 9, weight: .semibold))
                                .kerning(0.4)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.1)))
                        }
                    }
                    Text(Self.describe(screen))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button { openURL(Links.dockSettings) } label: {
                Label("Dock Settings…", systemImage: "dock.rectangle")
            }
            .buttonStyle(SoftButtonStyle())
            .padding(.top, 2)
        }
    }

    /// `Looks like 1512 × 982 · Dock on the left`
    ///
    /// Points, not pixels, and said the way System Settings → Displays says it:
    /// a bare 1512 × 982 next to a 3024 × 1964 panel reads as a mistake.
    static func describe(_ screen: ScreenInfo) -> String {
        "Looks like \(Int(screen.axFrame.width)) × \(Int(screen.axFrame.height)) · \(dockDescription(screen))"
    }

    static func dockDescription(_ screen: ScreenInfo) -> String {
        let insets = screen.insets
        let edges = [("left", insets.left), ("right", insets.right), ("bottom", insets.bottom)]
        guard let dock = edges.max(by: { $0.1 < $1.1 }), dock.1 > 1 else {
            return "No Dock on this display"
        }
        return "Dock on the \(dock.0)"
    }

    // MARK: - Dock

    private var dock: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Each title finishes the sentence the row's name starts: "Move
            // windows" · "that are under the Dock". Cut by what happens to a
            // window, not by what set it off; the wording is kept to the
            // simplest English that is still literally true.
            option(isOn: $state.moveFromUnderDock,
                   title: "Move windows that are under the Dock")
            // "Stick" promises the window ends up against the Dock, which is
            // true for one that was next to it or within a few points of it.
            // A window in the middle of the screen is not read as "windows".
            option(isOn: $state.stickToDock,
                   title: "Stick windows to the Dock when it changes size or moves",
                   enabled: state.moveFromUnderDock)
            // Pixels, not points: points mean nothing to most people, and on
            // a Retina display the number is twice the points.
            option(isOn: $state.ignoreSmallDockChanges,
                   title: "Skip very small changes (about \(Int(dockNoise) * 2) pixels)",
                   enabled: state.moveFromUnderDock && state.stickToDock)
                .padding(.leading, 20)
        }
    }

    private var externalDisplay: some View {
        option(isOn: $state.fillAcrossDisplays,
               title: "When the Dock moves to another display, fill the empty space with windows",
               enabled: state.moveFromUnderDock)
    }

    private var fixNow: some View {
        // The result goes under the button rather than beside it, where a
        // longer sentence had no room.
        VStack(alignment: .leading, spacing: 6) {
            Button { state.moveWindows() } label: {
                Label(state.isBusy ? "Fixing…" : "Fix Windows Now", systemImage: "wrench.and.screwdriver")
            }
                .buttonStyle(SoftButtonStyle(emphasised: true))
                .keyboardShortcut(.defaultAction)
                .disabled(state.isBusy)
            activity
        }
    }

    /// What the last pass did, and when. Nothing until something happened: an
    /// empty line is not worth a sentence.
    @ViewBuilder
    private var activity: some View {
        if let activity = state.lastActivity {
            // Counted from the event, not from the clock's minute: `.everyMinute`
            // ticks on the minute, so "just now" lasted anywhere up to two.
            TimelineView(.periodic(from: activity.date, by: 60)) { context in
                HStack(spacing: 6) {
                    Text("\(activity.text) · \(Self.when(activity.date, now: context.date))")
                        .foregroundStyle(activity.needsAttention ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if activity.needsAttention {
                        Button("Show Log") { openWindow(id: DockFixerApp.logWindowID) }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
            }
        }
    }

    /// `just now` for the first minute, then minutes: redrawn once a minute
    /// from the event, anything finer would sit wrong for most of it.
    private static func when(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60
            ? "just now"
            : date.formatted(.relative(presentation: .named))
    }

    // MARK: - Footer

    /// The way out: to the project, and to the log for when something looked
    /// wrong. Quitting is here too, since the menu-bar icon may be hidden.
    private var footer: some View {
        HStack(spacing: 6) {
            Button { openURL(Links.repository) } label: {
                Label { Text("GitHub") } icon: { Self.githubMark }
            }
            .buttonStyle(SoftButtonStyle())
            // A form of the app's own, not GitHub: see BugReportView.
            Button { openWindow(id: DockFixerApp.bugReportWindowID) } label: {
                Label("Report a Bug", systemImage: "ladybug")
            }
            .buttonStyle(SoftButtonStyle())
            link("Ask a Question", "questionmark.circle", Links.discussions)
            if let coffee = Links.buyMeACoffee {
                link("Buy Me a Coffee", "cup.and.saucer", coffee)
            }
            Button { openWindow(id: DockFixerApp.logWindowID) } label: {
                Label("Show Log", systemImage: "doc.text")
            }
            .buttonStyle(SoftButtonStyle())
            Spacer()
            Button { state.quit() } label: {
                Label("Quit", systemImage: "xmark.circle")
            }
            .buttonStyle(SoftButtonStyle())
        }
    }

    private func link(_ title: String, _ icon: String, _ url: URL) -> some View {
        Button { openURL(url) } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(SoftButtonStyle())
    }

    /// SF Symbols has no brand marks, so GitHub's own comes from Octicons (MIT),
    /// bundled as a PDF. A template image, so it takes the
    /// label's colour in light and dark alike.
    static var githubMark: some View {
        let image = Bundle.main.image(forResource: "github-mark") ?? NSImage()
        image.isTemplate = true
        return Image(nsImage: image)
            .resizable()
            .frame(width: 13, height: 13)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    // MARK: - Pieces

    /// One line of the page: its name flush right, then the controls.
    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
            content()
                .frame(width: Self.controlWidth, alignment: .leading)
        }
    }

    /// A checkbox, with a line under it when the title alone does not say what
    /// it does.
    private func option(isOn: Binding<Bool>,
                        title: String,
                        detail: String? = nil,
                        enabled: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // A title longer than the column wraps rather than being cut
            // with an ellipsis: a sentence is the point of these.
            Toggle(isOn: isOn) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Under the label, not under the box.
                    .padding(.leading, 20)
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// "Install updates automatically" and the button that checks right now.
///
/// A view of its own because the updater is an object of its own: observed
/// here, its changes redraw this row and nothing else.
private struct UpdatesRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Install updates automatically", isOn: $updater.automaticallyUpdates)
                // Literally what Updater does: a daily check, and an install
                // held back while a window is open. Off, Sparkle asks; an
                // update it already has still goes in at quit (Updater).
                Text("DockFixer checks for a new version once a day and installs it when this window is closed. Off, it asks first, and an update that is already downloaded waits until you quit DockFixer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            HStack(spacing: 8) {
                Button { updater.checkForUpdates() } label: {
                    Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(!updater.canCheckForUpdates)
                // The update waits for this very window to close; this is the
                // way to have it now without closing it.
                if updater.updateIsWaiting {
                    Button { updater.installNow() } label: {
                        Label("Restart to Update", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(SoftButtonStyle(emphasised: true))
                }
            }
        }
    }
}
