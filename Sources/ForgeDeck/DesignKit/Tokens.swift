import AppKit
import ForgeDeckKit
import SwiftUI

// The ForgeDeck look, taken from the design file (ForgeDeck.dc.html).
// Layer 1 (Palette) holds raw values. Layer 2 (Ink) gives them meaning in light and
// dark. Layer 3 (KitType, Metric, Motion) holds the scales. Views read layers 2 and 3.

private enum Palette {
    /// OKLCH to sRGB, so the design's color values are used as written.
    static func oklch(_ lightness: Double, _ chroma: Double, _ hue: Double) -> NSColor {
        let h = hue * .pi / 180
        let a = chroma * cos(h), b = chroma * sin(h)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        func gamma(_ x: Double) -> CGFloat {
            let clamped = min(1, max(0, x))
            return CGFloat(clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055)
        }
        return NSColor(srgbRed: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                       green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                       blue: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), alpha: 1)
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static let black = NSColor.black
    static let white = NSColor.white
    static let ink = hex(0x1D1D1F)
    static let snow = hex(0xF2F2F4)
}

enum Ink {
    static let window = Palette.dynamic(Palette.hex(0xFBFBFC), Palette.hex(0x1C1C1E))
    static let sidebarTint = Palette.dynamic(Palette.hex(0xEAECEF, alpha: 0.6), Palette.hex(0x2A2A2E, alpha: 0.5))
    static let toolbar = Palette.dynamic(Palette.hex(0xFBFBFC, alpha: 0.92), Palette.hex(0x1E1E20, alpha: 0.92))
    static let panel = Palette.dynamic(Palette.white, Palette.hex(0x242427))
    static let panel2 = Palette.dynamic(Palette.hex(0xF5F5F7), Palette.hex(0x2B2B2F))
    static let field = Palette.dynamic(Palette.black.withAlphaComponent(0.05), Palette.white.withAlphaComponent(0.07))
    static let chip = Palette.dynamic(Palette.black.withAlphaComponent(0.045), Palette.white.withAlphaComponent(0.07))
    static let button = Palette.dynamic(Palette.white, Palette.white.withAlphaComponent(0.08))
    static let buttonLine = Palette.dynamic(Palette.black.withAlphaComponent(0.11), Palette.white.withAlphaComponent(0.09))
    static let line = Palette.dynamic(Palette.black.withAlphaComponent(0.075), Palette.white.withAlphaComponent(0.08))
    static let line2 = Palette.dynamic(Palette.black.withAlphaComponent(0.05), Palette.white.withAlphaComponent(0.05))
    static let lineStrong = Palette.dynamic(Palette.black.withAlphaComponent(0.15), Palette.white.withAlphaComponent(0.17))
    static let text = Palette.dynamic(Palette.ink, Palette.snow)
    static let text2 = Palette.dynamic(Palette.ink.withAlphaComponent(0.68), Palette.snow.withAlphaComponent(0.7))
    /// The design's tertiary text is 46% ink. It is raised here so 11 pt labels pass 4.5:1.
    static let text3 = Palette.dynamic(Palette.ink.withAlphaComponent(0.58), Palette.snow.withAlphaComponent(0.56))
    static let hover = Palette.dynamic(Palette.black.withAlphaComponent(0.04), Palette.white.withAlphaComponent(0.05))
    static let selection = Palette.dynamic(Palette.black.withAlphaComponent(0.075), Palette.white.withAlphaComponent(0.09))
    static let accent = Palette.dynamic(Palette.oklch(0.57, 0.11, 178), Palette.oklch(0.76, 0.12, 175))
    /// Accent-colored text on a plain surface: darker than the fill in light mode so it reads.
    static let accentText = Palette.dynamic(Palette.oklch(0.47, 0.1, 178), Palette.oklch(0.8, 0.12, 175))
    static let onAccent = Palette.dynamic(Palette.white, Palette.hex(0x04201C))
    static let ok = Palette.dynamic(Palette.oklch(0.52, 0.14, 155), Palette.oklch(0.75, 0.15, 155))
    static let warn = Palette.dynamic(Palette.oklch(0.56, 0.13, 68), Palette.oklch(0.8, 0.14, 75))
    static let err = Palette.dynamic(Palette.oklch(0.55, 0.2, 25), Palette.oklch(0.72, 0.18, 25))
    static let prod = Palette.dynamic(Palette.oklch(0.56, 0.19, 36), Palette.oklch(0.7, 0.17, 40))
    static let onProd = Palette.dynamic(Palette.white, Palette.hex(0x1E0A02))
    static let popover = Palette.dynamic(Palette.hex(0xFBFBFD, alpha: 0.9), Palette.hex(0x26262A, alpha: 0.9))
    static let scrim = Palette.dynamic(Palette.hex(0x18181C, alpha: 0.16), Palette.black.withAlphaComponent(0.38))
    static let toast = Palette.dynamic(Palette.ink, Palette.snow)
    static let onToast = Palette.dynamic(Palette.white, Palette.ink)
    static let shadow = Palette.dynamic(Palette.black.withAlphaComponent(0.05), Palette.black.withAlphaComponent(0.3))
    static let shadowLarge = Palette.dynamic(Palette.black.withAlphaComponent(0.1), Palette.black.withAlphaComponent(0.4))

    static func tone(_ tone: Tone) -> Color {
        switch tone {
        case .ok: ok
        case .warn: warn
        case .err: err
        case .accent: accentText
        case .muted: text3
        case .prod: prod
        }
    }

    /// The two ends of a product icon's gradient.
    static func iconGradient(hue: Double) -> [Color] {
        [Color(nsColor: Palette.oklch(0.72, 0.12, hue)), Color(nsColor: Palette.oklch(0.48, 0.13, hue + 32))]
    }

