import AppKit
import DockFixerCore
import SwiftUI

/// What the bug report window holds between openings, and the sending.
///
/// Owned by `AppState` rather than by the window, so closing the window half
/// way through writing does not throw the words away.
@MainActor
final class BugReportForm: ObservableObject {
    enum Status: Equatable {
        case editing
        case sending
        case sent
        case failed(String)
    }

    @Published var message = ""
    @Published var email = ""
    @Published var attachLog = true
    @Published private(set) var status: Status = .editing
    /// The log text "See What's Sent" shows; set, the sheet is up.
    @Published var preview: String?

    private let log: Log

    init(log: Log) {
        self.log = log
    }

    /// A build without the PostHog key has nowhere to send to.
    var canSendAtAll: Bool { AppState.usageKey != nil }

    var canSend: Bool {
        canSendAtAll && status != .sending && BugReport.canSend(message: message)
    }

    /// Read off the main thread: the two files together can be ten megabytes.
    private func recentLog() async -> String {
        let directory = log.fileURL.deletingLastPathComponent()
        return await Task.detached(priority: .userInitiated) {
            RecentLog.read(directory: directory)
        }.value
    }

    func showPreview() {
        Task { preview = await recentLog() }
    }

    func send(state: AppState) {
        guard canSend, let key = AppState.usageKey else { return }
        status = .sending
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let settings = state.settingsForReport
        let displays = state.displaysSummary
        let distinctID = state.distinctIDForReport
        // Taken now: the form is locked while sending, but what goes out is
        // what was on screen when Send was pressed.
        let message = self.message, email = self.email, attachLog = self.attachLog
        Task {
            let logText = attachLog ? await recentLog() : nil
            let report = BugReport(message: message,
                                   email: email,
                                   version: version,
                                   system: ProcessInfo.processInfo.operatingSystemVersionString,
                                   settings: settings,
                                   displays: displays,
                                   log: logText)
            let data = report.event(distinctID: distinctID, eventID: UUID().uuidString.lowercased(),
                                    timestamp: Date(), apiKey: key)
            let delivery = await PostHog.deliver(data, version: version, compress: true)
            // What was sent is the person's business; that it was is the log's.
            let size = logText.map { " with \(ByteCountFormatter.string(fromByteCount: Int64($0.utf8.count), countStyle: .file)) of log" } ?? " without the log"
            if delivery.isAccepted {
                log.info("bug report sent\(size) — \(delivery.description)")
                self.message = ""
                self.email = ""
                self.attachLog = true
                status = .sent
            } else {
                log.add(level: .fail, app: "DockFixer", title: "",
                        detail: "bug report not sent\(size) — \(delivery.description)")
                status = .failed(delivery.description)
            }
        }
    }

    /// Back to an empty form after a report went, the next time the window opens.
    func startOver() {
        if status == .sent { status = .editing }
    }
}

/// The bug report window: a few words, an email if wanted, the log if allowed,
/// and Send. No account anywhere — the GitHub issue form lost everyone who had
/// none — but GitHub stays one click away for those who prefer it.
struct BugReportView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var form: BugReportForm
    @Environment(\.openURL) private var openURL
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if form.status == .sent {
                sent
            } else {
                editing
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { form.startOver() }
        .sheet(isPresented: Binding(get: { form.preview != nil },
                                    set: { shown in if !shown, form.preview != nil { form.preview = nil } })) {
            LogPreview(text: form.preview ?? "") { form.preview = nil }
        }
    }

    private var editing: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 6) {
                Text("What happened?")
                TextEditor(text: $form.message)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 120)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor)))
                    .disabled(form.status == .sending)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Your email (optional)")
                TextField("", text: $form.email, prompt: Text("name@example.com"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(form.status == .sending)
                caption("Only to answer you. Leave it empty if you don't need an answer.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Attach the log", isOn: $form.attachLog)
                    .disabled(form.status == .sending)
                // Literally what the log holds: application names, and window
                // titles cut to thirty characters (see `Log.format`).
                caption("The last 24 hours of the DockFixer log. It has app names and the start of window titles.")
                    .padding(.leading, 20)
                Button { form.showPreview() } label: {
                    Label("See What's Sent", systemImage: "eye")
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(!form.attachLog)
                .padding(.leading, 20)
            }

            // Every other thing `BugReport.event` puts in, in words.
            caption("The report also has the DockFixer and macOS versions, your DockFixer settings, and your screens.")

            Divider()
            status
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIconView(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Report a Bug")
                    .font(.system(size: 17, weight: .semibold))
                Text("Your report goes straight to the developer. You don't need an account.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if !form.canSendAtAll {
            caption("This copy of DockFixer can't send reports. Please open an issue on GitHub instead.")
                .foregroundStyle(Color.orange)
        } else if case .failed(let why) = form.status {
            caption("The report was not sent: \(why). Try again, or open an issue on GitHub instead.")
                .foregroundStyle(Color.orange)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { form.send(state: state) } label: {
                Label(form.status == .sending ? "Sending…" : "Send", systemImage: "paperplane")
            }
            .buttonStyle(SoftButtonStyle(emphasised: true))
            .disabled(!form.canSend)
            if form.status == .sending {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button { openURL(Links.bugReport(screens: state.screens)) } label: {
                Label { Text("Open an Issue on GitHub") } icon: { ContentView.githubMark }
            }
            .buttonStyle(SoftButtonStyle())
        }
    }

    private var sent: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text("Thanks — the report was sent.")
                .font(.system(size: 15, weight: .semibold))
            Button { dismissWindow() } label: {
                Label("Close", systemImage: "xmark")
            }
            .buttonStyle(SoftButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The log exactly as it would go, read-only. An AppKit text view: a day of a
/// debug log is hundreds of kilobytes, which a SwiftUI `Text` lays out slowly.
private struct LogPreview: View {
    let text: String
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text.isEmpty
                 ? "The log has nothing from the last 24 hours, so no log lines will be sent."
                 : "This is the log that goes with your report (\(ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file))).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ReadOnlyText(text: text)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor)))
            HStack {
                Spacer()
                Button { done() } label: { Label("Done", systemImage: "checkmark") }
                    .buttonStyle(SoftButtonStyle(emphasised: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 720, height: 440)
    }
}

private struct ReadOnlyText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.string = text
        // The newest lines are at the end, and they are the ones that matter.
        view.scrollToEndOfDocument(nil)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }
}
