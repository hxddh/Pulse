import AppKit
import SwiftUI

/// 15.0 · Witness — render every surface fixture to a PNG, then quit.
///
/// `PulseBar --capture-surfaces=<dir> [--language=zh|en] [--appearance=light|dark]`
///
/// Each fixture's real SwiftUI view is hosted in an offscreen borderless
/// window of this process and drawn with `cacheDisplay`, like the tray
/// captures: no Screen Recording, Accessibility or automation permission.
/// Besides one PNG per fixture it writes a contact sheet of all of them and
/// `manifest-<lang>-<appearance>.txt` (file and size per capture); a missing
/// PNG fails the CI step.
@MainActor
enum SurfaceCapture {
    static let flag = "--capture-surfaces="

    static func requestedDirectory(_ arguments: [String]) -> URL? {
        guard let raw = arguments.first(where: { $0.hasPrefix(flag) }) else { return nil }
        return URL(fileURLWithPath: String(raw.dropFirst(flag.count)), isDirectory: true)
    }

    static func run(to directory: URL, lang: ResolvedLanguage, dark: Bool) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let suffix = "\(lang == .zh ? "zh" : "en")-\(dark ? "dark" : "light")"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [(name: String, image: NSImage)] = []
        var lines: [String] = []
        for fixture in SurfaceFixtures.all(lang: lang) {
            let url = directory.appendingPathComponent("\(fixture.name)-\(suffix).png")
            if let image = render(view(for: fixture), width: fixture.width, appearance: appearance),
               write(image, to: url) {
                written.append((fixture.name, image))
                // Sizes go to the CI log: a card that doubled in height
                // between two runs is visible without opening the PNG.
                lines.append("\(url.lastPathComponent) \(Int(image.size.width))x\(Int(image.size.height))")
            } else {
                lines.append("MISSING \(url.lastPathComponent)")
            }
        }
        let sheetURL = directory.appendingPathComponent("contact-sheet-\(suffix).png")
        if let sheet = contactSheet(written, appearance: appearance) {
            _ = write(sheet, to: sheetURL)
        }
        try? (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("manifest-\(suffix).txt"), atomically: true, encoding: .utf8
        )
        DebugLog.write("surface capture wrote \(written.count) of \(lines.count) → \(directory.path)")
    }

    static func view(for fixture: SurfaceFixtures.Fixture) -> AnyView {
        switch fixture.value {
        case .row(let model, let hovering):
            return AnyView(TrayRowFace(model: model, hovering: hovering))
        case .header(let model):
            return AnyView(TrayHeaderFace(model: model))
        case .notice(let model):
            return AnyView(TrayNoticeFace(model: model))
        case .filter(let query, let matches, let lang):
            return AnyView(TrayFilterField(query: query, matches: matches, lang: lang))
        case .timeline(let model, let lang):
            return AnyView(TimelineStripView(model: model, lang: lang))
        case .detail(let model):
            return AnyView(SessionDetailFace(model: model, scrolls: false))
        case .settings(let model):
            return AnyView(SettingsFace(model: model).frame(height: 900))
        case .diagnostics(let model):
            return AnyView(DiagnosticsFace(model: model, tab: .constant(.overview), activityAgent: .constant(nil)).frame(height: 900))
        case .doctor(let report):
            return AnyView(DoctorReportView(report: report))
        }
    }

    /// Lay the view out at `width` in an offscreen window and draw it.
    static func render(_ content: AnyView, width: Double, appearance: NSAppearance?) -> NSImage? {
        let framed = AnyView(
            content
                .frame(width: width)
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        let host = NSHostingView(rootView: framed)
        host.appearance = appearance
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI and AppKit controls settle one run-loop turn.
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        host.displayIfNeeded()
        defer { window.orderOut(nil) }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    /// Every fixture stacked with its name above it.
    static func contactSheet(_ images: [(name: String, image: NSImage)], appearance: NSAppearance?) -> NSImage? {
        guard !images.isEmpty else { return nil }
        let sheet = VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Image(nsImage: item.image)
                }
            }
        }
        let width = images.map(\.image.size.width).max() ?? 600
        return render(AnyView(sheet), width: width, appearance: appearance)
    }

    @discardableResult
    static func write(_ image: NSImage, to url: URL) -> Bool {
        guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let data = bitmap.representation(using: .png, properties: [:])
        else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            DebugLog.write("surface capture failed \(url.lastPathComponent) \(error.localizedDescription)")
            return false
        }
    }
}
