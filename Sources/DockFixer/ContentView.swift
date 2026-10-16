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

/// The one warm thing in a grey window: the button that asks for support.
///
/// Same size and corners as `SoftButtonStyle`, so it sits in the row as an
/// equal, but filled with Buy Me a Coffee's own yellow. Everything else in
/// the window is grey, blue or white, and a request that looks like every
/// other button is a request nobody notices. The yellow is the same in light
/// and dark: it is a brand colour, and dark text stays readable on it in both.
struct DonateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Filled(configuration: configuration)
    }

    private struct Filled: View {
        let configuration: Configuration
        @State private var hovering = false

        /// Buy Me a Coffee's #FFDD00.
        private static let yellow = Color(red: 1, green: 0xDD / 255, blue: 0)

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Self.yellow)
                        // Darkened rather than lightened on press and hover:
                        // a lighter yellow on a light window would fade out.
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(configuration.isPressed ? 0.15 : hovering ? 0.06 : 0))
                        )
                )
                .foregroundStyle(Color.black.opacity(0.85))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .fixedSize()
                .onHover { hovering = $0 }
        }
    }
}

/// Where the links in the window go.
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


                   **Log lines** (DockFixer window → Settings → Show Log → Copy Log)

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

/// The main window: a line saying which app this is, a row of tabs, as in
/// a Mac app's settings window, the page of the chosen tab, and a foot that
/// is the same on every tab.
///
/// The tabs are drawn here rather than left to SwiftUI. A `TabView` gives the
/// toolbar of icons over titles only inside a `Settings` scene; in a `Window`
/// scene it draws a segmented control instead, and this window has to stay a
/// `Window` — the app delegate hides, rebuilds and finds it by title, none of
/// which a `Settings` scene allows. Putting a real toolbar into the title bar
/// from AppKit would fight SwiftUI, which owns that toolbar and rebuilds it.
///
/// The window is sized by the page it shows, as settings windows on the Mac
/// always were: a short page does not sit in a tall window of empty space,
/// and the width never changes, so the tabs and the foot stay where they are.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    static let width: CGFloat = 600
    /// Section names sit flush right in a column of their own, as in macOS
    /// settings. Fixed widths, not a `Form`, so the window sized by its
    /// contents has nothing to negotiate.
    static let labelWidth: CGFloat = 100
    static let controlWidth: CGFloat = 448

    var body: some View {
        Group {
            if state.isTrusted {
                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                    tabBar
                    Divider()
                    page
                        .padding(20)
                    Divider()
                    footer
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
            } else {
                OnboardingView()
                    .padding(20)
            }
        }
        .frame(width: Self.width)
        .animation(.easeInOut(duration: 0.2), value: state.isTrusted)
        .onChange(of: state.isTrusted) { _, trusted in
            // The switch was turned on in System Settings, which is in front.
            // Coming forward shows that it worked, and that there is a next step.
            if trusted { NSApp.activate() }
        }
    }

    // MARK: - Tabs

    private struct Tab: Identifiable {
        let page: AppState.Page
        let title: String
        let icon: String
        var id: AppState.Page { page }
    }

    private static let tabs: [Tab] = [
        Tab(page: .stats, title: "Stats", icon: "chart.bar"),
        Tab(page: .rules, title: "Rules", icon: "dock.rectangle"),
        Tab(page: .settings, title: "Settings", icon: "gearshape"),
    ] + (DebugView.isAvailable
         // DEV ONLY: a development build has a Debug tab; a release never does.
         ? [Tab(page: .debug, title: "Debug", icon: "ant")]
         : [])

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Self.tabs) { tab in
                TabButton(title: tab.title, icon: tab.icon, selected: state.page == tab.page) {
                    // Only a real change: every write to a @Published
                    // property redraws the whole window.
                    if state.page != tab.page { state.page = tab.page }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var page: some View {
        switch state.page {
        case .stats: StatsView()
        case .rules: rules
        case .settings: settings
        // A release has no tab that leads here; should something set the
        // page anyway, it shows the settings instead.
        case .debug: if DebugView.isAvailable { DebugView() } else { settings }
        }
    }

    // MARK: - Rules

    private var rules: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 16) {
            Self.row("Screens") { screens }
            Self.row("Move windows") { dock }
            Self.row("External display") { externalDisplay }
        }
    }

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

    private var dock: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Each title finishes the sentence the row's name starts: "Move
            // windows" · "that are under the Dock". Cut by what happens to a
            // window, not by what set it off; the wording is kept to the
            // simplest English that is still literally true.
            Self.option(isOn: $state.moveFromUnderDock,
                        title: "Move windows that are under the Dock")
            // "Stick" promises the window ends up against the Dock, which is
            // true for one that was next to it or within a few points of it.
            // A window in the middle of the screen is not read as "windows".
            Self.option(isOn: $state.stickToDock,
                        title: "Stick windows to the Dock when it changes size or moves",
                        enabled: state.moveFromUnderDock)
            // Pixels, not points: points mean nothing to most people, and on
            // a Retina display the number is twice the points.
            Self.option(isOn: $state.ignoreSmallDockChanges,
                        title: "Skip very small changes (about \(Int(dockNoise) * 2) pixels)",
                        enabled: state.moveFromUnderDock && state.stickToDock)
                .padding(.leading, 20)
        }
    }

    private var externalDisplay: some View {
        Self.option(isOn: $state.fillAcrossDisplays,
                    title: "When the Dock moves to another display, fill the empty space with windows",
                    enabled: state.moveFromUnderDock)
    }

    // MARK: - Settings

    private var settings: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 16) {
            Self.row("Startup") {
                Toggle("Launch at login", isOn: $state.launchAtLogin)
            }
            Self.row("Menu bar") {
                Self.option(isOn: $state.hideMenuBarIcon,
                            title: "Hide menu bar icon",
                            detail: "Open DockFixer again to show this window or quit.")
            }
            Self.row("Updates") { UpdatesRow(updater: state.updater) }
            Self.row("Statistics") {
                // What exactly goes out is in the README, linked from
                // there to UsageReport.event; the switch only has to say
                // what it is. The Stats tab does not depend on it: that
                // history never leaves the Mac.
                Self.option(isOn: $state.sendUsageStatistics,
                            title: "Send usage statistics")
            }
            Self.row("Help") { help }
        }
    }

    // MARK: - Header

    /// Who the app is, on one quiet line over the tabs, where an About box
    /// would be in another app: the version is what a bug report needs
    /// first, and it is the same on every tab.
    ///
    /// Small and on a line of its own, left-aligned while the tabs are
    /// centred: an icon as large as a tab's, or in the same row, would read
    /// as one more tab.
    private var header: some View {
        HStack(alignment: .center, spacing: 7) {
            AppIconView(size: 20)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("DockFixer")
                    .font(.system(size: 13, weight: .semibold))
                Text(Self.version)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("Keeps your windows away from the Dock")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
            Spacer(minLength: 0)
        }
    }

    /// The ways to get help: a form of the app's own, the project's
    /// discussions, and the log for when something looked wrong.
    private var help: some View {
        HStack(spacing: 6) {
            // A form of the app's own, not GitHub: see BugReportView.
            Button { openWindow(id: DockFixerApp.bugReportWindowID) } label: {
                Label("Report a Bug", systemImage: "ladybug")
            }
            .buttonStyle(SoftButtonStyle())
            Button { openURL(Links.discussions) } label: {
                Label("Ask a Question", systemImage: "questionmark.circle")
            }
            .buttonStyle(SoftButtonStyle())
            Button { openWindow(id: DockFixerApp.logWindowID) } label: {
                Label("Show Log", systemImage: "doc.text")
            }
            .buttonStyle(SoftButtonStyle())
            // The project itself: the code, the releases, the issues.
            Button { openURL(Links.repository) } label: {
                Label { Text("GitHub") } icon: { Self.githubMark }
            }
            .buttonStyle(SoftButtonStyle())
        }
    }

    // MARK: - Footer

    /// The same on every tab. Support first, where it is seen; the one
    /// thing the app does, on demand, with what it last did beside it; and
    /// Quit, which has to be reachable from any tab since the menu-bar icon
    /// may be hidden.
    private var footer: some View {
        HStack(spacing: 6) {
            // Hidden in a release until there is a page to send people to;
            // a development build shows it so the row can be judged.
            if Links.buyMeACoffee != nil || DebugView.isAvailable {
                DonateButton()
                    .padding(.trailing, 6)
            }
            FixNowControl()
            Spacer(minLength: 12)
            Button { state.quit() } label: {
                Label("Quit", systemImage: "xmark.circle")
            }
            .buttonStyle(SoftButtonStyle())
        }
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

    /// One line of a page: its name flush right, then the controls. Static,
    /// so the Stats tab can lay its numbers out in the same two columns.
    static func row<Content: View>(_ label: String,
                                   @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
            content()
                .frame(width: controlWidth, alignment: .leading)
        }
    }

    /// A checkbox, with a line under it when the title alone does not say what
    /// it does.
    private static func option(isOn: Binding<Bool>,
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

/// One tab at the top of the window: an icon over its title, the chosen one
/// on a soft rounded fill with its icon in the accent colour — the way the
/// toolbar of a Mac settings window marks the page it shows.
private struct TabButton: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .frame(height: 22)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .frame(minWidth: 56)
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.08 : hovering ? 0.04 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// "Buy Me a Coffee", in the warm style. On the Stats tab as well as at the
/// foot of the window, so it is one view.
struct DonateButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = Links.buyMeACoffee {
                openURL(url)
            } else {
                // Only a development build shows the button without a page.
                AppState.current?.log.info("Buy Me a Coffee: no page yet")
            }
        } label: {
            Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
        }
        .buttonStyle(DonateButtonStyle())
    }
}

