import AppKit
import SwiftUI

/// A hand-drawn mark on screen: circle, box, underline, or arrow.
struct OverlayAnnotation: Identifiable {
    enum Style { case circle, box, underline, arrow }

    let id = UUID()
    let style: Style
    /// Each stroke is a polyline in global AppKit coordinates.
    let strokes: [[CGPoint]]
    let label: String?
    let labelAnchor: CGPoint
    let createdAt: Date
    let drawDuration: TimeInterval
    var fadeOutStartedAt: Date?

    static let fadeOutDuration: TimeInterval = 0.45

    /// 0 → 1 while the marker draws the shape.
    func drawProgress(at now: Date) -> CGFloat {
        CGFloat(min(1, max(0, now.timeIntervalSince(createdAt) / drawDuration)))
    }

    func opacity(at now: Date) -> Double {
        guard let fadeOutStartedAt else { return 1 }
        return max(0, 1 - now.timeIntervalSince(fadeOutStartedAt) / Self.fadeOutDuration)
    }
}

/// Dims the screen except one region, so the learner looks exactly there.
struct OverlaySpotlight {
    let rect: CGRect
    /// Where the hole started, so a new spotlight glides from the old one.
    let fromRect: CGRect?
    let label: String?
    let startedAt: Date
    var fadeOutStartedAt: Date?

    static let moveDuration: TimeInterval = 0.45
    static let fadeDuration: TimeInterval = 0.35

    func frame(at now: Date) -> (rect: CGRect, opacity: Double) {
        let moveProgress = min(1, max(0, now.timeIntervalSince(startedAt) / Self.moveDuration))
        let easedProgress = CGFloat(moveProgress * moveProgress * (3 - 2 * moveProgress))
        var currentRect = rect
        var opacity = 1.0
        if let fromRect {
            currentRect = CGRect(
                x: fromRect.minX + (rect.minX - fromRect.minX) * easedProgress,
                y: fromRect.minY + (rect.minY - fromRect.minY) * easedProgress,
                width: fromRect.width + (rect.width - fromRect.width) * easedProgress,
                height: fromRect.height + (rect.height - fromRect.height) * easedProgress
            )
        } else {
            opacity = min(1, now.timeIntervalSince(startedAt) / Self.fadeDuration)
        }
        if let fadeOutStartedAt {
            opacity *= max(0, 1 - now.timeIntervalSince(fadeOutStartedAt) / Self.fadeDuration)
        }
        return (currentRect, opacity)
    }
}

/// A hand-drawn check mark or cross where the learner clicked in a click quiz.
struct OverlayClickMark: Identifiable {
    let id = UUID()
    let point: CGPoint
    let isCorrect: Bool
    let strokes: [[CGPoint]]
    let createdAt: Date

    static let drawDuration: TimeInterval = 0.35
    static let visibleDuration: TimeInterval = 3.2
    static let fadeDuration: TimeInterval = 0.5

    func drawProgress(at now: Date) -> CGFloat {
        CGFloat(min(1, max(0, now.timeIntervalSince(createdAt) / Self.drawDuration)))
    }

    func opacity(at now: Date) -> Double {
        let age = now.timeIntervalSince(createdAt)
        return age < Self.visibleDuration ? 1 : max(0, 1 - (age - Self.visibleDuration) / Self.fadeDuration)
    }
}

/// Everything the overlay draws, animated by an explicit tick so that any
/// frame can be rendered exactly.
@MainActor
final class OverlayState: ObservableObject {
    enum VoiceState: Equatable { case idle, listening, thinking, speaking }

    enum BuddyMode: Equatable {
        case following
        case flying
        case pointing
        case returning
    }

