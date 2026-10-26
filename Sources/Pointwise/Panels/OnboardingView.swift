import SwiftUI

/// First-run tour: meet Pointwise, tell it about yourself, grant permissions,
/// check the Claude connection, and try the hotkey.
struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var companion: CompanionController
    @StateObject private var permissionMonitor = PermissionMonitor()
    @State private var stepIndex = 0
    let onFinish: () -> Void

    private let stepCount = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Capsule().fill(index <= stepIndex ? DS.Colors.accent : DS.Colors.surface3).frame(height: 4)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)

            Group {
                switch stepIndex {
                case 0: welcomeStep
                case 1: aboutYouStep
                case 2: permissionsStep
                default: tryItStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)

            HStack {
                if stepIndex > 0 { Button("Back") { stepIndex -= 1 }.buttonStyle(PointwiseButtonStyle()) }
                Spacer()
                Button(stepIndex == stepCount - 1 ? "Start learning" : "Continue") {
                    if stepIndex == stepCount - 1 { onFinish() } else { stepIndex += 1 }
                }
                .buttonStyle(PointwiseButtonStyle(isProminent: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .frame(width: 560, height: 500)
        .background(DS.Colors.background)
        .foregroundColor(DS.Colors.textPrimary)
        .environment(\.colorScheme, .dark)
        .onAppear { permissionMonitor.startPolling() }
        .onDisappear { permissionMonitor.stopPolling() }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            BuddyTriangle()
                .fill(settings.cursorColor)
                .frame(width: 34, height: 34)
                .rotationEffect(.degrees(-35))
                .shadow(color: settings.cursorColor, radius: 14)
                .padding(.bottom, 6)
            Text("Hi, I'm Pointwise.").font(.system(size: 30, weight: .bold))
            Text("I'm an AI teacher that lives right next to your cursor. I can see your screen, talk with you, point at things, draw on your screen, and walk you through anything step by step.")
                .font(.system(size: 15)).foregroundColor(DS.Colors.textSecondary)
            VStack(alignment: .leading, spacing: 10) {
                featureRow("hand.point.up.left.fill", "Point and draw", "I fly to buttons and circle what matters.")
                featureRow("list.number", "Walkthroughs", "I wait for you to do each step, then check your work.")
                featureRow("pencil.and.scribble", "Whiteboard and quizzes", "Formulas, diagrams, and quick checks for understanding.")
                featureRow("globe", "Any app, any subject", "Math, science, coding, writing, art, music, and more.")
            }
        }
    }

    private func featureRow(_ systemImage: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage).foregroundColor(DS.Colors.accentText).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary)
            }
        }
    }

    private var aboutYouStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tell me about you").font(.system(size: 24, weight: .bold))
            Text("I'll match my words and examples to you. You can change this later.").foregroundColor(DS.Colors.textSecondary)
            labeledField("What should I call you?", text: $settings.learnerName, placeholder: "Your first name")
            labeledField("What grade or level are you?", text: $settings.gradeLevel, placeholder: "For example: 8th grade")
            labeledField("What are you into?", text: $settings.learnerInterests, placeholder: "For example: soccer, Minecraft, drawing")
            labeledField("Anything that helps you learn?", text: $settings.learningNeeds, placeholder: "For example: go slow, short sentences")
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 13, weight: .semibold))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 8).fill(DS.Colors.surface2))
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Let me see and hear").font(.system(size: 24, weight: .bold))
            Text("macOS asks you to allow these. Screenshots stay on your Mac except when sent to Claude with your question, and are never saved.")
                .foregroundColor(DS.Colors.textSecondary)
            ForEach(PointwisePermission.allCases) { permission in
                HStack(spacing: 12) {
                    Image(systemName: permission.systemImageName).frame(width: 22).foregroundColor(DS.Colors.accentText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.title).font(.system(size: 14, weight: .semibold))
                        Text(permission.reason).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
                    }
                    Spacer()
                    if permissionMonitor.grantedPermissions.contains(permission) {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundColor(DS.Colors.success).font(.system(size: 12, weight: .semibold))
                    } else {
                        Button("Allow") { permission.request() }.buttonStyle(PointwiseButtonStyle(isProminent: true))
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.surface1))
            }
            Text("After allowing Screen Recording, macOS may ask you to reopen Pointwise.").font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary)
        }
    }

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Try it!").font(.system(size: 24, weight: .bold))
            HStack(spacing: 10) {
                Image(systemName: companion.isBrainReady ? "checkmark.seal.fill" : "hourglass")
                    .foregroundColor(companion.isBrainReady ? DS.Colors.success : DS.Colors.warning)
                Text(companion.isBrainReady ? companion.brainStatusText : "Connecting to Claude through your Claude Code login…")
                    .font(.system(size: 13))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.surface1))
            if !companion.isBrainReady {
                Text("If this does not connect, install Claude Code from claude.com/code, open Terminal, run claude, and sign in.")
                    .font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary)
            }
            VStack(alignment: .leading, spacing: 10) {
                tryRow(keys: "⌃ ⌥", text: "Hold Control + Option and say: \"Hi Pointwise, what can you teach me on this screen?\"")
                tryRow(keys: "⌃ ⌃", text: "Double-tap Control to type instead.")
                tryRow(keys: "✍︎", text: "While holding the keys, move your mouse around something to circle it.")
                tryRow(keys: "esc", text: "Press Escape any time to stop me.")
            }
        }
    }

    private func tryRow(keys: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(keys)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 40)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(DS.Colors.surface3))
            Text(text).font(.system(size: 14)).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
