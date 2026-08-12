import DockFixCore
import SwiftUI

/// A wide, softly filled button: the shape the controls in this window take.
///
/// AppKit's default push button is sized to its text, so a row of them reads as
/// a ragged line of small boxes. These stretch to share the row evenly, which
/// gives the window a spine and makes the primary actions look like the point
/// of it rather than an afterthought.
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

/// The round one, for a single glyph.
struct RoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(width: 26, height: 26)
            .background(
                Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.22 : 0.09))
            )
            .foregroundStyle(.secondary)
            .contentShape(Circle())
    }
}

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var log: Log

    @State private var showingHelp = false

    /// Wide enough for a wall of log lines; narrow enough to be just the
    /// controls when they are all there is.
    private static let wideWidth: CGFloat = 820
    private static let narrowWidth: CGFloat = 470

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            settings
            actions
            if state.showLogs {
                logPane
                logActions
            }
            footer
        }
        .padding(16)
        .frame(minWidth: state.showLogs ? Self.wideWidth : Self.narrowWidth,
               minHeight: state.showLogs ? 480 : 0)
        .onAppear {
            // A window restored at the size it had when the log was on show
            // would open mostly empty. Only the collapsed case is forced: with
            // the log up, whatever size it was left at is the right one.
            guard !state.showLogs else { return }
            DispatchQueue.main.async { resizeWindow(showingLogs: false) }
        }
        .onChange(of: state.showLogs) { _, shown in
            // The frame above only sets a lower bound; the window keeps whatever
            // size it already had. Resizing it is what makes showing the log feel
            // like opening a drawer rather than revealing a cramped one.
            DispatchQueue.main.async { resizeWindow(showingLogs: shown) }
        }
    }

    /// Grows the window for the log, and shrinks it back to fit the controls.
    ///
    /// The collapsed height is measured rather than guessed: `fittingSize` is
    /// what the laid-out content actually needs, so the window hugs it however
    /// the controls change.
    private func resizeWindow(showingLogs shown: Bool) {
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) })
        else { return }

        if shown {
            window.setContentSize(NSSize(width: Self.wideWidth, height: 560))
        } else {
            let height = window.contentView.map { max($0.fittingSize.height, 200) } ?? 260
            window.setContentSize(NSSize(width: Self.narrowWidth, height: height))
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.isTrusted ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(state.isTrusted
                     ? "Accessibility access granted"
                     : "Accessibility access required to move windows")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if !state.isTrusted {
                    Button("Grant…") { state.requestAccessibility() }
                        .buttonStyle(SoftButtonStyle(emphasised: true))
                        .fixedSize()
                }
            }
            Text(state.displaysSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Settings

    /// Label on the left, control on the right, the way a settings pane reads.
    /// The grid keeps the labels in one column whatever their length.
    private var settings: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
            GridRow {
                rowLabel("Displays")
                Toggle("Fix windows when displays change", isOn: $state.autoFixEnabled)
                    .toggleStyle(.checkbox)
                    .help("Move windows that ended up underneath the Dock out into the usable area")
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Toggle("Follow the Dock when it leaves a display", isOn: $state.reclaimEnabled)
                    .toggleStyle(.checkbox)
                    // Knowing where the Dock used to be needs the display
                    // watcher, so this can only do anything while the option
                    // above is on.
                    .disabled(!state.autoFixEnabled)
                    .help("When the Dock moves to another display, stretch windows that were maximised into the strip it leaves behind, and slide across the ones that were resting against it")
            }
            GridRow {
                rowLabel("Startup")
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                    .toggleStyle(.checkbox)
                    .help("DockFix has to be running when a display is unplugged for the automatic pass to happen")
            }
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("Check Windows") { state.checkWindows() }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(state.isBusy)
                    .help("List the windows that overlap the Dock or the menu bar without moving anything")

                Button("Move Windows") { state.moveWindows() }
                    .buttonStyle(SoftButtonStyle(emphasised: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isBusy)
                    .help("Move and, where needed, narrow those windows so they clear the Dock")

                // Fixed slot, so the buttons beside it do not jump width when a
                // pass starts.
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16)
                    .opacity(state.isBusy ? 1 : 0)
            }

            HStack(spacing: 8) {
                Button(state.showLogs ? "Hide Logs" : "Show Logs") {
                    state.showLogs.toggle()
                }
                .buttonStyle(SoftButtonStyle())

                Button("Quit") { state.quit() }
                    .buttonStyle(SoftButtonStyle())

                Button("?") { showingHelp.toggle() }
                    .buttonStyle(RoundButtonStyle())
                    .popover(isPresented: $showingHelp, arrowEdge: .bottom) { helpCard }
            }
        }
    }

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What DockFix does")
                .font(.system(size: 13, weight: .semibold))
            Text("""
                 Unplug a display and macOS drops your windows onto the built-in \
                 screen, often half-way under the Dock. DockFix slides them back \
                 into the usable area, narrowing them only when sliding is not \
                 enough.

                 It also works the other way round: when the Dock moves to another \
                 display, windows that were maximised stretch into the strip it \
                 leaves behind, and windows that were resting against it slide \
                 across.

                 Closing this window leaves DockFix running in the menu bar, which \
                 is where it has to be to notice a display being unplugged.
                 """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - Log

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if log.entries.isEmpty {
                        Text("Drag a window part-way under the Dock, then press Check Windows.")
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
