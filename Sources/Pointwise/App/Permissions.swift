import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

/// The three macOS permissions Pointwise uses, with friendly explanations.
enum PointwisePermission: CaseIterable, Identifiable {
    case microphone
    case screenRecording
    case accessibility

    var id: Self { self }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }

    var reason: String {
        switch self {
        case .microphone: return "Hear your question while you hold Control + Option."
        case .screenRecording: return "See your screen so Pointwise can point and teach."
        case .accessibility: return "Notice the hotkeys, and click for you when you allow it."
        }
    }

    var systemImageName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "keyboard.fill"
        }
    }

    var isGranted: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .accessibility: return AXIsProcessTrusted()
        }
    }

    private var settingsPaneURL: URL? {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    /// Shows the system prompt the first time, and opens System Settings after that.
    @MainActor
    func request() {
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                openSystemSettings()
            }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openSystemSettings() }
        case .accessibility:
            let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(promptOptions) { openSystemSettings() }
        }
    }

    func openSystemSettings() {
        if let settingsPaneURL { NSWorkspace.shared.open(settingsPaneURL) }
    }

    static var allGranted: Bool { allCases.allSatisfy(\.isGranted) }
}

/// Publishes permission changes while a window that shows them is open.
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var grantedPermissions: Set<PointwisePermission> = []
    private var pollTimer: Timer?

    init() { refresh() }

    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        let currentlyGranted = Set(PointwisePermission.allCases.filter(\.isGranted))
        if currentlyGranted != grantedPermissions { grantedPermissions = currentlyGranted }
    }
}
