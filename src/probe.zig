//! Multi-agent process scanners for Pulse. Pure parsers + rule table.
//! At least 15 mainstream AI coding agents; IDE shells count as active
//! when the user opts into shell-as-running (default for Phase 3).

const std = @import("std");

pub const max_detected = 24;

/// Stable ids for every agent Pulse knows how to probe.
pub const AgentId = enum {
    claude,
    codex,
    cursor,
    cursor_agent,
    copilot,
    aider,
    gemini,
    amp,
    opencode,
    goose,
    cline,
    windsurf,
    codeium,
    zed,
    continue_,
    amazon_q,
    roo,
    augment,
    openhands,
    warp,
    pi,
    grok,

    pub fn displayName(self: AgentId) []const u8 {
        return switch (self) {
            .claude => "Claude",
            .codex => "Codex",
            .cursor => "Cursor",
            .cursor_agent => "Cursor Agent",
            .copilot => "Copilot",
            .aider => "Aider",
            .gemini => "Gemini",
            .amp => "Amp",
            .opencode => "OpenCode",
            .goose => "Goose",
            .cline => "Cline",
            .windsurf => "Windsurf",
            .codeium => "Codeium",
            .zed => "Zed",
            .continue_ => "Continue",
            .amazon_q => "Amazon Q",
            .roo => "Roo",
            .augment => "Augment",
            .openhands => "OpenHands",
            .warp => "Warp",
            .pi => "Pi",
            .grok => "Grok",
        };
    }

    pub fn all() []const AgentId {
        return std.enums.values(AgentId);
    }
};

/// Higher index = lower priority when choosing the menu-bar primary.
pub const priority_order = [_]AgentId{
    .claude,
    .cursor_agent,
    .codex,
    .grok,
    .pi,
    .amp,
    .aider,
    .gemini,
    .copilot,
    .opencode,
    .goose,
    .openhands,
    .cline,
    .roo,
    .continue_,
    .augment,
    .amazon_q,
    .codeium,
    .cursor,
    .windsurf,
    .zed,
    .warp,
};

/// Agents shown in Glance / Tray / Preferences.
/// IDE shells (Cursor.app, Warp, Zed…) inflate counts and are not “coding agents running”.
pub fn isSurfaceAgent(id: AgentId) bool {
    return switch (id) {
        .claude,
        .codex,
        .grok,
        .pi,
        .amp,
        .aider,
        .gemini,
        .copilot,
        .opencode,
        .goose,
        .openhands,
        .cline,
        .roo,
        .continue_,
        .augment,
        .amazon_q,
        .cursor_agent,
        => true,
        .cursor, .windsurf, .zed, .warp, .codeium => false,
    };
}

pub const DetectedAgent = struct {
    id: AgentId,
    process_count: u32 = 0,
    via_cli: bool = false,
    /// True when at least one process sits under Warp.app in the parent tree.
    via_warp: bool = false,
};

