import Foundation

/// Per-Agent retry and circuit policy for the bounded native harvest.
///
/// The collector already enforces a hard time budget. The supervisor adds the
/// missing operational layer around it: a broken adapter is retried on its own
/// schedule, repeated failures open a short circuit, and a half-open probe
/// eventually gives recovery a chance without holding the other 30 adapters.
struct HarvestSupervisor: Equatable {
    struct AgentState: Equatable {
        var consecutiveFailures = 0
        var nextRetryAtMs: Int64 = 0
        var circuitOpenUntilMs: Int64 = 0
        var lastFailureAtMs: Int64 = 0
        var lastSuccessAtMs: Int64 = 0
        var lastError = ""

        var isCircuitOpen: Bool { circuitOpenUntilMs > 0 }
    }

    /// A scan plan is intentionally just a set. The native reader remains the
    /// source of truth for adapter ordering and emits health for every adapter
    /// it actually attempted.
    struct Plan: Equatable {
        var attempted: Set<AgentID>
        var deferred: Set<AgentID>
    }

    static let maxFailuresBeforeCircuit = 3
    static let retryDelaysMs: [Int64] = [1_000, 5_000, 20_000]
    static let circuitDurationMs: Int64 = 60_000
    static let permissionRetryMs: Int64 = 5 * 60_000

    private(set) var states: [AgentID: AgentState] = [:]

    mutating func plan(
        nowMs: Int64,
        agents: Set<AgentID> = ActivityHarvest.expectedCollectorIDs
    ) -> Plan {
        let publicAgents = agents.map(\.surfaceID).filter { $0 != .cursorAgent }
        var attempted = Set<AgentID>()
        var deferred = Set<AgentID>()
        for agent in publicAgents {
            let state = states[agent] ?? AgentState()
            if state.circuitOpenUntilMs > nowMs || state.nextRetryAtMs > nowMs {
                deferred.insert(agent)
            } else {
                attempted.insert(agent)
            }
        }

        // If every adapter is in a backoff window, probe the one that becomes
        // eligible first rather than freezing health forever behind a circuit.
        if attempted.isEmpty, let earliest = deferred.min(by: { retryDate(for: $0) < retryDate(for: $1) }) {
            attempted.insert(earliest)
            deferred.remove(earliest)
        }
        return Plan(attempted: attempted, deferred: deferred)
    }

    mutating func record(
        _ health: [ActivityHarvest.CollectorHealth],
        nowMs: Int64
    ) {
        for item in health {
            let agent = item.id.surfaceID
            guard agent != .cursorAgent else { continue }
            var state = states[agent] ?? AgentState()
            switch item.state {
            case .observed, .noRecentData, .noSessions, .sourceAbsent:
                state.consecutiveFailures = 0
                state.nextRetryAtMs = 0
                state.circuitOpenUntilMs = 0
                state.lastSuccessAtMs = nowMs
                state.lastError = ""
            case .permissionDenied:
                state.consecutiveFailures += 1
                state.lastFailureAtMs = nowMs
                state.lastError = item.errorKind.isEmpty ? item.state.rawValue : item.errorKind
                state.nextRetryAtMs = nowMs + Self.permissionRetryMs
                if state.consecutiveFailures >= Self.maxFailuresBeforeCircuit {
                    state.circuitOpenUntilMs = nowMs + Self.circuitDurationMs
                }
            case .failed, .schemaMismatch:
                state.consecutiveFailures += 1
                state.lastFailureAtMs = nowMs
                state.lastError = item.errorKind.isEmpty ? item.state.rawValue : item.errorKind
                let index = min(state.consecutiveFailures - 1, Self.retryDelaysMs.count - 1)
                state.nextRetryAtMs = nowMs + Self.retryDelaysMs[index]
                if state.consecutiveFailures >= Self.maxFailuresBeforeCircuit {
                    state.circuitOpenUntilMs = nowMs + Self.circuitDurationMs
                }
            case .unscanned:
                // A global budget cutoff is not an adapter failure. Leave the
                // existing retry state alone so one slow neighbor cannot make
                // an untouched adapter look broken.
                break
            }
            states[agent] = state
        }
    }

    func state(for agent: AgentID) -> AgentState {
        states[agent.surfaceID] ?? AgentState()
    }

    func summary(nowMs: Int64) -> String {
        let open = states.values.filter { $0.circuitOpenUntilMs > nowMs }.count
        let retrying = states.values.filter {
            $0.nextRetryAtMs > nowMs && $0.circuitOpenUntilMs <= nowMs
        }.count
        let deferred = AgentID.allCases
            .filter { agent in
                let state = states[agent.surfaceID] ?? AgentState()
                return state.circuitOpenUntilMs > nowMs || state.nextRetryAtMs > nowMs
            }
            .map(\.rawValue)
            .sorted()
        let deferredLabel = deferred.isEmpty ? "-" : deferred.joined(separator: ",")
        return "open=\(open) retrying=\(retrying) deferred=\(deferredLabel)"
    }

    /// Recent adapter failures for the safe support report — agent, error, age.
    /// Newest first; empty errors are omitted.
    func failureTimeline(nowMs: Int64, limit: Int = 8) -> [(agent: AgentID, error: String, atMs: Int64)] {
        AgentID.allCases
            .compactMap { agent -> (AgentID, String, Int64)? in
                let state = states[agent.surfaceID] ?? AgentState()
                guard state.lastFailureAtMs > 0, !state.lastError.isEmpty else { return nil }
                // Prefer the surface id (Cursor Agent folds into Cursor).
                let surface = agent.surfaceID
                guard surface == agent else { return nil }
                return (surface, state.lastError, state.lastFailureAtMs)
            }
            .sorted { $0.2 > $1.2 }
            .prefix(limit)
            .map { ($0.0, $0.1, $0.2) }
    }

    private func retryDate(for agent: AgentID) -> Int64 {
        let state = states[agent.surfaceID] ?? AgentState()
        return max(state.nextRetryAtMs, state.circuitOpenUntilMs)
    }
}
