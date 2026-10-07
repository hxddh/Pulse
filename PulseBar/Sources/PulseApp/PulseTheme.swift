import AppKit
import SwiftUI

/// The product's one visual system: type sizes, fills, radii, motion, the
/// lamp's colours and its menu-bar image, named once. Everything a view
/// needs to look like Pulse is named here, so no call site writes its own
/// radius, point size or red.
///
/// Colours are computed properties, never `static let`: a stored colour
/// freezes the appearance that was current on first touch. State colours
/// are the system's dynamic colours, so Increase Contrast and dark mode move
/// them too.
enum PulseTheme {
    // MARK: Spacing — the 4-pt grid

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }

    // MARK: Radii

    enum Radius {
        /// Inner blocks, fields inside a card.
        static let inner: CGFloat = 6
        /// The selected row's fill and every card.
        static let card: CGFloat = 10
    }

    // MARK: Fills — opacity of `.primary` over the material

    enum Fill {
        static let subtle: Double = 0.04
        static let selected: Double = 0.10
        /// A notice's tinted surface.
        static let waitTint: Double = 0.07
    }

    // MARK: Type — semantic styles, so the platform owns the sizes

    enum Font {
        /// A section or card heading.
        static let heading: SwiftUI.Font = .system(.subheadline, design: .rounded).weight(.semibold)
        /// The line a glance lands on: a row's task, a card's subject.
        static let hero: SwiftUI.Font = .system(.body, design: .rounded).weight(.semibold)
        static let heroQuiet: SwiftUI.Font = .system(.body, design: .rounded)
        /// Sentences and facts.
        static let body: SwiftUI.Font = .system(.subheadline)
        static let bodyEmphasis: SwiftUI.Font = .system(.subheadline).weight(.medium)
        /// Times, sources, footnotes.
        static let caption: SwiftUI.Font = .system(.caption)
        /// Machine text: commands, paths, an agent's error in its own words.
        static let code: SwiftUI.Font = .system(.caption, design: .monospaced)
    }

    // MARK: Motion

    /// The one motion curve: the detail page's fade, a scroll to a
    /// section — two curves in one product read as two products.
    static let motion: Animation = .easeOut(duration: 0.16)

    /// `motion`, or none at all when the person asked for less movement.
    static func motion(reduced: Bool) -> Animation? {
        reduced ? nil : motion
    }

    /// Something to fix (a failed install, a login item macOS refused, an
    /// agent's error): the stall's orange, the one warning colour.
    static var warning: Color { Lamp.stalled.color }
}

// MARK: - The lamp's colours and its menu-bar image

extension Lamp {
    /// The state colour: red, green, orange — a grey lamp is `.secondary`.
    var color: Color { isGrey ? Color.secondary : Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .waiting: return .systemRed
        case .running: return .systemGreen
        case .stalled: return .systemOrange
        case .idle, .processOnly: return .systemGray
        }
    }

    /// The lamp's size in the menu bar, in points — drawn at this size,
    /// never scaled.
    static let statusIconSize: CGFloat = 16

    /// The status-bar lamp.
    ///
    /// A grey lamp is a template image: the menu bar draws it in its own
    /// foreground colour, like every system item beside it, in light, dark,
    /// tinted and high-contrast menu bars. A coloured lamp carries the
    /// product's one glance signal, which a template would erase, so it is
    /// drawn in its colour. `contentTintColor` is not the answer: AppKit
    /// applies it to the title as well.
    ///
    /// The image is a drawing handler at `statusIconSize` points: AppKit
    /// draws it at the screen's scale and calls it again when the menu
    /// bar's appearance changes, so the system colours resolve at draw time.
    var statusBarImage: NSImage {
        let side = Self.statusIconSize
        let lamp = self
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            lamp.draw(side: side)
            return true
        }
        image.isTemplate = isGrey
        return image
    }

    /// The lamp's strokes, in the current graphics context.
    private func draw(side: CGFloat) {
        // A template is drawn in black; the menu bar supplies its colour.
        let color = isGrey ? NSColor.black : nsColor
        let scale = side / 16
        let stroke: CGFloat = 1.6 * scale
        let circle = NSRect(x: 2.5 * scale, y: 2.5 * scale, width: 11 * scale, height: 11 * scale)
        let outline = NSBezierPath(ovalIn: circle.insetBy(dx: stroke / 2, dy: stroke / 2))
        outline.lineWidth = stroke
        switch self {
        case .waiting:
            color.setFill()
            NSBezierPath(ovalIn: circle).fill()
        case .running, .stalled:
            color.setStroke()
            outline.stroke()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 6 * scale, y: 6 * scale, width: 4 * scale, height: 4 * scale)).fill()
        case .idle:
            color.setStroke()
            outline.stroke()
        case .processOnly:
            outline.lineCapStyle = .round
            outline.setLineDash([0.1, 3.1 * scale], count: 2, phase: 0)
            color.setStroke()
            outline.stroke()
        }
        // Orange shares the ring with green; a notch in the top-right corner
        // is a shape the eye reads without the hue (Differentiate Without
        // Colour).
        if self == .stalled {
            let dot: CGFloat = 5 * scale
            let badge = NSRect(x: side - dot, y: side - dot, width: dot, height: dot)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: badge.insetBy(dx: -1.2 * scale, dy: -1.2 * scale)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            color.setFill()
            NSBezierPath(ovalIn: badge).fill()
        }
    }
}

/// The lamp's shape in its colour, beside a row and on the detail page —
/// the same vocabulary as the menu-bar image.
struct LampShapeView: View {
    let lamp: Lamp
    var size: CGFloat = 9

    var body: some View {
        let color = lamp.color
        Group {
            switch lamp {
            case .waiting:
                Circle().fill(color)
            case .running, .stalled:
                ZStack {
                    Circle().strokeBorder(color, lineWidth: 1.4)
                    Circle().fill(color).frame(width: size * 0.36, height: size * 0.36)
                }
            case .idle:
                Circle().strokeBorder(color, lineWidth: 1.4)
            case .processOnly:
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.4, dash: [1.4, 1.6]))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Pulse's mark, for the empty tray (a template).
struct PulseMarkView: View {
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: Self.image(size: size))
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// The bundled mark, or a drawn ring when the bundle is missing.
    static func image(size: CGFloat) -> NSImage {
        for file in ["pulse-mark", "pulse-mark@2x"] {
            if let url = PulseResources.url(forResource: file, withExtension: "png", subdirectory: "Brand"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                img.size = NSSize(width: size, height: size)
                return img
            }
        }
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.12, dy: size * 0.12))
            ring.lineWidth = max(1.1, size * 0.085)
            NSColor.black.setStroke()
            ring.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - Shared chrome

extension View {
    /// A block inside a card.
    func pulseInner(padding: CGFloat = PulseTheme.Space.s) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(PulseTheme.Fill.subtle),
                in: RoundedRectangle(cornerRadius: PulseTheme.Radius.inner, style: .continuous)
            )
    }
}