    // Published drawing state
    @Published var voiceState: VoiceState = .idle
    @Published var audioLevel: CGFloat = 0
    @Published private(set) var buddyPosition: CGPoint
    @Published private(set) var buddyRotationDegrees: Double = -35
    @Published private(set) var buddyScale: CGFloat = 1
    @Published private(set) var buddyOpacity: Double = 0
    @Published private(set) var buddyMode: BuddyMode = .following
    @Published private(set) var bubbleText = ""
    @Published private(set) var bubbleOpacity: Double = 0
    @Published private(set) var annotations: [OverlayAnnotation] = []
    @Published private(set) var paintTrail: [CGPoint] = []
    @Published private(set) var targetRingCenter: CGPoint?
    @Published private(set) var spotlight: OverlaySpotlight?
    @Published private(set) var clickMarks: [OverlayClickMark] = []
    /// The question of a running click quiz, shown as a banner ("Click the mitochondria").
    @Published var clickQuizPrompt: String?
    @Published var captionText = ""
    @Published var activityText: String?
    @Published private(set) var now = Date()
    @Published var cursorColor: Color = DS.Colors.defaultCursorBlue

    /// Where the learner's mouse is.
    var pointerLocationProvider: () -> CGPoint = { NSEvent.mouseLocation }
    /// When false the buddy fades away unless an interaction is running.
    var isBuddyAlwaysVisible = true { didSet { refreshBuddyVisibilityTarget() } }
    var isInteractionActive = false { didSet { refreshBuddyVisibilityTarget() } }

    /// Offset from the pointer to the buddy, so it sits beside the arrow.
    static let followOffset = CGVector(dx: 35, dy: -25)

    private var tickTimer: Timer?
    private var lastTickDate = Date()
    private var buddyVisibilityTarget: Double = 1
    private var flightStart = CGPoint.zero
    private var flightControlPoint = CGPoint.zero
    private var flightEnd = CGPoint.zero
    private var flightStartedAt = Date()
    private var flightDuration: TimeInterval = 0.8
    private var pointerLocationWhenReturnStarted = CGPoint.zero
    private var fullBubbleText = ""
    private var bubbleRevealStartedAt = Date()
    private var bubbleHideDeadline: Date?
    private var annotationSeedCounter: UInt64 = 1

    init() {
        let pointerLocation = NSEvent.mouseLocation
        buddyPosition = CGPoint(x: pointerLocation.x + Self.followOffset.dx, y: pointerLocation.y + Self.followOffset.dy)
    }

    // MARK: - Ticking

    func startTicking() {
        guard tickTimer == nil else { return }
        lastTickDate = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    func tick() {
        let currentDate = Date()
        let elapsedSeconds = min(currentDate.timeIntervalSince(lastTickDate), 0.1)
        lastTickDate = currentDate
        let pointerLocation = pointerLocationProvider()
        let followTarget = CGPoint(x: pointerLocation.x + Self.followOffset.dx, y: pointerLocation.y + Self.followOffset.dy)

        switch buddyMode {
        case .following:
            // Critically damped follow: fast but smooth, never overshoots.
            let smoothing = 1 - exp(-elapsedSeconds * 22)
            let nextPosition = CGPoint(
                x: buddyPosition.x + (followTarget.x - buddyPosition.x) * smoothing,
                y: buddyPosition.y + (followTarget.y - buddyPosition.y) * smoothing
            )
            setIfChanged(\.buddyPosition, nextPosition, tolerance: 0.05)
            setIfChanged(\.buddyRotationDegrees, -35)
            setIfChanged(\.buddyScale, 1)
        case .flying, .returning:
            if buddyMode == .returning {
                flightEnd = followTarget
                let pointerTravel = hypot(pointerLocation.x - pointerLocationWhenReturnStarted.x, pointerLocation.y - pointerLocationWhenReturnStarted.y)
                if pointerTravel > 120 {
                    buddyMode = .following
                    break
                }
            }
            advanceFlight(at: currentDate)
        case .pointing:
            break
        }

        updateBubble(at: currentDate)
        updateAnnotations(at: currentDate)

        let opacityStep = elapsedSeconds / 0.35
        let nextOpacity = buddyOpacity < buddyVisibilityTarget
            ? min(buddyVisibilityTarget, buddyOpacity + opacityStep)
            : max(buddyVisibilityTarget, buddyOpacity - opacityStep)
        setIfChanged(\.buddyOpacity, nextOpacity)

        // `now` drives time-based drawing (spinner, waveform, marker strokes).
        // Publish it only while something is moving to keep idle CPU near zero.
        let needsContinuousFrames = voiceState != .idle
            || buddyMode != .following
            || !annotations.isEmpty
            || targetRingCenter != nil
            || bubbleOpacity > 0
            || spotlight != nil
            || !clickMarks.isEmpty
            || clickQuizPrompt != nil
        if needsContinuousFrames || buddyOpacity != buddyVisibilityTarget {
            now = currentDate
        }
    }

    private func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<OverlayState, Value>, _ newValue: Value) {
        if self[keyPath: keyPath] != newValue { self[keyPath: keyPath] = newValue }
    }