pub const ScanResult = struct {
    agents: [max_detected]DetectedAgent = undefined,
    count: usize = 0,

    pub fn slice(self: *const ScanResult) []const DetectedAgent {
        return self.agents[0..self.count];
    }

    pub fn contains(self: *const ScanResult, id: AgentId) bool {
        for (self.agents[0..self.count]) |a| {
            if (a.id == id) return true;
        }
        return false;
    }

    pub fn processCount(self: *const ScanResult, id: AgentId) u32 {
        for (self.agents[0..self.count]) |a| {
            if (a.id == id) return a.process_count;
        }
        return 0;
    }

    pub fn viaCli(self: *const ScanResult, id: AgentId) bool {
        for (self.agents[0..self.count]) |a| {
            if (a.id == id) return a.via_cli;
        }
        return false;
    }

    pub fn viaWarp(self: *const ScanResult, id: AgentId) bool {
        for (self.agents[0..self.count]) |a| {
            if (a.id == id) return a.via_warp;
        }
        return false;
    }

    pub fn primary(self: *const ScanResult) ?AgentId {
        return self.surfacePrimary() orelse self.rawPrimary();
    }

    /// Primary among surface (coding) agents only — used for Glance/Tray.
    pub fn surfacePrimary(self: *const ScanResult) ?AgentId {
        if (self.count == 0) return null;
        var best: ?AgentId = null;
        var best_rank: usize = std.math.maxInt(usize);
        for (self.agents[0..self.count]) |a| {
            if (!isSurfaceAgent(a.id)) continue;
            const rank = priorityRank(a.id);
            if (rank < best_rank) {
                best_rank = rank;
                best = a.id;
            }
        }
        return best;
    }

    fn rawPrimary(self: *const ScanResult) ?AgentId {
        if (self.count == 0) return null;
        var best: ?AgentId = null;
        var best_rank: usize = std.math.maxInt(usize);
        for (self.agents[0..self.count]) |a| {
            const rank = priorityRank(a.id);
            if (rank < best_rank) {
                best_rank = rank;
                best = a.id;
            }
        }
        return best;
    }

    pub fn surfaceCount(self: *const ScanResult) usize {
        var n: usize = 0;
        for (self.agents[0..self.count]) |a| {
            if (isSurfaceAgent(a.id)) n += 1;
        }
        return n;
    }

    pub fn containsSurface(self: *const ScanResult, id: AgentId) bool {
        return isSurfaceAgent(id) and self.contains(id);
    }

    fn priorityRank(id: AgentId) usize {
        for (priority_order, 0..) |p, i| {
            if (p == id) return i;
        }
        return priority_order.len;
    }

    pub fn addProcess(self: *ScanResult, id: AgentId) void {
        self.addProcessFlags(id, false);
    }

    pub fn addProcessFlags(self: *ScanResult, id: AgentId, via_warp: bool) void {
        for (self.agents[0..self.count]) |*a| {
            if (a.id == id) {
                a.process_count +%= 1;
                if (via_warp) a.via_warp = true;
                return;
            }
        }
        if (self.count >= max_detected) return;
        self.agents[self.count] = .{ .id = id, .process_count = 1, .via_warp = via_warp };
        self.count += 1;
    }

    pub fn markCli(self: *ScanResult, id: AgentId) void {
        for (self.agents[0..self.count]) |*a| {
            if (a.id == id) {
                a.via_cli = true;
                return;
            }
        }
        if (self.count >= max_detected) return;
        self.agents[self.count] = .{ .id = id, .process_count = 0, .via_cli = true };
        self.count += 1;
    }
};

const Rule = struct {
    id: AgentId,
    basenames: []const []const u8 = &.{},
    path_needles: []const []const u8 = &.{},
    deny_needles: []const []const u8 = &.{},
};

