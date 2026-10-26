import AppKit
import SwiftUI

/// A transparent, click-through window that covers one display. During a
/// click quiz it catches clicks instead, so the answer click never reaches
/// (and never changes) the app underneath.
final class OverlayWindow: NSWindow {
    var onCapturedClick: ((CGPoint) -> Void)?

    init(screenFrame: CGRect) {
        super.init(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hasShadow = false
        hidesOnDeactivate = false
        setFrame(screenFrame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let onCapturedClick {
            onCapturedClick(convertPoint(toScreen: event.locationInWindow))
            return
        }
        super.sendEvent(event)
    }
}

/// Creates one overlay window per display and rebuilds them when displays change.
@MainActor
final class OverlayWindowManager {
    private(set) var overlayWindows: [OverlayWindow] = []
    private let state: OverlayState
    private var screenChangeObserver: NSObjectProtocol?

    init(state: OverlayState) {
        self.state = state
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindows() }
        }
    }

    func showOverlay() {
        if overlayWindows.isEmpty { rebuildWindows() }
        state.startTicking()
    }

    func rebuildWindows() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows = NSScreen.screens.map { screen in
            let window = OverlayWindow(screenFrame: screen.frame)
            let hostingView = NSHostingView(rootView: OverlayScreenView(screenFrame: screen.frame, state: state, settings: AppSettings.shared))
            hostingView.frame = CGRect(origin: .zero, size: screen.frame.size)
            window.contentView = hostingView
            window.orderFrontRegardless()
            return window
        }
    }

    /// While a handler is set, overlay windows take clicks and report them in global coordinates.
    func captureClicks(_ handler: ((CGPoint) -> Void)?) {
        for window in overlayWindows {
            window.onCapturedClick = handler
            window.ignoresMouseEvents = handler == nil
        }
        let shouldCapture = handler != nil
        guard shouldCapture != isCapturingClicks else { return }
        isCapturingClicks = shouldCapture
        if shouldCapture { NSCursor.crosshair.push() } else { NSCursor.pop() }
    }

    private var isCapturingClicks = false

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }
}
