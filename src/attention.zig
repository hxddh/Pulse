//! v2 attention / Waiting state from agent hooks.
//!
//! Pulse polls a small TSV written by `pulse_hook.py` (Claude Notification /
//! Stop hooks, Codex notify). Kinds that need the user set Attention;
//! stop/done clear that agent.

const std = @import("std");
const probe = @import("probe.zig");

pub const max_entries = 8;
pub const message_cap = 120;

/// How long a waiting signal stays valid without refresh (ms).
pub const attention_ttl_ms: i64 = 30 * 60 * 1000;

pub const Kind = enum {
    permission,
    idle_prompt,
    waiting,
    stop,
    done,
    unknown,

    pub fn needsUser(self: Kind) bool {
        return switch (self) {
            .permission, .idle_prompt, .waiting => true,
            .stop, .done, .unknown => false,
        };
    }

    pub fn parse(s: []const u8) Kind {
        if (std.mem.eql(u8, s, "permission") or std.mem.eql(u8, s, "permission_prompt")) return .permission;
        if (std.mem.eql(u8, s, "idle_prompt") or std.mem.eql(u8, s, "idle")) return .idle_prompt;
        if (std.mem.eql(u8, s, "waiting") or std.mem.eql(u8, s, "needs_input") or std.mem.eql(u8, s, "agent_needs_input")) return .waiting;
        if (std.mem.eql(u8, s, "stop") or std.mem.eql(u8, s, "Stop")) return .stop;
        if (std.mem.eql(u8, s, "done") or std.mem.eql(u8, s, "agent-turn-complete") or std.mem.eql(u8, s, "agent_completed")) return .done;
        return .unknown;
    }

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .permission => "Permission",
            .idle_prompt => "Idle prompt",
            .waiting => "Waiting",
            .stop => "Stop",
            .done => "Done",
            .unknown => "Signal",
        };
    }

    /// Chinese short label for UI.
    pub fn labelCn(self: Kind) []const u8 {
        return switch (self) {
            .permission => "需要授权",
            .idle_prompt => "等待输入",
            .waiting => "等待中",
            .stop => "已结束",
            .done => "已完成",
            .unknown => "有信号",
        };
    }
};

pub const Entry = struct {
    id: probe.AgentId = .claude,
    kind: Kind = .waiting,
    ts_ms: i64 = 0,
    message_buf: [message_cap]u8 = undefined,
    message_len: usize = 0,

    pub fn message(self: *const Entry) []const u8 {
        if (self.message_len == 0) return "";
        return self.message_buf[0..self.message_len];
    }

    pub fn setMessage(self: *Entry, s: []const u8) void {
        const n = @min(s.len, message_cap);
        if (n > 0) @memcpy(self.message_buf[0..n], s[0..n]);
        self.message_len = n;
    }
};

pub const State = struct {
    entries: [max_entries]Entry = undefined,
    count: usize = 0,

    pub fn slice(self: *const State) []const Entry {
        return self.entries[0..self.count];
    }

    pub fn contains(self: *const State, id: probe.AgentId) bool {
        for (self.entries[0..self.count]) |e| {
            if (e.id == id) return true;
        }
        return false;
    }

    pub fn kindFor(self: *const State, id: probe.AgentId) ?Kind {
        for (self.entries[0..self.count]) |e| {
            if (e.id == id) return e.kind;
        }
        return null;
    }

    pub fn entryFor(self: *const State, id: probe.AgentId) ?*const Entry {
        for (self.entries[0..self.count]) |*e| {
            if (e.id == id) return e;
        }
        return null;
    }

    pub fn clear(self: *State) void {
        self.count = 0;
    }

    fn upsert(self: *State, entry: Entry) void {
        for (self.entries[0..self.count]) |*e| {
            if (e.id == entry.id) {
                e.* = entry;
                return;
            }
        }
        if (self.count >= max_entries) return;
        self.entries[self.count] = entry;
        self.count += 1;
    }

    fn remove(self: *State, id: probe.AgentId) void {
        var i: usize = 0;
        while (i < self.count) {
            if (self.entries[i].id == id) {
                var j = i;
                while (j + 1 < self.count) : (j += 1) {
                    self.entries[j] = self.entries[j + 1];
                }
                self.count -= 1;
                continue;
            }
            i += 1;
        }
    }
};

fn parseAgent(name: []const u8) ?probe.AgentId {
    if (std.mem.eql(u8, name, "claude")) return .claude;
    if (std.mem.eql(u8, name, "codex")) return .codex;
    if (std.mem.eql(u8, name, "grok")) return .grok;
    if (std.mem.eql(u8, name, "pi")) return .pi;
    if (std.mem.eql(u8, name, "cursor")) return .cursor;
    if (std.mem.eql(u8, name, "cursor_agent")) return .cursor_agent;
    if (std.mem.eql(u8, name, "gemini")) return .gemini;
    if (std.mem.eql(u8, name, "copilot")) return .copilot;
    if (std.mem.eql(u8, name, "opencode")) return .opencode;
    if (std.mem.eql(u8, name, "amp")) return .amp;
    return null;
}

/// Parse TSV lines: agent\tkind\tunix_ms\tmessage
/// Later lines for the same agent win. Clear kinds remove attention.
pub fn parseTsv(text: []const u8, now_ms: i64, out: *State) void {
    out.clear();
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const agent_s = cols.next() orelse continue;
        const kind_s = cols.next() orelse continue;
        const ts_s = cols.next() orelse "0";
        const msg_s = cols.next() orelse "";
        const id = parseAgent(agent_s) orelse continue;
        const kind = Kind.parse(kind_s);
        const ts = std.fmt.parseInt(i64, ts_s, 10) catch 0;
        if (!kind.needsUser()) {
            out.remove(id);
            continue;
        }
        if (ts > 0 and now_ms > 0 and now_ms - ts > attention_ttl_ms) continue;
        var e: Entry = .{ .id = id, .kind = kind, .ts_ms = ts };
        e.setMessage(msg_s);
        out.upsert(e);
    }
}

/// True if `next` has any agent not in `prev` (new waiting signal).
pub fn hasNewAttention(prev: *const State, next: *const State) bool {
    for (next.entries[0..next.count]) |e| {
        if (!prev.contains(e.id)) return true;
    }
    return false;
}

test "parseTsv permission and stop" {
    const text =
        "claude\tpermission\t1000\tAllow bash?\n" ++
        "codex\tidle_prompt\t1001\t\n" ++
        "claude\tstop\t1002\t\n";
    var state: State = .{};
    parseTsv(text, 2000, &state);
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expect(state.contains(.codex));
    try std.testing.expect(!state.contains(.claude));
    try std.testing.expectEqual(Kind.idle_prompt, state.kindFor(.codex).?);
}

test "ttl drops stale waiting" {
    const text = "claude\twaiting\t1000\told\n";
    var state: State = .{};
    parseTsv(text, 1000 + attention_ttl_ms + 1, &state);
    try std.testing.expectEqual(@as(usize, 0), state.count);
}

test "hasNewAttention detects edges" {
    var prev: State = .{};
    var next: State = .{};
    const e: Entry = .{ .id = .claude, .kind = .permission, .ts_ms = 1 };
    next.upsert(e);
    try std.testing.expect(hasNewAttention(&prev, &next));
    prev.upsert(e);
    try std.testing.expect(!hasNewAttention(&prev, &next));
}
