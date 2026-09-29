import DockFixCore
import SwiftUI

/// A wide, softly filled button: the shape the controls in this window take.
///
/// AppKit's default push button is sized to its text, so a row of them reads as
/// a ragged line of small boxes. These stretch to share the row evenly, which
/// gives the window a spine and makes the primary action look like the point of
/// it rather than an afterthought.
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
                .font(.system(size: 13))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(fill))
                )
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var log: Log

    /// Wide enough for a wall of log lines; narrow enough to be just the
    /// controls when they are all there is.
    private static let wideWidth: CGFloat = 860
    private static let narrowWidth: CGFloat = 560
    private static let padding: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Screens") { screens }
            section("Behaviour") { behaviour }
            actions
            if state.showLogs {
                logPane
                logActions
            }
            footer
        }
        .padding(Self.padding)
        .frame(width: state.showLogs ? Self.wideWidth : Self.narrowWidth)
    }

    // MARK: - Section chrome

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.6)
            content()
        }
    }

    // MARK: - Screens

    /// One row per display: what it is, and what the Dock is doing on it.
    ///
    /// The Dock's whereabouts are the whole reason this app exists, so they are
    /// shown rather than described — it is also the fastest way to tell whether
    /// DockFix is seeing the same layout you are.
    private var screens: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(state.screens, id: \.displayID) { screen in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(screen.localizedName)
                                .font(.system(size: 13, weight: .medium))
                            if screen.isPrimary, state.screens.count > 1 {
                                Text("PRIMARY")
                                    .font(.system(size: 9, weight: .semibold))
                                    .kerning(0.4)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule().fill(Color.primary.opacity(0.1))
                                    )
                            }
                        }
                        Text(describe(screen))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    /// `1920 × 1080  ·  Dock on the left, 48 pt wide`
    private func describe(_ screen: ScreenInfo) -> String {
        let size = "\(Int(screen.axFrame.width)) × \(Int(screen.axFrame.height))"
        let insets = screen.insets
        let edges = [("left", insets.left, "wide"),
                     ("right", insets.right, "wide"),
                     ("bottom", insets.bottom, "tall")]

        guard let dock = edges.max(by: { $0.1 < $1.1 }), dock.1 > 1 else {
            return size + "  ·  No Dock on this display"
        }
        return size + "  ·  Dock on the \(dock.0), \(Int(dock.1.rounded())) pt \(dock.2)"
    }

    // MARK: - Behaviour

    private var behaviour: some View {
        VStack(alignment: .leading, spacing: 12) {
            accessibilityRow

            option(isOn: $state.autoFixEnabled,
                   title: "Move windows out from under the Dock",
                   detail: """
                           Connecting or disconnecting a display makes macOS shuffle \
                           windows around, and some of them land underneath the Dock \
                           with their edges out of reach. This slides them back into \
                           the usable area as soon as that happens — and does the same \
                           for a new window that opens underneath it.
                           """)

            option(isOn: $state.reclaimEnabled,
                   // No mention of an edge anywhere in here: the Dock can sit on
                   // any side, and the wording has to hold for all of them.
                   title: "Reclaim the space the Dock leaves behind",
                   detail: """
                           When the Dock moves to another display, the one it was on \
                           keeps an empty band the size of the Dock. Windows that filled \
                           the screen stretch into it; windows that were resting against \
                           the Dock move over to take it.
                           """,
                   // Knowing where the Dock used to be needs the display
                   // watcher, so this can only do anything while the option
                   // above is on.
                   enabled: state.autoFixEnabled,
                   indented: true)

            // No explanation: this one says all it needs to.
            option(isOn: $state.launchAtLogin, title: "Launch at login")
        }
    }

    /// A checkbox, with the reason for it underneath when the title alone does
    /// not carry it.
    private func option(isOn: Binding<Bool>,
                        title: String,
                        detail: String? = nil,
                        enabled: Bool = true,
                        indented: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Line the explanation up with the checkbox's label rather
                    // than with the box itself.
                    .padding(.leading, 20)
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .padding(.leading, indented ? 20 : 0)
    }

    /// Accessibility comes first because nothing below it works without it.
    private var accessibilityRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.isTrusted ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(state.isTrusted
                 ? "Accessibility access granted"
                 : "Accessibility access needed to move other apps' windows")
                .font(.system(size: 12))
                .foregroundStyle(state.isTrusted ? .secondary : .primary)
            Spacer()
            if !state.isTrusted {
                Button("Open Privacy Settings…") { state.requestAccessibility() }
                    .buttonStyle(SoftButtonStyle(emphasised: true))
                    .fixedSize()
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            // The button says what it is doing rather than sitting next to a
            // spinner: a spinner needs a slot of its own, and an empty slot
            // makes the row look mis-set for the whole time nothing is running.
            Button(state.isBusy ? "Fixing…" : "Fix Windows Now") { state.moveWindows() }
                .buttonStyle(SoftButtonStyle(emphasised: true))
                .keyboardShortcut(.defaultAction)
                .disabled(state.isBusy)

            Button(state.showLogs ? "Hide Logs" : "Show Logs") {
                state.showLogs.toggle()
            }
            .buttonStyle(SoftButtonStyle())

            Button("Quit") { state.quit() }
                .buttonStyle(SoftButtonStyle())
        }
    }

    // MARK: - Log

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if log.entries.isEmpty {
                        Text("Nothing yet. Press Fix Windows Now, or unplug a display.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                    ForEach(log.entries) { entry in
                        Text(Log.format(entry))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: entry.level))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                    }
                }
                .padding(6)
            }
            // A scroll view has no height of its own, and the window is now
            // exactly its contents, so without this the pane collapses to
            // nothing and the log looks empty.
            .frame(height: 320)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor))
            )
            .onChange(of: log.entries.count) {
                // Follow the tail, which is where new results appear.
                if let last = log.entries.last {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// Only useful with the log on show, so only there.
    private var logActions: some View {
        HStack(spacing: 8) {
            Button("Clear Log") { state.clearLog() }
                .buttonStyle(SoftButtonStyle())
            Button("Copy Log") { state.copyLog() }
                .buttonStyle(SoftButtonStyle())
            Button("Reveal Log File") { state.openLogFile() }
                .buttonStyle(SoftButtonStyle())
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        // Dimmer than the rest: in a debug build these outnumber everything
        // else, and they are background to whatever is being looked for.
        case .debug: return .secondary.opacity(0.6)
        case .info: return .secondary
        case .moved: return .green
        case .skip: return .orange
        case .fail: return .red
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let summary = state.lastSummary {
                Text(summary.headline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }
}
