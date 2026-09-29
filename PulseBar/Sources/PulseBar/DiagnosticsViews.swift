// 3.0-α: the support-health scene, moved out of PulseApp.swift.
//
// 23.0 · Diagnostics (it was "Health"). `DiagnosticsView` builds a
// `DiagnosticsModel` from the store and performs its intents;
// `DiagnosticsFace` renders the value: problems first, the self-check, then
// every agent on one line — and the activity log in its own tab.

import SwiftUI
import AppKit

@MainActor
struct DiagnosticsView: View {
    var store: StatusStore
    @State private var tab: DiagnosticsModel.Tab = .overview
    @State private var activityAgent: AgentID?

    init(store: StatusStore) {
        self.store = store
    }

    var body: some View {
        DiagnosticsFace(
            model: store.diagnosticsModel(activityAgent: activityAgent),
            tab: $tab,
            activityAgent: $activityAgent
        ) { intent in
            switch intent {
            case .fix(let fix): store.performDiagnosticsFix(fix)
            case .runSelfCheck: store.runDoctor()
            case .copyReport: store.copyReport()
            }
        }
    }
}

/// Renders a `DiagnosticsModel`. The tab and the activity filter are the
/// window's own state, passed in as bindings.
struct DiagnosticsFace: View {
    enum Intent: Equatable {
        case fix(DiagnosticsModel.Fix)
        case runSelfCheck
        case copyReport
    }

    let model: DiagnosticsModel
    @Binding var tab: DiagnosticsModel.Tab
    @Binding var activityAgent: AgentID?
    var send: (Intent) -> Void = { _ in }

    private func t(_ key: L10n.Key) -> String { L10n.t(key, model.lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, PulseTheme.Space.xl)
                .padding(.top, PulseTheme.Space.l)
                .padding(.bottom, PulseTheme.Space.m)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: PulseTheme.Space.l) {
                    switch tab {
                    case .overview:
                        problems
                        selfCheck
                        agents
                    case .activity:
                        ActivityLogView(
                            model: model.activity,
                            lang: model.lang,
                            agents: model.activityAgents,
                            filter: $activityAgent
                        )
                    }
                }
                .padding(PulseTheme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 520, minHeight: 320)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: PulseTheme.Space.m) {
            VStack(alignment: .leading, spacing: PulseTheme.Space.xs) {
                Text(t(.diagnosticsTitle))
                    .font(PulseTheme.Font.title)
                Text(model.scanLine)
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PulseTheme.Space.s)
            Picker("", selection: $tab) {
                Text(t(.diagnosticsOverview)).tag(DiagnosticsModel.Tab.overview)
                Text(t(.activityHeading)).tag(DiagnosticsModel.Tab.activity)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button(model.copied ? t(.copied) : t(.copyReport)) { send(.copyReport) }
        }
    }

    // MARK: Problems

    @ViewBuilder
    private var problems: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.s) {
            Text(t(.diagnosticsProblems))
                .font(PulseTheme.Font.heading)
            if model.problems.isEmpty {
                Label(t(.diagnosticsNoProblems), systemImage: "checkmark.circle")
                    .font(PulseTheme.Font.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.problems) { problem in
                    HStack(alignment: .firstTextBaseline, spacing: PulseTheme.Space.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(PulseTheme.Tone.attention.color)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: PulseTheme.Space.xxs) {
                            Text(problem.text)
                                .font(PulseTheme.Font.bodyEmphasis)
                                .fixedSize(horizontal: false, vertical: true)
                            if !problem.detail.isEmpty {
                                Text(problem.detail)
                                    .font(PulseTheme.Font.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: PulseTheme.Space.s)
                        if let fix = problem.fix {
                            Button(problem.fixTitle) { send(.fix(fix)) }
                                .controlSize(.small)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .pulseCard()
    }

    // MARK: Self-check

    private var selfCheck: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.s) {
            HStack(spacing: PulseTheme.Space.s) {
                Text(t(.doctorRun))
                    .font(PulseTheme.Font.heading)
                if model.doctorRunning { ProgressView().controlSize(.small) }
                Spacer(minLength: PulseTheme.Space.s)
                Button(model.doctor == nil ? t(.healthRunCheck) : t(.healthRunAgain)) { send(.runSelfCheck) }
                    .disabled(model.doctorRunning)
            }
            if let report = model.doctor {
                DoctorReportView(report: report) { send(.fix(.doctor($0))) }
            } else {
                Text(t(.doctorHint))
                    .font(PulseTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .pulseCard()
    }

    // MARK: Agents

    private var agents: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.s) {
            Text(t(.healthAgentsHeading))
                .font(PulseTheme.Font.heading)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.agents) { agent in
                    DiagnosticsAgentRow(model: agent) { send(.fix($0)) }
                    if agent.id != model.agents.last?.id {
                        Divider().padding(.leading, 26)
                    }
                }
            }
        }
    }
}

/// One agent on one line — icon, name, state, and the one fix — with its
/// details a click away. Renders a `DiagnosticsModel.Agent`.
struct DiagnosticsAgentRow: View {
    let model: DiagnosticsModel.Agent
    var send: (DiagnosticsModel.Fix) -> Void = { _ in }
    @State private var expanded = false

    init(model: DiagnosticsModel.Agent, send: @escaping (DiagnosticsModel.Fix) -> Void = { _ in }) {
        self.model = model
        self.send = send
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(model.details.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(PulseTheme.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 26)
            .padding(.bottom, PulseTheme.Space.s)
        } label: {
            HStack(spacing: PulseTheme.Space.s) {
                AgentIconView(id: model.agent)
                Text(model.name)
                    .font(PulseTheme.Font.bodyEmphasis)
                PulseChip(label: model.state, tone: model.tone)
                if let warning = model.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(PulseTheme.Tone.attention.color)
                        .help(warning)
                }
                Spacer(minLength: PulseTheme.Space.s)
                if let fix = model.fix {
                    Button(model.fixTitle) { send(fix) }
                        .controlSize(.small)
                }
            }
            .padding(.vertical, PulseTheme.Space.xs)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.name), \(model.state)")
    }
}

/// 22.0: the Activity log — renders a value; the filter is the only state.
struct ActivityLogView: View {
    let model: ActivityLogModel
    let lang: ResolvedLanguage
    var agents: [AgentID] = []
    @Binding var filter: AgentID?

    private func t(_ key: L10n.Key) -> String { L10n.t(key, lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: PulseTheme.Space.s) {
            HStack {
                Text(t(.activityHeading))
                    .font(PulseTheme.Font.heading)
                Spacer(minLength: PulseTheme.Space.s)
                if !agents.isEmpty {
                    Picker("", selection: $filter) {
                        Text(t(.activityAllAgents)).tag(AgentID?.none)
                        ForEach(agents, id: \.self) { agent in
                            Text(agent.displayName).tag(AgentID?.some(agent))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if model.entries.isEmpty {
                Text(t(.activityEmpty))
                    .font(PulseTheme.Font.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: PulseTheme.Space.s) {
                        Text(entry.clock)
                            .font(PulseTheme.Font.code)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 72, alignment: .leading)
                        Circle()
                            .fill(entry.tone == .idle ? Color.secondary : entry.tone.color)
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.text)
                                .font(PulseTheme.Font.body)
                            let who = [entry.agent?.displayName ?? "", entry.place].filter { !$0.isEmpty }.joined(separator: " · ")
                            if !who.isEmpty {
                                Text(who)
                                    .font(PulseTheme.Font.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
