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

    var body: some View {
        ProofCardView(model: store.proofCard(row)) { store.handle($0, row: row) }
            // A different row is a different directory: start its editor over.
            .id(store.proofRoot(row))
    }
}

/// 15.0 · renders a `ProofCardModel` and nothing else (`SurfaceCapture`).
struct ProofCardView: View {
    let model: ProofCardModel
    var send: (ProofIntent) -> Void = { _ in }

    @State private var checksText = ""
    @State private var loaded = false

    private func t(_ key: L10n.Key) -> String { L10n.t(key, model.lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t(.proofCard))
                .font(.headline)
            Text(t(.proofHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(t(.missionChecks), text: $checksText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .lineLimit(2...6)
            HStack(spacing: 10) {
                Button(t(.proofSaveChecks)) { send(.save(text: checksText)) }
                    .buttonStyle(.bordered)
                    .disabled(checksText == model.savedChecksText)
                Button(t(.proofRunChecks)) { send(.run) }
                    .buttonStyle(.bordered)
                    .disabled(!model.canRun)
                if model.busy {
                    ProgressView().controlSize(.small)
                    Button(t(.missionStopChecks)) { send(.stop) }
                        .buttonStyle(.bordered)
                }
            }
            if !model.lines.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(model.lines) { line in
                        GridRow {
                            Text(line.command)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .frame(maxWidth: 280, alignment: .leading)
                                .help(line.command)
                            CheckCellView(cell: line.cell)
                        }
                    }
                }
                Text(t(.proofSideEffects))
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
            checksText = model.savedChecksText
            send(.refresh)
        }
    }

    @ViewBuilder
    private var missionJoin: some View {
        if let joined = model.joined {
            HStack(spacing: 8) {
                Text(String(format: t(.proofJoined), joined.title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let externalID = joined.externalID {
                    Button(t(.proofLeaveMission)) {
                        send(.leave(missionID: joined.missionID, externalID: externalID))
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        } else if !model.joinable.isEmpty {
            Menu(t(.proofJoinMission)) {
                ForEach(model.joinable) { choice in
                    Button(choice.title) { send(.join(missionID: choice.id)) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
        }
    }
}