/// "Fix Windows Now" and, beside it, what its last press did. In the foot of
/// the window, so it is there on every tab.
struct FixNowControl: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The result goes beside the button, on the same line, cut short if
        // it is long: under the button it made the window taller the moment
        // it appeared, and every tab with it.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { state.moveWindows() } label: {
                Label(state.isBusy ? "Fixing…" : "Fix Windows Now", systemImage: "wrench.and.screwdriver")
            }
                .buttonStyle(SoftButtonStyle(emphasised: true))
                .keyboardShortcut(.defaultAction)
                .disabled(state.isBusy)
            activity
        }
    }

    /// What the last press of the button did, and when. Nothing before the
    /// first press: automatic passes answer no one here.
    @ViewBuilder
    private var activity: some View {
        if let activity = state.fixNowResult {
            // Counted from the event, not from the clock's minute: `.everyMinute`
            // ticks on the minute, so "just now" lasted anywhere up to two.
            TimelineView(.periodic(from: activity.date, by: 60)) { context in
                let text = "\(activity.text) · \(Self.when(activity.date, now: context.date))"
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(text)
                        .foregroundStyle(activity.needsAttention ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // The whole sentence, for when the line is cut.
                        .help(text)
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
}

/// "Install updates automatically" and the button that checks right now.
///
/// A view of its own because the updater is an object of its own: observed
/// here, its changes redraw this row and nothing else.
private struct UpdatesRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Install updates automatically", isOn: $updater.automaticallyUpdates)
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

