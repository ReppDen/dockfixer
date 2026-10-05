import AppKit
import SwiftUI

/// What the window shows until Accessibility access is granted.
///
/// Without the grant every switch in the settings does nothing, so showing them
/// would only be a list of controls that look broken. This takes their place,
/// says what is needed and why, and gets out of the way on its own: the grant
/// is polled, so the settings appear the moment the switch in System Settings
/// is turned on, with nothing to press here afterwards.
///
/// It comes back if the grant is ever revoked, for the same reason.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                AppIconView(size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("DockFixer needs Accessibility access")
                        .font(.system(size: 15, weight: .semibold))
                    Text("""
                         macOS only lets an app move other apps' windows with this \
                         permission. DockFixer uses it for that and nothing else.
                         """)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                step(1, "Press Open System Settings below.")
                step(2, "Turn on the switch next to DockFixer.")
                // The row is added by the system prompt shown at launch. If that
                // prompt was dismissed before the row existed, there is nothing
                // to switch on, and the list alone does not say what to do.
                Text("Not in the list? Press + under it and choose DockFixer from Applications.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }

            Button("Open System Settings") { state.requestAccessibility() }
                .buttonStyle(SoftButtonStyle(emphasised: true))
                .keyboardShortcut(.defaultAction)

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for permission…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                // Without the grant there is nothing else to do here, and
                // declining is a legitimate answer.
                Button("Quit") { state.quit() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(0.1)))
            Text(text)
                .font(.system(size: 13))
        }
    }
}