/// Full rule table — 20 agents (≥15 required).
pub const rules = [_]Rule{
    .{
        .id = .claude,
        .basenames = &.{ "claude" },
        .path_needles = &.{ "/.local/bin/claude", "/bin/claude" },
        .deny_needles = &.{ "Claude.app", "chrome-native-host", "Google Chrome" },
    },
    .{
        .id = .codex,
        .basenames = &.{ "codex" },
        .path_needles = &.{ "/opt/homebrew/bin/codex", "/bin/codex", "Resources/codex" },
        .deny_needles = &.{ "Codex Framework", "Codex (Service)", "Codex (Renderer)", "crashpad", "computer-use", "Computer Use", "codex-code-mode-host", "chrome-extension" },
    },
    .{
        .id = .cursor,
        .basenames = &.{ "Cursor", "cursor" },
        .path_needles = &.{ "Cursor.app/Contents/MacOS/Cursor", "/Applications/Cursor.app" },
        .deny_needles = &.{ "crashpad", "CursorUIViewService", "Electron Framework" },
    },
    .{
        .id = .cursor_agent,
        .basenames = &.{ "cursor-agent", "cursor_agent" },
        .path_needles = &.{ "cursor-agent", "anysphere.cursor-agent", "cursor-agent-worker" },
        .deny_needles = &.{ "crashpad" },
    },
    .{
        .id = .copilot,
        .basenames = &.{ "copilot", "github-copilot" },
        .path_needles = &.{ "github-copilot", "copilot-language-server", "GitHub.copilot", "/bin/copilot" },
        .deny_needles = &.{ "crashpad" },
    },
    .{
        .id = .aider,
        .basenames = &.{ "aider" },
        .path_needles = &.{ "/bin/aider", "-m aider", "python -m aider", "python3 -m aider" },
        .deny_needles = &.{},
    },
    .{
        .id = .gemini,
        .basenames = &.{ "gemini", "gemini-cli" },
        .path_needles = &.{ "/bin/gemini", "gemini-cli", "@google/gemini-cli" },
        .deny_needles = &.{ "Gemini.app" }, // browser shell if any
    },
    .{
        .id = .amp,
        .basenames = &.{ "amp" },
        .path_needles = &.{ "/.local/bin/amp", "/bin/amp" },
        .deny_needles = &.{ "AMPDevice", "AMPLibrary", "AMPArtwork", "AMPDevices", "TextInput" },
    },
    .{
        .id = .opencode,
        .basenames = &.{ "opencode", "open-code" },
        .path_needles = &.{ "/bin/opencode", "opencode" },
        .deny_needles = &.{},
    },
    .{
        .id = .goose,
        .basenames = &.{ "goose" },
        .path_needles = &.{ "/bin/goose", "block/goose", "goose-cli" },
        .deny_needles = &.{},
    },
    .{
        .id = .cline,
        .basenames = &.{ "cline" },
        .path_needles = &.{ "saoudrizwan.claude-dev", "cline", "claude-dev" },
        .deny_needles = &.{ "crashpad" },
    },
    .{
        .id = .windsurf,
        .basenames = &.{ "Windsurf", "windsurf" },
        .path_needles = &.{ "Windsurf.app", "/bin/windsurf" },
        .deny_needles = &.{ "crashpad", "Electron Framework" },
    },
    .{
        .id = .codeium,
        .basenames = &.{ "codeium", "Codeium", "language_server_macos" },
        .path_needles = &.{ "codeium", "Codeium", "Exafunction" },
        .deny_needles = &.{ "crashpad" },
    },
    .{
        .id = .zed,
        .basenames = &.{ "zed", "Zed" },
        .path_needles = &.{ "Zed.app/Contents/MacOS/zed", "Zed.app/Contents/MacOS/Zed", "/bin/zed" },
        .deny_needles = &.{ "crashpad" },
    },
    .{
        .id = .continue_,
        .basenames = &.{ "continue", "continue-cli" },
        .path_needles = &.{ "continue.dev", "Continue.continue", "continue-cli", "/.continue/" },
        .deny_needles = &.{ "crashpad" },
    },
    .{
        .id = .amazon_q,
        .basenames = &.{ "amazon-q", "q-chat", "qchat" },
        .path_needles = &.{ "amazon-q", "Amazon Q", "q-chat", "aws/amazon-q", "/opt/homebrew/bin/q", "/.local/bin/q" },
        .deny_needles = &.{ "qr", "qt-", "qemu", "QuickTime" },
    },
    .{
        .id = .roo,
        .basenames = &.{ "roo", "roo-code" },
        .path_needles = &.{ "roo-cline", "roo-code", "RooCode", "Roo-Code" },
        .deny_needles = &.{ "crashpad" },
    },
    .{
        .id = .augment,
        .basenames = &.{ "augment", "auggie" },
        .path_needles = &.{ "augmentcode", "augment-code", "/bin/augment", "Augment" },
        .deny_needles = &.{ "crashpad" },
    },
    .{
        .id = .openhands,
        .basenames = &.{ "openhands", "open-hands", "opendevin" },
        .path_needles = &.{ "openhands", "open-hands", "OpenHands", "OpenDevin" },
        .deny_needles = &.{},
    },
    .{
        .id = .warp,
        .basenames = &.{ "Warp", "warp" },
        .path_needles = &.{ "Warp.app/Contents/MacOS", "Warp.app" },
        .deny_needles = &.{ "crashpad", "Electron Framework" },
    },
    .{
        // @earendil-works/pi-coding-agent → homebrew bin `pi`
        .id = .pi,
        .basenames = &.{ "pi" },
        .path_needles = &.{ "pi-coding-agent", "/opt/homebrew/bin/pi", "/bin/pi" },
        .deny_needles = &.{ "pip", "pip3", "pihole", "pickle", "pixfmt", "fourcc", "pypi", "jupyter" },
    },
    .{
        // Grok Build TUI: ~/.grok/bin/grok or agent shells with GROK_AGENT=1
        .id = .grok,
        .basenames = &.{ "grok" },
        .path_needles = &.{ "/.grok/bin/grok", "grok-0.", "GROK_AGENT=", "/bin/grok" },
        .deny_needles = &.{},
    },
};

pub fn matchArgs(args: []const u8) ?AgentId {
    if (args.len == 0) return null;
    const exe = firstToken(args);
    const base = basename(exe);

    // First pass: deny-aware match; first matching rule wins by table order
    // but we call this per-rule from scan — actually scan tries all rules.
    _ = base;
    return null; // unused; scanPs uses matchRule
}

