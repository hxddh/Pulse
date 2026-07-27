import AppKit
import SwiftUI

enum AgentIcon {
    /// Template (monochrome) brand mark for menu / panel rows.
    static func image(for id: AgentID) -> NSImage {
        let name = assetName(for: id)
        if let img = loadPNG(name) ?? loadSVG(name) {
            img.isTemplate = true
            img.size = NSSize(width: 16, height: 16)
            return img
        }
        return monogram(for: id)
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
    var waiting: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: AgentIcon.image(for: id))
                .resizable()
                .renderingMode(.template)
                .frame(width: 16, height: 16)
            if waiting {
                Circle()
                    .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                    .background(Circle().fill(Color.orange))
                    .frame(width: 7, height: 7)
                    .offset(x: 3, y: 3)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel(id.displayName)
    }
}
