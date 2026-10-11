import AppKit
import SwiftUI

/// Single source of truth for the canvas look. The canvas is intentionally a
/// fixed dark surface (like a drafting table) rather than following the system
/// appearance — node accents are tuned against this background.
///
/// The palette is **Night Owl**. Every colour the app draws is either one of the
/// thirteen palette values or a blend of two of them, so the whole board — cards,
/// chrome, diffs and the terminals themselves — reads as one theme.
enum Theme {
    // MARK: Palette
    /// Night Owl, verbatim. Held as 24-bit hex because all three consumers —
    /// SwiftUI, AppKit and the terminal emulator — take their colours that way.
    enum NightOwl {
        static let background: UInt32 = 0x011627
        static let sidebar: UInt32 = 0x001122
        static let surface: UInt32 = 0x1D3B53
        static let foreground: UInt32 = 0xD6DEEB
        static let muted: UInt32 = 0x637777
        static let blue: UInt32 = 0x82AAFF
        static let purple: UInt32 = 0xC792EA
        static let teal: UInt32 = 0x7FDBCA
        static let green: UInt32 = 0xADDB67
        static let orange: UInt32 = 0xF78C6C
        static let yellow: UInt32 = 0xECC48D
        static let red: UInt32 = 0xFF6363
        static let pink: UInt32 = 0xFF2C83
    }

    /// Semantic colours as hex, so AppKit and the terminal can reach them too.
    /// Nothing below derives from anything but `NightOwl`.
    enum Hex {
        // Surfaces, deepest first: sidebar → background → the three card fills.
        static let canvasDeep = NightOwl.sidebar
        static let chrome = NightOwl.sidebar
        static let canvas = NightOwl.background
        static let surfaceSunken = blend(NightOwl.background, NightOwl.surface, 0.3)
        static let surface = blend(NightOwl.background, NightOwl.surface, 0.62)
        static let surfaceRaised = NightOwl.surface

        static let textPrimary = NightOwl.foreground
        static let textSecondary = blend(NightOwl.muted, NightOwl.foreground, 0.5)
        static let textTertiary = NightOwl.muted

        static let accent = NightOwl.blue
        /// Night Owl's accents are all pastel, so anything filled with `accent`
        /// has to put the background colour back on top to stay readable.
        static let onAccent = NightOwl.background

        static let busy = NightOwl.yellow
        static let idle = NightOwl.teal
        static let ended = blend(NightOwl.surface, NightOwl.muted, 0.5)
        static let worktree = blend(NightOwl.muted, NightOwl.blue, 0.35)
        static let branch = NightOwl.purple
        static let dirty = NightOwl.orange
        static let clean = NightOwl.green
        static let danger = NightOwl.red
        static let sidechain = NightOwl.pink
        static let reasoning = NightOwl.teal
        static let hairlineStrong = blend(NightOwl.surface, NightOwl.muted, 0.55)
    }

    // MARK: Surfaces
    static let canvas = Color(hex: Hex.canvas)
    static let canvasDeep = Color(hex: Hex.canvasDeep)
    static let grid = Color(hex: NightOwl.muted).opacity(0.22)
    static let gridMajor = Color(hex: NightOwl.muted).opacity(0.4)

    static let surface = Color(hex: Hex.surface)
    static let surfaceRaised = Color(hex: Hex.surfaceRaised)
    static let surfaceSunken = Color(hex: Hex.surfaceSunken)
    static let chrome = Color(hex: Hex.chrome)

    static let hairline = Color(hex: NightOwl.surface).opacity(0.8)
    static let hairlineStrong = Color(hex: Hex.hairlineStrong)

    /// Hover and pressed states. Tinted with the palette's own panel colour
    /// rather than white, which would wash the blue out of the chrome.
    static let fillSubtle = Color(hex: NightOwl.surface).opacity(0.3)
    static let fill = Color(hex: NightOwl.surface).opacity(0.5)
    static let fillStrong = Color(hex: NightOwl.surface).opacity(0.85)

    // MARK: Text
    static let textPrimary = Color(hex: Hex.textPrimary)
    static let textSecondary = Color(hex: Hex.textSecondary)
    static let textTertiary = Color(hex: Hex.textTertiary)

    // MARK: Accents
    /// Night Owl's blue carries selection and primary actions. Status keeps
    /// colours of its own — an agent at work is amber whatever the accent is.
    static let accent = Color(hex: Hex.accent)
    /// Text and glyphs sitting on top of a solid `accent` fill.
    static let onAccent = Color(hex: Hex.onAccent)
    static let busy = Color(hex: Hex.busy)
    static let idle = Color(hex: Hex.idle)
    static let ended = Color(hex: Hex.ended)
    /// Repositories read as a neutral slate so the accent stays the app's alone.
    static let worktree = Color(hex: Hex.worktree)
    static let branch = Color(hex: Hex.branch)
    /// A checkout with uncommitted work. Failures are `danger`, not this.
    static let dirty = Color(hex: Hex.dirty)
    static let clean = Color(hex: Hex.clean)
    /// Something went wrong: a failed tool call, an unusable repo, deleted lines.
    static let danger = Color(hex: Hex.danger)
    /// A sidechain — a session forked off another one.
    static let sidechain = Color(hex: Hex.sidechain)
    /// Informational banners.
    static let info = Color(hex: NightOwl.blue)
    /// Extended thinking in a transcript.
    static let reasoning = Color(hex: Hex.reasoning)

    // MARK: Brand
    /// The mark, drawn in the palette: Night Owl's purple for the lit node. The
    /// shipped icon assets keep the original brand purple.
    static let markTint = Color(hex: Hex.textPrimary)
    static let markAccent = Color(hex: NightOwl.purple)

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

    /// Deterministic tint per repository so groups stay recognisable between
    /// launches. Drawn from the palette rather than the whole hue wheel, so a
    /// board of many repositories still looks like one theme.
    private static let repoTints: [UInt32] = [
        NightOwl.blue, NightOwl.purple, NightOwl.teal,
        NightOwl.green, NightOwl.orange, NightOwl.yellow, NightOwl.pink
    ]

    static func repoTint(_ seed: String) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Color(hex: repoTints[Int(hash % UInt64(repoTints.count))])
    }

    /// `amount` of `b` mixed into `a`, in sRGB. Used only to derive the handful
    /// of shades the palette does not name outright.
    static func blend(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        let t = min(max(amount, 0), 1)
        var out: UInt32 = 0
        for shift in [16, 8, 0] {
            let from = Double((a >> UInt32(shift)) & 0xFF)
            let to = Double((b >> UInt32(shift)) & 0xFF)
            let mixed = UInt32((from + (to - from) * t).rounded())
            out |= min(mixed, 0xFF) << UInt32(shift)
        }
        return out
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

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