    private func setIfChanged(_ keyPath: ReferenceWritableKeyPath<OverlayState, CGPoint>, _ newValue: CGPoint, tolerance: CGFloat) {
        let currentValue = self[keyPath: keyPath]
        if abs(currentValue.x - newValue.x) > tolerance || abs(currentValue.y - newValue.y) > tolerance {
            self[keyPath: keyPath] = newValue
        }
    }

    // MARK: - Visibility

    private func refreshBuddyVisibilityTarget() {
        buddyVisibilityTarget = (isBuddyAlwaysVisible || isInteractionActive) ? 1 : 0
    }

    // MARK: - Pointing

    /// Flies the buddy along an arc to a target and shows a label bubble.
    func point(at targetGlobalPoint: CGPoint, label: String?) {
        // Sit just below-right of the target so the tip points at it.
        let restingPoint = CGPoint(x: targetGlobalPoint.x + 9, y: targetGlobalPoint.y - 13)
        beginFlight(to: restingPoint)
        buddyMode = .flying
        targetRingCenter = targetGlobalPoint
        fullBubbleText = label ?? ""
        bubbleText = ""
        bubbleOpacity = 0
        bubbleHideDeadline = nil
    }

    /// Flies next to a mark Pointwise is drawing, without a ring or label, so it looks like the buddy drew it.
    func visit(_ globalPoint: CGPoint) {
        beginFlight(to: CGPoint(x: globalPoint.x + 9, y: globalPoint.y - 13))
        buddyMode = .flying
        targetRingCenter = nil
        fullBubbleText = ""
        hideBubble()
    }

    /// Flies back to the pointer and resumes following it.
    func returnToPointer() {
        guard buddyMode == .pointing || buddyMode == .flying else { return }
        targetRingCenter = nil
        hideBubble()
        pointerLocationWhenReturnStarted = pointerLocationProvider()
        let pointerLocation = pointerLocationWhenReturnStarted
        beginFlight(to: CGPoint(x: pointerLocation.x + Self.followOffset.dx, y: pointerLocation.y + Self.followOffset.dy))
        buddyMode = .returning
    }

    var isPointing: Bool { buddyMode == .pointing || buddyMode == .flying }

    private func beginFlight(to destination: CGPoint) {
        flightStart = buddyPosition
        flightEnd = destination
        flightStartedAt = Date()
        let distance = hypot(destination.x - flightStart.x, destination.y - flightStart.y)
        flightDuration = min(max(Double(distance) / 900, 0.55), 1.3)
        // Arc upward (positive y in AppKit) for a playful swoop.
        let arcHeight = min(distance * 0.22, 90)
        flightControlPoint = CGPoint(x: (flightStart.x + destination.x) / 2, y: (flightStart.y + destination.y) / 2 + arcHeight)
    }

