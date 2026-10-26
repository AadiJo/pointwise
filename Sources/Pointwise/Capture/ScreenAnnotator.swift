import AppKit

/// Small image helpers: draw the learner's pointer trail onto a screenshot,
/// and make tiny fingerprints to notice when the screen changes.
enum ScreenAnnotator {
    /// Returns a copy of the screenshot with the paint trail drawn on it, so
    /// Claude sees exactly what the learner circled while talking.
    static func drawTrail(_ trail: [CGPoint], on screen: CapturedScreen) -> CapturedScreen {
        guard trail.contains(where: { screen.displayFrame.contains($0) }),
              let sourceImage = NSBitmapImageRep(data: screen.jpegData)?.cgImage,
              let context = CGContext(
                data: nil, width: sourceImage.width, height: sourceImage.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return screen }
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height))
        context.setStrokeColor(NSColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.6).cgColor)
        context.setLineWidth(6)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        // CGContext has a bottom-left origin, so flip the screenshot's y axis.
        let trailInContext = trail.map { globalPoint -> CGPoint in
            let pixelPoint = screen.screenshotPoint(fromGlobal: globalPoint)
            return CGPoint(x: pixelPoint.x, y: CGFloat(sourceImage.height) - pixelPoint.y)
        }
        context.addLines(between: trailInContext)
        context.strokePath()
        guard let annotatedImage = context.makeImage(), let annotatedJPEG = JPEGEncoding.jpegData(from: annotatedImage) else { return screen }
        return CapturedScreen(
            jpegData: annotatedJPEG, label: screen.label, isCursorScreen: screen.isCursorScreen, displayFrame: screen.displayFrame,
            pixelWidth: screen.pixelWidth, pixelHeight: screen.pixelHeight, screenNumber: screen.screenNumber
        )
    }

    /// A 48×30 grayscale thumbnail used to compare two screenshots cheaply.
    static func fingerprint(of jpegData: Data) -> [UInt8]? {
        guard let sourceImage = NSBitmapImageRep(data: jpegData)?.cgImage else { return nil }
        let width = 48, height = 30
        var pixels = [UInt8](repeating: 0, count: width * height)
        let didDraw = pixels.withUnsafeMutableBytes { pixelBuffer -> Bool in
            guard let context = CGContext(
                data: pixelBuffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return didDraw ? pixels : nil
    }

    /// Mean absolute difference between two fingerprints, from 0 (same) to 1.
    static func difference(between firstFingerprint: [UInt8], and secondFingerprint: [UInt8]) -> Double {
        guard firstFingerprint.count == secondFingerprint.count, !firstFingerprint.isEmpty else { return 1 }
        let totalDifference = zip(firstFingerprint, secondFingerprint).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(totalDifference) / Double(firstFingerprint.count * 255)
    }
}
