import AppKit
import SwiftUI

/// The menu bar icon and the dark dropdown panel under it.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = FloatingPanel(size: CGSize(width: 320, height: 470), acceptsKeyboardFocus: true)
    private var outsideClickMonitor: Any?
    private let companion: CompanionController
    private let permissionMonitor = PermissionMonitor()
    var onOpenSettings: (() -> Void)?
    var onOpenHome: (() -> Void)?
    var onOpenOnboarding: (() -> Void)?
    var onOpenLessonLibrary: (() -> Void)?

    init(companion: CompanionController) {
        self.companion = companion
        super.init()
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
            button.target = self
            button.action = #selector(togglePanel)
        }
        panel.setSwiftUIContent(
            CompanionPanelView(
                companion: companion,
                settings: AppSettings.shared,
                permissionMonitor: permissionMonitor,
                onOpenSettings: { [weak self] in self?.hidePanel(); self?.onOpenSettings?() },
                onOpenHome: { [weak self] in self?.hidePanel(); self?.onOpenHome?() },
                onOpenOnboarding: { [weak self] in self?.hidePanel(); self?.onOpenOnboarding?() },
                onOpenLessonLibrary: { [weak self] in self?.hidePanel(); self?.onOpenLessonLibrary?() },
                onTypeQuestion: { [weak self] in self?.hidePanel(); companion.showAskBar() }
            )
        )
    }

    /// A small tilted triangle, like the buddy, drawn as a template image.
    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = NSBezierPath()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let vertices = [CGPoint(x: 0, y: 7), CGPoint(x: -6, y: -4.5), CGPoint(x: 6, y: -4.5)].map { vertex -> CGPoint in
                let angle = 35.0 * Double.pi / 180
                return CGPoint(x: center.x + vertex.x * cos(angle) - vertex.y * sin(angle), y: center.y + vertex.x * sin(angle) + vertex.y * cos(angle))
            }
            path.move(to: vertices[0])
            path.line(to: vertices[1])
            path.line(to: vertices[2])
            path.close()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        permissionMonitor.refresh()
        permissionMonitor.startPolling()
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        if let fittingSize = panel.contentView?.fittingSize { panel.setContentSize(fittingSize) }
        panel.setFrameOrigin(CGPoint(x: buttonFrame.midX - panel.frame.width / 2, y: buttonFrame.minY - panel.frame.height - 6))
        panel.makeKeyAndOrderFront(nil)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
    }

    func hidePanel() {
        panel.orderOut(nil)
        permissionMonitor.stopPolling()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
}

struct CompanionPanelView: View {
    @ObservedObject var companion: CompanionController
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissionMonitor: PermissionMonitor
    let onOpenSettings: () -> Void
    let onOpenHome: () -> Void
    let onOpenOnboarding: () -> Void
    let onOpenLessonLibrary: () -> Void
    let onTypeQuestion: () -> Void

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 14) {
                header
                Text(companion.brainStatusText)
                    .font(.system(size: 11))
                    .foregroundColor(companion.isBrainReady ? DS.Colors.textSecondary : DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)

                shortcutHints

                if permissionMonitor.grantedPermissions.count < PointwisePermission.allCases.count {
                    permissionsSection
                }

                VStack(spacing: 8) {
                    panelButton("Type a question", systemImage: "keyboard", action: onTypeQuestion)
                    panelButton("Lesson library", systemImage: "square.grid.2x2", action: onOpenLessonLibrary)
                    panelButton("Lessons and study notes", systemImage: "book.closed", action: onOpenHome)
                    panelButton("New lesson", systemImage: "arrow.counterclockwise") { companion.startNewLesson() }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Teacher").font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
                    Picker("", selection: $settings.modelIdentifier) {
                        ForEach(ClaudeModelOption.all) { option in Text(option.displayName).tag(option.id) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                VStack(spacing: 6) {
                    settingToggle("Speak answers aloud", isOn: $settings.speaksAloud)
                    settingToggle("Show captions", isOn: $settings.captionsEnabled)
                    settingToggle("Pointwise can click and type for me", isOn: $settings.actionsEnabled)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)

                Divider().overlay(DS.Colors.borderSubtle)

                HStack {
                    Button("Settings…", action: onOpenSettings).buttonStyle(.plain).foregroundColor(DS.Colors.textSecondary).pointerCursorOnHover()
                    Button("Tour", action: onOpenOnboarding).buttonStyle(.plain).foregroundColor(DS.Colors.textSecondary).pointerCursorOnHover()
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundColor(DS.Colors.textSecondary).pointerCursorOnHover()
                }
                .font(.system(size: 12))
            }
            .padding(16)
            .frame(width: 320)
        }
    }

    private func settingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BuddyTriangle()
                .fill(settings.cursorColor)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(-35))
                .shadow(color: settings.cursorColor, radius: 6)
            Text("Pointwise").font(.system(size: 17, weight: .bold)).foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Text(activityLabel)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(activityColor.opacity(0.18)))
                .foregroundColor(activityColor)
        }
    }

    private var shortcutHints: some View {
        VStack(alignment: .leading, spacing: 5) {
            hintRow(keys: "⌃ ⌥", text: "Hold to talk (draw while talking to circle things)")
            hintRow(keys: "⌃ ⌃", text: "Double-tap to type a question")
            hintRow(keys: "esc", text: "Stop Pointwise")
        }
    }

    private func hintRow(keys: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(keys)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: 34)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(DS.Colors.surface3))
            Text(text).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pointwise needs a few permissions").font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.warning)
            ForEach(PointwisePermission.allCases) { permission in
                HStack(spacing: 8) {
                    Image(systemName: permission.systemImageName).frame(width: 16).foregroundColor(DS.Colors.textSecondary)
                    Text(permission.title).font(.system(size: 12)).foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                    if permissionMonitor.grantedPermissions.contains(permission) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(DS.Colors.success)
                    } else {
                        Button("Grant") { permission.request() }.buttonStyle(PointwiseButtonStyle(isProminent: true))
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(DS.Colors.surface1))
    }

    private func panelButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).frame(width: 16)
                Text(title)
                Spacer()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.Colors.surface2))
        }
        .buttonStyle(.plain)
        .pointerCursorOnHover()
    }

    private var activityLabel: String {
        switch companion.activity {
        case .idle: return companion.isBrainReady ? "Ready" : "Starting"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .waitingForLearner: return "Your turn"
        }
    }

    private var activityColor: Color {
        switch companion.activity {
        case .idle: return companion.isBrainReady ? DS.Colors.success : DS.Colors.warning
        case .listening: return DS.Colors.accentText
        case .thinking: return DS.Colors.warning
        case .speaking: return DS.Colors.accentText
        case .waitingForLearner: return DS.Colors.warning
        }
    }
}
