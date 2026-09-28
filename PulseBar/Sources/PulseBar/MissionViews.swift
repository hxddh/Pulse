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

    var body: some View {
        MissionBoardView(
            board: store.missionBoard(mission, currentCandidateID: currentCandidateID),
            edit: { editing = true },
            send: { store.handle($0, mission: mission) }
        )
        .sheet(isPresented: $editing) {
            MissionEditSheet(store: store, mission: mission)
        }
    }
}

/// 15.0 · renders a `MissionBoard` and nothing else — no store, so a fixture
/// can render every state of it (`SurfaceCapture`).
struct MissionBoardView: View {
    let board: MissionBoard
    var edit: () -> Void = {}
    var send: (MissionIntent) -> Void = { _ in }

    private func t(_ key: L10n.Key) -> String { L10n.t(key, board.lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(board.goal)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
            if !board.constraints.isEmpty {
                Text(board.constraints)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if let note = board.legacyNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = board.noChecksWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            comparison
            actions
            Text(t(.missionNoRanking))
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
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(t(.missionHeading))
                .font(.headline)
            Text(board.lifecycle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(board.revision)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button(t(.missionEdit), action: edit)
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var comparison: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(board.columns) { column in
                        columnHeader(column)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                factRow(t(.missionRowSession)) { $0.session }
                ForEach(Array(board.checks.enumerated()), id: \.offset) { index, command in
                    GridRow {
                        Text(command)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .frame(maxWidth: 220, alignment: .leading)
                            .help(command)
                        ForEach(board.columns) { column in
                            CheckCellView(cell: column.cells[index])
                        }
                    }
                }
                factRow(t(.missionRowChanges)) { $0.changes }
                factRow(t(.missionRowAnswer)) { $0.answer }
                factRow(t(.missionRowProblems)) { $0.problems }
            }
            .padding(.vertical, 4)
        }
    }

    private func factRow(_ label: String, _ value: @escaping (MissionBoard.Column) -> String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(board.columns) { column in
                Text(value(column))
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: 220, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func columnHeader(_ column: MissionBoard.Column) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(column.title)
                    .font(.callout.weight(column.isCurrent ? .bold : .regular))
                if column.chosen {
                    Text(t(.missionChosen))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !column.externalNote.isEmpty {
                Text(column.externalNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !column.revisionNote.isEmpty {
                Text(column.revisionNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                if let key = column.selectionKey {
                    Button(t(.managedViewAttempt)) { send(.select(key: key)) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Button(t(column.chosen ? .missionUnchoose : .missionChoose)) {
                    send(.choose(candidateID: column.id))
                }
                .buttonStyle(.link)
                .font(.caption)
                if let externalID = column.externalID {
                    Button(t(.proofLeaveMission)) { send(.leave(externalID: externalID)) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(t(.missionRunChecks)) { send(.runChecks) }
                .buttonStyle(.bordered)
                .disabled(!board.canRunChecks)
            if board.busy {
                ProgressView().controlSize(.small)
                Button(t(.missionStopChecks)) { send(.stopChecks) }
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// One check result. A pass is not coloured as a win: only a warning
/// (failed, stale, unconfirmed) stands out.
struct CheckCellView: View {
    let cell: CheckCell
    var maxWidth: CGFloat = 220

    var body: some View {
        Text(cell.text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(cell.tone == .warn ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .frame(maxWidth: maxWidth, alignment: .leading)
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
