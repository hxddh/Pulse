// 5.0-β Managed sessions — the conversation, live (scene BG).
//
// A managed row's inspector is not a reconstruction: the entries below came
// off the process's own stream. The reply box is a real turn; cancel is a
// real signal; the diff card measures a worktree Pulse created. This is what
// the market's top products have that observation alone never could — and
// the observed fleet keeps every 4.0 surface unchanged.

import SwiftUI

@MainActor
struct ManagedSessionInspector: View {
    @ObservedObject var store: StatusStore
    let row: AgentRow

    @State private var reply = ""
    @State private var commitMessage = ""
    @State private var acceptanceBusy = false
    @State private var acceptanceNotice = ""
    @State private var acceptanceNoticeIsError = false
    @State private var compareURL: URL?

    private var runner: ManagedSessionRunner? { store.managedRunner(for: row) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                conversationCard
                if let model = runner?.model {
                    statusCard(model)
                }
                effectCard
                if runner?.isRunning != true,
                   ManagedWorktree.isPulseWorktree(row.workspaceRoot) {
                    acceptanceCard
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 5.0-γ (scene BH): acceptance, on the user's click, inside Pulse's own
    /// namespace only — the diff sits one card above, the message is the
    /// user's words, and every outcome lands here in a sentence.
    private var acceptanceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.tr(.managedAcceptance))
                .font(.headline)
            Text(store.tr(.managedAcceptanceHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(store.tr(.managedCommitPlaceholder), text: $commitMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            HStack(spacing: 10) {
                Button(store.tr(.managedCommit)) {
                    let message = commitMessage
                    runAcceptance { worktree in
                        if let error = ManagedAcceptance.commit(worktree: worktree, message: message) {
                            return .failure(error)
                        }
                        return .success(store.tr(.managedCommitted))
                    }
                }
                .disabled(acceptanceBusy
                          || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(store.tr(.managedPush)) {
                    runAcceptance { worktree in
                        guard let branch = ManagedAcceptance.branch(worktree: worktree) else {
                            return .failure(.gitFailed("no branch"))
                        }
                        if let error = ManagedAcceptance.push(worktree: worktree, branch: branch) {
                            return .failure(error)
                        }
                        if let origin = ManagedAcceptance.originURL(worktree: worktree) {
                            let url = ManagedAcceptance.compareURL(originURL: origin, branch: branch)
                            DispatchQueue.main.async { compareURL = url }
                        }
                        return .success(String(format: store.tr(.managedPushed), branch))
                    }
                }
                .disabled(acceptanceBusy)
                if let compareURL {
                    Button(store.tr(.managedOpenPR)) {
                        NSWorkspace.shared.open(compareURL)
                    }
                }
                if acceptanceBusy { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.bordered)
            if !acceptanceNotice.isEmpty {
                Text(acceptanceNotice)
                    .font(.caption)
                    .foregroundStyle(acceptanceNoticeIsError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func runAcceptance(
        _ verb: @escaping (String) -> Result<String, ManagedAcceptance.VerbError>
    ) {
        guard !acceptanceBusy else { return }
        acceptanceBusy = true
        acceptanceNotice = ""
        let worktree = row.workspaceRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = verb(worktree)
            DispatchQueue.main.async {
                acceptanceBusy = false
                switch outcome {
                case .success(let message):
                    acceptanceNotice = message
                    acceptanceNoticeIsError = false
                case .failure(.outsideNamespace):
                    acceptanceNotice = store.tr(.managedOutsideNamespace)
                    acceptanceNoticeIsError = true
                case .failure(.gitFailed(let reason)):
                    acceptanceNotice = reason
                    acceptanceNoticeIsError = true
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(row.agent.displayName)
                    .font(.title2.weight(.semibold))
                Text(store.tr(.managedBadge))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                if !row.model.isEmpty {
                    Text(row.model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !row.task.isEmpty {
                Text(row.task)
                    .font(.title3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(row.cwd)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var conversationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.tr(.managedConversation))
                .font(.headline)
            if let model = runner?.model {
                if model.entriesCapped {
                    Text(String(format: store.tr(.workbenchTranscriptCapped), ManagedSession.maxEntries))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(model.entries.enumerated()), id: \.offset) { index, entry in
                                ManagedEntryRow(store: store, agentName: row.agent.displayName, entry: entry)
                                    .id(index)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 200, maxHeight: 460)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: model.entries.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                    .onAppear {
                        proxy.scrollTo(model.entries.count - 1, anchor: .bottom)
                    }
                }
            }
            replyRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var replyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if runner?.isRunning == true {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(row.tool.isEmpty
                         ? store.tr(.managedRunning)
                         : store.tr(.managedRunning) + " · " + row.tool)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(store.tr(.managedCancel)) { runner?.cancel() }
                        .buttonStyle(.bordered)
                }
            } else {
                TextField(store.tr(.managedReplyPlaceholder), text: $reply, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
                HStack {
                    Button(store.tr(.managedSend)) {
                        let text = reply
                        reply = ""
                        runner?.send(prompt: text)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
            }
        }
    }

    private func statusCard(_ model: ManagedSession.Model) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.status {
            case .idle:
                Text(store.tr(.managedIdle))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .running:
                EmptyView()
            case .cancelled:
                Text(store.tr(.managedCancelled))
                    .font(.callout)
                    .foregroundStyle(.orange)
            case .failed(let reason):
                Text(String(format: store.tr(.managedFailed), reason))
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Text(String(format: store.tr(.managedCost), model.totalCostUSD, model.turns))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.tokensIn > 0 || model.tokensOut > 0 {
                    Text("↑\(AgentRow.compactToken(model.tokensIn)) ↓\(AgentRow.compactToken(model.tokensOut))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.unknownEvents > 0 || model.unparsedLines > 0 {
                    // Format drift stated out loud, never swallowed.
                    Text(String(format: store.tr(.managedUnknownEvents),
                                model.unknownEvents + model.unparsedLines))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if model.isWorktree {
                Text(store.tr(.managedWorktreeNote))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var effectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.tr(.workbenchDiff))
                .font(.headline)
            // The same read-only plumbing card the observed inspector uses —
            // against the worktree Pulse created, which is disk-confirmed by
            // construction.
            WorkspaceDiffSection(store: store, row: row)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One conversation line. The same entry shape the transcript card renders —
/// one parser, one look.
@MainActor
struct ManagedEntryRow: View {
    @ObservedObject var store: StatusStore
    let agentName: String
    let entry: TranscriptReader.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(labelColor)
                .frame(width: 76, alignment: .trailing)
            Text(entry.text.isEmpty ? "—" : entry.text)
                .font(entry.kind == .tool ? .caption.monospaced() : .callout)
                .foregroundStyle(entry.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch entry.kind {
        case .user: return store.tr(.workbenchTranscriptUser)
        case .agent: return agentName
        case .tool:
            if entry.isError { return store.tr(.detailLastError) }
            return entry.toolName.isEmpty ? store.tr(.workbenchTranscriptResult) : entry.toolName
        }
    }

    private var labelColor: Color {
        switch entry.kind {
        case .user: return .accentColor
        case .agent: return .primary
        case .tool: return entry.isError ? .orange : .secondary
        }
    }
}

