import DockFixCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var log: Log

    /// Wide enough for a wall of log lines; narrow enough to be just the
    /// controls when they are all there is.
    private static let wideWidth: CGFloat = 820
    private static let narrowWidth: CGFloat = 430

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            controls
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
                }
            }
            Text(state.displaysSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Fix windows automatically when displays change", isOn: $state.autoFixEnabled)
                .toggleStyle(.checkbox)
                .help("Move windows that ended up underneath the Dock out into the usable area")
            Toggle("Follow the Dock when it leaves a display", isOn: $state.reclaimEnabled)
                .toggleStyle(.checkbox)
                .padding(.leading, 18)
                // Knowing where the Dock used to be needs the display watcher,
                // so this can only do anything while the option above is on.
                .disabled(!state.autoFixEnabled)
                .help("When the Dock moves to another display, stretch windows that were maximised into the strip it leaves behind, and slide across the ones that were resting against it")
            Toggle("Launch at login", isOn: $state.launchAtLogin)
                .toggleStyle(.checkbox)
                .help("DockFix has to be running when a display is unplugged for the automatic pass to happen")

            HStack(spacing: 8) {
                Button("Check Windows") { state.checkWindows() }
                    .disabled(state.isBusy)
                    .help("List the windows that overlap the Dock or the menu bar without moving anything")

                Button("Move Windows") { state.moveWindows() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isBusy)
                    .help("Move and, where needed, narrow those windows so they clear the Dock")

                if state.isBusy {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Button(state.showLogs ? "Hide Logs" : "Show Logs") {
                    state.showLogs.toggle()
                }
                Button("Quit") { state.quit() }
            }
        }
    }

    /// Only useful with the log on show, so only there.
    private var logActions: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Clear Log") { state.clearLog() }
                .controlSize(.small)
            Button("Copy Log") { state.copyLog() }
                .controlSize(.small)
            Button("Reveal Log File") { state.openLogFile() }
                .controlSize(.small)
        }
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
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
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
