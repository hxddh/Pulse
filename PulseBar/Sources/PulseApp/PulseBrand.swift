import AppKit
import SwiftUI

/// Pulse brand mark and the menu-bar lamp.
///
/// The status item draws the same four lamp shapes as a tray row
/// (`LampFace`): filled = needs you, ring = running, hollow = your turn /
/// recent / idle, dotted = seen only as a process. One glyph family, so the
/// menu bar and the row it summarises read alike.
enum PulseBrand {
    /// The lamp's size in the menu bar, in points — drawn at this size,
    /// never scaled.
    static let statusIconSize: CGFloat = 16

    /// The status-bar lamp for a glance.
    static func statusBarIcon(for glance: GlanceKind) -> NSImage {
        statusBarIcon(for: LampFace.glance(glance))
    }

    /// The status-bar lamp.
    ///
    /// A grey lamp (idle, recent, your turn, process only) is a template
    /// image: the menu bar draws it in its own foreground colour, like every
    /// system item beside it, in light, dark, tinted and high-contrast menu
    /// bars. A coloured lamp — red (needs you), green (running), orange (a
    /// stall) — carries the product's one glance signal, which a template
    /// would erase, so it is drawn in its colour. `contentTintColor` is not
    /// the answer: AppKit applies it to the title as well.
    ///
    /// The image is a drawing handler at `statusIconSize` points: AppKit
    /// draws it at the screen's scale (no 16 → 15 downscale blur) and calls
    /// it again when the menu bar's appearance changes, so the system
    /// colours resolve at draw time and are never stored.
    static func statusBarIcon(for lamp: LampFace) -> NSImage {
        let side = statusIconSize
        let template = lamp.tone == .idle
        let tone = lamp.tone
        let shape = lamp.shape
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            drawLamp(shape: shape, tone: tone, template: template, side: side)
            return true
        }
        image.isTemplate = template
        return image
    }

    /// The lamp's strokes, in the current graphics context.
    private static func drawLamp(shape: LampFace.Shape, tone: PulseTheme.Tone, template: Bool, side: CGFloat) {
        // A template is drawn in black; the menu bar supplies its colour.
        let color = template ? NSColor.black : statusColor(for: tone)
        let scale = side / 16
        let stroke: CGFloat = 1.6 * scale
        let circle = NSRect(x: 2.5 * scale, y: 2.5 * scale, width: 11 * scale, height: 11 * scale)
        switch shape {
        case .filled:
            color.setFill()
            NSBezierPath(ovalIn: circle).fill()
        case .ring:
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: stroke / 2, dy: stroke / 2))
            ring.lineWidth = stroke
            color.setStroke()
            ring.stroke()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 6 * scale, y: 6 * scale, width: 4 * scale, height: 4 * scale)).fill()
        case .hollow:
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: stroke / 2, dy: stroke / 2))
            ring.lineWidth = stroke
            color.setStroke()
            ring.stroke()
        case .dotted:
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: stroke / 2, dy: stroke / 2))
            ring.lineWidth = stroke
            ring.lineCapStyle = .round
            ring.setLineDash([0.1, 3.1 * scale], count: 2, phase: 0)
            color.setStroke()
            ring.stroke()
        }
        // Orange shares the ring with green; a notch in the top-right corner
        // is a shape the eye reads without the hue (Differentiate Without
        // Colour).
        if tone == .attention {
            let dot: CGFloat = 5 * scale
            let badge = NSRect(x: side - dot, y: side - dot, width: dot, height: dot)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: badge.insetBy(dx: -1.2 * scale, dy: -1.2 * scale)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            color.setFill()
            NSBezierPath(ovalIn: badge).fill()
        }
    }

    static func statusColor(for glance: GlanceKind) -> NSColor {
        switch glance {
        case .waiting: return .systemRed
        case .running: return .systemGreen
        case .stalled: return .systemOrange
        case .idle: return .systemGray
        }
    }

    static func statusColor(for tone: PulseTheme.Tone) -> NSColor {
        switch tone {
        case .waiting: return statusColor(for: GlanceKind.waiting)
        case .running: return statusColor(for: GlanceKind.running)
        case .attention: return statusColor(for: GlanceKind.stalled)
        case .idle: return statusColor(for: GlanceKind.idle)
        }
    }

    /// Larger mark for the empty tray (template).
    static func markImage(size: CGFloat = 28) -> NSImage {
        if let img = loadPNG("pulse-mark") {
            img.isTemplate = true
            img.size = NSSize(width: size, height: size)
            return img
        }
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let stroke = max(1.1, size * 0.085)
        let ring = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.12, dy: size * 0.12))
        ring.lineWidth = stroke
        NSColor.labelColor.setStroke()
        ring.stroke()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    private static func loadPNG(_ name: String) -> NSImage? {
        for file in [name, "\(name)@2x"] {
            if let url = PulseResources.url(forResource: file, withExtension: "png", subdirectory: "Brand"),
               let img = NSImage(contentsOf: url) {
                return img
            }
        }
        return nil
    }
}

struct PulseMarkView: View {
    var size: CGFloat = 28
    var tone: Color = .secondary

    var body: some View {
        Image(nsImage: PulseBrand.markImage(size: size))
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(tone)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
