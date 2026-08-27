import SwiftUI

/// 11.0-β (scene BW) — one visual system for the whole product.
///
/// The tray earned a type scale and a card discipline in 9.0/10.0; every
/// other window still carried its own hand-written numbers, so the product
/// read as one ironed shirt-front on an unironed shirt. `PulseTheme` owns
/// what every window shares — the card chrome, the spacing rhythm, the one
/// motion curve — and window code names a role here instead of liking a
/// number. `TrayChrome` keeps the tray's compact layout grid and derives
/// from the same rhythm. Colours stay out of `static let` everywhere; the
/// appearance gate's rule is about colour, and these are metrics.
enum PulseTheme {
    /// Window-surface card chrome (the tray's compact family lives in
    /// `TrayChrome`: card 8 / inner 6 on the 4-pt grid; windows breathe one
    /// step wider on the same grid).
    static let cardRadius: CGFloat = 10
    static let innerRadius: CGFloat = 6
    static let cardPadding: CGFloat = 14
    static let innerPadding: CGFloat = 8
    static let cardSpacing: CGFloat = 8
    static let hairline: CGFloat = 1

    /// The one motion curve. Every fold, expand and reorder in the product
    /// moves with the same short ease — two curves in one product read as
    /// two products.
    static let motion: Animation = .easeOut(duration: 0.16)
}