    private func advanceFlight(at currentDate: Date) {
        let linearProgress = min(1, currentDate.timeIntervalSince(flightStartedAt) / flightDuration)
        let easedProgress = linearProgress * linearProgress * (3 - 2 * linearProgress)
        let inverseProgress = 1 - easedProgress
        let position = CGPoint(
            x: inverseProgress * inverseProgress * flightStart.x + 2 * inverseProgress * easedProgress * flightControlPoint.x + easedProgress * easedProgress * flightEnd.x,
            y: inverseProgress * inverseProgress * flightStart.y + 2 * inverseProgress * easedProgress * flightControlPoint.y + easedProgress * easedProgress * flightEnd.y
        )
        let tangentX = 2 * inverseProgress * (flightControlPoint.x - flightStart.x) + 2 * easedProgress * (flightEnd.x - flightControlPoint.x)
        let tangentY = 2 * inverseProgress * (flightControlPoint.y - flightStart.y) + 2 * easedProgress * (flightEnd.y - flightControlPoint.y)
        buddyPosition = position
        if hypot(tangentX, tangentY) > 0.5 {
            // The triangle's tip points up at 0°. SwiftUI rotates clockwise and y grows down on screen.
            buddyRotationDegrees = atan2(Double(-tangentY), Double(tangentX)) * 180 / .pi + 90
        }
        buddyScale = 1 + CGFloat(sin(linearProgress * .pi)) * 0.3

        if linearProgress >= 1 {
            buddyScale = 1
            if buddyMode == .flying {
                buddyMode = .pointing
                buddyRotationDegrees = -35
                if !fullBubbleText.isEmpty {
                    bubbleRevealStartedAt = currentDate
                    bubbleOpacity = 1
                }
            } else {
                buddyMode = .following
                buddyRotationDegrees = -35
            }
        }
    }

    // MARK: - Bubble

    /// Shows a short message next to the buddy while it follows the pointer.
    func flashBubble(_ text: String, duration: TimeInterval = 3) {
        fullBubbleText = text
        bubbleText = ""
        bubbleRevealStartedAt = Date()
        bubbleOpacity = 1
        bubbleHideDeadline = Date().addingTimeInterval(duration + Double(text.count) / 40)
    }

    func hideBubble() {
        bubbleOpacity = 0
        bubbleText = ""
        fullBubbleText = ""
        bubbleHideDeadline = nil
    }

    private func updateBubble(at currentDate: Date) {
        guard bubbleOpacity > 0, !fullBubbleText.isEmpty else { return }
        let revealedCount = min(fullBubbleText.count, Int(currentDate.timeIntervalSince(bubbleRevealStartedAt) * 40) + 1)
        let revealedText = String(fullBubbleText.prefix(revealedCount))
        if revealedText != bubbleText { bubbleText = revealedText }
        if let bubbleHideDeadline, currentDate > bubbleHideDeadline { hideBubble() }
    }

    // MARK: - Annotations

    func addCircle(center: CGPoint, radius: CGFloat, label: String?) {
        let strokes = [HandDrawnShapes.circle(center: center, radius: max(radius, 14), seed: nextSeed())]
        appendAnnotation(style: .circle, strokes: strokes, label: label, labelAnchor: CGPoint(x: center.x + radius * 0.8, y: center.y + radius * 1.1), drawDuration: 0.55)
    }

    func addBox(from firstCorner: CGPoint, to secondCorner: CGPoint, label: String?) {
        let strokes = [HandDrawnShapes.box(from: firstCorner, to: secondCorner, seed: nextSeed())]
        let topRight = CGPoint(x: max(firstCorner.x, secondCorner.x), y: max(firstCorner.y, secondCorner.y))
        appendAnnotation(style: .box, strokes: strokes, label: label, labelAnchor: CGPoint(x: topRight.x, y: topRight.y + 14), drawDuration: 0.6)
    }

    func addUnderline(from start: CGPoint, to end: CGPoint) {
        let strokes = [HandDrawnShapes.underline(from: start, to: end, seed: nextSeed())]
        appendAnnotation(style: .underline, strokes: strokes, label: nil, labelAnchor: end, drawDuration: 0.35)
    }

    func addArrow(from start: CGPoint, to end: CGPoint, label: String?) {
        let arrowStrokes = HandDrawnShapes.arrow(from: start, to: end, seed: nextSeed())
        appendAnnotation(style: .arrow, strokes: [arrowStrokes.shaft, arrowStrokes.head], label: label, labelAnchor: start, drawDuration: 0.5)
    }

    /// Fades out every annotation, the spotlight, and the paint trail.
    func clearAnnotations() {
        let currentDate = Date()
        for annotationIndex in annotations.indices where annotations[annotationIndex].fadeOutStartedAt == nil {
            annotations[annotationIndex].fadeOutStartedAt = currentDate
        }
        hideSpotlight()
        paintTrail.removeAll()
    }

