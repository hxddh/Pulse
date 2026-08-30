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
    @State private var runCheckCommand = ""
    @State private var runCheckBusy = false
    @State private var currentFingerprint: CodeFingerprint?
    @State private var fingerprintMeasured = false
    @State private var fingerprintRefreshInFlight = false
    @State private var fingerprintRefreshQueued = false
    @State private var acceptanceBusy = false
    @State private var acceptanceNotice = ""
    @State private var acceptanceNoticeIsError = false
    @State private var compareURL: URL?

    private var runner: ManagedSessionRunner? { store.managedRunner(for: row) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                // 6.0-β: the asks this session is blocked on, first — the
                // turn is waiting on exactly this.
                ForEach(store.managedPermissionRequests(for: row), id: \.id) { request in
                    permissionCard(request)
                }
                conversationCard
                if let model = runner?.model {
                    statusCard(model)
                    // 6.0-γ: the other tries of the same task, side by side.
                    if store.managedAttemptSiblings(for: row).count > 1 {
                        compareCard
                    }
                }
                effectCard
                if runner?.isRunning != true,
                   ManagedWorktree.isPulseWorktree(row.workspaceRoot) {
                    runCheckCard
                    acceptanceCard
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            runCheckCommand = runner?.model.runCommand ?? ""
            refreshFingerprint()
        }
        .onChange(of: row) { _, _ in refreshFingerprint() }
    }

    /// 6.0-γ (scene BK): same task, N independent tries — status and what
    /// each has landed, one click to switch. Judgment stays a human act:
    /// Pulse lines them up, the user picks.
    private var compareCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.tr(.managedAttempts))
                .font(.headline)
            ForEach(Array(store.managedAttemptSiblings(for: row).enumerated()), id: \.element.model.id) { index, sibling in
                HStack(spacing: 10) {
                    Text(String(format: store.tr(.managedAttemptOrdinal), index + 1))
                        .font(.callout.weight(sibling.model.id == row.managedID ? .bold : .regular))
                    Text(statusLabel(sibling.model.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let effect = sibling.model.lastTurnEffect {
                        Text("+\(effect.insertions) −\(effect.deletions)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if sibling.model.id == row.managedID {
                        Text(store.tr(.managedCurrentAttempt))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Button(store.tr(.managedViewAttempt)) {
                            store.workbenchSelectKey = "managed|" + sibling.model.id
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
        .padding(PulseTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: PulseTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PulseTheme.cardRadius)
                .strokeBorder(.quaternary, lineWidth: PulseTheme.hairline)
        )
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

    /// 6.0-γ (scene BK): run the repo's own check inside the worktree before
    /// landing anything. The command is the user's, remembered per session;
    /// exit code and output tail come back verbatim.
    private var runCheckCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.tr(.managedRunCheck))
                .font(.headline)
            HStack(spacing: 8) {
                TextField(store.tr(.managedRunCheckPlaceholder), text: $runCheckCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button {
                    runCheck()
                } label: {
                    if runCheckBusy || runner?.isChecking == true {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(store.tr(.managedRunCheck))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(runCheckBusy || runner?.isChecking == true
                          || runCheckCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let evidence = runner?.model.acceptanceEvidence.last {
                Text(evidence.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text(evidenceLabel(evidence))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(evidenceFailed(evidence)
                                     ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            if let evidence = runner?.model.acceptanceEvidence.last,
               !evidenceOutput(evidence).isEmpty {
                ScrollView {
                    Text(evidenceOutput(evidence))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: PulseTheme.innerRadius))
            }
        }
        .padding(PulseTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: PulseTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PulseTheme.cardRadius)
                .strokeBorder(.quaternary, lineWidth: PulseTheme.hairline)
        )
    }

    private func runCheck() {
        guard !runCheckBusy, let runner, !runner.isChecking else { return }
        let command = runCheckCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        runCheckBusy = true
        runner.runCheck(command: command) {
            runCheckBusy = false
            refreshFingerprint()
        }
    }

    private func refreshFingerprint() {
        let root = row.workspaceRoot
        guard !root.isEmpty else { return }
        if fingerprintRefreshInFlight {
            fingerprintRefreshQueued = true
            return
        }
        fingerprintRefreshInFlight = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fingerprint = CodeFingerprint.measure(cwd: root)
            DispatchQueue.main.async {
                currentFingerprint = fingerprint
                fingerprintMeasured = true
                fingerprintRefreshInFlight = false
                if fingerprintRefreshQueued {
                    fingerprintRefreshQueued = false
                    refreshFingerprint()
                }
            }
        }
    }

    private func evidenceLabel(_ evidence: AcceptanceEvidence) -> String {
        if evidence.outcome == .passed {
            guard fingerprintMeasured else { return store.tr(.managedRunCheckMeasuring) }
            guard let currentFingerprint else { return store.tr(.managedRunCheckUnverified) }
            guard currentFingerprint == evidence.postFingerprint else {
                return store.tr(.managedRunCheckStale)
            }
        }
        switch evidence.outcome {
        case .passed, .failed:
            return String(format: store.tr(.managedRunCheckExit), evidence.exitCode ?? -1)
        case .timedOut:
            return store.tr(.managedRunCheckTimeout)
        case .couldNotRun:
            return store.tr(.managedRunCheckUnverified)
        case .invalidatedDuringRun:
            return store.tr(.managedRunCheckChanged)
        case .interrupted:
            return store.tr(.managedRunCheckInterrupted)
        }
    }

    private func evidenceFailed(_ evidence: AcceptanceEvidence) -> Bool {
        guard evidence.outcome == .passed else { return true }
        return !fingerprintMeasured || currentFingerprint != evidence.postFingerprint
    }

    private func evidenceOutput(_ evidence: AcceptanceEvidence) -> String {
        var text = String(decoding: evidence.stdout, as: UTF8.self)
        let stderr = String(decoding: evidence.stderr, as: UTF8.self)
        if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += (text.isEmpty ? "" : "\n") + stderr
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 6.0-β (scene BJ): a live permission ask. 7.0-α: the card body is the
    /// shared `SessionPermissionCard` — the popup renders the same truth
    /// compact; only the workbench chrome (padding, tint) lives here.
    private func permissionCard(_ request: ManagedPermission.Request) -> some View {
        SessionPermissionCard(store: store, request: request, compact: false)
            .padding(PulseTheme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: PulseTheme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: PulseTheme.cardRadius)
                    .strokeBorder(.quaternary, lineWidth: PulseTheme.hairline)
            )
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
        .padding(PulseTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: PulseTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PulseTheme.cardRadius)
                .strokeBorder(.quaternary, lineWidth: PulseTheme.hairline)
        )
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
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: PulseTheme.innerRadius))
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
        .padding(PulseTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: PulseTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PulseTheme.cardRadius)
                .strokeBorder(.quaternary, lineWidth: PulseTheme.hairline)
        )
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
            } else if runner?.model.status == .queued {
                Text(store.tr(.managedQueuedNote))
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
            case .queued:
                Text(store.tr(.managedQueuedNote))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .interrupted:
                Text(store.tr(.managedInterrupted))
                    .font(.callout)
                    .foregroundStyle(.orange)
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
            if let effect = model.lastTurnEffect {
                Text(String(format: store.tr(.managedTurnEffect), effect.insertions, effect.deletions))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if model.isWorktree {
                Text(store.tr(.managedWorktreeNote))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 6.0-α: a finished session can be cleared. The record goes;
            // the worktree stays for the user — Pulse does not delete work
            // products on cleanup.
            if model.status != .running {
                HStack(spacing: 8) {
                    Button(store.tr(.managedRemove)) {
                        store.managedRemove(row)
                    }
                    .buttonStyle(.bordered)
                    Text(store.tr(.managedRemoveNote))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(PulseTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: PulseTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PulseTheme.cardRadius)
                .strokeBorder(.quaternary, lineWidth: PulseTheme.hairline)
        )
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
        .padding(PulseTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: PulseTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PulseTheme.cardRadius)
                .strokeBorder(.quaternary, lineWidth: PulseTheme.hairline)
        )
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
            if entry.isError { return "↳ " + store.tr(.detailLastError) }
            // 6.0-γ: a result visibly hangs off its call.
            return entry.toolName.isEmpty
                ? "↳ " + store.tr(.workbenchTranscriptResult)
                : entry.toolName
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
