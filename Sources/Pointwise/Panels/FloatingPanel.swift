import AppKit
import SwiftUI

/// A borderless, non-activating panel that floats above other apps without
/// stealing focus from the app the learner is working in.
final class FloatingPanel: NSPanel {
    private let acceptsKeyboardFocus: Bool

    init(size: CGSize, acceptsKeyboardFocus: Bool = false) {
        self.acceptsKeyboardFocus = acceptsKeyboardFocus
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { acceptsKeyboardFocus }
    override var canBecomeMain: Bool { false }

    func setSwiftUIContent<Content: View>(_ content: Content) {
        let hostingView = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
        hostingView.frame = CGRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        contentView = hostingView
    }

    /// Places the panel so it stays fully on the screen that contains `anchor`.
    func place(near anchor: CGPoint, offset: CGVector, on screenFrames: [CGRect]) {
        let screenFrame = screenFrames.first { $0.contains(anchor) } ?? screenFrames.first ?? .zero
        var origin = CGPoint(x: anchor.x + offset.dx, y: anchor.y + offset.dy)
        // Flip to the other side of the anchor when the panel would leave the screen.
        if origin.x + frame.width > screenFrame.maxX - 12 { origin.x = anchor.x - offset.dx - frame.width }
        if origin.y < screenFrame.minY + 12 { origin.y = anchor.y + abs(offset.dy) }
        origin.x = min(max(origin.x, screenFrame.minX + 12), screenFrame.maxX - frame.width - 12)
        origin.y = min(max(origin.y, screenFrame.minY + 12), screenFrame.maxY - frame.height - 30)
        setFrameOrigin(origin)
    }
}

/// The rounded dark card every Pointwise panel uses.
struct PanelCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.background.opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
    }
}
