import AppKit
import SwiftUI

/// Pulse brand mark and the menu-bar lamp.
///
/// The status item draws the same four lamp shapes as a tray row
/// (`LampFace`): filled = needs you, ring = running, hollow = your turn /
/// recent / idle, dotted = seen only as a process. One glyph family, so the
/// menu bar and the row it summarises read alike.
enum PulseBrand {
    /// Full-colour status-bar icon for a glance.
    static func statusBarIcon(for glance: GlanceKind) -> NSImage {
        statusBarIcon(for: LampFace.glance(glance))
    }

    /// Full-colour status-bar icon.
    ///
    /// NSStatusBarButton renders a template image in the menu bar's own
    /// foreground colour. That is excellent for contrast, but it also erases
    /// the product's only glance signal: red / green / grey / orange. Forcing
    /// `contentTintColor` is not an answer because AppKit applies it to the
    /// title as well and it can resolve black-on-black against a dark menu bar.
    /// Draw the pixels in the state colour instead; leave the button title
    /// system-adaptive. Colours are read here, at draw time, never stored.
    static func statusBarIcon(for lamp: LampFace) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        let color = statusColor(for: lamp.tone)
        let stroke: CGFloat = 1.6
        let circle = NSRect(x: 2.5, y: 2.5, width: 11, height: 11)
        switch lamp.shape {
        case .filled:
            color.setFill()
            NSBezierPath(ovalIn: circle).fill()
        case .ring:
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: stroke / 2, dy: stroke / 2))
            ring.lineWidth = stroke
            color.setStroke()
            ring.stroke()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 4, height: 4)).fill()
        case .hollow:
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: stroke / 2, dy: stroke / 2))
            ring.lineWidth = stroke
            color.setStroke()
            ring.stroke()
        case .dotted:
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: stroke / 2, dy: stroke / 2))
            ring.lineWidth = stroke
            ring.lineCapStyle = .round
            ring.setLineDash([0.1, 3.1], count: 2, phase: 0)
            color.setStroke()
            ring.stroke()
        }
        // Orange shares the ring with green; a notch in the top-right corner
        // is a shape the eye reads without the hue (Differentiate Without
        // Colour).
        if lamp.tone == .attention {
            let dot: CGFloat = 5
            let badge = NSRect(x: size.width - dot, y: size.height - dot, width: dot, height: dot)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: badge.insetBy(dx: -1.2, dy: -1.2)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            color.setFill()
            NSBezierPath(ovalIn: badge).fill()
        }
        image.unlockFocus()
        image.isTemplate = false
        image.size = size
        return image
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
        if let url = PulseResources.url(forResource: name, withExtension: "png", subdirectory: "Brand"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let url = PulseResources.url(forResource: "\(name)@2x", withExtension: "png", subdirectory: "Brand"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Brand/\(name).png"),
           let img = NSImage(contentsOf: url) {
            return img
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
