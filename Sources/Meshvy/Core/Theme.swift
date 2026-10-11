import SwiftUI

/// Single source of truth for the canvas look. The canvas is intentionally a
/// fixed dark surface (like a drafting table) rather than following the system
/// appearance — node accents are tuned against this background.
enum Theme {
    // MARK: Brand
    /// Straight from the mark: the lit node, the unlit nodes, the icon ground.
    static let brandPurple = Color(hex: 0x6E56F8)
    static let brandCream = Color(hex: 0xF3F3EE)
    static let brandNavy = Color(hex: 0x1C1D2B)

    // MARK: Surfaces
    static let canvas = Color(hex: 0x0F1018)
    static let canvasDeep = Color(hex: 0x0A0B11)
    static let grid = Color.white.opacity(0.055)
    static let gridMajor = Color.white.opacity(0.09)

    static let surface = Color(hex: 0x191A26)
    static let surfaceRaised = Color(hex: 0x222432)
    static let surfaceSunken = Color(hex: 0x14151F)
    static let chrome = Color(hex: 0x161722)

    static let hairline = Color.white.opacity(0.085)
    static let hairlineStrong = Color.white.opacity(0.16)

    // MARK: Text
    static let textPrimary = brandCream
    static let textSecondary = Color(hex: 0x9CA1B5)
    static let textTertiary = Color(hex: 0x666B80)

    // MARK: Accents
    /// Brand purple carries selection and primary actions. Status keeps colours
    /// of its own — an agent at work is amber whatever the brand is.
    static let accent = brandPurple
    static let busy = Color(hex: 0xF2A33C)
    static let idle = Color(hex: 0x45C0A8)
    static let ended = Color(hex: 0x5A6375)
    /// Repositories read as neutral so purple stays the brand's alone.
    static let worktree = Color(hex: 0x8E97B4)
    static let branch = Color(hex: 0xA78BFA)
    static let dirty = Color(hex: 0xE8785E)
    static let clean = Color(hex: 0x45C0A8)
    static let sidechain = Color(hex: 0x58B2E0)

    // MARK: Metrics
    static let nodeCorner: CGFloat = 12
    static let groupCorner: CGFloat = 20
    static let accentRail: CGFloat = 3

    static let sessionNodeSize = CGSize(width: 268, height: 132)
    static let worktreeNodeSize = CGSize(width: 268, height: 112)

    // MARK: Type
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Deterministic hue per repository so groups stay recognisable between launches.
    static func repoTint(_ seed: String) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.42, brightness: 0.78)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
