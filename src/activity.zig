//! Activity details for concurrent agents: task, tokens, last tool/skill, project.
//! Pure parsers over TSV harvest lines and multi-agent title formatting.

const std = @import("std");
const probe = @import("probe.zig");

pub const max_activities = 8;
pub const task_cap = 160;
pub const name_cap = 48;
pub const cwd_cap = 240;

pub const Activity = struct {
    id: probe.AgentId = .claude,
    task_buf: [task_cap]u8 = undefined,
    task_len: usize = 0,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    tool_buf: [name_cap]u8 = undefined,
    tool_len: usize = 0,
    skill_buf: [name_cap]u8 = undefined,
    skill_len: usize = 0,
    project_buf: [name_cap]u8 = undefined,
    project_len: usize = 0,
    cwd_buf: [cwd_cap]u8 = undefined,
    cwd_len: usize = 0,

    pub fn task(self: *const Activity) []const u8 {
        if (self.task_len == 0) return "";
        return self.task_buf[0..self.task_len];
    }
    pub fn tool(self: *const Activity) []const u8 {
        if (self.tool_len == 0) return "";
        return self.tool_buf[0..self.tool_len];
    }
    pub fn skill(self: *const Activity) []const u8 {
        if (self.skill_len == 0) return "";
        return self.skill_buf[0..self.skill_len];
    }
    pub fn project(self: *const Activity) []const u8 {
        if (self.project_len == 0) return "";
        return self.project_buf[0..self.project_len];
    }
    pub fn cwd(self: *const Activity) []const u8 {
        if (self.cwd_len == 0) return "";
        return self.cwd_buf[0..self.cwd_len];
    }
    pub fn name(self: *const Activity) []const u8 {
        return self.id.displayName();
    }

    pub fn hasTask(self: *const Activity) bool {
        const t = self.task();
        return t.len > 0 and !std.mem.eql(u8, t, "-") and !std.mem.eql(u8, t, "—");
    }
    pub fn hasTokens(self: *const Activity) bool {
        return self.tokens_in != 0 or self.tokens_out != 0;
    }
    pub fn hasToolOrSkill(self: *const Activity) bool {
        return self.tool().len > 0 or self.skill().len > 0;
    }
    pub fn hasProject(self: *const Activity) bool {
        const p = self.project();
        return p.len > 0 and !std.mem.eql(u8, p, "-") and !std.mem.eql(u8, p, "—");
    }
    pub fn hasCwd(self: *const Activity) bool {
        const c = self.cwd();
        return c.len > 1 and c[0] == '/';
    }
    pub fn totalTokens(self: *const Activity) u64 {
        return self.tokens_in +% self.tokens_out;
    }

    pub fn setTask(self: *Activity, s: []const u8) void {
        const n = @min(s.len, task_cap);
        @memcpy(self.task_buf[0..n], s[0..n]);
        self.task_len = n;
    }
    pub fn setTool(self: *Activity, s: []const u8) void {
        const n = @min(s.len, name_cap);
        @memcpy(self.tool_buf[0..n], s[0..n]);
        self.tool_len = n;
    }
    pub fn setSkill(self: *Activity, s: []const u8) void {
        const n = @min(s.len, name_cap);
        @memcpy(self.skill_buf[0..n], s[0..n]);
        self.skill_len = n;
    }
    pub fn setProject(self: *Activity, s: []const u8) void {
        const n = @min(s.len, name_cap);
        if (n > 0) @memcpy(self.project_buf[0..n], s[0..n]);
        self.project_len = n;
    }
    pub fn setCwd(self: *Activity, s: []const u8) void {
        const n = @min(s.len, cwd_cap);
        if (n > 0) @memcpy(self.cwd_buf[0..n], s[0..n]);
        self.cwd_len = n;
    }

    /// Empty when no tokens — never placeholder noise.
    pub fn tokensLine(self: *const Activity, arena: std.mem.Allocator) []const u8 {
        if (!self.hasTokens()) return "";
        return std.fmt.allocPrint(arena, "Tokens {d} in · {d} out", .{ self.tokens_in, self.tokens_out }) catch "";
    }

    /// Compact tool/skill line; empty if both missing.
    pub fn toolSkillLine(self: *const Activity, arena: std.mem.Allocator) []const u8 {
        const t = self.tool();
        const s = self.skill();
        if (t.len == 0 and s.len == 0) return "";
        if (t.len > 0 and s.len > 0) {
            return std.fmt.allocPrint(arena, "Tool {s} · Skill {s}", .{ t, s }) catch "";
        }
        if (t.len > 0) return std.fmt.allocPrint(arena, "Tool {s}", .{t}) catch t;
        return std.fmt.allocPrint(arena, "Skill {s}", .{s}) catch s;
    }
};

pub fn parseAgentId(name: []const u8) ?probe.AgentId {
    if (std.mem.eql(u8, name, "claude")) return .claude;
    if (std.mem.eql(u8, name, "codex")) return .codex;
    if (std.mem.eql(u8, name, "grok")) return .grok;
    if (std.mem.eql(u8, name, "pi")) return .pi;
    if (std.mem.eql(u8, name, "cursor")) return .cursor;
    if (std.mem.eql(u8, name, "cursor_agent")) return .cursor_agent;
    if (std.mem.eql(u8, name, "amp")) return .amp;
    if (std.mem.eql(u8, name, "copilot")) return .copilot;
    return null;
}