    static let brandGradient = [Color(nsColor: Palette.oklch(0.72, 0.12, 175)), Color(nsColor: Palette.oklch(0.45, 0.1, 200))]
}

extension Color {
    /// The soft fill behind a toned label or icon.
    func soft(_ amount: Double = 0.13) -> Color { opacity(amount) }
}

enum KitType {
    case pageTitle, productTitle, cardTitle, section, body, bodyMedium, bodyStrong, label, labelMedium, labelStrong
    case meta, metaMedium, metaStrong, metric, metricSmall, mono, monoSmall, monoTitle, badge, paletteInput, paletteRow

    var font: Font {
        switch self {
        case .pageTitle, .productTitle: .system(size: 22, weight: .semibold)
        case .cardTitle: .system(size: 15, weight: .semibold)
        case .section: .system(size: 13, weight: .semibold)
        case .body: .system(size: 13)
        case .bodyMedium: .system(size: 13, weight: .medium)
        case .bodyStrong: .system(size: 14, weight: .semibold)
        case .label: .system(size: 12)
        case .labelMedium: .system(size: 12, weight: .medium)
        case .labelStrong: .system(size: 12, weight: .semibold)
        case .meta: .system(size: 11)
        case .metaMedium: .system(size: 11, weight: .medium)
        case .metaStrong: .system(size: 11, weight: .semibold)
        case .metric: .system(size: 25, weight: .semibold)
        case .metricSmall: .system(size: 17, weight: .semibold)
        case .mono: .system(size: 12, design: .monospaced)
        case .monoSmall: .system(size: 11, design: .monospaced)
        case .monoTitle: .system(size: 17, weight: .semibold, design: .monospaced)
        case .badge: .system(size: 10, weight: .bold)
        case .paletteInput: .system(size: 16)
        case .paletteRow: .system(size: 13.5)
        }
    }

    var tracking: CGFloat {
        switch self {
        case .pageTitle, .productTitle: -0.4
        case .metric: -0.6
        case .badge: 0.4
        default: 0
        }
    }
}

extension View {
    func kitType(_ type: KitType, _ color: Color = Ink.text) -> some View {
        font(type.font).tracking(type.tracking).foregroundStyle(color)
    }
}

enum Metric {
    static let sidebarWidth: CGFloat = 236
    static let toolbarHeight: CGFloat = 52
    static let rowHeight: CGFloat = 28
    static let controlHeight: CGFloat = 28
    static let buttonHeight: CGFloat = 28
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 7
    static let chipRadius: CGFloat = 5
    static let rowRadius: CGFloat = 6
    static let sheetRadius: CGFloat = 14
    static let iconButtonWidth: CGFloat = 30
    static let tileRadius: CGFloat = 8
    static let pagePadding: CGFloat = 28
    static let activityWidth: CGFloat = 340
    static let hairline: CGFloat = 1
}

enum Motion {
    static let hover = Animation.easeOut(duration: 0.12)
    static let select = Animation.easeOut(duration: 0.15)
    static let pop = Animation.easeOut(duration: 0.18)
    static let toast = Animation.easeOut(duration: 0.22)
}

/// Every icon the app uses, so the set can change in one place.
enum KitIcon: String {
    case overview = "square.grid.2x2"
    case projects = "folder"
    case deploy = "arrow.up.to.line"
    case infra = "server.rack"
    case secrets = "lock"
    case activity = "waveform.path.ecg"
    case settings = "slider.horizontal.3"
    case terminal = "terminal"
    case code = "chevron.left.forwardslash.chevron.right"
    case external = "arrow.up.right.square"
    case laptop = "laptopcomputer"
    case branch = "arrow.triangle.branch"
    case globe = "globe"
    case lead = "person"
    case purchase = "creditcard"
    case alert = "exclamationmark.triangle"
    case error = "xmark.circle"
    case key = "key"
    case check = "checkmark"
    case play = "play"
    case chart = "chart.bar"
    case link = "link"
    case shield = "shield"
    case touchID = "touchid"
    case search = "magnifyingglass"
    case bolt = "bolt"
    case bell = "bell"
    case plus = "plus"
    case chevronRight = "chevron.right"
    case chevronLeft = "chevron.left"
    case chevronUpDown = "chevron.up.chevron.down"
    case chevronDown = "chevron.down"
    case gauge = "gauge.with.dots.needle.33percent"
    case sync = "arrow.triangle.2.circlepath"
    case star = "star"
    case starFill = "star.fill"
    case finder = "folder.badge.gearshape"
    case copy = "doc.on.doc"
    case eye = "eye"
    case eyeSlash = "eye.slash"
    case trash = "trash"
    case clock = "clock"
    case pullRequest = "arrow.triangle.pull"
    case commit = "smallcircle.filled.circle"
    case docker = "shippingbox"
    case leads = "person.2"
    case stethoscope = "stethoscope"
    case sparkle = "sparkles"
    case question = "questionmark.circle"
    case wifiOff = "wifi.slash"
    case archive = "archivebox"
    case pencil = "pencil"
    case more = "ellipsis"
    case download = "arrow.down.circle"
    case info = "info.circle"
    case hammer = "hammer"
    case wrench = "wrench.and.screwdriver"
    case xmark = "xmark"
}

struct Icon: View {
    let icon: KitIcon
    var size: CGFloat = 14
    var weight: Font.Weight = .regular

    init(_ icon: KitIcon, size: CGFloat = 14, weight: Font.Weight = .regular) {
        self.icon = icon
        self.size = size
        self.weight = weight
    }

    var body: some View {
        Image(systemName: icon.rawValue)
            .font(.system(size: size, weight: weight))
            .accessibilityHidden(true)
    }
}
