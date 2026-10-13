import AppKit
import SwiftUI

/// Single source of truth for the canvas look. The canvas is intentionally a
/// fixed dark surface (like a drafting table) rather than following the system
/// appearance — node accents are tuned against this background.
///
/// The palette is **Night Owl**. Every colour the app draws is either one of the
/// fourteen palette values or a blend of two of them, so the whole board — cards,
/// chrome, diffs and the terminals themselves — reads as one theme.
public enum Theme {
    // MARK: Palette
    /// Night Owl, verbatim, plus `mint` — the one value from outside the theme,
    /// taken off the icon so the app and its artwork share a primary. Held as
    /// 24-bit hex because all three consumers — SwiftUI, AppKit and the terminal
    /// emulator — take their colours that way.
    public enum NightOwl {
        public static let background: UInt32 = 0x011627
        public static let sidebar: UInt32 = 0x001122
        public static let surface: UInt32 = 0x1D3B53
        public static let foreground: UInt32 = 0xD6DEEB
        public static let muted: UInt32 = 0x637777
        public static let blue: UInt32 = 0x82AAFF
        public static let purple: UInt32 = 0xC792EA
        public static let teal: UInt32 = 0x7FDBCA
        public static let green: UInt32 = 0xADDB67
        public static let orange: UInt32 = 0xF78C6C
        public static let yellow: UInt32 = 0xECC48D
        public static let red: UInt32 = 0xFF6363
        public static let pink: UInt32 = 0xFF2C83
        /// The brand mint, from the lit node in the mark. Brighter and more
        /// saturated than `teal`, which it sits beside on a session card.
        public static let mint: UInt32 = 0x64FFDA
    }

    /// Semantic colours as hex, so AppKit and the terminal can reach them too.
    /// Nothing below derives from anything but `NightOwl`.
    public enum Hex {
        // Surfaces, deepest first: sidebar → background → the three card fills.
        public static let canvasDeep = NightOwl.sidebar
        public static let chrome = NightOwl.sidebar
        public static let canvas = NightOwl.background
        public static let surfaceSunken = blend(NightOwl.background, NightOwl.surface, 0.3)
        public static let surface = blend(NightOwl.background, NightOwl.surface, 0.62)
        public static let surfaceRaised = NightOwl.surface

        public static let textPrimary = NightOwl.foreground
        public static let textSecondary = blend(NightOwl.muted, NightOwl.foreground, 0.5)
        public static let textTertiary = NightOwl.muted

        public static let accent = NightOwl.mint
        /// The accent is a light mint, so anything filled with `accent` has to
        /// put the background colour back on top to stay readable.
        public static let onAccent = NightOwl.background

        public static let busy = NightOwl.yellow
        public static let idle = NightOwl.teal
        public static let ended = blend(NightOwl.surface, NightOwl.muted, 0.5)
        public static let worktree = blend(NightOwl.muted, NightOwl.blue, 0.35)
        public static let branch = NightOwl.purple
        public static let dirty = NightOwl.orange
        public static let clean = NightOwl.green
        public static let danger = NightOwl.red
        public static let sidechain = NightOwl.pink
        /// An agent stopped on a question. The palette's loudest colour, and
        /// the one thing on the board that should pull your eye across a room.
        public static let needsYou = NightOwl.pink
        public static let reasoning = NightOwl.teal
        public static let hairlineStrong = blend(NightOwl.surface, NightOwl.muted, 0.55)
    }

    // MARK: Surfaces
    public static let canvas = Color(hex: Hex.canvas)
    public static let canvasDeep = Color(hex: Hex.canvasDeep)
    public static let grid = Color(hex: NightOwl.muted).opacity(0.22)
    public static let gridMajor = Color(hex: NightOwl.muted).opacity(0.4)

    public static let surface = Color(hex: Hex.surface)
    public static let surfaceRaised = Color(hex: Hex.surfaceRaised)
    public static let surfaceSunken = Color(hex: Hex.surfaceSunken)
    public static let chrome = Color(hex: Hex.chrome)

    public static let hairline = Color(hex: NightOwl.surface).opacity(0.8)
    public static let hairlineStrong = Color(hex: Hex.hairlineStrong)

    /// Hover and pressed states. Tinted with the palette's own panel colour
    /// rather than white, which would wash the blue out of the chrome.
    public static let fillSubtle = Color(hex: NightOwl.surface).opacity(0.3)
    public static let fill = Color(hex: NightOwl.surface).opacity(0.5)
    public static let fillStrong = Color(hex: NightOwl.surface).opacity(0.85)

    // MARK: Text
    public static let textPrimary = Color(hex: Hex.textPrimary)
    public static let textSecondary = Color(hex: Hex.textSecondary)
    public static let textTertiary = Color(hex: Hex.textTertiary)

    // MARK: Accents
    /// The brand mint carries selection and primary actions. Status keeps
    /// colours of its own — an agent at work is amber whatever the accent is.
    public static let accent = Color(hex: Hex.accent)
    /// Text and glyphs sitting on top of a solid `accent` fill.
    public static let onAccent = Color(hex: Hex.onAccent)
    public static let busy = Color(hex: Hex.busy)
    public static let idle = Color(hex: Hex.idle)
    public static let ended = Color(hex: Hex.ended)
    /// Repositories read as a neutral slate so the accent stays the app's alone.
    public static let worktree = Color(hex: Hex.worktree)
    public static let branch = Color(hex: Hex.branch)
    /// A checkout with uncommitted work. Failures are `danger`, not this.
    public static let dirty = Color(hex: Hex.dirty)
    public static let clean = Color(hex: Hex.clean)
    /// Something went wrong: a failed tool call, an unusable repo, deleted lines.
    public static let danger = Color(hex: Hex.danger)
    /// A sidechain — a session forked off another one.
    public static let sidechain = Color(hex: Hex.sidechain)
    /// An agent waiting on you. Shares the pink with `sidechain`, which only
    /// ever appears in a transcript, so the two never sit side by side.
    public static let needsYou = Color(hex: Hex.needsYou)
    /// Informational banners.
    public static let info = Color(hex: NightOwl.blue)
    /// Extended thinking in a transcript.
    public static let reasoning = Color(hex: Hex.reasoning)

    // MARK: Brand
    /// The mark, drawn in the palette, matching the shipped artwork exactly:
    /// `mark-on-dark.svg` is Night Owl's foreground with a mint lit node.
    public static let markTint = Color(hex: Hex.textPrimary)
    public static let markAccent = Color(hex: NightOwl.mint)

    // MARK: Metrics
    public static let nodeCorner: CGFloat = 12
    public static let groupCorner: CGFloat = 20
    public static let accentRail: CGFloat = 3

    // MARK: Type
    public static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Deterministic tint per repository so groups stay recognisable between
    /// launches. Drawn from the palette rather than the whole hue wheel, so a
    /// board of many repositories still looks like one theme.
    private static let repoTints: [UInt32] = [
        NightOwl.blue, NightOwl.purple, NightOwl.teal,
        NightOwl.green, NightOwl.orange, NightOwl.yellow, NightOwl.pink
    ]

    public static func repoTint(_ seed: String) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Color(hex: repoTints[Int(hash % UInt64(repoTints.count))])
    }

    /// `amount` of `b` mixed into `a`, in sRGB. Used only to derive the handful
    /// of shades the palette does not name outright.
    public static func blend(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
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
    public init(hex: UInt32) {
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
    public convenience init(hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
