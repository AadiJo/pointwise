import AppKit
import SwiftUI

/// Design tokens shared by every Pointwise surface. Colors follow the dark,
/// rounded look of the original Pointwise panel.
enum DS {
    enum Colors {
        static let background = Color(hex: "#101211")
        static let surface1 = Color(hex: "#171918")
        static let surface2 = Color(hex: "#202221")
        static let surface3 = Color(hex: "#272A29")
        static let borderSubtle = Color(hex: "#373B39")
        static let textPrimary = Color(hex: "#ECEEED")
        static let textSecondary = Color(hex: "#ADB5B2")
        static let textTertiary = Color(hex: "#6B736F")
        static let accent = Color(hex: "#2563EB")
        static let accentText = Color(hex: "#60A5FA")
        static let success = Color(hex: "#34D399")
        static let warning = Color(hex: "#FFB224")
        static let destructive = Color(hex: "#E5484D")
        /// Default buddy cursor color. The learner can change it in Settings.
        static let defaultCursorBlue = Color(hex: "#3380FF")
        /// Hand-drawn annotation color: a warm marker red that reads on light and dark apps.
        static let markerRed = Color(hex: "#FF4D4D")
        static let markerYellow = Color(hex: "#FFD60A")
    }

    enum CornerRadius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }
}

extension Color {
    init(hex: String) {
        let hexDigits = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var hexValue: UInt64 = 0
        Scanner(string: hexDigits).scanHexInt64(&hexValue)
        let red, green, blue, alpha: Double
        switch hexDigits.count {
        case 8:
            red = Double((hexValue >> 24) & 0xFF) / 255
            green = Double((hexValue >> 16) & 0xFF) / 255
            blue = Double((hexValue >> 8) & 0xFF) / 255
            alpha = Double(hexValue & 0xFF) / 255
        default:
            red = Double((hexValue >> 16) & 0xFF) / 255
            green = Double((hexValue >> 8) & 0xFF) / 255
            blue = Double(hexValue & 0xFF) / 255
            alpha = 1
        }
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// Hex string for persisting a color the learner picked.
    var hexString: String {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        return String(
            format: "#%02X%02X%02X",
            Int(round(nsColor.redComponent * 255)),
            Int(round(nsColor.greenComponent * 255)),
            Int(round(nsColor.blueComponent * 255))
        )
    }
}

/// Shows the pointing-hand cursor while hovering a clickable control.
struct PointerCursorOnHover: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { isHovering in
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

extension View {
    func pointerCursorOnHover() -> some View { modifier(PointerCursorOnHover()) }
}

/// A compact dark button used across Pointwise panels.
struct PointwiseButtonStyle: ButtonStyle {
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundColor(isProminent ? .white : DS.Colors.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(isProminent ? DS.Colors.accent : DS.Colors.surface3)
                    .opacity(configuration.isPressed ? 0.75 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(isProminent ? Color.clear : DS.Colors.borderSubtle, lineWidth: 1)
            )
            .pointerCursorOnHover()
    }
}
