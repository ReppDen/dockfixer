import AppKit
import SwiftUI

/// What the window shows instead of the tabs on the first run, and whenever
/// Accessibility access is missing.
///
/// Three screens, one at a time, each with one thing to do:
///
/// 1. Accessibility. Without the grant every switch in the tabs does
///    nothing, so showing them would only be a list of controls that look
///    broken. The grant is polled, so the screen moves on by itself the
///    moment the switch in System Settings is turned on. It comes back if the
///    grant is ever revoked, for the same reason — and that is the only one
///    of the three that can come back.
/// 2. Notifications. The quiet kind is taken silently as it opens, and the
///    system's prompt comes up straight after it. The step waits for an
///    answer there, "Not Now", or a return from System Settings, where its
///    button leads.
/// 3. "We're ready" for a second and a half, then the Stats tab.
///
/// All three share one layout and one height, so the window does not jump
/// from one to the next.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if !state.isTrusted {
                AccessibilityStep()
            } else if state.onboardingStep == .ready {
                ReadyStep()
            } else {
                NotificationsStep()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

/// An icon, a title, a sentence and the buttons, centred: the shape of every
/// onboarding screen, and all of it. Nothing sits under the buttons: one
/// thing to read and one thing to press is what makes a screen like this
/// quick to get through.
private struct StepLayout<Icon: View, Buttons: View>: View {
    let title: String
    var text: String? = nil
    @ViewBuilder let icon: Icon
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(spacing: 0) {
            icon
                .frame(height: 72)
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 18)
            if let text {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                    .padding(.top, 8)
            }
            VStack(spacing: 12) { buttons }
                .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AccessibilityStep: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        StepLayout(title: "DockFixer",
                   text: "To move windows for you, DockFixer needs Accessibility access.") {
            AppIconView(size: 72)
        } buttons: {
            Button("Open Accessibility Settings") { state.openAccessibilitySettings() }
                .buttonStyle(SoftButtonStyle(emphasised: true))
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct NotificationsStep: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        // On purpose says nothing about what the notifications will be or
        // how often: a list of what an app plans to send reads as a warning
        // of spam. It asks for the chance to show the app's worth, which is
        // what the notifications are for.
        StepLayout(title: "Let us show how DockFixer helps you") {
            Image(systemName: "bell.badge")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)
        } buttons: {
            Button("Allow Notifications") { state.allowNotifications() }
                .buttonStyle(SoftButtonStyle(emphasised: true))
                .keyboardShortcut(.defaultAction)
            // A button that looks like a line of text: the way out is there
            // for whoever wants it, without standing next to the answer the
            // screen is asking for as its equal.
            Button("Not Now") { state.skipNotifications() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        // Keyed on the permission because the screen can appear before the
        // system has said what it is; the step waits for that answer.
        .task(id: state.notificationPermission) { state.notificationsStepAppeared() }
    }
}

private struct ReadyStep: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        StepLayout(title: "We're ready to move windows for you") {
            DrawnCheckmark()
                .frame(width: 64, height: 64)
        } buttons: {
            EmptyView()
        }
        .task {
            // Long enough to watch the tick and read the line, short enough
            // not to be waited on.
            try? await Task.sleep(for: .seconds(1.5))
            state.finishOnboarding()
        }
    }
}

/// A green disc that springs in, and a tick drawn across it a moment later:
/// the "done" a person expects to see happen rather than find already there.
/// Over in about 0.6 s, so most of the step is spent reading.
private struct DrawnCheckmark: View {
    @State private var disc = false
    @State private var tick: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green)
                .scaleEffect(disc ? 1 : 0.3)
                .opacity(disc ? 1 : 0)
            Tick()
                .trim(from: 0, to: tick)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                .padding(16)
        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { disc = true }
            withAnimation(.easeOut(duration: 0.3).delay(0.25)) { tick = 1 }
        }
    }

    /// Short stroke down to the corner, long one up: drawn in that order,
    /// so the trim runs the way a hand would.
    private struct Tick: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY - rect.height * 0.1))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
            return path
        }
    }
}
