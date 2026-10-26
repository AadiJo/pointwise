import AppKit
import ScreenCaptureKit

/// One display captured for Claude. Coordinates Claude returns are in the
/// screenshot's pixel space; `displayFrame` maps them back to the screen.
struct CapturedScreen {
    let jpegData: Data
    let label: String
    let isCursorScreen: Bool
    /// The display frame in global AppKit coordinates (bottom-left origin).
    let displayFrame: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    /// One-based number used in the label and in `:screenN` tags.
    let screenNumber: Int

    var protocolDictionary: [String: Any] {
        [
            "jpegBase64": jpegData.base64EncodedString(),
            "label": label,
            "widthInPixels": pixelWidth,
            "heightInPixels": pixelHeight,
        ]
    }

    /// Converts a point in screenshot pixels (top-left origin) to global AppKit coordinates.
    func globalPoint(fromScreenshotX screenshotX: Double, screenshotY: Double) -> CGPoint {
        let clampedX = max(0, min(screenshotX, Double(pixelWidth)))
        let clampedY = max(0, min(screenshotY, Double(pixelHeight)))
        let pointsPerPixelX = displayFrame.width / CGFloat(pixelWidth)
        let pointsPerPixelY = displayFrame.height / CGFloat(pixelHeight)
        let displayLocalX = CGFloat(clampedX) * pointsPerPixelX
        let displayLocalYFromTop = CGFloat(clampedY) * pointsPerPixelY
        return CGPoint(
            x: displayFrame.minX + displayLocalX,
            y: displayFrame.maxY - displayLocalYFromTop
        )
    }

    /// Converts a global AppKit point back into this screenshot's pixel space.
    func screenshotPoint(fromGlobal globalPoint: CGPoint) -> CGPoint {
        let pixelsPerPointX = CGFloat(pixelWidth) / displayFrame.width
        let pixelsPerPointY = CGFloat(pixelHeight) / displayFrame.height
        return CGPoint(
            x: (globalPoint.x - displayFrame.minX) * pixelsPerPointX,
            y: (displayFrame.maxY - globalPoint.y) * pixelsPerPointY
        )
    }

    /// Length conversion for radii, from screenshot pixels to points.
    func points(fromScreenshotLength screenshotLength: Double) -> CGFloat {
        CGFloat(screenshotLength) * displayFrame.width / CGFloat(pixelWidth)
    }
}

/// Where Pointwise's view of the screen comes from: the real displays, or a
/// fixed image for testing (`--fixture-screen`).
@MainActor
protocol ScreenSource: AnyObject {
    /// All display frames in global AppKit coordinates.
    var displayFrames: [CGRect] { get }
    func captureScreens(pointerLocation: CGPoint) async throws -> [CapturedScreen]
}

/// Captures every connected display with ScreenCaptureKit, hiding Pointwise's own windows.
@MainActor
final class SystemScreenSource: ScreenSource {
    /// Long edge of the image sent to Claude. 1280 keeps tokens low and pointing accurate.
    private let maximumScreenshotDimension = 1280

    var displayFrames: [CGRect] { NSScreen.screens.map(\.frame) }

    func captureScreens(pointerLocation: CGPoint) async throws -> [CapturedScreen] {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !shareableContent.displays.isEmpty else { throw ScreenCaptureError.noDisplays }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownWindows = shareableContent.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }

        var screenByDisplayIdentifier: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let displayIdentifier = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                screenByDisplayIdentifier[displayIdentifier] = screen
            }
        }

        // The cursor's display goes first so Claude treats it as the main focus.
        let orderedDisplays = shareableContent.displays.sorted { firstDisplay, secondDisplay in
            let firstFrame = screenByDisplayIdentifier[firstDisplay.displayID]?.frame ?? firstDisplay.frame
            let secondFrame = screenByDisplayIdentifier[secondDisplay.displayID]?.frame ?? secondDisplay.frame
            return firstFrame.contains(pointerLocation) && !secondFrame.contains(pointerLocation)
        }

        var capturedScreens: [CapturedScreen] = []
        for (displayIndex, display) in orderedDisplays.enumerated() {
            let displayFrame = screenByDisplayIdentifier[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y, width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(pointerLocation)

            let configuration = SCStreamConfiguration()
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maximumScreenshotDimension
                configuration.height = Int((CGFloat(maximumScreenshotDimension) / aspectRatio).rounded())
            } else {
                configuration.height = maximumScreenshotDimension
                configuration.width = Int((CGFloat(maximumScreenshotDimension) * aspectRatio).rounded())
            }
            configuration.showsCursor = false

            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let jpegData = JPEGEncoding.jpegData(from: image) else { continue }

            capturedScreens.append(CapturedScreen(
                jpegData: jpegData,
                label: ScreenLabels.label(screenNumber: displayIndex + 1, screenCount: orderedDisplays.count, isCursorScreen: isCursorScreen),
                isCursorScreen: isCursorScreen,
                displayFrame: displayFrame,
                pixelWidth: configuration.width,
                pixelHeight: configuration.height,
                screenNumber: displayIndex + 1
            ))
        }
        guard !capturedScreens.isEmpty else { throw ScreenCaptureError.captureFailed }
        return capturedScreens
    }
}

enum ScreenLabels {
    static func label(screenNumber: Int, screenCount: Int, isCursorScreen: Bool) -> String {
        if screenCount == 1 { return "screen 1 of 1 (the learner's screen, cursor is here)" }
        return isCursorScreen
            ? "screen \(screenNumber) of \(screenCount) (cursor is here, main focus)"
            : "screen \(screenNumber) of \(screenCount) (secondary screen)"
    }
}

enum JPEGEncoding {
    static func jpegData(from image: CGImage, compressionFactor: Double = 0.8) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
    }
}

enum ScreenCaptureError: LocalizedError {
    case noDisplays
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .noDisplays: return "No display is available to capture."
        case .captureFailed: return "Pointwise could not capture the screen. Check Screen Recording permission."
        }
    }
}