    // MARK: - Spotlight

    func showSpotlight(around rect: CGRect, label: String?) {
        let currentDate = Date()
        let currentRect = spotlight.flatMap { $0.fadeOutStartedAt == nil ? $0.frame(at: currentDate).rect : nil }
        spotlight = OverlaySpotlight(rect: rect.standardized, fromRect: currentRect, label: label, startedAt: currentDate)
    }

    func hideSpotlight() {
        if spotlight != nil, spotlight?.fadeOutStartedAt == nil { spotlight?.fadeOutStartedAt = Date() }
    }

    // MARK: - Click marks

    func addClickMark(at point: CGPoint, isCorrect: Bool) {
        let seed = nextSeed()
        let strokes: [[CGPoint]]
        if isCorrect {
            // A check mark: down to the bottom point, then a long stroke up and right (AppKit y grows up).
            let bottomPoint = CGPoint(x: point.x - 3, y: point.y - 12)
            strokes = [HandDrawnShapes.underline(from: CGPoint(x: point.x - 16, y: point.y + 2), to: bottomPoint, seed: seed)
                + HandDrawnShapes.underline(from: bottomPoint, to: CGPoint(x: point.x + 20, y: point.y + 20), seed: seed &+ 1)]
        } else {
            strokes = [
                HandDrawnShapes.underline(from: CGPoint(x: point.x - 13, y: point.y + 13), to: CGPoint(x: point.x + 13, y: point.y - 13), seed: seed),
                HandDrawnShapes.underline(from: CGPoint(x: point.x + 13, y: point.y + 13), to: CGPoint(x: point.x - 13, y: point.y - 13), seed: seed &+ 1),
            ]
        }
        clickMarks.append(OverlayClickMark(point: point, isCorrect: isCorrect, strokes: strokes, createdAt: Date()))
    }

    private func appendAnnotation(style: OverlayAnnotation.Style, strokes: [[CGPoint]], label: String?, labelAnchor: CGPoint, drawDuration: TimeInterval) {
        // Keep the screen readable: at most six marks at a time.
        if annotations.filter({ $0.fadeOutStartedAt == nil }).count >= 6,
           let oldestIndex = annotations.firstIndex(where: { $0.fadeOutStartedAt == nil }) {
            annotations[oldestIndex].fadeOutStartedAt = Date()
        }
        annotations.append(OverlayAnnotation(style: style, strokes: strokes, label: label, labelAnchor: labelAnchor, createdAt: Date(), drawDuration: drawDuration))
    }

    private func updateAnnotations(at currentDate: Date) {
        let visibleAnnotations = annotations.filter { annotation in
            guard let fadeOutStartedAt = annotation.fadeOutStartedAt else { return true }
            return currentDate.timeIntervalSince(fadeOutStartedAt) < OverlayAnnotation.fadeOutDuration
        }
        if visibleAnnotations.count != annotations.count { annotations = visibleAnnotations }
        if let fadeOutStartedAt = spotlight?.fadeOutStartedAt, currentDate.timeIntervalSince(fadeOutStartedAt) > OverlaySpotlight.fadeDuration {
            spotlight = nil
        }
        let visibleClickMarks = clickMarks.filter { $0.opacity(at: currentDate) > 0 }
        if visibleClickMarks.count != clickMarks.count { clickMarks = visibleClickMarks }
    }

    private func nextSeed() -> UInt64 {
        annotationSeedCounter &+= 0x9E3779B97F4A7C15
        return annotationSeedCounter
    }

    // MARK: - Paint trail (draw while talking)

    func startPaintTrail() { paintTrail = [] }

    func appendPaintTrailPoint(_ globalPoint: CGPoint) {
        if let lastPoint = paintTrail.last, hypot(lastPoint.x - globalPoint.x, lastPoint.y - globalPoint.y) < 2 { return }
        paintTrail.append(globalPoint)
    }

    func clearPaintTrail() { paintTrail.removeAll() }
}
