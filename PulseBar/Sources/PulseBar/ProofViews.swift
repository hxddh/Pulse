import SwiftUI

/// 14.0 · acceptance for a working copy Pulse did not create.
///
/// Any observed session with a known working copy — the user's own Claude
/// Code, Codex, Cursor — can be held to the user's ruler: checks written
/// here are this directory's, run here on the user's click, and judged on
/// the code as it is now. The agent working in the directory never sees
/// them. The same working copy can join a Mission as an external Candidate,
/// side by side with the ones Pulse launched.
@MainActor
struct WorkingCopyProofCard: View {
    @ObservedObject var store: StatusStore
    let row: AgentRow

    @State private var checksText = ""
    @State private var loaded = false

    private var checks: [Mission.Check] { store.workingCopyChecks(row) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.tr(.proofCard))
                .font(.headline)
            Text(store.tr(.proofHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(store.tr(.missionChecks), text: $checksText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .lineLimit(2...6)
            HStack(spacing: 10) {
                Button(store.tr(.proofSaveChecks)) {
                    store.setWorkingCopyChecks(row, text: checksText)
                }
                .buttonStyle(.bordered)
                .disabled(checksText == checks.map(\.command).joined(separator: "\n"))
                Button(store.tr(.proofRunChecks)) {
                    store.runWorkingCopyChecks(row)
                }
                .buttonStyle(.bordered)
                .disabled(checks.isEmpty || store.workingCopyBusy(row))
                if store.workingCopyBusy(row) {
                    ProgressView().controlSize(.small)
                    Button(store.tr(.missionStopChecks)) {
                        store.cancelWorkingCopyChecks(row)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if !checks.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(checks, id: \.id) { check in
                        GridRow {
                            Text(check.command)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .frame(maxWidth: 280, alignment: .leading)
                                .help(check.command)
                            let label = CheckLabels.label(store.workingCopyStanding(check, row), store: store)
                            Text(label.0)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(label.1 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        }
                    }
                }
                Text(store.tr(.proofSideEffects))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            missionJoin
        }
        .padding(PulseTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: PulseTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PulseTheme.cardRadius)
                .strokeBorder(.quaternary, lineWidth: PulseTheme.hairline)
        )
        .onAppear {
            guard !loaded else { return }
            loaded = true
            checksText = checks.map(\.command).joined(separator: "\n")
            store.refreshWorkingCopy(row)
        }
    }

    @ViewBuilder
    private var missionJoin: some View {
        if let joined = store.joinedMission(row) {
            HStack(spacing: 8) {
                Text(String(format: store.tr(.proofJoined), joined.title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let external = joined.externals.first(where: { $0.root == store.proofRoot(row) }) {
                    Button(store.tr(.proofLeaveMission)) {
                        store.leaveMission(joined, externalID: external.id)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        } else if !store.missionsForJoining.isEmpty {
            Menu(store.tr(.proofJoinMission)) {
                ForEach(store.missionsForJoining, id: \.id) { mission in
                    Button(mission.title) {
                        store.joinMission(mission, row: row)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
        }
    }
}
