//! Multi-language strings for Pulse (en / zh-Hans).
//! Agent product names stay English in every locale.

const std = @import("std");

pub const Locale = enum {
    en,
    zh,

    pub fn code(self: Locale) []const u8 {
        return switch (self) {
            .en => "en",
            .zh => "zh",
        };
    }

    pub fn displayName(self: Locale, view: Locale) []const u8 {
        return switch (view) {
            .en => switch (self) {
                .en => "English",
                .zh => "Chinese",
            },
            .zh => switch (self) {
                .en => "English",
                .zh => "中文",
            },
        };
    }
};

/// User preference; auto follows system.
pub const LangPref = enum {
    auto,
    en,
    zh,

    pub fn parse(s: []const u8) LangPref {
        if (std.mem.eql(u8, s, "en")) return .en;
        if (std.mem.eql(u8, s, "zh") or std.mem.eql(u8, s, "zh-Hans") or std.mem.eql(u8, s, "zh_CN")) return .zh;
        return .auto;
    }

    pub fn code(self: LangPref) []const u8 {
        return switch (self) {
            .auto => "auto",
            .en => "en",
            .zh => "zh",
        };
    }

    pub fn resolve(self: LangPref, system: Locale) Locale {
        return switch (self) {
            .auto => system,
            .en => .en,
            .zh => .zh,
        };
    }

    pub fn cycle(self: LangPref) LangPref {
        return switch (self) {
            .auto => .en,
            .en => .zh,
            .zh => .auto,
        };
    }
};

/// Detect from a process environ map (Zig 0.16 has no std.posix.getenv).
pub fn detectSystemLocale(env: anytype) Locale {
    const keys = [_][]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" };
    for (keys) |k| {
        if (env.get(k)) |v| {
            if (v.len >= 2 and (std.mem.startsWith(u8, v, "zh") or std.mem.startsWith(u8, v, "ZH"))) return .zh;
        }
    }
    return .en;
}

/// Fallback when no env map is available (tests).
pub fn detectSystemLocaleDefault() Locale {
    return .en;
}

pub const Key = enum {
    // Glance / states
    idle,
    error_short,
    running_short,
    waiting_short,
    // Tray status words
    status_running,
    status_waiting,
    // Tray summary
    cannot_refresh,
    needs_you,
    one_running,
    // Tray actions
    refresh,
    preferences,
    quit,
    more_agents,
    empty_tray_hint,
    // Prefs chrome
    prefs_title,
    refresh_a11y,
    section_status,
    section_agents,
    section_settings,
    section_connect,
    section_language,
    empty_title,
    empty_body,
    live_updates,
    notifications,
    connect_title,
    connect_body,
    install_hooks,
    language_label,
    lang_auto,
    login_at_start,
    dismiss_waiting,
    open_project,
    // Meta / hooks status
    could_not_refresh,
    needs_attention,
    no_agents,
    hooks_installing,
    hooks_ok,
    hooks_fail,
    hooks_need_app,
    // Notifications (osascript English ok; also localized)
    notify_idle_body,
    notify_wait_body,
    // Kind labels (attention)
    kind_permission,
    kind_idle_prompt,
    kind_waiting,
    kind_stop,
    kind_done,
    kind_unknown,
};

const Entry = struct { en: []const u8, zh: []const u8 };

