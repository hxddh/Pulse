import Foundation

// The timeline: what each heard line did (`Effect`), and consecutive steps
// of one speaker merged into one entry as they are heard. Presentation
// bookkeeping the reducer keeps beside the state; it never moves a state.
extension SessionBook {
    /// One heard line on the session's timeline; the oldest beyond
    /// `maxTimeline` goes.
    ///
    /// A step heard right after a step (or a run of them) of the same
    /// speaker joins it: one entry, "Edit ×4 · Bash ×2", at the newest
    /// line's clock and event. A single step keeps its own words, target
    /// and duration.
    static func hear(_ session: inout Session, _ heard: Heard) {
        if let last = session.timeline.last, last.sub == heard.sub,
           case .steps(var run) = last.effect, case .steps(let next) = heard.effect, next.count == 1,
           let tool = next.tools.first?.tool {
            run.add(tool, failed: next.failed > 0)
            let steps = Array((last.steps + heard.steps).suffix(maxStepsPerEntry))
            session.timeline[session.timeline.count - 1] = Heard(
                ms: max(last.ms, heard.ms), event: heard.event, effect: .steps(run), sub: heard.sub, steps: steps
            )
            return
        }
        session.timeline.append(heard)
        if session.timeline.count > maxTimeline { session.timeline.removeFirst(session.timeline.count - maxTimeline) }
    }

    /// How long a `tool` line's step ran (`took`), for its timeline entry;
    /// 0 for any other line.
    static func took(_ record: AttentionRecord) -> Int64 {
        record.kind == .tool ? max(0, record.tookMs) : 0
    }

    /// One applied line as its timeline entry: its effect, its speaker, its
    /// step's duration and category, and the facts it carried.
    static func heard(_ record: AttentionRecord, effect: Effect, sub: String) -> Heard {
        var steps: [Step] = []
        if case .steps = effect, let step = stepOf(record) { steps = [step] }
        return Heard(
            ms: record.ms, event: record.event, effect: effect, sub: sub, tookMs: took(record),
            category: record.category, meta: record.meta, steps: steps
        )
    }

    /// The files a line that is not a step named (`meta` `files`: a
    /// batch's diff) go in the turn's digest; a step's own went in with it
    /// (`progress`).
    static func digestFiles(_ record: AttentionRecord, into session: inout Session) {
        guard !record.meta.files.isEmpty, stepOf(record) == nil || record.kind != .tool else { return }
        session.digest.addFiles(record.meta.files)
    }

    /// What one applied line did, from the state before it (`prior`, after
    /// a held turn settled) and after it. Pure.
    static func effect(of record: AttentionRecord, prior: State, now session: Session) -> Effect {
        var wasBlocked = false
        if case .blocked = prior { wasBlocked = true }
        var isBlocked = false
        if case .blocked = session.state { isBlocked = true }
        let answered = wasBlocked && !isBlocked
        if !record.sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A subagent's own lifecycle moves nothing but its own ask.
            switch record.kind {
            case .start, .working, .turn, .failed, .idle, .stopped, .title, .end:
                return answered ? .answered : .subagent
            default:
                break
            }
        }
        switch record.kind {
        case .start:
            return .started
        case .working:
            return answered ? .answered : .prompt
        case .tool:
            if answered { return .answered }
            guard let step = stepOf(record) else { return .working }
            return .step(tool: step.tool, target: step.target, failed: step.failed)
        case .status:
            return .status
        case .permission, .question, .waiting:
            // Not raised: the echo of a dismissed block. A re-raise of the
            // open block inside its grace (`raise` merges it): said again.
            guard case .blocked = session.state else { return .again }
            if case .blocked(let was) = prior, was.kind == record.kind,
               abs(record.ms - was.sinceMs) < stopGraceMs {
                return .again
            }
            return .raised(record.kind)
        case .turn, .failed, .idle:
            if isBlocked, session.heldTurn != nil { return .held }
            if record.kind == .failed { return .failed }
            if record.kind == .idle, session.state == prior { return .atPrompt }
            if case .yourTurn = session.state { return .yourTurn }
            return .turnEnded
        case .done:
            return .resolved
        case .dismiss:
            return record.event == AttentionRecord.seenEvent ? .seen : .dismissed
        case .stopped:
            return .stopped
        case .title:
            return .named
        case .end:
            return .ended
        case .ignored:
            return .skipped(reason: record.message)
        }
    }
}
