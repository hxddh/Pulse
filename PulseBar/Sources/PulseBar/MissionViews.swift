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

    /// One column: a Candidate Pulse launched, or (14.0) a working copy the
    /// user joined from outside Pulse. Both are judged by the same ruler, in
    /// their own working copy.
    private struct Column: Identifiable {
        let id: String
        let runner: ManagedSessionRunner?
        let external: Mission.External?
        let root: String
        let revision: Int
    }

    private var candidates: [ManagedSessionRunner] { store.managedCandidates(of: mission) }

    /// Dispatch order, then join order — the only orders ever shown.
    private var columns: [Column] {
        candidates.map {
            Column(id: $0.model.id, runner: $0, external: nil, root: $0.model.root, revision: $0.model.contractRevision)
        } + mission.externals.map {
            Column(id: $0.id, runner: nil, external: $0, root: $0.root, revision: $0.revision)
        }
    }

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
        let columns = self.columns
        return ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                        columnHeader(column, ordinal: index + 1)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                factRow(store.tr(.missionRowSession), columns) { sessionFact($0) }
                ForEach(mission.contract.checks, id: \.id) { check in
                    GridRow {
                        Text(check.command)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .frame(maxWidth: 220, alignment: .leading)
                            .help(check.command)
                        ForEach(columns) { column in
                            checkCell(check, column)
                        }
                    }
                }
                factRow(store.tr(.missionRowChanges), columns) { changesFact($0) }
                factRow(store.tr(.missionRowAnswer), columns) { answerFact($0) }
                factRow(store.tr(.missionRowProblems), columns) { problemsFact($0) }
            }
            .padding(.vertical, 4)
        }
    }

    private func factRow(_ label: String, _ columns: [Column], _ value: @escaping (Column) -> String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(columns) { column in
                Text(value(column))
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: 220, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func columnHeader(_ column: Column, ordinal: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(String(format: store.tr(.missionCandidate), ordinal))
                    .font(.callout.weight(column.id == currentCandidateID ? .bold : .regular))
                if mission.chosenCandidateID == column.id {
                    Text(store.tr(.missionChosen))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let external = column.external {
                Text(String(format: store.tr(.missionExternal), external.label))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if column.revision != mission.contract.revision, column.revision > 0 {
                Text(String(format: store.tr(.missionOlderRevision), column.revision))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                if column.id != currentCandidateID, let key = selectionKey(column) {
                    Button(store.tr(.managedViewAttempt)) {
                        store.workbenchSelectKey = key
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Button(store.tr(mission.chosenCandidateID == column.id ? .missionUnchoose : .missionChoose)) {
                    store.managedChoose(mission, candidateID: column.id)
                }
                .buttonStyle(.link)
                .font(.caption)
                if let external = column.external {
                    Button(store.tr(.proofLeaveMission)) {
                        store.leaveMission(mission, externalID: external.id)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    private func selectionKey(_ column: Column) -> String? {
        if let runner = column.runner { return "managed|" + runner.model.id }
        return store.observedRow(forRoot: column.root)?.rowKey
    }

    private func sessionFact(_ column: Column) -> String {
        if let model = column.runner?.model {
            var parts = [model.runtimeID]
            if !model.modelName.isEmpty { parts.append(model.modelName) }
            parts.append(statusLabel(model.status))
            return parts.joined(separator: " · ")
        }
        guard let row = store.observedRow(forRoot: column.root) else {
            return store.tr(.missionExternalGone)
        }
        var parts = [row.agent.displayName]
        if !row.model.isEmpty { parts.append(row.model) }
        parts.append(row.waiting ? store.tr(.needsYou) : row.liveProcess ? store.tr(.managedRunning) : store.tr(.managedIdle))
        return parts.joined(separator: " · ")
    }

    private func changesFact(_ column: Column) -> String {
        if let runner = column.runner {
            if let effect = runner.model.lastTurnEffect { return "+\(effect.insertions) −\(effect.deletions)" }
            return "—"
        }
        guard let row = store.observedRow(forRoot: column.root), row.hasWorkspaceEffect,
              row.insertions >= 0, row.deletions >= 0 else { return "—" }
        return "+\(row.insertions) −\(row.deletions)"
    }

    private func answerFact(_ column: Column) -> String {
        if let runner = column.runner {
            return runner.model.lastResultText.isEmpty ? "—" : runner.model.lastResultText
        }
        let word = store.observedRow(forRoot: column.root)?.lastWord ?? ""
        return word.isEmpty ? "—" : word
    }

    private func problemsFact(_ column: Column) -> String {
        if let runner = column.runner {
            return "\(runner.model.errorResults) · \(runner.model.unknownEvents)"
        }
        guard let row = store.observedRow(forRoot: column.root) else { return "—" }
        return "\(row.errors) · —"
    }

    private func checkCell(_ check: Mission.Check, _ column: Column) -> some View {
        let book = store.evidenceBook
        let standing = Mission.standing(
            of: check,
            revision: column.revision,
            evidence: book.evidence(for: column.root),
            running: book.runningCheck(for: column.root),
            mission: mission
        ) { book.standing(of: $0, at: column.root) }
        let (text, warn) = checkLabel(standing)
        return Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(warn ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .frame(maxWidth: 220, alignment: .leading)
    }

    /// The same honesty rules as the run-check card: only a current pass on
    /// unchanged code reads as passed.
    private func checkLabel(_ standing: Mission.CheckStanding) -> (String, Bool) {
        CheckLabels.label(standing, store: store)
    }

    private var actions: some View {
        let columns = self.columns
        let busy = columns.contains { store.evidenceBook.isBusy(at: $0.root) }
        let turnRunning = candidates.contains(where: \.isRunning)
        return HStack(spacing: 10) {
            Button(store.tr(.missionRunChecks)) {
                store.managedRunMissionChecks(mission)
            }
            .buttonStyle(.bordered)
            .disabled(mission.contract.checks.isEmpty || busy || turnRunning || columns.isEmpty)
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

/// One wording for a check cell, shared by the Mission card and the working
/// copy card. Only a current pass on unchanged code reads as passed.
@MainActor
enum CheckLabels {
    static func label(_ standing: Mission.CheckStanding, store: StatusStore) -> (String, Bool) {
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