pub fn matchRule(rule: Rule, args: []const u8) bool {
    for (rule.deny_needles) |deny| {
        if (std.mem.indexOf(u8, args, deny) != null) return false;
    }
    const exe = firstToken(args);
    const base = basename(exe);
    for (rule.basenames) |bn| {
        if (std.mem.eql(u8, base, bn)) return true;
    }
    for (rule.path_needles) |needle| {
        if (std.mem.indexOf(u8, args, needle) != null) return true;
    }
    // Amazon Q CLI often installed as bare `q` under homebrew/local.
    if (rule.id == .amazon_q and std.mem.eql(u8, base, "q")) {
        if (std.mem.indexOf(u8, exe, "homebrew") != null) return true;
        if (std.mem.indexOf(u8, exe, "/.local/") != null) return true;
        if (std.mem.endsWith(u8, exe, "/bin/q")) return true;
        return false;
    }
    // Warp ships a binary named `stable` only under Warp.app.
    if (rule.id == .warp and std.mem.eql(u8, base, "stable")) {
        return std.mem.indexOf(u8, args, "Warp.app") != null;
    }
    return false;
}

const PsProc = struct {
    pid: u32,
    ppid: u32,
    is_warp: bool,
    agent: ?AgentId,
};

/// Parse `ps -axo pid=,ppid=,args=` (also accepts legacy `pid=,args=`).
/// Marks agents whose parent chain includes Warp.app with `via_warp`.
pub fn scanPs(stdout: []const u8) ScanResult {
    const max_procs = 512;
    var procs: [max_procs]PsProc = undefined;
    var proc_n: usize = 0;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        if (proc_n >= max_procs) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = parsePsLine(line) orelse continue;
        var agent: ?AgentId = null;
        const is_warp = matchRule(findRule(.warp), parsed.args);
        if (!is_warp) {
            for (rules) |rule| {
                if (rule.id == .warp) continue;
                if (matchRule(rule, parsed.args)) {
                    agent = rule.id;
                    break;
                }
            }
        }
        procs[proc_n] = .{
            .pid = parsed.pid,
            .ppid = parsed.ppid,
            .is_warp = is_warp,
            .agent = agent,
        };
        proc_n += 1;
    }

    var result: ScanResult = .{};
    for (procs[0..proc_n]) |p| {
        if (p.is_warp) result.addProcess(.warp);
    }
    for (procs[0..proc_n]) |p| {
        const id = p.agent orelse continue;
        const under_warp = ancestorIsWarp(procs[0..proc_n], p.ppid);
        result.addProcessFlags(id, under_warp);
    }
    return result;
}

const ParsedPs = struct { pid: u32, ppid: u32, args: []const u8 };

fn parsePsLine(line: []const u8) ?ParsedPs {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const pid = parseUint(line, &i) orelse return null;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    var ppid: u32 = 0;
    const save = i;
    if (parseUint(line, &i)) |pp| {
        var j = i;
        while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
        if (j < line.len) {
            ppid = pp;
            i = j;
        } else {
            i = save;
        }
    }
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len) return null;
    return .{ .pid = pid, .ppid = ppid, .args = line[i..] };
}

fn parseUint(line: []const u8, i: *usize) ?u32 {
    const start = i.*;
    while (i.* < line.len and line[i.*] >= '0' and line[i.*] <= '9') : (i.* += 1) {}
    if (i.* == start) return null;
    return std.fmt.parseInt(u32, line[start..i.*], 10) catch null;
}

