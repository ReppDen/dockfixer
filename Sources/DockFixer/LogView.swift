import DockFixerCore
import SwiftUI

/// The log, in a window of its own.
///
/// It is for when something looked wrong, which is not what the settings are
/// for, and it wants to be wide where the settings want to be narrow. Kept
/// apart, neither has to change shape for the other.
struct LogView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var log: Log

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            entries
            HStack(spacing: 8) {
                Button("Copy Log") { state.copyLog() }
                Button("Clear Log") { state.clearLog() }
                Spacer()
                Button("Reveal in Finder") { state.openLogFile() }
            }
        }
        .padding(14)
        .frame(minWidth: 640, minHeight: 320)
    }

    private var entries: some View {
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
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor))
            )
            .onAppear {
                if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
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
        // Dimmer than the rest: in a debug build these outnumber everything
        // else, and they are background to whatever is being looked for.
        case .debug: return .secondary.opacity(0.6)
        case .info: return .secondary
        case .moved: return .green
        case .skip: return .orange
        case .fail: return .red
        }
    }
}
