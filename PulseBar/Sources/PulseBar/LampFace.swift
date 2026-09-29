import Foundation

/// 23.0 · one lamp vocabulary for the row, the detail page and the menu bar.
///
/// The shape says what the session needs; the tone says how it is going.
///
/// | shape  | means                              |
/// | ------ | ---------------------------------- |
/// | filled | needs you (blocked)                |
/// | ring   | running (a circle with a dot)      |
/// | hollow | your turn, recent, idle            |
/// | dotted | seen only as a process             |
///
/// Tones: red is blocked, green is running, orange is **only** a stall or an
/// error, grey is everything else. A process-only session is grey dotted —
/// a process is not a session, so it is never orange and never green.
/// Shape plus tone, so the state reads without colour too. Pure.
struct LampFace: Equatable {
    enum Shape: String, Equatable {
        case filled, ring, hollow, dotted
    }

    var shape: Shape
    var tone: PulseTheme.Tone

    static var idle: LampFace { LampFace(shape: .hollow, tone: .idle) }

    /// The lamp beside one row.
    static func row(_ row: AgentRow) -> LampFace {
        switch row.state {
        case .blocked:
            return LampFace(shape: .filled, tone: .waiting)
        case .processOnly:
            return LampFace(shape: .dotted, tone: .idle)
        case .running:
            return LampFace(shape: .ring, tone: row.isStalled || row.errors > 0 ? .attention : .running)
        case .yourTurn, .recent:
            return LampFace(shape: .hollow, tone: row.errors > 0 ? .attention : .idle)
        }
    }

    /// The menu-bar lamp. `processOnly` draws the dotted glyph for a grey
    /// lamp whose only live evidence is processes.
    static func glance(_ glance: GlanceKind, processOnly: Bool = false) -> LampFace {
        switch glance {
        case .waiting: return LampFace(shape: .filled, tone: .waiting)
        case .running: return LampFace(shape: .ring, tone: .running)
        case .stalled: return LampFace(shape: .ring, tone: .attention)
        case .idle: return LampFace(shape: processOnly ? .dotted : .hollow, tone: .idle)
        }
    }
}
