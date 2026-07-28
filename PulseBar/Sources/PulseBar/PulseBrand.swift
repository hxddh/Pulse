import AppKit
import SwiftUI

/// Pulse brand mark — lamp ring + pulse. Menu bar uses template PNGs.
enum PulseBrand {
    enum GlanceAsset {
        case idle, running, waiting, error

        var resourceBase: String {
            switch self {
            case .idle, .error: return "pulse-idle"
            case .running: return "pulse-running"
            case .waiting: return "pulse-waiting"
            }
        }
    }

    static func menuIcon(for glance: GlanceKind) -> NSImage {
        let asset: GlanceAsset
        switch glance {
        case .idle: asset = .idle
        case .running: asset = .running
        case .stalled: asset = .error
        case .waiting: asset = .waiting
        case .error: asset = .error
        }
        if let img = loadPNG(asset.resourceBase) {
            img.isTemplate = true
            img.size = NSSize(width: 16, height: 16)
            return img
        }
        return fallbackDrawn(asset)
    }

    /// Larger mark for tray empty / about (template).
    static func markImage(size: CGFloat = 28) -> NSImage {
        if let img = loadPNG("pulse-mark") {
            img.isTemplate = true
            img.size = NSSize(width: size, height: size)
            return img
        }
        return fallbackDrawn(.idle, canvas: size)
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

    private static func fallbackDrawn(_ asset: GlanceAsset, canvas: CGFloat = 16) -> NSImage {
        let s = canvas
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: NSSize(width: s, height: s)).fill()
        let stroke = max(1.1, s * 0.085)
        let inset = s * 0.12
        let r = (s - inset * 2) / 2
        let c = CGPoint(x: s / 2, y: s / 2)
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        NSColor.labelColor.setStroke()
        ring.lineWidth = stroke
        ring.stroke()
        switch asset {
        case .running:
            let ir = r * 0.32
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - ir, y: c.y - ir, width: ir * 2, height: ir * 2)).fill()
        case .waiting:
            let path = NSBezierPath()
            path.lineWidth = stroke * 1.05
            path.lineCapStyle = .round
            let gap = r * 0.28
            let h = r * 0.55
            path.move(to: NSPoint(x: c.x - gap, y: c.y - h))
            path.line(to: NSPoint(x: c.x - gap, y: c.y + h))
            path.move(to: NSPoint(x: c.x + gap, y: c.y - h))
            path.line(to: NSPoint(x: c.x + gap, y: c.y + h))
            NSColor.labelColor.setStroke()
            path.stroke()
        case .idle, .error:
            let path = NSBezierPath()
            path.lineWidth = stroke
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let y = c.y
            let x0 = c.x - r * 0.72
            let x1 = c.x - r * 0.28
            let x2 = c.x
            let x3 = c.x + r * 0.28
            let x4 = c.x + r * 0.72
            path.move(to: NSPoint(x: x0, y: y))
            path.line(to: NSPoint(x: x1, y: y))
            path.line(to: NSPoint(x: x1 + (x2 - x1) * 0.35, y: y + r * 0.55))
            path.line(to: NSPoint(x: x2, y: y - r * 0.72))
            path.line(to: NSPoint(x: x2 + (x3 - x2) * 0.55, y: y + r * 0.22))
            path.line(to: NSPoint(x: x3, y: y))
            path.line(to: NSPoint(x: x4, y: y))
            NSColor.labelColor.setStroke()
            path.stroke()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
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

extension GlanceKind {
    /// Traffic-light lamp tint (Glance / header / waiting scream).
    var lampColor: Color {
        switch self {
        case .waiting: return Color(red: 0.92, green: 0.28, blue: 0.22)
        case .running: return Color(red: 0.22, green: 0.68, blue: 0.40)
        case .stalled: return Color.orange
        case .idle: return Color.secondary
        case .error: return Color.orange
        }
    }
}
