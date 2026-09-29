import Foundation

/// 22.0 · Lamp — what each session did over the last hours, as spans.
///
/// Pulse saw every running → needs-you → running → done edge and kept none
/// of them: "why did the lamp go red at 14:02, and for how long?" had no
/// answer once the moment passed. The timeline keeps those edges, bounded,
/// and stamps each one with the evidence's own clock where there is one
/// (the hook's raise time, the turn's time, the transcript's last change),
/// so an identical scan produces no transition and writes nothing.
///
/// Pure: `transitions` compares two row lists; `SessionLog` applies them
/// (23.0 — the spans live there beside the waits); `TimelineStripModel`
/// renders a window of them.

/// The state a session is in, as the lamp would colour it.
enum TimelineState: String, Codable, Equatable, Sendable {
    /// `thin` is a session seen only as a process (the raw value stays for
    /// logs written before 23.0).
    case running, thin, stalled, blocked, turn, recent

    /// The row lamp's tone for the state: orange only for a stall.
    var tone: PulseTheme.Tone {
        switch self {
        case .blocked: return .waiting
        case .running: return .running
        case .stalled: return .attention
        case .thin, .turn, .recent: return .idle
        }
    }
}

/// Which evidence put the session in that state.
enum TimelineEvidence: String, Codable, Equatable, Sendable {
    case hook, pending, vendor, harvest, process
}

struct TimelineSpan: Codable, Equatable, Sendable {
    var state: TimelineState
    var evidence: TimelineEvidence
    /// The wait kind for a blocked span (`Permission`, `Input`…), else "".
    var kind: String = ""
    var startMs: Int64
    /// Nil while the span is open.
    var endMs: Int64?
    /// False when no evidence clock existed and the scan time stood in.
    var exact: Bool = true
}

struct TimelineTransition: Equatable, Sendable {
    var rowKey: String
    /// Nil: the session left the list.
    var state: TimelineState?
    var evidence: TimelineEvidence
    var kind: String
    var atMs: Int64
    var exact: Bool
}

enum SessionTimeline {
    /// The row's state and its evidence — the same predicates the lamp uses,
    /// so the strip can never disagree with the colour.
    static func classify(_ row: AgentRow) -> (state: TimelineState, evidence: TimelineEvidence, kind: String) {
        let evidence: TimelineEvidence = row.isProcessOnly ? .process : .harvest
        switch row.state {
        case .blocked(let wait):
            switch wait.signal {
            case .hooks: return (.blocked, .hook, wait.kind)
            case .vendor: return (.blocked, .vendor, wait.kind)
            case .pending: return (.blocked, .pending, wait.kind)
            }
        case .yourTurn: return (.turn, .hook, "")
        case .processOnly: return (.thin, .process, "")
        case .recent: return (.recent, evidence, "")
        case .running:
            if row.isStalled { return (.stalled, evidence, "") }
            return (.running, evidence, "")
        }
    }

    /// Edges between two scans. A row whose state and evidence did not
    /// change produces nothing, so the same world twice is silent.
    static func transitions(
        previous: [AgentRow],
        current: [AgentRow],
        nowMs: Int64
    ) -> [TimelineTransition] {
        var before: [String: AgentRow] = [:]
        for row in previous { before[row.rowKey] = row }
        var out: [TimelineTransition] = []
        var seen = Set<String>()
        for row in current {
            seen.insert(row.rowKey)
            let now = classify(row)
            if let old = before[row.rowKey] {
                let was = classify(old)
                if was.state == now.state, was.evidence == now.evidence, was.kind == now.kind { continue }
            }
            let stamp = evidenceStamp(row, state: now.state, nowMs: nowMs)
            out.append(TimelineTransition(
                rowKey: row.rowKey, state: now.state, evidence: now.evidence,
                kind: now.kind, atMs: stamp.ms, exact: stamp.exact
            ))
        }
        for (key, old) in before where !seen.contains(key) {
            out.append(TimelineTransition(
                rowKey: key, state: nil, evidence: classify(old).evidence,
                kind: "", atMs: nowMs, exact: false
            ))
        }
        return out.sorted { ($0.atMs, $0.rowKey) < ($1.atMs, $1.rowKey) }
    }

    /// The evidence's own clock for the state, when it has one.
    static func evidenceStamp(_ row: AgentRow, state: TimelineState, nowMs: Int64) -> (ms: Int64, exact: Bool) {
        let candidate: Int64
        switch state {
        case .blocked: candidate = row.wait?.sinceMs ?? 0
        case .turn: candidate = row.turnSinceMs ?? 0
        case .running, .thin: candidate = row.activityMs
        case .stalled, .recent: candidate = 0
        }
        // A clock from the future, or one older than the log keeps, is not
        // evidence of when this edge happened.
        if candidate > 0, candidate <= nowMs, nowMs - candidate < SessionLog.retentionMs {
            return (candidate, true)
        }
        return (nowMs, false)
    }
}

/// A window of one session's spans as proportional segments.
struct TimelineStripModel: Equatable {
    struct Segment: Equatable {
        /// Nil: nothing known (before the first span, or after it left).
        var state: TimelineState?
        var fraction: Double
        var startMs: Int64
        var endMs: Int64
        var evidence: TimelineEvidence?
        var kind: String
    }

    var segments: [Segment]
    var windowMs: Int64

    static let defaultWindowMs: Int64 = 60 * 60 * 1000

    /// `nowMs` should be quantized to the minute by the caller so the strip
    /// does not redraw every second.
    static func make(spans: [TimelineSpan], nowMs: Int64, windowMs: Int64 = defaultWindowMs) -> TimelineStripModel {
        let start = nowMs - windowMs
        var segments: [Segment] = []
        var cursor = start
        func push(_ state: TimelineState?, _ from: Int64, _ to: Int64, _ evidence: TimelineEvidence?, _ kind: String) {
            let a = max(from, start)
            let b = min(to, nowMs)
            guard b > a else { return }
            if let last = segments.last, last.state == state, last.evidence == evidence, last.kind == kind, last.endMs == a {
                segments[segments.count - 1].endMs = b
            } else {
                segments.append(Segment(state: state, fraction: 0, startMs: a, endMs: b, evidence: evidence, kind: kind))
            }
        }
        for span in spans {
            let end = span.endMs ?? nowMs
            guard end > start else { continue }
            if span.startMs > cursor { push(nil, cursor, span.startMs, nil, "") }
            push(span.state, max(span.startMs, cursor), end, span.evidence, span.kind)
            cursor = max(cursor, end)
        }
        if cursor < nowMs { push(nil, cursor, nowMs, nil, "") }
        let total = Double(max(1, windowMs))
        for index in segments.indices {
            segments[index].fraction = Double(segments[index].endMs - segments[index].startMs) / total
        }
        return TimelineStripModel(segments: segments, windowMs: windowMs)
    }

    /// Minutes spent in each state inside the window — for VoiceOver and the
    /// detail pane, never a running total over days.
    var minutesByState: [(TimelineState, Int)] {
        var totals: [TimelineState: Int64] = [:]
        for segment in segments {
            guard let state = segment.state else { continue }
            totals[state, default: 0] += segment.endMs - segment.startMs
        }
        let order: [TimelineState] = [.blocked, .running, .thin, .stalled, .turn, .recent]
        return order.compactMap { state in
            guard let ms = totals[state], ms >= 60_000 else { return nil }
            return (state, Int(ms / 60_000))
        }
    }
}
