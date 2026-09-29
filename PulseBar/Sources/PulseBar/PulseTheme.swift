import AppKit
import SwiftUI

/// 21.0 Clarity — the product's one visual system.
///
/// 11.0 named card chrome and motion; the rest — type sizes, fills, radii,
/// state colours — kept being written by hand at each call site, and an audit
/// at 20.0 counted seven corner radii, a dozen point sizes and three different
/// reds. Everything a view needs to look like Pulse is named here, and
/// `scripts/surface_check.py` rejects a literal size, radius or opacity in a
/// view that has a token for it.
///
/// Colours are computed properties, never `static let`: a stored colour
/// freezes the appearance that was current on first touch (see
/// `scripts/appearance_check.py`). State colours are the system's dynamic
/// colours, so Increase Contrast and dark mode move them too.
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
        /// Inner blocks, chips' containers, fields inside a card.
        static let inner: CGFloat = 6
        /// Rows' hover/selection fill and every card.
        static let card: CGFloat = 10
        /// The tray panel and floating surfaces.
        static let panel: CGFloat = 14
    }

    // MARK: Fills — opacity of `.primary` over the material

    enum Fill {
        static let subtle: Double = 0.04
        static let hover: Double = 0.06
        static let selected: Double = 0.10
        /// A waiting row's own surface tint — the row's one red carrier.
        static let waitTint: Double = 0.07
        static let waitTintUrgent: Double = 0.11
        static let chip: Double = 0.14
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
        /// Chips.
        static let chip: SwiftUI.Font = .system(.caption, design: .rounded).weight(.semibold)
        /// Machine text: commands, paths, an agent's error in its own words.
        static let code: SwiftUI.Font = .system(.caption, design: .monospaced)
    }

    // MARK: Chrome

    static let hairline: CGFloat = 1
    static let cardPadding: CGFloat = Space.m
    static let innerPadding: CGFloat = Space.s
    static let cardSpacing: CGFloat = Space.s
    static let cardRadius: CGFloat = Radius.card
    static let innerRadius: CGFloat = Radius.inner

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
    /// the chip and the header count all read this.
    enum Tone: Equatable {
        /// Blocked on the person (red).
        case waiting
        /// Working (green).
        case running
        /// Stalled, failed, or seen only as a process (orange).
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
        case .stalled, .error: return .attention
        case .idle: return .idle
        }
    }
}

// MARK: - Shared chrome

extension View {
    /// A card: the one surface every in-list and window card shares.
    func pulseCard(padding: CGFloat = PulseTheme.cardPadding) -> some View {
        modifier(PulseCardChrome(padding: padding, radius: PulseTheme.Radius.card))
    }

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

private struct PulseCardChrome: ViewModifier {
    let padding: CGFloat
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(PulseTheme.Fill.subtle),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: PulseTheme.hairline)
            )
    }
}

/// One chip for the whole product: a state word in its tone.
struct PulseChip: View {
    let label: String
    var tone: PulseTheme.Tone = .idle

    var body: some View {
        Text(label)
            .font(PulseTheme.Font.chip)
            .monospacedDigit()
            .foregroundStyle(tone == .idle ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                (tone == .idle ? Color.primary : tone.color)
                    .opacity(tone == .idle ? PulseTheme.Fill.hover : PulseTheme.Fill.chip),
                in: Capsule(style: .continuous)
            )
            .lineLimit(1)
            .fixedSize()
    }
}
