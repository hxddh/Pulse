import AppKit
import SwiftUI

enum AgentIcon {
    private static let cache = NSCache<NSString, NSImage>()
    private static let rasterSize = 64
    private static let opticalSize: CGFloat = 52

    /// Template (monochrome) brand mark for menu / panel rows.
    static func image(for id: AgentID) -> NSImage {
        let key = id.rawValue as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let name = assetName(for: id)
        let source = loadPNG(name) ?? loadSVG(name) ?? monogram(for: id)
        let image = opticallyNormalized(source)
        cache.setObject(image, forKey: key)
        return image
    }

    static func assetName(for id: AgentID) -> String {
        switch id {
        case .codex: return "codex"
        case .continue_: return "continue"
        default: return id.rawValue
        }
    }

    /// Fallback glyph when PNG/SVG missing — keep unique across the roster.
    static func monogramLetter(for id: AgentID) -> String {
        switch id {
        case .claude: return "Cl"
        case .codex: return "Cx"
        case .cursor: return "Cu"
        case .cursorAgent: return "CA"
        case .grok: return "Gk"
        case .pi: return "Pi"
        case .amp: return "Am"
        case .aider: return "Ai"
        case .gemini: return "Ge"
        case .copilot: return "Cp"
        case .opencode: return "Oc"
        case .goose: return "Go"
        case .openhands: return "OH"
        case .cline: return "Ci"
        case .roo: return "Ro"
        case .continue_: return "Cn"
        case .amazonQ: return "Q"
        case .cascade: return "Cs"
        case .windsurf: return "Ws"
        case .augment: return "Au"
        case .zedAgent: return "Zd"
        case .trae: return "Tr"
        case .warpAgent: return "Wa"
        case .devin: return "Dv"
        case .kiro: return "Kr"
        case .junie: return "Ju"
        case .kilo: return "Ko"
        case .replit: return "Rp"
        case .droid: return "Dr"
        case .commandCode: return "CC"
        case .antigravity: return "Ag"
        case .kimi: return "Km"
        }
    }

    private static func loadPNG(_ name: String) -> NSImage? {
        if let url = PulseResources.url(forResource: name, withExtension: "png", subdirectory: "AgentIcons"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("AgentIcons/\(name).png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }

    private static func loadSVG(_ name: String) -> NSImage? {
        if let url = PulseResources.url(forResource: name, withExtension: "svg", subdirectory: "AgentIcons"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("AgentIcons/\(name).svg"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }

    /// Brand files have very different transparent margins. Scaling every raw
    /// canvas to 16 pt made Pi look tiny, Grok oversized, and several marks sit
    /// visibly above or below their row. Normalize the *visible alpha bounds*
    /// onto one optical canvas while preserving the original artwork.
    static func opticallyNormalized(_ source: NSImage) -> NSImage {
        guard let raster = rasterize(source),
              let bounds = alphaBounds(in: raster)
        else {
            source.isTemplate = true
            source.size = NSSize(width: 16, height: 16)
            return source
        }

        let scale = opticalSize / max(bounds.width, bounds.height)
        let targetSize = NSSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        let target = NSRect(
            x: (CGFloat(rasterSize) - targetSize.width) / 2,
            y: (CGFloat(rasterSize) - targetSize.height) / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        guard let output = bitmap() else { return source }
        // `NSBitmapImageRep.colorAt` and `NSImage.draw(from:)` disagree about
        // the vertical origin. Convert the measured top-origin pixel bounds
        // into AppKit's bottom-origin source rect before drawing; without this
        // Pi, Amazon Q, Junie and Droid were cropped and shifted.
        let drawingBounds = NSRect(
            x: bounds.minX,
            y: CGFloat(rasterSize) - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
        let context = NSGraphicsContext(bitmapImageRep: output)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: rasterSize, height: rasterSize).fill()

        let rasterImage = NSImage(size: NSSize(width: rasterSize, height: rasterSize))
        rasterImage.addRepresentation(raster)
        rasterImage.draw(
            in: target,
            from: drawingBounds,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        NSGraphicsContext.restoreGraphicsState()

        let normalized = NSImage(size: NSSize(width: 16, height: 16))
        normalized.addRepresentation(output)
        normalized.isTemplate = true
        return normalized
    }

    /// Pixel bounds of visible artwork, used by normalization and its
    /// all-agent alignment contract.
    static func alphaBounds(in image: NSImage) -> NSRect? {
        guard let raster = rasterize(image) else { return nil }
        return alphaBounds(in: raster)
    }

    private static func rasterize(_ image: NSImage) -> NSBitmapImageRep? {
        guard let output = bitmap() else { return nil }
        let context = NSGraphicsContext(bitmapImageRep: output)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: rasterSize, height: rasterSize).fill()
        image.draw(
            in: NSRect(x: 0, y: 0, width: rasterSize, height: rasterSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        NSGraphicsContext.restoreGraphicsState()
        return output
    }

    private static func bitmap() -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: rasterSize,
            pixelsHigh: rasterSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    }

    private static func alphaBounds(in raster: NSBitmapImageRep) -> NSRect? {
        var minX = raster.pixelsWide
        var minY = raster.pixelsHigh
        var maxX = -1
        var maxY = -1
        for y in 0..<raster.pixelsHigh {
            for x in 0..<raster.pixelsWide
                where (raster.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return NSRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }

    private static func monogram(for id: AgentID) -> NSImage {
        let letter = monogramLetter(for: id)
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor.labelColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: letter.count > 1 ? 7 : 9, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ]
        let s = letter as NSString
        let t = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: (size.width - t.width) / 2, y: (size.height - t.height) / 2 - 0.5), withAttributes: attrs)
        img.unlockFocus()
        img.isTemplate = true
        return img
    }
}

struct AgentIconView: View {
    let id: AgentID

    var body: some View {
        Image(nsImage: AgentIcon.image(for: id))
            .resizable()
            .renderingMode(.template)
            .frame(width: 16, height: 16)
            .frame(width: 18, height: 18)
            .accessibilityLabel(id.displayName)
    }
}
