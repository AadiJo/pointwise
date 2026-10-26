import CoreGraphics
import Foundation

/// Builds slightly wobbly polylines so annotations look drawn by hand with a
/// marker, like Excalidraw. All points are in global AppKit coordinates.
enum HandDrawnShapes {
    /// A deterministic pseudo-random wobble so one shape never jitters between frames.
    private struct Wobble {
        var seed: UInt64

        mutating func nextUnit() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 10_000) / 10_000
        }

        mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
            range.lowerBound + nextUnit() * (range.upperBound - range.lowerBound)
        }
    }

    /// An ellipse-like loop that overshoots its start, the way people circle things.
    static func circle(center: CGPoint, radius: CGFloat, seed: UInt64) -> [CGPoint] {
        var wobble = Wobble(seed: seed)
        let horizontalRadius = radius * wobble.next(in: 1.05...1.25)
        let verticalRadius = radius * wobble.next(in: 0.85...1.0)
        let startAngle = wobble.next(in: 0.6...1.4) * .pi
        let totalSweep = 2 * .pi * wobble.next(in: 1.08...1.18)
        let firstWaveFrequency = wobble.next(in: 2...3)
        let firstWavePhase = wobble.next(in: 0...(2 * .pi))
        let pointCount = 72
        return (0...pointCount).map { pointIndex in
            let progress = CGFloat(pointIndex) / CGFloat(pointCount)
            let angle = startAngle + totalSweep * progress
            // The loop drifts outward a little so the overshoot does not retrace the start.
            let radialDrift = 1 + 0.07 * progress + 0.025 * sin(firstWaveFrequency * angle + firstWavePhase)
            return CGPoint(
                x: center.x + cos(angle) * horizontalRadius * radialDrift,
                y: center.y + sin(angle) * verticalRadius * radialDrift
            )
        }
    }

    /// A rectangle whose sides bow slightly and whose corners overshoot.
    static func box(from firstCorner: CGPoint, to secondCorner: CGPoint, seed: UInt64) -> [CGPoint] {
        var wobble = Wobble(seed: seed)
        let padding: CGFloat = 6
        let minX = min(firstCorner.x, secondCorner.x) - padding
        let maxX = max(firstCorner.x, secondCorner.x) + padding
        let minY = min(firstCorner.y, secondCorner.y) - padding
        let maxY = max(firstCorner.y, secondCorner.y) + padding
        let corners = [
            CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY),
            CGPoint(x: maxX, y: minY), CGPoint(x: minX, y: minY), CGPoint(x: minX, y: maxY),
        ]
        var points: [CGPoint] = []
        for sideIndex in 0..<4 {
            let sideStart = corners[sideIndex]
            let sideEnd = corners[sideIndex + 1]
            let overshoot = wobble.next(in: 2...7)
            points += wobblyLine(from: sideStart, to: sideEnd, bow: wobble.next(in: -3...3), overshoot: overshoot, pointCount: 16)
        }
        return points
    }

    /// A gently curved underline.
    static func underline(from start: CGPoint, to end: CGPoint, seed: UInt64) -> [CGPoint] {
        var wobble = Wobble(seed: seed)
        return wobblyLine(from: start, to: end, bow: wobble.next(in: -2.5...2.5), overshoot: 4, pointCount: 24)
    }

    /// A curved arrow shaft plus the two strokes of its head, returned separately.
    static func arrow(from start: CGPoint, to end: CGPoint, seed: UInt64) -> (shaft: [CGPoint], head: [CGPoint]) {
        var wobble = Wobble(seed: seed)
        let length = hypot(end.x - start.x, end.y - start.y)
        let shaft = wobblyLine(from: start, to: end, bow: length * wobble.next(in: 0.06...0.12), overshoot: 0, pointCount: 28)
        let arrivalAngle = atan2(end.y - shaft[shaft.count - 3].y, end.x - shaft[shaft.count - 3].x)
        let headLength = min(18, max(10, length * 0.18))
        let leftWing = CGPoint(x: end.x - headLength * cos(arrivalAngle - 0.5), y: end.y - headLength * sin(arrivalAngle - 0.5))
        let rightWing = CGPoint(x: end.x - headLength * cos(arrivalAngle + 0.5), y: end.y - headLength * sin(arrivalAngle + 0.5))
        return (shaft, [leftWing, end, rightWing])
    }

    /// A line bowed sideways by `bow` points that extends `overshoot` points past its end.
    private static func wobblyLine(from start: CGPoint, to end: CGPoint, bow: CGFloat, overshoot: CGFloat, pointCount: Int) -> [CGPoint] {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let length = max(hypot(deltaX, deltaY), 0.001)
        let unitX = deltaX / length
        let unitY = deltaY / length
        let normalX = -unitY
        let normalY = unitX
        let extendedEnd = CGPoint(x: end.x + unitX * overshoot, y: end.y + unitY * overshoot)
        return (0...pointCount).map { pointIndex in
            let progress = CGFloat(pointIndex) / CGFloat(pointCount)
            let bowOffset = sin(progress * .pi) * bow
            return CGPoint(
                x: start.x + (extendedEnd.x - start.x) * progress + normalX * bowOffset,
                y: start.y + (extendedEnd.y - start.y) * progress + normalY * bowOffset
            )
        }
    }
}
