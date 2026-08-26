import Foundation
import AppKit

/// 4.0-γ file split — Evidence formatting (2.1) — sentences for facts the digest produced.
/// Behavior-frozen: every member moved verbatim from StatusStore.swift;
/// the full test suite is the contract that nothing changed.
extension StatusStore {
    // MARK: - 2.1 Evidence · the rest of what the digest already knew
    //
    // EXPERIENCE puts *complete evidence* in Details, and caps a tray row at
    // four facts. 1.1 computed a session-wide picture and 1.2 spent three of
    // those slots' worth of it; the remainder belongs here, where a label and
    // a sentence can go next to each number. Everything below formats a fact
    // the digest already produced — none of it recomputes anything.

    /// `Read → Edit → Bash → Edit` — what it has been doing all along.
    func evidenceTimeline(_ row: AgentRow) -> String {
        AgentRow.toolTimeline(row.recentTools)
    }

    /// The token pair, carrying only the halves that were actually reported.
    ///
    /// `compactToken` returns "" for 0, and every call site used to turn that
    /// "" back into a literal `0` — so an agent that publishes output tokens
    /// and not input rendered `↑0 ↓4.2k`, stating that the turn consumed no
    /// input. Nothing measured that. Unknown is absent, the same rule the CPU
    /// fact has followed since 2.2, and when neither side was reported the
    /// fact disappears instead of printing a pair of zeros.
    func tokenPair(input rawIn: Int, output rawOut: Int, scope: TokenScope = .compact) -> String {
        let input = AgentRow.compactToken(rawIn)
        let output = AgentRow.compactToken(rawOut)
        if !input.isEmpty, !output.isEmpty {
            return String(format: tr(scope.both), input, output)
        }
        if !input.isEmpty { return String(format: tr(scope.inputOnly), input) }
        if !output.isEmpty { return String(format: tr(scope.outputOnly), output) }
        return ""
    }

    /// Whole-session token totals, kept visibly apart from the latest-message
    /// pair the facts grid shows under Resources. Two token numbers that
    /// disagree are a bug report waiting to happen unless each says its scope.
    func evidenceSessionTokens(_ row: AgentRow) -> String {
        tokenPair(input: row.sessionTokensIn, output: row.sessionTokensOut)
    }

    /// `12 KB/min`. Empty when unknown — never a fabricated zero, which would
    /// read as "parked" rather than "not measured".
    func evidenceRate(_ row: AgentRow) -> String {
        let size = AgentRow.compactBytes(row.bytesPerMinute)
        guard !size.isEmpty else { return "" }
        return String(format: tr(.evidenceRatePerMinute), size)
    }

    /// Real CPU share, or an em dash. **Never renders unknown as 0%**: the
    /// difference between "measured, and it is idle" and "no second sample
    /// yet" is the whole reason the probe reports -1.
    func evidenceCPU(_ row: AgentRow) -> String {
        guard row.hasCPUSample else { return "—" }
        return String(format: tr(.cpuFact), Int(row.cpuPercent.rounded()))
    }

    /// The sentence under compute: what it distinguishes, or why it is absent.
    func evidenceCPUNote(_ row: AgentRow) -> String {
        row.hasCPUSample ? tr(.evidenceCPUHint) : tr(.evidenceCPUUnknown)
    }

    /// Resident memory, or nil so the row disappears rather than showing 0.
    func evidenceMemory(_ row: AgentRow) -> String? {
        let size = AgentRow.compactBytes(row.rssBytes)
        return size.isEmpty ? nil : size
    }

    /// The sentence under the rate: what it is for, or that it is missing.
    func evidenceRateNote(_ row: AgentRow) -> String {
        row.bytesPerMinute > 0 ? tr(.evidenceRateHint) : tr(.evidenceRateUnknown)
    }

    /// How long this session has really been going. Empty when unknown, so the
    /// row disappears rather than showing an age nothing measured.
    func evidenceSessionLength(
        _ row: AgentRow,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> String {
        let seconds = row.sessionDurationSeconds(nowMs: nowMs)
        guard seconds >= 60 else { return "" }
        return durationLabel(seconds: seconds)
    }

    /// "Whole transcript read" vs "Still catching up · 78% read".
    ///
    /// This version lets qualitative digest facts reach the row before the
    /// read is complete, so the surface owes the reader the other half of that
    /// sentence: the counts beside it are not yet totals. Empty when there is
    /// no digest at all — a cache-only row has no transcript to be behind on.
    func evidenceReadState(_ row: AgentRow) -> String {
        guard row.hasSessionDigest else { return "" }
        if row.digestCaughtUp { return tr(.evidenceReadCaughtUp) }
        return String(
            format: tr(.evidenceReadCatchingUp),
            max(0, min(100, row.digestProgressPercent))
        )
    }

    /// True while the counts on the evidence card are still partial.
    func evidenceCountsArePartial(_ row: AgentRow) -> Bool {
        row.hasSessionDigest && !row.digestCaughtUp
    }

    /// `78% read` — the same caveat sized for a tray row.
    ///
    /// The Details wording carries its own `·`, which on a row would split into
    /// what looks like two separate facts. A separator inside a fact is a fact
    /// that lies about how many facts there are.
    func evidenceReadCompact(_ row: AgentRow) -> String {
        guard evidenceCountsArePartial(row) else { return "" }
        return String(
            format: tr(.evidenceReadCompact),
            max(0, min(100, row.digestProgressPercent))
        )
    }

    /// Anything worth drawing a card for.
    func hasSessionEvidence(_ row: AgentRow) -> Bool {
        !evidenceTimeline(row).isEmpty
            || !evidenceSessionTokens(row).isEmpty
            || row.bytesPerMinute > 0
            || !evidenceSessionLength(row).isEmpty
            || !evidenceReadState(row).isEmpty
    }
}
