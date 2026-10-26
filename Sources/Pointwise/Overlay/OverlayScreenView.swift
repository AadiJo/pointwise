import SwiftUI

/// Draws Pointwise's layer for one display: the buddy cursor, its bubble,
/// hand-drawn annotations, the paint trail, and captions.
///
/// Everything is drawn in a single Canvas with absolute coordinates, so marks
/// land exactly where Claude placed them.
struct OverlayScreenView: View {
    /// This display's frame in global AppKit coordinates.
    let screenFrame: CGRect
    @ObservedObject var state: OverlayState
    @ObservedObject var settings: AppSettings

    private static let markerFontName = "Noteworthy-Bold"

    var body: some View {
        Canvas { context, _ in
            drawSpotlight(in: &context)
            drawPaintTrail(in: &context)
            drawAnnotations(in: &context)
            drawClickMarks(in: &context)
            drawTargetRing(in: &context)
            if isBuddyOnThisScreen {
                drawBuddy(in: &context)
                drawBubble(in: &context)
            }
            if shouldShowCaption {
                drawCaption(in: &context)
            }
            if let clickQuizPrompt = state.clickQuizPrompt, screenFrame.contains(state.pointerLocationProvider()) {
                drawClickQuizBanner(clickQuizPrompt, in: &context)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }

    // MARK: - Coordinates

    private func localPoint(_ globalPoint: CGPoint) -> CGPoint {
        CGPoint(x: globalPoint.x - screenFrame.minX, y: screenFrame.maxY - globalPoint.y)
    }

    /// Converts a global AppKit rect (y up) into this view's coordinates (y down).
    private func localRect(_ globalRect: CGRect) -> CGRect {
        CGRect(x: globalRect.minX - screenFrame.minX, y: screenFrame.maxY - globalRect.maxY, width: globalRect.width, height: globalRect.height)
    }

    private var isBuddyOnThisScreen: Bool {
        screenFrame.insetBy(dx: -40, dy: -40).contains(state.buddyPosition)
    }

    private var shouldShowCaption: Bool {
        settings.captionsEnabled && !state.captionText.isEmpty && screenFrame.contains(state.pointerLocationProvider())
    }

    // MARK: - Spotlight

    private func drawSpotlight(in context: inout GraphicsContext) {
        guard let spotlight = state.spotlight, screenFrame.contains(CGPoint(x: spotlight.rect.midX, y: spotlight.rect.midY)) else { return }
        let (spotlightRect, opacity) = spotlight.frame(at: state.now)
        guard opacity > 0 else { return }
        let holeRect = localRect(spotlightRect).insetBy(dx: -14, dy: -14)
        var dimmingPath = Path(CGRect(origin: .zero, size: screenFrame.size))
        dimmingPath.addPath(Path(roundedRect: holeRect, cornerRadius: 18))
        context.fill(dimmingPath, with: .color(.black.opacity(0.6 * opacity)), style: FillStyle(eoFill: true))
        var glowContext = context
        glowContext.addFilter(.shadow(color: .white.opacity(0.7 * opacity), radius: 10))
        glowContext.stroke(Path(roundedRect: holeRect, cornerRadius: 18), with: .color(.white.opacity(0.85 * opacity)), lineWidth: 2.5)
        if let label = spotlight.label {
            let resolvedLabel = context.resolve(Text(label).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(.white))
            let labelSize = resolvedLabel.measure(in: CGSize(width: 400, height: 40))
            let labelAboveHole = holeRect.minY - labelSize.height - 18 > 0
            let pillRect = CGRect(
                x: min(max(holeRect.minX, 10), screenFrame.width - labelSize.width - 30),
                y: labelAboveHole ? holeRect.minY - labelSize.height - 16 : holeRect.maxY + 8,
                width: labelSize.width + 20, height: labelSize.height + 8
            )
            var labelContext = context
            labelContext.opacity = opacity
            labelContext.fill(Path(roundedRect: pillRect, cornerRadius: pillRect.height / 2), with: .color(state.cursorColor))
            labelContext.draw(resolvedLabel, in: pillRect.insetBy(dx: 10, dy: 4))
        }
    }

    // MARK: - Marks

    private func drawPaintTrail(in context: inout GraphicsContext) {
        guard state.paintTrail.count > 1 else { return }
        var trailPath = Path()
        trailPath.addLines(state.paintTrail.map(localPoint))
        context.stroke(trailPath, with: .color(state.cursorColor.opacity(0.55)), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
    }

    private func drawAnnotations(in context: inout GraphicsContext) {
        for annotation in state.annotations {
            let progress = annotation.drawProgress(at: state.now)
            let opacity = annotation.opacity(at: state.now)
            guard progress > 0, opacity > 0 else { continue }
            let totalPointCount = annotation.strokes.reduce(0) { $0 + $1.count }
            var remainingPointBudget = Int(CGFloat(totalPointCount) * progress)
            for stroke in annotation.strokes where remainingPointBudget > 1 {
                let visiblePoints = Array(stroke.prefix(remainingPointBudget))
                remainingPointBudget -= stroke.count
                guard visiblePoints.count > 1 else { continue }
                var strokePath = Path()
                strokePath.addLines(visiblePoints.map(localPoint))
                var haloContext = context
                haloContext.opacity = opacity * 0.4
                haloContext.stroke(strokePath, with: .color(.white), style: StrokeStyle(lineWidth: 7.5, lineCap: .round, lineJoin: .round))
                var markerContext = context
                markerContext.opacity = opacity
                markerContext.stroke(strokePath, with: .color(DS.Colors.markerRed), style: StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round))
            }
            if let label = annotation.label, progress >= 1 {
                drawAnnotationLabel(label, at: localPoint(annotation.labelAnchor), opacity: opacity, in: &context)
            }
        }
    }

    private func drawClickMarks(in context: inout GraphicsContext) {
        for clickMark in state.clickMarks {
            let progress = clickMark.drawProgress(at: state.now)
            let opacity = clickMark.opacity(at: state.now)
            let totalPointCount = clickMark.strokes.reduce(0) { $0 + $1.count }
            var remainingPointBudget = Int(CGFloat(totalPointCount) * progress)
            let markColor = clickMark.isCorrect ? Color(red: 0.09, green: 0.64, blue: 0.29) : DS.Colors.markerRed
            for stroke in clickMark.strokes where remainingPointBudget > 1 {
                let visiblePoints = Array(stroke.prefix(remainingPointBudget))
                remainingPointBudget -= stroke.count
                guard visiblePoints.count > 1 else { continue }
                var strokePath = Path()
                strokePath.addLines(visiblePoints.map(localPoint))
                var haloContext = context
                haloContext.opacity = opacity * 0.85
                haloContext.stroke(strokePath, with: .color(.white), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                var markContext = context
                markContext.opacity = opacity
                markContext.stroke(strokePath, with: .color(markColor), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func drawClickQuizBanner(_ prompt: String, in context: inout GraphicsContext) {
        let pulse = (sin(state.now.timeIntervalSinceReferenceDate * 3) + 1) / 2
        let resolvedText = context.resolve(Text("🎯  " + prompt).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundColor(.white))
        let textSize = resolvedText.measure(in: CGSize(width: 700, height: 80))
        let bannerRect = CGRect(x: (screenFrame.width - textSize.width - 44) / 2, y: 46, width: textSize.width + 44, height: textSize.height + 22)
        var bannerContext = context
        bannerContext.addFilter(.shadow(color: state.cursorColor.opacity(0.35 + 0.35 * pulse), radius: 12 + 6 * pulse))
        bannerContext.fill(Path(roundedRect: bannerRect, cornerRadius: bannerRect.height / 2), with: .color(state.cursorColor))
        context.draw(resolvedText, in: bannerRect.insetBy(dx: 22, dy: 11))
    }

    private func drawAnnotationLabel(_ label: String, at anchor: CGPoint, opacity: Double, in context: inout GraphicsContext) {
        var labelContext = context
        labelContext.opacity = opacity
        let haloText = labelContext.resolve(Text(label).font(.custom(Self.markerFontName, size: 18)).foregroundColor(.white))
        let markerText = labelContext.resolve(Text(label).font(.custom(Self.markerFontName, size: 18)).foregroundColor(DS.Colors.markerRed))
        let textOrigin = CGPoint(x: anchor.x + 6, y: anchor.y)
        for haloOffset in [CGSize(width: -1.5, height: 0), CGSize(width: 1.5, height: 0), CGSize(width: 0, height: -1.5), CGSize(width: 0, height: 1.5)] {
            labelContext.draw(haloText, at: CGPoint(x: textOrigin.x + haloOffset.width, y: textOrigin.y + haloOffset.height), anchor: .leading)
        }
        labelContext.draw(markerText, at: textOrigin, anchor: .leading)
    }

    private func drawTargetRing(in context: inout GraphicsContext) {
        guard let targetRingCenter = state.targetRingCenter, state.buddyMode == .pointing else { return }
        let center = localPoint(targetRingCenter)
        let pulsePhase = state.now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
        let pulseRadius = 10 + CGFloat(pulsePhase) * 18
        context.stroke(
            Path(ellipseIn: CGRect(x: center.x - pulseRadius, y: center.y - pulseRadius, width: pulseRadius * 2, height: pulseRadius * 2)),
            with: .color(state.cursorColor.opacity(0.8 * (1 - pulsePhase))), lineWidth: 2.5
        )
        context.stroke(Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)), with: .color(state.cursorColor), lineWidth: 2.5)
    }

    // MARK: - Buddy

    private func drawBuddy(in context: inout GraphicsContext) {
        let position = localPoint(state.buddyPosition)
        var buddyContext = context
        buddyContext.opacity = state.buddyOpacity
        let glowRadius = 8 + (state.buddyScale - 1) * 20
        buddyContext.addFilter(.shadow(color: state.cursorColor.opacity(0.9), radius: glowRadius))
        let timeSeconds = state.now.timeIntervalSinceReferenceDate

        switch state.voiceState {
        case .listening:
            let barProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]
            for (barIndex, profileHeight) in barProfile.enumerated() {
                let idlePulse = (sin(CGFloat(timeSeconds * 3.6) + CGFloat(barIndex) * 0.35) + 1) / 2 * 1.5
                let reactiveHeight = pow(min(max(state.audioLevel - 0.008, 0) * 2.85, 1), 0.76) * 12 * profileHeight
                let barHeight = 3 + reactiveHeight + idlePulse
                let barRect = CGRect(x: position.x - 11 + CGFloat(barIndex) * 4.5, y: position.y - barHeight / 2, width: 2.5, height: barHeight)
                buddyContext.fill(Path(roundedRect: barRect, cornerRadius: 1.25), with: .color(state.cursorColor))
            }
        case .thinking:
            let rotation = Angle.degrees(timeSeconds.truncatingRemainder(dividingBy: 0.8) / 0.8 * 360)
            var arcPath = Path()
            arcPath.addArc(center: position, radius: 7.5, startAngle: rotation, endAngle: rotation + .degrees(250), clockwise: false)
            buddyContext.stroke(arcPath, with: .color(state.cursorColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        case .idle, .speaking:
            let triangleSize = 20 * state.buddyScale
            let triangleRect = CGRect(x: position.x - triangleSize / 2, y: position.y - triangleSize / 2, width: triangleSize, height: triangleSize)
            let trianglePath = BuddyTriangle().path(in: triangleRect)
                .applying(CGAffineTransform(translationX: -position.x, y: -position.y)
                    .concatenating(CGAffineTransform(rotationAngle: state.buddyRotationDegrees * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: position.x, y: position.y)))
            buddyContext.fill(trianglePath, with: .color(state.cursorColor))
        }
    }

    private func drawBubble(in context: inout GraphicsContext) {
        let bubbleContent: String? = {
            if state.voiceState == .thinking, let activityText = state.activityText { return activityText + "…" }
            if state.bubbleOpacity > 0, !state.bubbleText.isEmpty { return state.bubbleText }
            return nil
        }()
        guard let bubbleContent else { return }
        let position = localPoint(state.buddyPosition)
        var bubbleContext = context
        bubbleContext.opacity = state.buddyOpacity
        let resolvedText = bubbleContext.resolve(Text(bubbleContent).font(.system(size: 12, weight: .semibold)).foregroundColor(.white))
        let textSize = resolvedText.measure(in: CGSize(width: 320, height: 200))
        let bubbleRect = CGRect(x: position.x + 12, y: position.y + 10, width: textSize.width + 18, height: textSize.height + 10)
        var shadowContext = bubbleContext
        shadowContext.addFilter(.shadow(color: state.cursorColor.opacity(0.5), radius: 6))
        shadowContext.fill(Path(roundedRect: bubbleRect, cornerRadius: 7), with: .color(state.cursorColor))
        bubbleContext.draw(resolvedText, in: bubbleRect.insetBy(dx: 9, dy: 5))
    }

    // MARK: - Captions

    private func drawCaption(in context: inout GraphicsContext) {
        let resolvedText = context.resolve(
            Text(state.captionText)
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .foregroundColor(.white)
        )
        let maximumTextWidth: CGFloat = min(740, screenFrame.width - 80)
        let textSize = resolvedText.measure(in: CGSize(width: maximumTextWidth, height: 400))
        let boxSize = CGSize(width: textSize.width + 36, height: textSize.height + 22)
        let boxRect = CGRect(x: (screenFrame.width - boxSize.width) / 2, y: screenFrame.height - 70 - boxSize.height, width: boxSize.width, height: boxSize.height)
        context.fill(Path(roundedRect: boxRect, cornerRadius: 12), with: .color(.black.opacity(0.78)))
        context.draw(resolvedText, in: boxRect.insetBy(dx: 18, dy: 11))
    }
}

/// The buddy's cursor shape: a notched arrowhead whose tip points up before
/// rotation, so it clearly points at things (an equilateral triangle tilted
/// 35 degrees reads as a "play" symbol instead).
struct BuddyTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let arrowWidth = min(rect.width, rect.height) * 0.86
        let arrowHeight = min(rect.width, rect.height)
        let top = rect.midY - arrowHeight / 2
        let bottom = rect.midY + arrowHeight / 2
        path.move(to: CGPoint(x: rect.midX, y: top))
        path.addLine(to: CGPoint(x: rect.midX + arrowWidth / 2, y: bottom))
        path.addLine(to: CGPoint(x: rect.midX, y: bottom - arrowHeight * 0.27))
        path.addLine(to: CGPoint(x: rect.midX - arrowWidth / 2, y: bottom))
        path.closeSubpath()
        return path
    }
}
