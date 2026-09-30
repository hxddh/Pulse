import AppKit
import SwiftUI

/// The product's one visual system: type sizes, fills, radii, motion and
/// state colours, named once. Everything a view needs to look like Pulse is
/// named here, so no call site writes its own radius, point size or red.
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
        static let xl: CGFloat = 24
    }

    // MARK: Radii — three, nested inside each other

    enum Radius {
        /// Inner blocks, fields inside a card.
        static let inner: CGFloat = 6
        /// The selected row's fill and every card.
        static let card: CGFloat = 10
        /// The tray panel and floating surfaces.
        static let panel: CGFloat = 14
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
        /// A panel or window title.
        static let title: SwiftUI.Font = .system(.title3, design: .rounded).weight(.semibold)
        /// A section or card heading.
        static let heading: SwiftUI.Font = .system(.subheadline, design: .rounded).weight(.semibold)
        /// The line a glance lands on: a row's task, a card's subject.
        static let hero: SwiftUI.Font = .system(.body, design: .rounded).weight(.semibold)
        static let heroQuiet: SwiftUI.Font = .system(.body, design: .rounded)
        /// Sentences and facts.
        static let body: SwiftUI.Font = .system(.subheadline)
        static let bodyEmphasis: SwiftUI.Font = .system(.subheadline).weight(.medium)
        /// Names beside a lamp.
        static let label: SwiftUI.Font = .system(.subheadline, design: .rounded).weight(.semibold)
        /// Times, sources, footnotes.
        static let caption: SwiftUI.Font = .system(.caption)
        /// Machine text: commands, paths, an agent's error in its own words.
        static let code: SwiftUI.Font = .system(.caption, design: .monospaced)
    }

    // MARK: Chrome

    static let innerPadding: CGFloat = Space.s

    // MARK: Motion

    /// The one motion curve. Every fold, expand and reorder moves with the
    /// same short ease — two curves in one product read as two products.
    static let motion: Animation = .easeOut(duration: 0.16)

    /// `motion`, or none at all when the person asked for less movement.
    static func motion(reduced: Bool) -> Animation? {
        reduced ? nil : motion
    }

    // MARK: State colours — one per state, everywhere

    /// The four things Pulse can say about an agent, plus neutral. The lamp,
    /// the row and the header count all read this.
    enum Tone: Equatable {
        /// Blocked on the person (red).
        case waiting
        /// Working (green).
        case running
        /// Stalled or failing (orange) — never a process-only session.
        case attention
        /// Nothing to say (grey).
        case idle

        var color: Color {
            switch self {
            case .waiting: return Color(nsColor: .systemRed)
            case .running: return Color(nsColor: .systemGreen)
            case .attention: return Color(nsColor: .systemOrange)
            case .idle: return Color.secondary
            }
        }
    }
}

extension GlanceKind {
    var tone: PulseTheme.Tone {
        switch self {
        case .waiting: return .waiting
        case .running: return .running
        case .stalled: return .attention
        case .idle: return .idle
        }
    }
}

// MARK: - Shared chrome

extension View {
    /// A block inside a card.
    func pulseInner(padding: CGFloat = PulseTheme.innerPadding) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(PulseTheme.Fill.subtle),
                in: RoundedRectangle(cornerRadius: PulseTheme.Radius.inner, style: .continuous)
            )
    }
}