fn entry(key: Key) Entry {
    return switch (key) {
        .idle => .{ .en = "Idle", .zh = "空闲" },
        .error_short => .{ .en = "Error", .zh = "错误" },
        .running_short => .{ .en = "Running", .zh = "运行中" },
        .waiting_short => .{ .en = "Waiting", .zh = "等待中" },
        .status_running => .{ .en = "running", .zh = "运行中" },
        .status_waiting => .{ .en = "waiting", .zh = "等待中" },
        .cannot_refresh => .{ .en = "Can't refresh", .zh = "无法刷新" },
        .needs_you => .{ .en = "Needs you", .zh = "需要你处理" },
        .one_running => .{ .en = "1 running", .zh = "1 个运行中" },
        .refresh => .{ .en = "Refresh", .zh = "刷新" },
        .preferences => .{ .en = "Preferences…", .zh = "偏好设置…" },
        .quit => .{ .en = "Quit Pulse", .zh = "退出 Pulse" },
        .more_agents => .{ .en = "+{d} more…", .zh = "另有 {d} 个…" },
        .empty_tray_hint => .{ .en = "○  No coding agents", .zh = "○  当前没有编码 Agent" },
        .prefs_title => .{ .en = "Pulse", .zh = "Pulse" },
        .refresh_a11y => .{ .en = "Refresh", .zh = "刷新状态" },
        .section_status => .{ .en = "Status", .zh = "状态" },
        .section_agents => .{ .en = "Agents", .zh = "Agent" },
        .section_settings => .{ .en = "General", .zh = "通用" },
        .section_connect => .{ .en = "Waiting signals", .zh = "等待信号" },
        .section_language => .{ .en = "Language", .zh = "语言" },
        .empty_title => .{ .en = "No agents running", .zh = "当前没有运行中的 Agent" },
        .empty_body => .{ .en = "Start Claude, Codex, or another tool to see it here", .zh = "启动 Claude、Codex 等工具后会显示在这里" },
        .live_updates => .{ .en = "Live updates", .zh = "实时更新" },
        .notifications => .{ .en = "Notifications", .zh = "状态通知" },
        .connect_title => .{ .en = "Claude / Codex hooks", .zh = "Claude / Codex 连接" },
        .connect_body => .{ .en = "Enables Waiting when an agent needs permission or input", .zh = "安装后可显示等待授权 / 等待输入状态" },
        .install_hooks => .{ .en = "Install hooks", .zh = "安装连接" },
        .language_label => .{ .en = "Language", .zh = "语言" },
        .lang_auto => .{ .en = "System", .zh = "系统" },
        .login_at_start => .{ .en = "Launch at login", .zh = "登录时启动" },
        .dismiss_waiting => .{ .en = "Dismiss waiting", .zh = "清除等待" },
        .open_project => .{ .en = "Open project", .zh = "打开项目" },
        .could_not_refresh => .{ .en = "Could not refresh", .zh = "无法刷新" },
        .needs_attention => .{ .en = "Needs attention", .zh = "需要你处理" },
        .no_agents => .{ .en = "No agents", .zh = "未检测到 Agent" },
        .hooks_installing => .{ .en = "Installing…", .zh = "正在安装…" },
        .hooks_ok => .{ .en = "Hooks installed", .zh = "连接已安装" },
        .hooks_fail => .{ .en = "Install failed — see README", .zh = "安装失败，请查看 README" },
        .hooks_need_app => .{ .en = "Open the app fully, then try again", .zh = "请完整启动应用后再试" },
        .notify_idle_body => .{ .en = "All agents are idle", .zh = "所有 Agent 已空闲" },
        .notify_wait_body => .{ .en = "An agent needs your attention", .zh = "有 Agent 需要你处理" },
        .kind_permission => .{ .en = "Permission", .zh = "需要授权" },
        .kind_idle_prompt => .{ .en = "Idle prompt", .zh = "等待输入" },
        .kind_waiting => .{ .en = "Waiting", .zh = "等待中" },
        .kind_stop => .{ .en = "Stop", .zh = "已结束" },
        .kind_done => .{ .en = "Done", .zh = "已完成" },
        .kind_unknown => .{ .en = "Signal", .zh = "有信号" },
    };
}

pub fn t(locale: Locale, key: Key) []const u8 {
    const e = entry(key);
    return switch (locale) {
        .en => e.en,
        .zh => e.zh,
    };
}

/// Format helpers with one integer (fmt strings must be comptime).
pub fn fmt1(locale: Locale, key: Key, buf: []u8, n: u64) []const u8 {
    return switch (key) {
        .more_agents => switch (locale) {
            .en => std.fmt.bufPrint(buf, "+{d} more…", .{n}) catch "+ more…",
            .zh => std.fmt.bufPrint(buf, "另有 {d} 个…", .{n}) catch "更多…",
        },
        else => t(locale, key),
    };
}

pub fn nRunning(locale: Locale, buf: []u8, n: u64) []const u8 {
    return switch (locale) {
        .en => std.fmt.bufPrint(buf, "{d} running", .{n}) catch "running",
        .zh => std.fmt.bufPrint(buf, "{d} 个运行中", .{n}) catch "运行中",
    };
}

pub fn nWaiting(locale: Locale, buf: []u8, n: u64) []const u8 {
    return switch (locale) {
        .en => std.fmt.bufPrint(buf, "{d} waiting", .{n}) catch "waiting",
        .zh => std.fmt.bufPrint(buf, "{d} 项等待", .{n}) catch "等待中",
    };
}