/// Parse one TSV line: agent\ttask\tin\tout\ttool\tskill[\tproject[\tcwd]]
pub fn parseTsvLine(line: []const u8) ?Activity {
    var it = std.mem.splitScalar(u8, line, '\t');
    const agent_s = it.next() orelse return null;
    const task_s = it.next() orelse "";
    const in_s = it.next() orelse "0";
    const out_s = it.next() orelse "0";
    const tool_s = it.next() orelse "";
    const skill_s = it.next() orelse "";
    const project_s = it.next() orelse "";
    const cwd_s = it.next() orelse "";
    const id = parseAgentId(std.mem.trim(u8, agent_s, " \r")) orelse return null;
    var a: Activity = .{ .id = id };
    a.setTask(task_s);
    a.tokens_in = std.fmt.parseInt(u64, std.mem.trim(u8, in_s, " "), 10) catch 0;
    a.tokens_out = std.fmt.parseInt(u64, std.mem.trim(u8, out_s, " "), 10) catch 0;
    a.setTool(tool_s);
    a.setSkill(skill_s);
    a.setProject(std.mem.trim(u8, project_s, " \r"));
    a.setCwd(std.mem.trim(u8, cwd_s, " \r"));
    return a;
}

pub fn parseTsvAll(text: []const u8, out: []Activity) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (count >= out.len) break;
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        if (parseTsvLine(line)) |act| {
            out[count] = act;
            count += 1;
        }
    }
    return count;
}

/// Filter harvest activities to agents currently detected in scan (or keep all if scan empty).
pub fn filterToScan(scan: *const probe.ScanResult, src: []const Activity, out: []Activity) usize {
    var count: usize = 0;
    for (src) |a| {
        if (count >= out.len) break;
        if (scan.count == 0 or scan.contains(a.id) or a.id == .cursor) {
            out[count] = a;
            count += 1;
        }
    }
    // Ensure each scanned high-value agent has a row even without harvest.
    const interesting = [_]probe.AgentId{ .claude, .codex, .grok, .pi, .cursor, .cursor_agent, .amp };
    for (interesting) |id| {
        if (count >= out.len) break;
        if (!scan.contains(id)) continue;
        var found = false;
        for (out[0..count]) |row| {
            if (row.id == id) {
                found = true;
                break;
            }
        }
        if (!found) {
            // Empty task: tray/Preferences omit noise placeholders.
            out[count] = .{ .id = id };
            count += 1;
        }
    }
    return count;
}

/// Glance-layer menu bar title: surface agents only.
/// Single → name; multi → "{N}"; empty → "" (icon-only idle).
pub fn formatMultiTitle(scan: *const probe.ScanResult, buf: []u8) []const u8 {
    const n = scan.surfaceCount();
    if (n == 0) return "";
    const primary = scan.surfacePrimary() orelse return "";
    if (n == 1) return primary.displayName();
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch primary.displayName();
}

// ----------------------------------------------------------------- tests

test "parseTsvLine claude activity" {
    const line = "claude\tInstall opencode\t12345\t678\tBash\tmy-skill\tPulse";
    const a = parseTsvLine(line).?;
    try std.testing.expectEqual(probe.AgentId.claude, a.id);
    try std.testing.expectEqualStrings("Install opencode", a.task());
    try std.testing.expectEqual(@as(u64, 12345), a.tokens_in);
    try std.testing.expectEqual(@as(u64, 678), a.tokens_out);
    try std.testing.expectEqualStrings("Bash", a.tool());
    try std.testing.expectEqualStrings("my-skill", a.skill());
    try std.testing.expectEqualStrings("Pulse", a.project());
    try std.testing.expect(a.hasProject());
}

test "parseTsvAll multiple agents" {
    const text =
        \\claude\tTask A\t10\t2\tRead\t—
        \\codex\tTask B\t100\t20\texec_command\t
        \\grok\tTask C\t0\t0\trun_terminal_command\tcreate-skill
        \\
    ;
    var out: [8]Activity = undefined;
    // Fix: the above has literal \t in source wrong - use real tabs in test below
    _ = text;
    const real =
        "claude\tTask A\t10\t2\tRead\t-\n" ++
        "codex\tTask B\t100\t20\texec_command\t\n" ++
        "grok\tTask C\t0\t0\trun_terminal_command\tcreate-skill\n";
    const n = parseTsvAll(real, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(probe.AgentId.codex, out[1].id);
}

test "formatMultiTitle concurrent" {
    var scan: probe.ScanResult = .{};
    scan.addProcess(.claude);
    scan.addProcess(.codex);
    scan.addProcess(.grok);
    var buf: [64]u8 = undefined;
    const title = formatMultiTitle(&scan, &buf);
    try std.testing.expectEqualStrings("3", title);
}

test "filterToScan keeps detected agents" {
    var scan: probe.ScanResult = .{};
    scan.addProcess(.claude);
    scan.addProcess(.pi);
    const src = [_]Activity{
        blk: {
            var a: Activity = .{ .id = .claude };
            a.setTask("T1");
            break :blk a;
        },
        blk: {
            var a: Activity = .{ .id = .codex };
            a.setTask("T2");
            break :blk a;
        },
    };
    var out: [8]Activity = undefined;
    const n = filterToScan(&scan, &src, &out);
    // claude from harvest + pi stub (detected but no harvest)
    try std.testing.expect(n >= 2);
    try std.testing.expect(out[0].id == .claude or out[1].id == .claude);
}
