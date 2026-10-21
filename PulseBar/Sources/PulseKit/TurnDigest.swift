import Foundation

/// What the current turn did, as its lines said it — the detail page's
/// "This turn" and the summary a person can copy (`TurnSummary`).
///
/// Accumulated by `SessionBook.apply` as the lines apply, in `seq` order,
/// and started over when a turn starts (the person's prompt, or work after
/// a turn ended — the same moments the turn's clock and step count start
/// over), so the launch replay rebuilds it exactly. Pure and bounded: at
/// most `maxFiles` files, `maxNames` tools, skills and MCP servers, and
/// `maxSubagents` subagents.
///
/// Whose is what — one rule, kept everywhere:
///
/// - **`tools`** is the main agent's steps alone, by tool: a subagent is
///   not the person's agent, and its steps are counted in its own entry
///   (`subagents`). The turn's step total (`SessionFacts.turnSteps`) still
///   counts every speaker's steps, as it always has.
/// - **`files`, `skills`, `mcpServers`** are what the turn touched,
///   whichever speaker touched it: a file a subagent edited changed all the
///   same.
/// - **`subagents`**: each subagent heard in the turn — its type, its own
///   steps, whether its start and its end were heard. One is *live* only
///   when its start was heard and its end was not: a subagent known from
///   its steps alone is never said to be going (no guessed state).
///
/// Tokens, cost and model are never here — a decision.
package struct TurnDigest: Hashable, Sendable {
    /// A name and how many times.
    package struct Count: Hashable, Sendable {
        package var name: String
        package var count: Int

        package init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    /// One subagent of the turn.
    package struct Subagent: Hashable, Sendable {
        /// The vendor's subagent id (`sub`).
        package var sub: String
        /// Its type (`meta` `type`); "" unknown.
        package var type = ""
        /// Its own steps this turn, and how many failed.
        package var steps = 0
        package var failed = 0
        /// Its start was heard (`start` with `sub`).
        package var started = false
        /// Its end was heard (its end of turn, stop or end).
        package var finished = false

        package init(sub: String, type: String = "", steps: Int = 0, failed: Int = 0, started: Bool = false, finished: Bool = false) {
            self.sub = sub
            self.type = type
            self.steps = steps
            self.failed = failed
            self.started = started
            self.finished = finished
        }

        /// Its start was heard and its end was not.
        package var isLive: Bool { started && !finished }
    }

    /// The main agent's steps, by tool, in the order each first ran.
    package var tools: [Count] = []
    /// The files the turn changed, deduplicated, in the order first heard:
    /// an edit step's target, or the files a line's `meta` named.
    package var files: [String] = []
    /// More files were heard than `maxFiles` kept.
    package var filesOverflowed = false
    /// The skills the turn invoked, by name.
    package var skills: [String] = []
    /// The MCP servers whose tools ran.
    package var mcpServers: [String] = []
    /// The subagents heard in the turn, in the order first heard.
    package var subagents: [Subagent] = []

    package static let maxFiles = 32
    package static let maxNames = 16
    package static let maxSubagents = 16

    package init(
        tools: [Count] = [], files: [String] = [], filesOverflowed: Bool = false,
        skills: [String] = [], mcpServers: [String] = [], subagents: [Subagent] = []
    ) {
        self.tools = tools
        self.files = files
        self.filesOverflowed = filesOverflowed
        self.skills = skills
        self.mcpServers = mcpServers
        self.subagents = subagents
    }

    /// Nothing heard.
    package var isEmpty: Bool { self == TurnDigest() }

    /// The live subagents, in the order first heard.
    package var liveSubagents: [Subagent] { subagents.filter(\.isLive) }

    /// `tools`, the most used first; a tie keeps the order they first ran.
    package var toolsByCount: [Count] {
        tools.enumerated()
            .sorted { a, b in a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset }
            .map(\.element)
    }

    // MARK: - Accumulating

    /// One step as its line said it, with the files the line's `meta`
    /// named. The main agent's goes in the tally, a subagent's in its own
    /// entry; what it touched goes in the turn's lists either way.
    package mutating func add(_ step: SessionBook.Step, files named: [String]) {
        if step.sub.isEmpty {
            if let index = tools.firstIndex(where: { $0.name == step.tool }) {
                tools[index].count += 1
            } else if tools.count < Self.maxNames {
                tools.append(Count(name: step.tool, count: 1))
            }
        } else {
            withSubagent(step.sub) { entry in
                entry.steps += 1
                if step.failed { entry.failed += 1 }
            }
        }
        switch step.category {
        case .edit?:
            if named.isEmpty { addFile(step.target) }
        case .skill?:
            Self.insert(step.target, into: &skills)
        case .mcp?:
            Self.insert(Self.server(of: step.tool), into: &mcpServers)
        default:
            break
        }
        for file in named { addFile(file) }
    }

    /// The files a line's `meta` named that is not a step (a batch's diff).
    package mutating func addFiles(_ named: [String]) {
        for file in named { addFile(file) }
    }

    /// A subagent's lifecycle line: its start, or its end (its end of turn,
    /// a stop or an end), with its type when the line said one.
    package mutating func hear(sub: String, type: String, kind: AttentionKind) {
        let started = kind == .start
        let finished: Bool
        switch kind {
        case .turn, .failed, .idle, .stopped, .end: finished = true
        default: finished = false
        }
        guard started || finished || !type.isEmpty else { return }
        withSubagent(sub) { entry in
            if !type.isEmpty { entry.type = type }
            if started { entry.started = true }
            if finished { entry.finished = true }
        }
    }

    /// The MCP server a tool label names ("server · tool",
    /// `PulseHookReceiver.toolLabel`), else the label itself.
    package static func server(of tool: String) -> String {
        guard let range = tool.range(of: " · ") else { return tool }
        return String(tool[..<range.lowerBound])
    }

    private mutating func withSubagent(_ sub: String, _ change: (inout Subagent) -> Void) {
        if let index = subagents.firstIndex(where: { $0.sub == sub }) {
            change(&subagents[index])
        } else if subagents.count < Self.maxSubagents {
            var entry = Subagent(sub: sub)
            change(&entry)
            subagents.append(entry)
        }
    }

    private mutating func addFile(_ raw: String) {
        let file = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !file.isEmpty, !files.contains(file) else { return }
        guard files.count < Self.maxFiles else {
            filesOverflowed = true
            return
        }
        files.append(file)
    }

    private static func insert(_ raw: String, into names: inout [String]) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !names.contains(name), names.count < maxNames else { return }
        names.append(name)
    }
}