pub fn runningAndWaiting(locale: Locale, buf: []u8, running: u64, waiting: u64) []const u8 {
    return switch (locale) {
        .en => std.fmt.bufPrint(buf, "{d} running · {d} waiting", .{ running, waiting }) catch "busy",
        .zh => std.fmt.bufPrint(buf, "{d} 运行 · {d} 等待", .{ running, waiting }) catch "忙碌",
    };
}

pub fn glanceWaitOne(locale: Locale, buf: []u8, name: []const u8) []const u8 {
    return switch (locale) {
        .en => std.fmt.bufPrint(buf, "{s}…", .{name}) catch name,
        .zh => std.fmt.bufPrint(buf, "{s} 等", .{name}) catch name,
    };
}

pub fn glanceWaitN(locale: Locale, buf: []u8, n: u64) []const u8 {
    return switch (locale) {
        .en => std.fmt.bufPrint(buf, "Wait {d}", .{n}) catch "Wait",
        .zh => std.fmt.bufPrint(buf, "等 {d}", .{n}) catch "等",
    };
}

pub fn glanceRunningN(locale: Locale, buf: []u8, n: u64) []const u8 {
    _ = locale;
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?";
}

pub fn agentRow(locale: Locale, buf: []u8, name: []const u8, waiting: bool) []const u8 {
    _ = locale;
    // Status glyph first (SDK tray items have no icons) — scan before reading the name.
    const mark: []const u8 = if (waiting) "⏸ " else "● ";
    return std.fmt.bufPrint(buf, "{s}{s}", .{ mark, name }) catch name;
}

/// Main tray line with optional project: "● Claude · Pulse" / "⏸ Claude · Pulse"
pub fn agentRowWithProject(locale: Locale, buf: []u8, name: []const u8, project: []const u8, waiting: bool) []const u8 {
    if (project.len == 0) return agentRow(locale, buf, name, waiting);
    const mark: []const u8 = if (waiting) "⏸ " else "● ";
    return std.fmt.bufPrint(buf, "{s}{s} · {s}", .{ mark, name, project }) catch name;
}

/// Tray action lines — leading glyph stands in for missing NSMenuItem images.
pub fn trayAction(locale: Locale, key: Key) []const u8 {
    return switch (key) {
        .refresh => switch (locale) {
            .en => "↻  Refresh",
            .zh => "↻  刷新",
        },
        .preferences => switch (locale) {
            .en => "Prefs…",
            .zh => "偏好设置…",
        },
        .dismiss_waiting => switch (locale) {
            .en => "Clear waiting",
            .zh => "清除等待",
        },
        .quit => switch (locale) {
            .en => "Quit Pulse",
            .zh => "退出 Pulse",
        },
        else => t(locale, key),
    };
}

/// Indented subline under an agent (session / wait reason).
pub fn traySubline(buf: []u8, text: []const u8) []const u8 {
    const prefix = "    ";
    const max_body = if (buf.len > prefix.len + 1) buf.len - prefix.len - 1 else 8;
    if (text.len <= max_body) {
        return std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, text }) catch text;
    }
    return std.fmt.bufPrint(buf, "{s}{s}…", .{ prefix, text[0..max_body] }) catch text;
}

pub fn justNow(locale: Locale) []const u8 {
    return switch (locale) {
        .en => "just now",
        .zh => "刚刚",
    };
}

pub fn secondsAgo(locale: Locale, buf: []u8, s: u64) []const u8 {
    return switch (locale) {
        .en => std.fmt.bufPrint(buf, "{d}s ago", .{s}) catch "recently",
        .zh => std.fmt.bufPrint(buf, "{d} 秒前", .{s}) catch "最近",
    };
}

pub fn minutesAgo(locale: Locale, buf: []u8, m: u64) []const u8 {
    return switch (locale) {
        .en => std.fmt.bufPrint(buf, "{d}m ago", .{m}) catch "recently",
        .zh => std.fmt.bufPrint(buf, "{d} 分钟前", .{m}) catch "最近",
    };
}

pub fn notYet(locale: Locale) []const u8 {
    return switch (locale) {
        .en => "not yet",
        .zh => "尚未刷新",
    };
}