fn ancestorIsWarp(procs: []const PsProc, start_ppid: u32) bool {
    var pid = start_ppid;
    var hop: usize = 0;
    while (hop < 32 and pid > 0) : (hop += 1) {
        var found = false;
        for (procs) |p| {
            if (p.pid != pid) continue;
            if (p.is_warp) return true;
            pid = p.ppid;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return false;
}

pub const AgentsSignals = struct {
    has_active: bool = false,
    count: u32 = 0,
    parsed: bool = false,
};

pub fn parseAgentsJson(stdout: []const u8) AgentsSignals {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return .{};
    if (trimmed[0] != '[') return .{};
    if (std.mem.eql(u8, trimmed, "[]")) {
        return .{ .parsed = true, .has_active = false, .count = 0 };
    }
    var count: u32 = 0;
    var depth: i32 = 0;
    for (trimmed) |c| {
        if (c == '[') depth += 1;
        if (c == ']') depth -= 1;
        if (c == '{' and depth == 1) count +%= 1;
    }
    return .{ .parsed = true, .has_active = count > 0, .count = count };
}

/// Merge CLI active sessions into scan result.
pub fn applyClaudeAgents(scan: *ScanResult, agents: AgentsSignals) void {
    if (agents.parsed and agents.has_active) {
        scan.markCli(.claude);
    }
}

pub fn statusTitle(scan: *const ScanResult) []const u8 {
    const p = scan.primary() orelse return "Idle";
    // Fixed strings for menu bar (no alloc).
    return switch (p) {
        .claude => "Claude · Running",
        .codex => "Codex · Running",
        .cursor => "Cursor · Running",
        .cursor_agent => "Cursor Agent · Running",
        .copilot => "Copilot · Running",
        .aider => "Aider · Running",
        .gemini => "Gemini · Running",
        .amp => "Amp · Running",
        .opencode => "OpenCode · Running",
        .goose => "Goose · Running",
        .cline => "Cline · Running",
        .windsurf => "Windsurf · Running",
        .codeium => "Codeium · Running",
        .zed => "Zed · Running",
        .continue_ => "Continue · Running",
        .amazon_q => "Amazon Q · Running",
        .roo => "Roo · Running",
        .augment => "Augment · Running",
        .openhands => "OpenHands · Running",
        .warp => "Warp · Running",
        .pi => "Pi · Running",
        .grok => "Grok · Running",
    };
}

/// Format "Claude, Codex, Cursor" into buf; returns written slice.
pub fn formatAgentsLine(scan: *const ScanResult, buf: []u8) []const u8 {
    if (scan.count == 0) {
        const msg = "none";
        const n = @min(msg.len, buf.len);
        @memcpy(buf[0..n], msg[0..n]);
        return buf[0..n];
    }
    var i: usize = 0;
    var first = true;
    for (priority_order) |id| {
        if (!scan.contains(id)) continue;
        const name = id.displayName();
        if (!first) {
            if (i + 2 > buf.len) break;
            buf[i] = ',';
            buf[i + 1] = ' ';
            i += 2;
        }
        first = false;
        if (i + name.len > buf.len) break;
        @memcpy(buf[i .. i + name.len], name);
        i += name.len;
    }
    return buf[0..i];
}

// ---------------------------------------------------------------- helpers

fn firstToken(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return "";
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sp| return trimmed[0..sp];
    return trimmed;
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
    return path;
}

fn skipLeadingPid(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == start) return line;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return line[i..];
}

// ----------------------------------------------------------------- tests

test "rule table covers at least 15 agents" {
    try std.testing.expect(rules.len >= 15);
    try std.testing.expect(AgentId.all().len >= 15);
}

test "claude and codex hit/miss" {
    try std.testing.expect(matchRule(rules[0], "/Users/me/.local/bin/claude"));
    try std.testing.expect(!matchRule(rules[0], "/Applications/Claude.app/Contents/Helpers/chrome-native-host"));
    try std.testing.expect(matchRule(rules[1], "/opt/homebrew/bin/codex"));
    try std.testing.expect(!matchRule(rules[1], "x/Codex Framework/x/Codex (Service)"));
}

test "cursor shell and cursor-agent both match (shell counts)" {
    try std.testing.expect(matchRule(findRule(.cursor), "/Applications/Cursor.app/Contents/MacOS/Cursor"));
    try std.testing.expect(matchRule(findRule(.cursor_agent), "/Users/me/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/bin/cursor-agent"));
    try std.testing.expect(!matchRule(findRule(.cursor), "chrome_crashpad_handler Cursor.app"));
}

test "amp excludes system AMP agents" {
    try std.testing.expect(matchRule(findRule(.amp), "/Users/me/.local/bin/amp"));
    try std.testing.expect(!matchRule(findRule(.amp), "/System/Library/PrivateFrameworks/AMPLibrary.framework/Versions/A/Support/AMPLibraryAgent"));
}

test "scanPs marks via Warp from parent chain" {
    const sample =
        \\  100 1 /Applications/Warp.app/Contents/MacOS/stable
        \\  200 100 -zsh
        \\  300 200 /Users/me/.local/bin/claude
        \\  400 1 /opt/homebrew/bin/codex
        \\
    ;
    const scan = scanPs(sample);
    try std.testing.expect(scan.contains(.claude));
    try std.testing.expect(scan.contains(.codex));
    try std.testing.expect(scan.viaWarp(.claude));
    try std.testing.expect(!scan.viaWarp(.codex));
    try std.testing.expect(scan.contains(.warp));
}

test "scanPs multi agent primary is highest priority" {
    const sample =
        \\  1 0 /Applications/Cursor.app/Contents/MacOS/Cursor
        \\  2 1 /Users/me/.local/bin/claude
        \\  3 1 /opt/homebrew/bin/codex
        \\  4 1 /Applications/Warp.app/Contents/MacOS/stable
        \\
    ;
    const scan = scanPs(sample);
    try std.testing.expect(scan.contains(.claude));
    try std.testing.expect(scan.contains(.codex));
    try std.testing.expect(scan.contains(.cursor));
    try std.testing.expect(scan.contains(.warp));
    try std.testing.expectEqual(AgentId.claude, scan.primary().?);
    try std.testing.expectEqualStrings("Claude · Running", statusTitle(&scan));
}

test "each of 15 core agents has a positive fixture" {
    const fixtures = [_]struct { AgentId, []const u8 }{
        .{ .claude, "/Users/x/.local/bin/claude --print" },
        .{ .codex, "/opt/homebrew/bin/codex" },
        .{ .cursor, "/Applications/Cursor.app/Contents/MacOS/Cursor" },
        .{ .cursor_agent, ".../anysphere.cursor-agent-worker/.../cursor-agent" },
        .{ .copilot, "/usr/local/bin/copilot" },
        .{ .aider, "/Users/x/.local/bin/aider" },
        .{ .gemini, "/opt/homebrew/bin/gemini" },
        .{ .amp, "/Users/x/.local/bin/amp" },
        .{ .opencode, "/usr/local/bin/opencode" },
        .{ .goose, "/Users/x/.local/bin/goose" },
        .{ .cline, "node .../saoudrizwan.claude-dev/extension.js" },
        .{ .windsurf, "/Applications/Windsurf.app/Contents/MacOS/Windsurf" },
        .{ .codeium, "/Users/x/codeium/language_server_macos" },
        .{ .amazon_q, "/opt/homebrew/bin/q" },
        .{ .openhands, "/usr/local/bin/openhands" },
        .{ .pi, "/opt/homebrew/bin/pi" },
        .{ .grok, "/Users/me/.grok/bin/grok" },
    };
    try std.testing.expect(fixtures.len >= 15);
    for (fixtures) |fx| {
        const id = fx[0];
        const line = fx[1];
        try std.testing.expect(matchRule(findRule(id), line));
    }
}

test "parseAgentsJson and applyClaudeAgents" {
    var scan = scanPs("");
    applyClaudeAgents(&scan, parseAgentsJson("[]"));
    try std.testing.expectEqual(@as(usize, 0), scan.count);
    applyClaudeAgents(&scan, parseAgentsJson("[{\"id\":1}]"));
    try std.testing.expect(scan.contains(.claude));
    try std.testing.expectEqualStrings("Claude · Running", statusTitle(&scan));
}

test "formatAgentsLine" {
    var scan = scanPs(
        \\1 /Users/x/.local/bin/claude
        \\2 /opt/homebrew/bin/codex
        \\
    );
    var buf: [128]u8 = undefined;
    const line = formatAgentsLine(&scan, &buf);
    try std.testing.expect(std.mem.indexOf(u8, line, "Claude") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "Codex") != null);
}

test "pi and grok rules hit and avoid pip" {
    try std.testing.expect(matchRule(findRule(.pi), "/opt/homebrew/bin/pi"));
    try std.testing.expect(matchRule(findRule(.pi), "node .../pi-coding-agent/dist/cli.js"));
    try std.testing.expect(!matchRule(findRule(.pi), "/opt/homebrew/bin/pip3"));
    try std.testing.expect(matchRule(findRule(.grok), "/Users/me/.grok/bin/grok"));
    try std.testing.expect(matchRule(findRule(.grok), "/bin/zsh -c ... GROK_AGENT=1 ..."));
    const scan = scanPs(
        \\  1 /opt/homebrew/bin/pi
        \\  2 /Users/me/.grok/bin/grok
        \\
    );
    try std.testing.expect(scan.contains(.pi));
    try std.testing.expect(scan.contains(.grok));
    // grok ranks above pi in priority_order after codex; both after claude
    try std.testing.expectEqual(AgentId.grok, scan.primary().?);
}

fn findRule(id: AgentId) Rule {
    for (rules) |r| {
        if (r.id == id) return r;
    }
    unreachable;
}
