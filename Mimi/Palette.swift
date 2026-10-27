import AppKit
import SwiftUI

/// Colors with no system equivalent, each with a light and a dark variant.
enum Palette {
    static let warningBackground = Color(light: 0xFDF1E2, dark: (0xFF9F0A, 0.16))
    static let warningIcon = Color(light: 0xC25E00, dark: 0xFF9F0A)
    static let warningText = Color(light: 0x7A3D00, dark: 0xFFC46B)
    static let warningButtonBorder = Color(light: (0x7A3D00, 0.3), dark: (0xFFC46B, 0.35))

    static let errorBackground = Color(light: 0xFDEEED, dark: (0xFF453A, 0.14))
    static let errorIcon = Color(light: 0xD1281C, dark: 0xFF453A)
    static let errorText = Color(light: 0x7A1710, dark: 0xFFC2BD)
    static let errorButtonBorder = Color(light: (0x7A1710, 0.3), dark: (0xFFC2BD, 0.35))

    static let bannerButtonBackground = Color(light: 0xFFFFFF, dark: (0xFFFFFF, 0.06))

    /// The text of a failure inside a settings row.
    static let danger = Color(light: 0xC4261D, dark: 0xFF6961)

    static let pushButtonBackground = Color(light: 0xFFFFFF, dark: (0xFFFFFF, 0.1))
    static let pushButtonBorder = Color(light: (0x000000, 0.2), dark: (0xFFFFFF, 0.12))

    static let radioBackground = Color(light: 0xFFFFFF, dark: (0xFFFFFF, 0.06))
    static let radioBorder = Color(light: (0x000000, 0.25), dark: (0xFFFFFF, 0.3))

    static let progressTrack = Color(light: 0xE5E5EA, dark: (0xFFFFFF, 0.14))
}

private extension Color {
    init(light: Int, dark: Int) {
        self.init(light: (light, 1), dark: (dark, 1))
    }

    init(light: Int, dark: (Int, Double)) {
        self.init(light: (light, 1), dark: dark)
    }

    init(light: (Int, Double), dark: (Int, Double)) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (hex, alpha) = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha
            )
        })
    }
}