pub fn metaRunning(locale: Locale, buf: []u8, n: u64, updated: []const u8) []const u8 {
    return switch (locale) {
        .en => std.fmt.bufPrint(buf, "{d} running · {s}", .{ n, updated }) catch updated,
        .zh => std.fmt.bufPrint(buf, "{d} 个运行中 · {s}", .{ n, updated }) catch updated,
    };
}

pub fn metaWaiting(locale: Locale, buf: []u8, waiting: u64, running: u64, updated: []const u8) []const u8 {
    return switch (locale) {
        .en => std.fmt.bufPrint(buf, "{d} waiting · {d} running · {s}", .{ waiting, running, updated }) catch updated,
        .zh => std.fmt.bufPrint(buf, "{d} 等待 · {d} 运行 · {s}", .{ waiting, running, updated }) catch updated,
    };
}

pub fn metaIdle(locale: Locale, buf: []u8, updated: []const u8) []const u8 {
    return switch (locale) {
        .en => std.fmt.bufPrint(buf, "No agents · {s}", .{updated}) catch updated,
        .zh => std.fmt.bufPrint(buf, "未检测到 Agent · {s}", .{updated}) catch updated,
    };
}

pub fn metaError(locale: Locale, buf: []u8, err: []const u8) []const u8 {
    return switch (locale) {
        .en => std.fmt.bufPrint(buf, "Could not refresh · {s}", .{err}) catch err,
        .zh => std.fmt.bufPrint(buf, "无法刷新 · {s}", .{err}) catch err,
    };
}

pub fn languageButton(locale: Locale, pref: LangPref, buf: []u8) []const u8 {
    const label = t(locale, .language_label);
    const value: []const u8 = switch (pref) {
        .auto => t(locale, .lang_auto),
        .en => Locale.en.displayName(locale),
        .zh => Locale.zh.displayName(locale),
    };
    return std.fmt.bufPrint(buf, "{s}: {s}", .{ label, value }) catch label;
}

pub fn kindLabel(locale: Locale, kind_tag: []const u8) []const u8 {
    // Map attention.Kind via string to avoid circular import
    if (std.mem.eql(u8, kind_tag, "permission")) return t(locale, .kind_permission);
    if (std.mem.eql(u8, kind_tag, "idle_prompt")) return t(locale, .kind_idle_prompt);
    if (std.mem.eql(u8, kind_tag, "waiting")) return t(locale, .kind_waiting);
    if (std.mem.eql(u8, kind_tag, "stop")) return t(locale, .kind_stop);
    if (std.mem.eql(u8, kind_tag, "done")) return t(locale, .kind_done);
    return t(locale, .kind_unknown);
}

/// Indented project line for tray / prefs context.
pub fn projectLine(locale: Locale, buf: []u8, project: []const u8) []const u8 {
    return switch (locale) {
        .en => std.fmt.bufPrint(buf, "  in {s}", .{project}) catch project,
        .zh => std.fmt.bufPrint(buf, "  在 {s}", .{project}) catch project,
    };
}

pub fn waitSeconds(locale: Locale, buf: []u8, s: u64) []const u8 {
    return switch (locale) {
        .en => std.fmt.bufPrint(buf, "{d}s", .{s}) catch "",
        .zh => std.fmt.bufPrint(buf, "{d} 秒", .{s}) catch "",
    };
}

pub fn waitMinutes(locale: Locale, buf: []u8, m: u64) []const u8 {
    return switch (locale) {
        .en => std.fmt.bufPrint(buf, "{d}m", .{m}) catch "",
        .zh => std.fmt.bufPrint(buf, "{d} 分钟", .{m}) catch "",
    };
}

pub fn waitHours(locale: Locale, buf: []u8, h: u64) []const u8 {
    return switch (locale) {
        .en => std.fmt.bufPrint(buf, "{d}h", .{h}) catch "",
        .zh => std.fmt.bufPrint(buf, "{d} 小时", .{h}) catch "",
    };
}

test "resolve auto defaults" {
    // Just ensure codes parse
    try std.testing.expectEqual(LangPref.en, LangPref.parse("en"));
    try std.testing.expectEqual(LangPref.zh, LangPref.parse("zh"));
    try std.testing.expectEqual(LangPref.auto, LangPref.parse("auto"));
    try std.testing.expectEqualStrings("空闲", t(.zh, .idle));
    try std.testing.expectEqualStrings("Idle", t(.en, .idle));
}
