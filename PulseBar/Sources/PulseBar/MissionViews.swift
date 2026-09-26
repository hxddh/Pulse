import SwiftUI

/// 13.0 · the Mission a managed session belongs to, and its Candidates side
/// by side (docs/plan-outcome.md β/γ).
///
/// Columns are Candidates in dispatch order — the only order shown; rows are
/// the facts that can change a choice: session state, every acceptance check
/// of the contract, what landed on disk, the final answer, errors and
/// unknown events. There is no score, no badge, no "best": "your choice" is
/// the user's own mark and writes nothing to git.
@MainActor
struct MissionCard: View {
    @ObservedObject var store: StatusStore
    let mission: Mission.Model
    /// The Candidate whose inspector this card sits in.
    let currentCandidateID: String

    @State private var editing = false

    private var candidates: [ManagedSessionRunner] { store.managedCandidates(of: mission) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(mission.contract.goal)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
            if !mission.contract.constraints.isEmpty {
                Text(mission.contract.constraints)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if mission.legacy {
                Text(store.tr(.missionLegacyNote))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if mission.contract.checks.isEmpty {
                Text(store.tr(.missionNoChecks))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            comparison
            actions
            Text(store.tr(.missionNoRanking))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PulseTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: PulseTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PulseTheme.cardRadius)
                .strokeBorder(.quaternary, lineWidth: PulseTheme.hairline)
        )
        .sheet(isPresented: $editing) {
            MissionEditSheet(store: store, mission: mission)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(store.tr(.missionHeading))
                .font(.headline)
            Text(lifecycleLabel(store.managedMissionLifecycle(mission)))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: store.tr(.missionRevision), mission.contract.revision))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button(store.tr(.missionEdit)) { editing = true }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var comparison: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(Array(candidates.enumerated()), id: \.element.model.id) { index, runner in
                        candidateHeader(runner, ordinal: index + 1)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                factRow(store.tr(.missionRowSession)) { runner in
                    sessionFact(runner.model)
                }
                ForEach(mission.contract.checks, id: \.id) { check in
                    GridRow {
                        Text(check.command)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .frame(maxWidth: 220, alignment: .leading)
                            .help(check.command)
                        ForEach(candidates, id: \.model.id) { runner in
                            checkCell(check, runner)
                        }
                    }
                }
                factRow(store.tr(.missionRowChanges)) { runner in
                    if let effect = runner.model.lastTurnEffect {
                        return "+\(effect.insertions) −\(effect.deletions)"
                    }
                    return "—"
                }
                factRow(store.tr(.missionRowAnswer)) { runner in
                    runner.model.lastResultText.isEmpty ? "—" : runner.model.lastResultText
                }
                factRow(store.tr(.missionRowProblems)) { runner in
                    "\(runner.model.errorResults) · \(runner.model.unknownEvents)"
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func factRow(_ label: String, _ value: @escaping (ManagedSessionRunner) -> String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(candidates, id: \.model.id) { runner in
                Text(value(runner))
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: 220, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func candidateHeader(_ runner: ManagedSessionRunner, ordinal: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(String(format: store.tr(.missionCandidate), ordinal))
                    .font(.callout.weight(runner.model.id == currentCandidateID ? .bold : .regular))
                if mission.chosenCandidateID == runner.model.id {
                    Text(store.tr(.missionChosen))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if runner.model.contractRevision != mission.contract.revision, runner.model.contractRevision > 0 {
                Text(String(format: store.tr(.missionOlderRevision), runner.model.contractRevision))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                if runner.model.id != currentCandidateID {
                    Button(store.tr(.managedViewAttempt)) {
                        store.workbenchSelectKey = "managed|" + runner.model.id
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Button(store.tr(mission.chosenCandidateID == runner.model.id ? .missionUnchoose : .missionChoose)) {
                    store.managedChoose(mission, candidateID: runner.model.id)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private func sessionFact(_ model: ManagedSession.Model) -> String {
        var parts = [model.runtimeID]
        if !model.modelName.isEmpty { parts.append(model.modelName) }
        parts.append(statusLabel(model.status))
        return parts.joined(separator: " · ")
    }

    private func checkCell(_ check: Mission.Check, _ runner: ManagedSessionRunner) -> some View {
        let standing = Mission.standing(of: check, candidate: runner.model, mission: mission) {
            runner.acceptance.standing(of: $0)
        }
        let (text, warn) = checkLabel(standing)
        return Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(warn ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .frame(maxWidth: 220, alignment: .leading)
    }

    /// The same honesty rules as the run-check card: only a current pass on
    /// unchanged code reads as passed.
    private func checkLabel(_ standing: Mission.CheckStanding) -> (String, Bool) {
        switch standing {
        case .notInContract: return (store.tr(.missionCheckNotInContract), false)
        case .notRun: return (store.tr(.missionCheckNotRun), false)
        case .running: return (store.tr(.missionCheckRunning), false)
        case .evidence(let judged, let evidence):
            switch judged {
            case .passing: return (store.tr(.missionCheckPassed), false)
            case .stale: return (store.tr(.managedRunCheckStale), true)
            case .measuring: return (store.tr(.managedRunCheckMeasuring), false)
            case .unverified: return (store.tr(.managedRunCheckUnverified), true)
            case .notPassing:
                switch evidence.outcome {
                case .timedOut: return (store.tr(.managedRunCheckTimeout), true)
                case .couldNotRun: return (store.tr(.managedRunCheckUnverified), true)
                case .invalidatedDuringRun: return (store.tr(.managedRunCheckChanged), true)
                case .interrupted: return (store.tr(.managedRunCheckInterrupted), true)
                case .passed, .failed:
                    return (String(format: store.tr(.missionCheckFailed), Int(evidence.exitCode ?? -1)), true)
                }
            }
        }
    }

    private var actions: some View {
        let busy = candidates.contains(where: \.isRunningChecks)
        let turnRunning = candidates.contains(where: \.isRunning)
        return HStack(spacing: 10) {
            Button(store.tr(.missionRunChecks)) {
                store.managedRunMissionChecks(mission)
            }
            .buttonStyle(.bordered)
            .disabled(mission.contract.checks.isEmpty || busy || turnRunning || candidates.isEmpty)
            if busy {
                ProgressView().controlSize(.small)
                Button(store.tr(.missionStopChecks)) {
                    store.managedCancelMissionChecks(mission)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func lifecycleLabel(_ lifecycle: Mission.Lifecycle) -> String {
        switch lifecycle {
        case .draft: return store.tr(.missionLifecycleDraft)
        case .running: return store.tr(.missionLifecycleRunning)
        case .ready: return store.tr(.missionLifecycleReady)
        case .archived: return store.tr(.missionLifecycleArchived)
        }
    }

    private func statusLabel(_ status: ManagedSession.Status) -> String {
        switch status {
        case .idle: return store.tr(.managedIdle)
        case .running: return store.tr(.managedRunning)
        case .queued: return store.tr(.managedQueuedNote)
        case .interrupted: return store.tr(.managedInterrupted)
        case .cancelled: return store.tr(.managedCancelled)
        case .failed(let reason): return String(format: store.tr(.managedFailed), reason)
        }
    }
}

/// The user's edit of the contract. Once a Candidate has started, saving
/// makes a new revision; the earlier Candidates keep theirs.
@MainActor
struct MissionEditSheet: View {
    @ObservedObject var store: StatusStore
    let mission: Mission.Model
    @Environment(\.dismiss) private var dismiss

    @State private var goal = ""
    @State private var constraints = ""
    @State private var checksText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.tr(.missionEdit))
                .font(.headline)
            Text(store.tr(.missionGoal))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(store.tr(.missionGoal), text: $goal, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
            TextField(store.tr(.missionConstraints), text: $constraints, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            TextField(store.tr(.missionChecks), text: $checksText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .lineLimit(2...8)
            Text(store.tr(.missionEditFrozenHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(store.tr(.cancel)) { dismiss() }
                Button(store.tr(.missionSave)) {
                    store.managedReviseMission(
                        mission, goal: goal, constraints: constraints, checksText: checksText
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            goal = mission.contract.goal
            constraints = mission.contract.constraints
            checksText = mission.contract.checks.map(\.command).joined(separator: "\n")
        }
    }
}
