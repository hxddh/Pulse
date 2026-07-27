//! Pulse: macOS menu-bar runtime awareness for AI coding agents.
//!
//! Multi-language (en / zh) via i18n; CJK Preferences when system font loads.
//! Clarity tray + Preferences; v2 attention/hooks.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const probe = @import("probe.zig");
const activity = @import("activity.zig");
const attention = @import("attention.zig");
const version = @import("version.zig");
const i18n = @import("i18n.zig");
const cjk_font = @import("cjk_font.zig");
const activity_scan_py = @embedFile("activity_scan.py");
const pulse_hook_py = @embedFile("pulse_hook.py");
const install_hooks_py = @embedFile("install_hooks.py");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

/// Re-export for tests / package scripts.
pub const app_version = version.semver;

pub const canvas_label = "pulse-canvas";
pub const window_label = "main";
const window_width: f32 = 380;
const window_height: f32 = 480;

pub const open_command = "app.open";
pub const quit_command = "app.quit";
pub const refresh_command = "pulse.refresh";
pub const auto_command = "pulse.toggle_auto";
pub const install_hooks_command = "pulse.install_hooks";

pub const poll_timer_key: u64 = 1;
pub const probe_ps_key: u64 = 2;
pub const probe_cli_key: u64 = 3;
pub const activity_scan_key: u64 = 6;
pub const activity_script_key: u64 = 7;
pub const settings_load_key: u64 = 4;
pub const settings_save_key: u64 = 5;
/// One-shot: minimize main after status item has a chance to install.
pub const hide_window_timer_key: u64 = 8;
pub const notify_key: u64 = 9;
pub const attention_read_key: u64 = 10;
pub const install_hooks_key: u64 = 11;
pub const hook_assets_key: u64 = 12;
pub const install_script_key: u64 = 13;
pub const open_done_key: u64 = 14;
pub const login_key: u64 = 15;
pub const attention_clear_key: u64 = 16;
pub const poll_interval_ms: u32 = 3000;
/// Delay so the installing frame can create the tray first (keep short to reduce flash).
pub const hide_window_delay_ms: u64 = 50;
/// Actions: sep + 刷新 + 偏好设置 + [清除等待] + sep + 退出 ≤ 6.
pub const tray_action_reserve: usize = 6;
/// Max agents in the tray (detail-first; overflow as "+N more").
pub const tray_menu_max_agents: usize = 4;
/// Task / wait-message line max length.
pub const tray_task_preview_cap: usize = 60;
/// Meta line (tokens / tool / skill / project) max length.
pub const tray_meta_preview_cap: usize = 72;

/// Relative path under Application Support / home fallback.
pub const settings_relpath = "Library/Application Support/Pulse/settings.txt";
pub const attention_relpath = "Library/Application Support/Pulse/attention.tsv";
pub const pulse_home_relpath = "Library/Application Support/Pulse";
pub const login_agent_relpath = "Library/LaunchAgents/com.pulse.app.plist";
pub const open_project_command_prefix = "pulse.open_project:";
pub const clear_attention_command = "pulse.clear_attention";
pub const login_agent_label = "com.pulse.app";

const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_view,
    native_sdk.security.permission_filesystem,
};
const shell_views = [_]native_sdk.ShellView{
    .{
        .label = canvas_label,
        .kind = .gpu_surface,
        .fill = true,
        .role = "Pulse status",
        .accessibility_label = "Pulse",
        .gpu_backend = .metal,
        .gpu_pixel_format = .bgra8_unorm,
        .gpu_present_mode = .timer,
        .gpu_alpha_mode = .@"opaque",
        .gpu_color_space = .srgb,
        .gpu_vsync = true,
    },
};
/// Compact utility header height (tall hidden-inset band floor).
pub const header_natural_height: f32 = 52;

const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = window_label,
    .title = "Pulse",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .close_policy = .hide,
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Source = enum {
    probe,
    manual,
    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .probe => "Auto",
            .manual => "Manual",
        };
    }
};

/// Manual / display phase for demos when not driven purely by scan.
pub const Phase = enum {
    running,
    waiting,
    errored,
    idle,
};

pub const Msg = union(enum) {
    refresh,
    toggle_auto_probe,
    toggle_notify_idle,
    toggle_login_at_start,
    cycle_language,
    set_lang_auto,
    set_lang_en,
    set_lang_zh,
    install_hooks,
    clear_attention,
    open_agent_project: probe.AgentId,
    /// Manual simulate: set primary agent + running (or idle/waiting/error).
    sim_idle,
    sim_waiting,
    sim_errored,
    sim_agent: probe.AgentId,
    toggle_agent_picker,
    close_agent_picker,
    poll_tick: native_sdk.EffectTimer,
    probe_ps_done: native_sdk.EffectExit,
    probe_cli_done: native_sdk.EffectExit,
    activity_done: native_sdk.EffectExit,
    notify_done: native_sdk.EffectExit,
    install_hooks_done: native_sdk.EffectExit,
    login_done: native_sdk.EffectExit,
    open_done: native_sdk.EffectExit,
    attention_loaded: native_sdk.EffectFileResult,
    settings_loaded: native_sdk.EffectFileResult,
    settings_saved: native_sdk.EffectFileResult,
    open_window,
    quit,
    /// Tall hidden-inset titlebar geometry from `on_chrome`.
    chrome_changed: native_sdk.WindowChrome,
    /// One-shot: minimize main after tray install (dropdown-first).
    hide_main_tick: native_sdk.EffectTimer,

    pub const view_unbound = .{
        "open_window", "quit", "poll_tick", "probe_ps_done", "probe_cli_done",
        "settings_loaded", "settings_saved", "chrome_changed", "activity_done",
        "hide_main_tick", "notify_done", "install_hooks_done", "attention_loaded",
        "login_done", "open_done", "clear_attention", "open_agent_project",
        // Debug-only simulate path (not on product Preferences surface).
        "sim_idle", "sim_waiting", "sim_errored", "sim_agent",
        "toggle_agent_picker", "close_agent_picker", "cycle_language",
    };
};

const summary_cap = 192;
const agents_cap = 192;
const title_cap = 48;
const error_cap = 120;

pub const Model = struct {
    source: Source = .probe,
    auto_probe: bool = true,
    /// Language preference: auto | en | zh
    lang_pref: i18n.LangPref = .auto,
    /// Resolved system locale for `lang=auto` (set in main from environ).
    system_locale: i18n.Locale = .en,
    /// Notify when the last active agent goes idle (v1.1 attention loop).
    notify_on_idle: bool = true,
    /// Launch Pulse at login via LaunchAgent.
    login_at_start: bool = false,
    /// v2: attention/Waiting from agent hooks.
    attention: attention.State = .{},
    prev_attention: attention.State = .{},
    attention_glance_buf: [48]u8 = undefined,
    attention_glance_len: usize = 0,
    hooks_status_len: usize = 0,
    hooks_status_buf: [160]u8 = undefined,
    phase: Phase = .idle,
    /// Manual primary when source=manual; ignored when probe-driven running.
    manual_agent: probe.AgentId = .claude,
    agent_picker_open: bool = false,
    refresh_count: u32 = 0,
    probe_in_flight: bool = false,
    /// Previous probe agent count for busy→idle edge detection.
    prev_agent_count: usize = 0,
    last_scan: probe.ScanResult = .{},
    staged_scan: probe.ScanResult = .{},
    activities: [activity.max_activities]activity.Activity = undefined,
    activity_count: usize = 0,
    multi_title_buf: [64]u8 = undefined,
    multi_title_len: usize = 0,
    /// Prebuilt tray dropdown (menu-bar is the primary UI).
    tray_labels: [32][100]u8 = undefined,
    tray_items: [32]native_sdk.TrayMenuItem = undefined,
    tray_item_count: usize = 0,
    /// Minimize main window after first chrome (dropdown-first; keeps window alive).
    hide_main_on_start: bool = true,
    /// Title buffer for dynamic multi strings (optional).
    title_len: usize = 0,
    title_buf: [title_cap]u8 = undefined,
    agents_len: usize = 0,
    agents_buf: [agents_cap]u8 = undefined,
    summary_len: usize = 0,
    summary_buf: [summary_cap]u8 = undefined,
    error_len: usize = 0,
    error_buf: [error_cap]u8 = undefined,
    last_probe_ms: i64 = 0,
    settings_path_len: usize = 0,
    settings_path_buf: [512]u8 = undefined,
    settings_dirty: bool = false,
    /// Traffic-light clearance for the drag header (from on_chrome).
    chrome_leading: f32 = 0,
    header_height: f32 = header_natural_height,

    pub const view_unbound = .{
        "phase", "manual_agent", "probe_in_flight", "last_scan", "staged_scan", "activities", "activity_count", "multi_title_buf", "multi_title_len", "agent_picker_open", "tray_labels", "tray_items", "tray_item_count", "hide_main_on_start",
        "title_len", "title_buf", "agents_len", "agents_buf",
        "summary_len", "summary_buf", "error_len", "error_buf",
        "last_probe_ms", "source", "refresh_count", "sim_items", "prev_agent_count",
        "settings_path_len", "settings_path_buf", "settings_dirty", "settingsPath", "setSettingsPath",
        "sourceLabel", "autoLabel", "agentsLine", "probeSummary", "agentCount",
        "attention", "prev_attention", "attention_glance_buf", "attention_glance_len",
        "hooks_status_len", "hooks_status_buf", "lang_pref", "system_locale",
        // Debug-only simulate helpers (not bound in product markup).
        "phaseIsIdle", "phaseIsWaiting", "phaseIsErrored", "selectedAgentLabel", "simAgents",
        "menuHeadline", "menuHeaderWithTime", "menuUpdatedLine", "activityFor", "usefulTask", "pushAgentRow",
        "previewLine", "compactMeta", "formatCount", "formatWaitAge", "totalActivityTokens",
        "attentionCount", "hasAttention", "rowStatus", "refreshAttentionGlance", "refreshGlanceTitle",
        "versionLabel", "hooksStatus", "setHooksStatus", "buildPrefRow", "isListedAgent",
        "hasSessionActivity", "hasSessionPending",
        "activityRows", "hasActivities", "locale",
    };

    pub fn locale(model: *const Model) i18n.Locale {
        return model.lang_pref.resolve(model.system_locale);
    }

    pub fn tr(model: *const Model, key: i18n.Key) []const u8 {
        return i18n.t(model.locale(), key);
    }

    pub fn settingsPath(model: *const Model) []const u8 {
        if (model.settings_path_len == 0) return "";
        return model.settings_path_buf[0..model.settings_path_len];
    }

    pub fn setSettingsPath(model: *Model, path: []const u8) void {
        const n = @min(path.len, model.settings_path_buf.len);
        // resolveSettingsPath may already write into settings_path_buf — use
        // copyForwards so same-buffer (aliased) paths do not panic.
        if (n > 0) {
            std.mem.copyForwards(u8, model.settings_path_buf[0..n], path[0..n]);
        }
        model.settings_path_len = n;
    }

    /// Static labels for simulate rows (ids only).
    pub const SimItem = struct {
        id: probe.AgentId,
        label: []const u8,
    };

    pub const sim_items = [_]SimItem{
        .{ .id = .claude, .label = "Claude" },
        .{ .id = .codex, .label = "Codex" },
        .{ .id = .cursor, .label = "Cursor" },
        .{ .id = .cursor_agent, .label = "Cursor Agent" },
        .{ .id = .copilot, .label = "Copilot" },
        .{ .id = .aider, .label = "Aider" },
        .{ .id = .gemini, .label = "Gemini" },
        .{ .id = .amp, .label = "Amp" },
        .{ .id = .opencode, .label = "OpenCode" },
        .{ .id = .goose, .label = "Goose" },
        .{ .id = .windsurf, .label = "Windsurf" },
        .{ .id = .codeium, .label = "Codeium" },
        .{ .id = .amazon_q, .label = "Amazon Q" },
        .{ .id = .cline, .label = "Cline" },
        .{ .id = .openhands, .label = "OpenHands" },
        .{ .id = .zed, .label = "Zed" },
        .{ .id = .continue_, .label = "Continue" },
        .{ .id = .roo, .label = "Roo" },
        .{ .id = .augment, .label = "Augment" },
        .{ .id = .warp, .label = "Warp" },
        .{ .id = .pi, .label = "Pi" },
        .{ .id = .grok, .label = "Grok" },
    };

    /// View row with selection for compact list presentation.
    pub const SimRow = struct {
        id: probe.AgentId,
        label: []const u8,
        selected: bool,
    };

    pub fn simAgents(model: *const Model, arena: std.mem.Allocator) []const SimRow {
        const out = arena.alloc(SimRow, sim_items.len) catch return &.{};
        for (sim_items, 0..) |item, i| {
            out[i] = .{
                .id = item.id,
                .label = item.label,
                .selected = model.source == .manual and model.phase == .running and model.manual_agent == item.id,
            };
        }
        return out;
    }

    pub fn phaseIsIdle(model: *const Model) bool {
        return model.source == .manual and model.phase == .idle;
    }
    pub fn phaseIsWaiting(model: *const Model) bool {
        return model.source == .manual and model.phase == .waiting;
    }
    pub fn phaseIsErrored(model: *const Model) bool {
        return model.source == .manual and model.phase == .errored;
    }

    pub fn heroState(model: *const Model) []const u8 {
        if (model.hasProbeError() and model.agentCount() == 0) return model.tr(.error_short);
        if (model.hasAttention()) return model.tr(.waiting_short);
        if (model.agentCount() == 0) return model.tr(.idle);
        return model.tr(.running_short);
    }

    /// One muted context line for Preferences (not a hero board).
    pub fn contextLine(model: *const Model, arena: std.mem.Allocator) []const u8 {
        var tbuf: [40]u8 = undefined;
        const when = model.menuUpdatedLine(&tbuf);
        var buf: [120]u8 = undefined;
        const state = model.heroState();
        const line = std.fmt.bufPrint(&buf, "{s} · {s}", .{ state, when }) catch state;
        return arena.dupe(u8, line) catch state;
    }

    pub fn metaLine(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return model.contextLine(arena);
    }

    // --- Preferences i18n bindings (markup) ---
    pub fn prefsTitle(model: *const Model) []const u8 {
        return model.tr(.prefs_title);
    }
    pub fn refreshA11y(model: *const Model) []const u8 {
        return model.tr(.refresh_a11y);
    }
    pub fn sectionAgents(model: *const Model) []const u8 {
        return model.tr(.section_agents);
    }
    pub fn sectionSettings(model: *const Model) []const u8 {
        return model.tr(.section_settings);
    }
    pub fn sectionConnect(model: *const Model) []const u8 {
        return model.tr(.section_connect);
    }
    pub fn emptyTitle(model: *const Model) []const u8 {
        return model.tr(.empty_title);
    }
    pub fn emptyBody(model: *const Model) []const u8 {
        return model.tr(.empty_body);
    }
    pub fn liveUpdatesLabel(model: *const Model) []const u8 {
        return model.tr(.live_updates);
    }
    pub fn notificationsLabel(model: *const Model) []const u8 {
        return model.tr(.notifications);
    }
    pub fn connectTitle(model: *const Model) []const u8 {
        return model.tr(.connect_title);
    }
    pub fn connectBody(model: *const Model) []const u8 {
        return model.tr(.connect_body);
    }
    pub fn installHooksLabel(model: *const Model) []const u8 {
        return model.tr(.install_hooks);
    }
    pub fn loginAtStartLabel(model: *const Model) []const u8 {
        return model.tr(.login_at_start);
    }
    pub fn languageSectionLabel(model: *const Model) []const u8 {
        return model.tr(.language_label);
    }
    pub fn langAutoLabel(model: *const Model) []const u8 {
        return model.tr(.lang_auto);
    }
    pub fn langIsAuto(model: *const Model) bool {
        return model.lang_pref == .auto;
    }
    pub fn langIsEn(model: *const Model) bool {
        return model.lang_pref == .en;
    }
    pub fn langIsZh(model: *const Model) bool {
        return model.lang_pref == .zh;
    }
    pub fn languageButtonLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
        var buf: [64]u8 = undefined;
        const line = i18n.languageButton(model.locale(), model.lang_pref, &buf);
        return arena.dupe(u8, line) catch model.tr(.language_label);
    }

    pub fn footerLine(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.hooks_status_len > 0) {
            return std.fmt.allocPrint(arena, "{s}", .{model.hooksStatus()}) catch model.hooksStatus();
        }
        if (model.hasProbeError()) {
            return std.fmt.allocPrint(arena, "{s}", .{model.probeError()}) catch model.probeError();
        }
        var vbuf: [32]u8 = undefined;
        return version.aboutLine(&vbuf);
    }

    /// Preference agent rows — name + status only (settings page, not HUD).
    pub const PrefRow = struct {
        name: []const u8,
        status: []const u8,
    };

    pub fn preferenceRows(model: *const Model, arena: std.mem.Allocator) []const PrefRow {
        var tmp: [16]PrefRow = undefined;
        var n: usize = 0;
        if (model.source == .manual and model.phase == .running and probe.isSurfaceAgent(model.manual_agent)) {
            tmp[0] = .{ .name = model.manual_agent.displayName(), .status = model.rowStatus(model.manual_agent) };
            n = 1;
        } else {
            for (probe.priority_order) |id| {
                if (!model.isListedAgent(id)) continue;
                if (n >= tmp.len) break;
                tmp[n] = .{ .name = id.displayName(), .status = model.rowStatus(id) };
                n += 1;
            }
        }
        if (n == 0) return &.{};
        const out = arena.alloc(PrefRow, n) catch return &.{};
        @memcpy(out[0..n], tmp[0..n]);
        return out;
    }

    pub fn hasPreferenceRows(model: *const Model) bool {
        if (model.source == .manual and model.phase == .running and probe.isSurfaceAgent(model.manual_agent)) return true;
        if (model.agentCount() > 0) return true;
        return model.hasAttention();
    }

    fn buildPrefRow(model: *const Model, arena: std.mem.Allocator, id: probe.AgentId) PrefRow {
        _ = arena;
        return .{ .name = id.displayName(), .status = model.rowStatus(id) };
    }

    pub fn versionLabel(_: *const Model) []const u8 {
        return version.semver;
    }

    pub fn hooksStatus(model: *const Model) []const u8 {
        if (model.hooks_status_len == 0) return "";
        return model.hooks_status_buf[0..model.hooks_status_len];
    }

    fn setHooksStatus(model: *Model, text: []const u8) void {
        const n = @min(text.len, model.hooks_status_buf.len);
        if (n > 0) @memcpy(model.hooks_status_buf[0..n], text[0..n]);
        model.hooks_status_len = n;
    }

    pub fn attentionCount(model: *const Model) usize {
        return model.attention.count;
    }

    pub fn hasAttention(model: *const Model) bool {
        return model.attention.count > 0;
    }

    pub fn menuHeadline(model: *const Model, buf: []u8) []const u8 {
        const loc = model.locale();
        if (model.hasProbeError() and model.agentCount() == 0) return model.tr(.cannot_refresh);
        const waiting = model.attention.count;
        const n = model.agentCount();
        if (waiting > 0 and n > 0) return i18n.runningAndWaiting(loc, buf, n, waiting);
        if (waiting > 0) {
            if (waiting == 1) return model.tr(.needs_you);
            return i18n.nWaiting(loc, buf, waiting);
        }
        if (n == 0) return model.tr(.idle);
        if (n == 1) return model.tr(.one_running);
        return i18n.nRunning(loc, buf, n);
    }

    /// Summary + relative time — no token dump (tokens are noisy / often wrong).
    pub fn menuHeaderWithTime(model: *const Model, buf: []u8) []const u8 {
        var hbuf: [48]u8 = undefined;
        var tbuf: [40]u8 = undefined;
        const head = model.menuHeadline(&hbuf);
        const when = model.menuUpdatedLine(&tbuf);
        return std.fmt.bufPrint(buf, "{s} · {s}", .{ head, when }) catch head;
    }

    fn totalActivityTokens(model: *const Model) u64 {
        var sum: u64 = 0;
        for (model.activities[0..model.activity_count]) |a| {
            sum +%= a.totalTokens();
        }
        return sum;
    }

    pub fn menuUpdatedLine(model: *const Model, buf: []u8) []const u8 {
        const loc = model.locale();
        if (model.last_probe_ms == 0) return i18n.notYet(loc);
        const now = native_sdk.nowMs();
        const delta_ms: i64 = if (now >= model.last_probe_ms) now - model.last_probe_ms else 0;
        if (delta_ms < 5_000) return i18n.justNow(loc);
        if (delta_ms < 60_000) {
            const s: u64 = @intCast(@divTrunc(delta_ms, 1000));
            return i18n.secondsAgo(loc, buf, s);
        }
        const m: u64 = @intCast(@divTrunc(delta_ms, 60_000));
        return i18n.minutesAgo(loc, buf, m);
    }

    /// Closed select label for the agent picker.
    pub fn selectedAgentLabel(model: *const Model) []const u8 {
        if (model.source == .manual and model.phase == .running) {
            return model.manual_agent.displayName();
        }
        return "Choose agent…";
    }

    pub fn activeAgentsLabel(model: *const Model) []const u8 {
        if (model.agentCount() == 0) return "None detected";
        return model.agentsLine();
    }

    pub fn statusTitle(model: *const Model) []const u8 {
        // EXPERIENCE: Idle = icon-only; never show IDE-shell counts.
        if (model.hasProbeError() and model.agentCount() == 0) return "!";
        if (model.attention_glance_len > 0) return model.attention_glance_buf[0..model.attention_glance_len];
        if (model.source == .manual) {
            return switch (model.phase) {
                .idle, .waiting => "",
                .errored => "!",
                .running => if (probe.isSurfaceAgent(model.manual_agent)) model.manual_agent.displayName() else "",
            };
        }
        if (model.last_scan.surfaceCount() == 0) return "";
        if (model.multi_title_len > 0) return model.multi_title_buf[0..model.multi_title_len];
        if (model.last_scan.surfacePrimary()) |p| return p.displayName();
        return "";
    }

    fn refreshAttentionGlance(model: *Model) void {
        if (model.attention.count == 0) {
            model.attention_glance_len = 0;
            return;
        }
        const loc = model.locale();
        if (model.attention.count == 1) {
            const t = i18n.glanceWaitOne(loc, model.attention_glance_buf[0..], model.attention.entries[0].id.displayName());
            model.attention_glance_len = t.len;
            return;
        }
        const t = i18n.glanceWaitN(loc, model.attention_glance_buf[0..], model.attention.count);
        model.attention_glance_len = t.len;
    }

    pub fn rowStatus(model: *const Model, id: probe.AgentId) []const u8 {
        if (model.attention.contains(id)) return model.tr(.status_waiting);
        return model.tr(.status_running);
    }

    fn activityFor(model: *const Model, id: probe.AgentId) ?*const activity.Activity {
        for (model.activities[0..model.activity_count]) |*a| {
            if (a.id == id) return a;
        }
        return null;
    }

    fn usefulTask(_: *const Model, task: []const u8) bool {
        if (task.len == 0) return false;
        if (std.mem.eql(u8, task, "-")) return false;
        if (std.mem.eql(u8, task, "—")) return false;
        if (std.mem.eql(u8, task, "Running")) return false;
        if (std.mem.eql(u8, task, "Active")) return false;
        if (std.mem.eql(u8, task, "none")) return false;
        // Skip pure path dumps / noise
        if (task.len > 2 and task[0] == '/' and std.mem.indexOfScalar(u8, task, ' ') == null) return false;
        return true;
    }

    pub fn activityRows(model: *const Model) []const activity.Activity {
        return model.activities[0..model.activity_count];
    }

    pub fn hasActivities(model: *const Model) bool {
        return model.activity_count > 0;
    }

    pub fn sourceLabel(model: *const Model) []const u8 {
        return model.source.label();
    }

    pub fn autoLabel(model: *const Model) []const u8 {
        return if (model.auto_probe) "On" else "Off";
    }

    pub fn agentsLine(model: *const Model) []const u8 {
        if (model.agents_len == 0) return "none";
        return model.agents_buf[0..model.agents_len];
    }

    pub fn probeSummary(model: *const Model) []const u8 {
        if (model.summary_len == 0) return "—";
        return model.summary_buf[0..model.summary_len];
    }

    pub fn probeError(model: *const Model) []const u8 {
        if (model.error_len == 0) return "";
        return model.error_buf[0..model.error_len];
    }

    pub fn hasProbeError(model: *const Model) bool {
        return model.error_len > 0;
    }

    pub fn agentCount(model: *const Model) usize {
        if (model.source == .manual and model.phase == .running) {
            return if (probe.isSurfaceAgent(model.manual_agent) or model.manual_agent == .cursor) @as(usize, 1) else 0;
        }
        var n = model.last_scan.surfaceCount();
        // Session-backed Cursor (DB), not Cursor.app process count.
        if (model.hasSessionActivity(.cursor)) n += 1;
        // Avoid double-counting Cursor Agent worker when session already listed.
        if (model.hasSessionActivity(.cursor) and model.last_scan.contains(.cursor_agent)) {
            if (n > 0) n -= 1;
        }
        return n;
    }

    /// Cursor (and future IDE) sessions from harvest — not process presence.
    fn hasSessionActivity(model: *const Model, id: probe.AgentId) bool {
        if (model.activityFor(id)) |a| {
            return a.hasTask() or a.hasProject() or a.hasCwd() or std.mem.eql(u8, a.skill(), "pending");
        }
        return false;
    }

    /// True when this agent should appear in tray / prefs / glance.
    fn isListedAgent(model: *const Model, id: probe.AgentId) bool {
        if (model.attention.contains(id)) return true;
        if (model.source == .manual and model.phase == .running) return id == model.manual_agent;
        // Session-backed Cursor: only with local composer evidence.
        if (id == .cursor) return model.hasSessionActivity(.cursor);
        // Prefer session row over raw cursor-agent worker when both exist.
        if (id == .cursor_agent and model.hasSessionActivity(.cursor)) return false;
        if (!probe.isSurfaceAgent(id)) return false;
        return model.last_scan.contains(id);
    }

    fn setAgentsLine(model: *Model, text: []const u8) void {
        const n = @min(text.len, agents_cap);
        @memcpy(model.agents_buf[0..n], text[0..n]);
        model.agents_len = n;
    }

    fn setSummary(model: *Model, text: []const u8) void {
        const n = @min(text.len, summary_cap);
        @memcpy(model.summary_buf[0..n], text[0..n]);
        model.summary_len = n;
    }

    fn setError(model: *Model, text: []const u8) void {
        const n = @min(text.len, error_cap);
        @memcpy(model.error_buf[0..n], text[0..n]);
        model.error_len = n;
    }

    fn clearError(model: *Model) void {
        model.error_len = 0;
    }

    /// Recompute Glance title from surface scan + session-backed activities.
    fn refreshGlanceTitle(model: *Model) void {
        const n = model.agentCount();
        if (n == 0) {
            model.multi_title_len = 0;
            return;
        }
        if (n == 1) {
            // Prefer waiting attention, else first listed agent name.
            if (model.hasAttention() and model.attention.count == 1) {
                const name = model.attention.entries[0].id.displayName();
                const copied = @min(name.len, model.multi_title_buf.len);
                @memcpy(model.multi_title_buf[0..copied], name[0..copied]);
                model.multi_title_len = copied;
                return;
            }
            for (probe.priority_order) |id| {
                if (!model.isListedAgent(id)) continue;
                const name = id.displayName();
                const copied = @min(name.len, model.multi_title_buf.len);
                @memcpy(model.multi_title_buf[0..copied], name[0..copied]);
                model.multi_title_len = copied;
                return;
            }
            model.multi_title_len = 0;
            return;
        }
        const t = std.fmt.bufPrint(model.multi_title_buf[0..], "{d}", .{n}) catch {
            model.multi_title_len = 0;
            return;
        };
        model.multi_title_len = t.len;
    }

    /// Returns true when this scan crossed active → idle (for notify).
    pub fn applyScan(model: *Model, scan: probe.ScanResult, summary: []const u8) bool {
        const prev = model.prev_agent_count;
        model.source = .probe;
        model.last_scan = scan;
        model.setSummary(summary);
        var line_buf: [agents_cap]u8 = undefined;
        const line = probe.formatAgentsLine(&scan, &line_buf);
        model.setAgentsLine(line);
        model.refreshGlanceTitle();
        model.phase = if (model.agentCount() == 0) .idle else .running;
        model.clearError();
        model.last_probe_ms = native_sdk.nowMs();
        model.prev_agent_count = model.agentCount();
        model.rebuildTrayMenu();
        return prev > 0 and model.agentCount() == 0;
    }

    pub fn applyActivities(model: *Model, items: []const activity.Activity) void {
        const n = @min(items.len, activity.max_activities);
        @memcpy(model.activities[0..n], items[0..n]);
        model.activity_count = n;
        model.refreshGlanceTitle();
        model.phase = if (model.agentCount() == 0) .idle else .running;
        model.prev_agent_count = model.agentCount();
        model.rebuildTrayMenu();
    }

    fn pushTrayLabel(model: *Model, text: []const u8, cmd: []const u8, enabled: bool) void {
        if (model.tray_item_count >= model.tray_items.len) return;
        const i = model.tray_item_count;
        const n = @min(text.len, model.tray_labels[i].len);
        @memcpy(model.tray_labels[i][0..n], text[0..n]);
        const label = model.tray_labels[i][0..n];
        model.tray_items[i] = .{
            .id = @intCast(i + 1),
            .label = label,
            .command = cmd,
            .enabled = enabled,
            .separator = false,
        };
        model.tray_item_count += 1;
    }

    fn pushTraySep(model: *Model) void {
        if (model.tray_item_count >= model.tray_items.len) return;
        const i = model.tray_item_count;
        model.tray_items[i] = .{ .id = 0, .separator = true };
        model.tray_item_count += 1;
    }

    /// Scannable tray: header + glyph-prefixed agents (+ one subline max) + actions.
    pub fn rebuildTrayMenu(model: *Model) void {
        model.tray_item_count = 0;

        const idle = model.agentCount() == 0 and !model.hasAttention() and
            !(model.source == .manual and model.phase == .running and probe.isSurfaceAgent(model.manual_agent));
        if (idle) {
            if (!model.hasProbeError()) {
                model.pushTrayLabel(model.tr(.empty_tray_hint), "", false);
            } else {
                model.pushTrayLabel(model.tr(.cannot_refresh), "", false);
            }
        } else {
            var hbuf: [96]u8 = undefined;
            model.pushTrayLabel(model.menuHeaderWithTime(&hbuf), "", false);

            var listed: usize = 0;
            var listed_mask: [64]bool = .{false} ** 64;
            const mark = struct {
                fn set(mask: []bool, id: probe.AgentId) void {
                    const i: usize = @intFromEnum(id);
                    if (i < mask.len) mask[i] = true;
                }
                fn get(mask: []const bool, id: probe.AgentId) bool {
                    const i: usize = @intFromEnum(id);
                    return i < mask.len and mask[i];
                }
            };

            if (model.source == .manual and model.phase == .running and model.isListedAgent(model.manual_agent)) {
                model.pushAgentRow(model.manual_agent);
                listed = 1;
            } else {
                // 1) Waiting first (hooks + Cursor pending sessions)
                for (probe.priority_order) |id| {
                    if (!model.isListedAgent(id)) continue;
                    const session_wait = model.hasSessionPending(id);
                    if (!model.attention.contains(id) and !session_wait) continue;
                    if (listed >= tray_menu_max_agents) break;
                    model.pushAgentRow(id);
                    mark.set(&listed_mask, id);
                    listed += 1;
                }
                // 2) Running listed agents
                for (probe.priority_order) |id| {
                    if (!model.isListedAgent(id)) continue;
                    if (mark.get(&listed_mask, id)) continue;
                    if (listed >= tray_menu_max_agents) break;
                    model.pushAgentRow(id);
                    mark.set(&listed_mask, id);
                    listed += 1;
                }
                const total = model.agentCount();
                if (total > listed and listed >= tray_menu_max_agents) {
                    var mbuf: [40]u8 = undefined;
                    const more = i18n.fmt1(model.locale(), .more_agents, &mbuf, total - listed);
                    model.pushTrayLabel(more, "", false);
                }
            }
        }

        model.pushTraySep();
        const loc = model.locale();
        model.pushTrayLabel(i18n.trayAction(loc, .refresh), refresh_command, true);
        model.pushTrayLabel(i18n.trayAction(loc, .preferences), open_command, true);
        if (model.hasAttention()) {
            model.pushTrayLabel(i18n.trayAction(loc, .dismiss_waiting), clear_attention_command, true);
        }
        model.pushTraySep();
        model.pushTrayLabel(i18n.trayAction(loc, .quit), quit_command, true);
    }

    fn hasSessionPending(model: *const Model, id: probe.AgentId) bool {
        if (model.activityFor(id)) |a| {
            return std.mem.eql(u8, a.skill(), "pending");
        }
        return false;
    }

    fn pushAgentRow(model: *Model, id: probe.AgentId) void {
        const act = model.activityFor(id);
        const session_wait = model.hasSessionPending(id);
        const waiting = model.attention.contains(id) or session_wait;
        const project = if (act) |a| (if (a.hasProject()) a.project() else "") else "";
        const via_warp = model.last_scan.viaWarp(id);

        // Glyph encodes waiting vs running — no trailing "running/waiting" word.
        var line_buf: [96]u8 = undefined;
        const base = blk: {
            if (project.len > 0) {
                break :blk i18n.agentRowWithProject(model.locale(), &line_buf, id.displayName(), project, waiting);
            }
            break :blk i18n.agentRow(model.locale(), &line_buf, id.displayName(), waiting);
        };
        var title_buf: [120]u8 = undefined;
        const title = if (via_warp)
            (std.fmt.bufPrint(&title_buf, "{s} · via Warp", .{base}) catch base)
        else
            base;
        const can_open = act != null and act.?.hasCwd();
        model.pushTrayLabel(title, openProjectCommand(id, can_open), can_open);

        // At most one subline: wait reason, or session title.
        if (waiting) {
            if (model.attention.entryFor(id)) |e| {
                const kl = i18n.kindLabel(model.locale(), @tagName(e.kind));
                var age_buf: [24]u8 = undefined;
                const age = model.formatWaitAge(&age_buf, e.ts_ms);
                var head_buf: [80]u8 = undefined;
                const head = blk: {
                    if (age.len > 0) {
                        break :blk std.fmt.bufPrint(&head_buf, "{s} · {s}", .{ kl, age }) catch kl;
                    }
                    break :blk kl;
                };
                var wbuf: [tray_task_preview_cap + 16]u8 = undefined;
                const msg = e.message();
                if (msg.len > 0 and model.usefulTask(msg)) {
                    var combined: [tray_task_preview_cap + 40]u8 = undefined;
                    const body = std.fmt.bufPrint(&combined, "{s}: {s}", .{ head, msg }) catch msg;
                    model.pushTrayLabel(i18n.traySubline(&wbuf, body), "", false);
                } else {
                    model.pushTrayLabel(i18n.traySubline(&wbuf, head), "", false);
                }
            } else if (session_wait) {
                if (act) |a| {
                    if (a.hasTask() and model.usefulTask(a.task())) {
                        var wbuf: [tray_task_preview_cap + 16]u8 = undefined;
                        model.pushTrayLabel(i18n.traySubline(&wbuf, a.task()), "", false);
                    }
                }
            }
        } else if (act) |a| {
            if (id == .cursor and a.hasTask() and model.usefulTask(a.task())) {
                var tbuf: [tray_task_preview_cap + 12]u8 = undefined;
                model.pushTrayLabel(i18n.traySubline(&tbuf, a.task()), "", false);
            }
        }
    }

    /// Stable command strings for tray → open project (must outlive menu rebuild).
    fn openProjectCommand(id: probe.AgentId, enabled: bool) []const u8 {
        if (!enabled) return "";
        return switch (id) {
            .claude => "pulse.open_project:claude",
            .codex => "pulse.open_project:codex",
            .grok => "pulse.open_project:grok",
            .pi => "pulse.open_project:pi",
            .cursor => "pulse.open_project:cursor",
            .cursor_agent => "pulse.open_project:cursor_agent",
            .amp => "pulse.open_project:amp",
            else => "",
        };
    }

    fn previewLine(_: *const Model, buf: []u8, prefix: []const u8, text: []const u8) []const u8 {
        const max_body = if (buf.len > prefix.len + 1) buf.len - prefix.len - 1 else 8;
        if (text.len <= max_body) {
            return std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, text }) catch text;
        }
        return std.fmt.bufPrint(buf, "{s}{s}…", .{ prefix, text[0..max_body] }) catch text;
    }

    /// Dense runtime line: "  ↑1.2k ↓80 · Bash · skill" — empty if nothing useful.
    fn compactMeta(model: *const Model, buf: []u8, act: *const activity.Activity) []const u8 {
        _ = model;
        var in_b: [16]u8 = undefined;
        var out_b: [16]u8 = undefined;
        var parts: [3][]const u8 = undefined;
        var n: usize = 0;
        var tok_line: [40]u8 = undefined;
        if (act.hasTokens()) {
            const ins = formatCount(&in_b, act.tokens_in);
            const outs = formatCount(&out_b, act.tokens_out);
            const t = std.fmt.bufPrint(&tok_line, "↑{s} ↓{s}", .{ ins, outs }) catch "";
            if (t.len > 0) {
                parts[n] = t;
                n += 1;
            }
        }
        const tool = act.tool();
        if (tool.len > 0) {
            parts[n] = tool;
            n += 1;
        }
        const skill = act.skill();
        if (skill.len > 0 and n < parts.len) {
            parts[n] = skill;
            n += 1;
        }
        if (n == 0) return "";
        // Join with " · " under a two-space indent.
        var pos: usize = 0;
        if (buf.len < 4) return "";
        buf[0] = ' ';
        buf[1] = ' ';
        pos = 2;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (i > 0) {
                const sep = " · ";
                if (pos + sep.len > buf.len) break;
                @memcpy(buf[pos .. pos + sep.len], sep);
                pos += sep.len;
            }
            const p = parts[i];
            const take = @min(p.len, if (pos < buf.len) buf.len - pos else 0);
            if (take == 0) break;
            @memcpy(buf[pos .. pos + take], p[0..take]);
            pos += take;
        }
        return buf[0..pos];
    }

    /// Relative wait age from attention timestamp; empty if unknown/stale clock.
    fn formatWaitAge(model: *const Model, buf: []u8, ts_ms: i64) []const u8 {
        if (ts_ms <= 0) return "";
        const now = native_sdk.nowMs();
        if (now <= ts_ms) return i18n.justNow(model.locale());
        const delta_ms = now - ts_ms;
        if (delta_ms < 5_000) return i18n.justNow(model.locale());
        if (delta_ms < 60_000) {
            const s: u64 = @intCast(@divTrunc(delta_ms, 1000));
            return i18n.waitSeconds(model.locale(), buf, s);
        }
        if (delta_ms < 60 * 60_000) {
            const m: u64 = @intCast(@divTrunc(delta_ms, 60_000));
            return i18n.waitMinutes(model.locale(), buf, m);
        }
        const h: u64 = @intCast(@divTrunc(delta_ms, 3_600_000));
        return i18n.waitHours(model.locale(), buf, h);
    }

    fn formatCount(buf: []u8, n: u64) []const u8 {
        if (n >= 1_000_000) {
            const m = n / 1_000_000;
            const frac = (n % 1_000_000) / 100_000;
            return std.fmt.bufPrint(buf, "{d}.{d}M", .{ m, frac }) catch "?";
        }
        if (n >= 1000) {
            const k = n / 1000;
            const frac = (n % 1000) / 100;
            return std.fmt.bufPrint(buf, "{d}.{d}k", .{ k, frac }) catch "?";
        }
        return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?";
    }

    /// Apply attention file contents; returns true if a new waiting agent appeared.
    pub fn applyAttentionBytes(model: *Model, bytes: []const u8) bool {
        model.prev_attention = model.attention;
        var next: attention.State = .{};
        attention.parseTsv(bytes, native_sdk.nowMs(), &next);
        const is_new = attention.hasNewAttention(&model.prev_attention, &next);
        model.attention = next;
        model.refreshAttentionGlance();
        model.rebuildTrayMenu();
        return is_new;
    }

    pub fn applyManualIdle(model: *Model) void {
        model.source = .manual;
        model.phase = .idle;
        model.agent_picker_open = false;
        model.last_scan = .{};
        model.prev_agent_count = 0;
        model.setAgentsLine("none");
        model.setSummary("manual idle");
        model.last_probe_ms = native_sdk.nowMs();
        model.rebuildTrayMenu();
    }

    pub fn applyManualWaiting(model: *Model) void {
        model.source = .manual;
        model.phase = .waiting;
        model.agent_picker_open = false;
        model.setAgentsLine("Waiting");
        model.setSummary("manual waiting");
        model.last_probe_ms = native_sdk.nowMs();
        model.rebuildTrayMenu();
    }

    pub fn applyManualError(model: *Model) void {
        model.source = .manual;
        model.phase = .errored;
        model.agent_picker_open = false;
        model.setAgentsLine("Error");
        model.setSummary("manual error");
        model.last_probe_ms = native_sdk.nowMs();
        model.rebuildTrayMenu();
    }

    pub fn applyManualAgent(model: *Model, id: probe.AgentId) void {
        model.source = .manual;
        model.phase = .running;
        model.manual_agent = id;
        model.agent_picker_open = false;
        model.last_scan = .{};
        model.last_scan.addProcess(id);
        model.prev_agent_count = 1;
        model.setAgentsLine(id.displayName());
        model.setSummary("manual simulate");
        model.last_probe_ms = native_sdk.nowMs();
        model.rebuildTrayMenu();
    }
};

pub const Effects = native_sdk.Effects(Msg);

pub fn boot(model: *Model, fx: *Effects) void {
    // settings_path filled in main() from HOME; tests leave it empty.
    if (model.settingsPath().len > 0) {
        fx.readFile(.{
            .key = settings_load_key,
            .path = model.settingsPath(),
            .on_result = Effects.fileMsg(.settings_loaded),
        });
    } else {
        startProbeLoop(model, fx);
    }
}

fn startProbeLoop(model: *Model, fx: *Effects) void {
    installHookAssets(model, fx);
    if (model.auto_probe) {
        startPollTimer(fx);
        beginProbe(model, fx);
        beginAttentionRead(model, fx);
    }
}

pub fn resolveSettingsPath(buf: []u8, home: []const u8) ?[]const u8 {
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, settings_relpath }) catch null;
}

/// Serialize prefs.
pub fn encodeSettings(model: *const Model, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "auto={d}\nnotify={d}\nlang={s}\nlogin={d}\n", .{
        @intFromBool(model.auto_probe),
        @intFromBool(model.notify_on_idle),
        model.lang_pref.code(),
        @intFromBool(model.login_at_start),
    }) catch "auto=1\nnotify=1\nlang=auto\nlogin=0\n";
}

pub fn resolvePulseHome(buf: []u8, home: []const u8) ?[]const u8 {
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, pulse_home_relpath }) catch null;
}

pub fn resolveAttentionPath(buf: []u8, home: []const u8) ?[]const u8 {
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, attention_relpath }) catch null;
}

/// Relative tray/dock icon (dev cwd). Packaged `.app` launch often has cwd `/`,
/// so `create_tray` must receive an absolute path under Contents/Resources.
pub const tray_icon_relpath = "assets/tray.png";

/// Filled in `main` before `options()` / runner — must outlive the app.
var tray_icon_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var tray_icon_path: []const u8 = tray_icon_relpath;

fn pathExists(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Resolve tray icon for both `native run` (project cwd) and `open pulse.app`
/// (cwd `/`, assets under `Contents/Resources/`).
pub fn resolveTrayIconPath(io: std.Io, buf: []u8) []const u8 {
    if (pathExists(io, tray_icon_relpath)) {
        const n = std.Io.Dir.cwd().realPathFile(io, tray_icon_relpath, buf) catch return tray_icon_relpath;
        return buf[0..n];
    }
    // Dev fallback: older layouts only shipped assets/icon.png
    if (pathExists(io, "assets/icon.png")) {
        const n = std.Io.Dir.cwd().realPathFile(io, "assets/icon.png", buf) catch return "assets/icon.png";
        return buf[0..n];
    }

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(io, &exe_buf) catch return tray_icon_relpath;
    const exe = exe_buf[0..exe_len];
    const macos_dir = std.fs.path.dirname(exe) orelse return tray_icon_relpath;
    const contents_dir = std.fs.path.dirname(macos_dir) orelse return tray_icon_relpath;

    const bundled = std.fmt.bufPrint(buf, "{s}/Resources/{s}", .{ contents_dir, tray_icon_relpath }) catch return tray_icon_relpath;
    if (pathExists(io, bundled)) return bundled;

    const legacy = std.fmt.bufPrint(buf, "{s}/Resources/assets/icon.png", .{contents_dir}) catch return tray_icon_relpath;
    if (pathExists(io, legacy)) return legacy;

    return tray_icon_relpath;
}

pub fn applySettingsBytes(model: *Model, bytes: []const u8) void {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "auto=")) {
            const v = line["auto=".len..];
            model.auto_probe = !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"));
        } else if (std.mem.startsWith(u8, line, "notify=")) {
            const v = line["notify=".len..];
            model.notify_on_idle = !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"));
        } else if (std.mem.startsWith(u8, line, "lang=")) {
            model.lang_pref = i18n.LangPref.parse(line["lang=".len..]);
        } else if (std.mem.startsWith(u8, line, "login=")) {
            const v = line["login=".len..];
            model.login_at_start = !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"));
        }
    }
}

fn saveSettings(model: *Model, fx: *Effects) void {
    const path = model.settingsPath();
    if (path.len == 0) return;
    var buf: [96]u8 = undefined;
    const bytes = encodeSettings(model, &buf);
    fx.writeFile(.{
        .key = settings_save_key,
        .path = path,
        .bytes = bytes,
        .on_result = Effects.fileMsg(.settings_saved),
    });
}

/// Process-lifetime buffers so spawn argv stays valid until the effect copies it.
var notify_script_idle: [220]u8 = undefined;
var notify_script_wait: [220]u8 = undefined;

fn notifyAllIdle(model: *const Model, fx: *Effects) void {
    const body = model.tr(.notify_idle_body);
    const script = std.fmt.bufPrint(notify_script_idle[0..], "display notification \"{s}\" with title \"Pulse\"", .{body}) catch
        "display notification \"Idle\" with title \"Pulse\"";
    fx.spawn(.{
        .key = notify_key,
        .argv = &.{ "osascript", "-e", script },
        .output = .collect,
        .on_exit = Effects.exitMsg(.notify_done),
    });
}

fn notifyNeedsAttention(model: *const Model, fx: *Effects) void {
    const body = model.tr(.notify_wait_body);
    const script = std.fmt.bufPrint(notify_script_wait[0..], "display notification \"{s}\" with title \"Pulse\"", .{body}) catch
        "display notification \"Attention\" with title \"Pulse\"";
    fx.spawn(.{
        .key = notify_key,
        .argv = &.{ "osascript", "-e", script },
        .output = .collect,
        .on_exit = Effects.exitMsg(.notify_done),
    });
}

fn pulseSupportDir(model: *const Model, buf: []u8) ?[]const u8 {
    const sp = model.settingsPath();
    if (sp.len == 0) return null;
    if (std.mem.lastIndexOfScalar(u8, sp, '/')) |slash| {
        return std.fmt.bufPrint(buf, "{s}", .{sp[0..slash]}) catch null;
    }
    return null;
}

fn installHookAssets(model: *const Model, fx: *Effects) void {
    var dir_buf: [512]u8 = undefined;
    const dir = pulseSupportDir(model, &dir_buf) orelse return;
    var hook_path: [540]u8 = undefined;
    var install_path: [540]u8 = undefined;
    const hp = std.fmt.bufPrint(&hook_path, "{s}/pulse_hook.py", .{dir}) catch return;
    const ip = std.fmt.bufPrint(&install_path, "{s}/install_hooks.py", .{dir}) catch return;
    fx.writeFile(.{
        .key = hook_assets_key,
        .path = hp,
        .bytes = pulse_hook_py,
        .on_result = null,
    });
    fx.writeFile(.{
        .key = install_script_key,
        .path = ip,
        .bytes = install_hooks_py,
        .on_result = null,
    });
}

fn beginAttentionRead(model: *const Model, fx: *Effects) void {
    var path_buf: [512]u8 = undefined;
    const sp = model.settingsPath();
    if (sp.len == 0) return;
    // attention.tsv sits next to settings.txt
    const path = blk: {
        if (std.mem.lastIndexOfScalar(u8, sp, '/')) |slash| {
            break :blk std.fmt.bufPrint(&path_buf, "{s}/attention.tsv", .{sp[0..slash]}) catch return;
        }
        return;
    };
    fx.readFile(.{
        .key = attention_read_key,
        .path = path,
        .on_result = Effects.fileMsg(.attention_loaded),
    });
}

fn beginInstallHooks(model: *Model, fx: *Effects) void {
    installHookAssets(model, fx);
    var dir_buf: [512]u8 = undefined;
    const dir = pulseSupportDir(model, &dir_buf) orelse {
        model.setHooksStatus(model.tr(.hooks_need_app));
        return;
    };
    var script_path: [540]u8 = undefined;
    const script = std.fmt.bufPrint(&script_path, "{s}/install_hooks.py", .{dir}) catch return;
    model.setHooksStatus(model.tr(.hooks_installing));
    fx.spawn(.{
        .key = install_hooks_key,
        .argv = &.{ "python3", script },
        .output = .collect,
        .on_exit = Effects.exitMsg(.install_hooks_done),
    });
}

var open_path_buf: [activity.cwd_cap + 1]u8 = undefined;

fn openAgentProject(model: *const Model, fx: *Effects, id: probe.AgentId) void {
    const act = blk: {
        for (model.activities[0..model.activity_count]) |*a| {
            if (a.id == id and a.hasCwd()) break :blk a;
        }
        return;
    };
    const cwd = act.cwd();
    const n = @min(cwd.len, open_path_buf.len);
    @memcpy(open_path_buf[0..n], cwd[0..n]);
    const path = open_path_buf[0..n];
    fx.spawn(.{
        .key = open_done_key,
        .argv = &.{ "open", path },
        .output = .collect,
        .on_exit = Effects.exitMsg(.open_done),
    });
}

fn clearAttention(model: *Model, fx: *Effects) void {
    model.attention.clear();
    model.refreshAttentionGlance();
    model.rebuildTrayMenu();
    var path_buf: [512]u8 = undefined;
    const sp = model.settingsPath();
    if (sp.len == 0) return;
    const path = blk: {
        if (std.mem.lastIndexOfScalar(u8, sp, '/')) |slash| {
            break :blk std.fmt.bufPrint(&path_buf, "{s}/attention.tsv", .{sp[0..slash]}) catch return;
        }
        return;
    };
    fx.writeFile(.{
        .key = attention_clear_key,
        .path = path,
        .bytes = "",
        .on_result = null,
    });
}

var login_plist_buf: [720]u8 = undefined;
var login_plist_path_buf: [512]u8 = undefined;

fn applyLoginAtStart(model: *const Model, fx: *Effects) void {
    // Resolve ~/Library/LaunchAgents/com.pulse.app.plist from settings path home.
    const sp = model.settingsPath();
    if (sp.len == 0) return;
    const marker = "/Library/Application Support/Pulse/settings.txt";
    const home = if (std.mem.endsWith(u8, sp, marker))
        sp[0 .. sp.len - marker.len]
    else
        return;
    const plist_path = std.fmt.bufPrint(&login_plist_path_buf, "{s}/{s}", .{ home, login_agent_relpath }) catch return;
    if (model.login_at_start) {
        const body =
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0"><dict>
            \\<key>Label</key><string>com.pulse.app</string>
            \\<key>ProgramArguments</key><array>
            \\<string>/usr/bin/open</string><string>-a</string><string>Pulse</string>
            \\</array>
            \\<key>RunAtLoad</key><true/>
            \\</dict></plist>
        ;
        const n = @min(body.len, login_plist_buf.len);
        @memcpy(login_plist_buf[0..n], body[0..n]);
        fx.writeFile(.{
            .key = login_key,
            .path = plist_path,
            .bytes = login_plist_buf[0..n],
            .on_result = null,
        });
        // Legacy load works for user LaunchAgents; ignore already-loaded errors.
        fx.spawn(.{
            .key = login_key,
            .argv = &.{ "launchctl", "load", "-w", plist_path },
            .output = .collect,
            .on_exit = Effects.exitMsg(.login_done),
        });
    } else {
        fx.spawn(.{
            .key = login_key,
            .argv = &.{ "launchctl", "unload", "-w", plist_path },
            .output = .collect,
            .on_exit = Effects.exitMsg(.login_done),
        });
    }
}

fn startPollTimer(fx: *Effects) void {
    fx.startTimer(.{
        .key = poll_timer_key,
        .interval_ms = poll_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.poll_tick),
    });
}

fn beginProbe(model: *Model, fx: *Effects) void {
    if (model.probe_in_flight) return;
    model.probe_in_flight = true;
    model.refresh_count +%= 1;
    fx.spawn(.{
        .key = probe_ps_key,
        .argv = &.{ "ps", "-axo", "pid=,ppid=,args=" },
        .output = .collect,
        .on_exit = Effects.exitMsg(.probe_ps_done),
    });
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .refresh => beginProbe(model, fx),
        .toggle_auto_probe => {
            model.auto_probe = !model.auto_probe;
            if (model.auto_probe) {
                startPollTimer(fx);
                beginProbe(model, fx);
            } else {
                fx.cancelTimer(poll_timer_key);
            }
            saveSettings(model, fx);
            model.rebuildTrayMenu();
        },
        .toggle_notify_idle => {
            model.notify_on_idle = !model.notify_on_idle;
            saveSettings(model, fx);
        },
        .toggle_login_at_start => {
            model.login_at_start = !model.login_at_start;
            saveSettings(model, fx);
            applyLoginAtStart(model, fx);
        },
        .cycle_language => {
            model.lang_pref = model.lang_pref.cycle();
            model.refreshAttentionGlance();
            model.rebuildTrayMenu();
            saveSettings(model, fx);
        },
        .set_lang_auto => {
            model.lang_pref = .auto;
            model.refreshAttentionGlance();
            model.rebuildTrayMenu();
            saveSettings(model, fx);
        },
        .set_lang_en => {
            model.lang_pref = .en;
            model.refreshAttentionGlance();
            model.rebuildTrayMenu();
            saveSettings(model, fx);
        },
        .set_lang_zh => {
            model.lang_pref = .zh;
            model.refreshAttentionGlance();
            model.rebuildTrayMenu();
            saveSettings(model, fx);
        },
        .install_hooks => beginInstallHooks(model, fx),
        .clear_attention => clearAttention(model, fx),
        .open_agent_project => |id| openAgentProject(model, fx, id),
        .settings_loaded => |result| {
            switch (result.outcome) {
                .ok => {
                    applySettingsBytes(model, result.bytes);
                    model.refreshAttentionGlance();
                    model.rebuildTrayMenu();
                },
                .not_found => {}, // first run — defaults
                else => {},
            }
            installHookAssets(model, fx);
            startProbeLoop(model, fx);
            beginAttentionRead(model, fx);
            if (model.login_at_start) applyLoginAtStart(model, fx);
        },
        .settings_saved => {
            model.settings_dirty = false;
        },
        .attention_loaded => |result| {
            switch (result.outcome) {
                .ok => {
                    const is_new = model.applyAttentionBytes(result.bytes);
                    if (is_new and model.notify_on_idle) notifyNeedsAttention(model, fx);
                },
                .not_found => {
                    // No hooks yet — clear attention.
                    if (model.attention.count > 0) {
                        model.attention.clear();
                        model.refreshAttentionGlance();
                        model.rebuildTrayMenu();
                    }
                },
                else => {},
            }
        },
        .sim_idle => model.applyManualIdle(),
        .sim_waiting => model.applyManualWaiting(),
        .sim_errored => model.applyManualError(),
        .sim_agent => |id| model.applyManualAgent(id),
        .toggle_agent_picker => model.agent_picker_open = !model.agent_picker_open,
        .close_agent_picker => model.agent_picker_open = false,
        .poll_tick => |timer| {
            if (timer.outcome != .fired) return;
            if (!model.auto_probe) return;
            beginProbe(model, fx);
            beginAttentionRead(model, fx);
        },
        .probe_ps_done => |exit| handlePsDone(model, fx, exit),
        .probe_cli_done => |exit| handleCliDone(model, fx, exit),
        .activity_done => |exit| handleActivityDone(model, exit),
        .notify_done => {},
        .login_done => {},
        .open_done => {},
        .install_hooks_done => |exit| {
            if (exit.reason == .exited and exit.code == 0) {
                model.setHooksStatus(model.tr(.hooks_ok));
            } else {
                model.setHooksStatus(model.tr(.hooks_fail));
            }
        },
        .open_window => fx.showWindow(window_label),
        .quit => fx.quitApp(),
        .chrome_changed => |chrome| {
            model.chrome_leading = chrome.insets.left;
            model.header_height = @max(header_natural_height, chrome.insets.top);
            // Defer minimize until after the installing frame creates the tray.
            // Never fx.closeWindow here: runtime close destroys the window even
            // with close_policy=hide (hide is only the user's red button), which
            // aborts status-item install and leaves no menu-bar extra.
            if (model.hide_main_on_start) {
                model.hide_main_on_start = false;
                fx.startTimer(.{
                    .key = hide_window_timer_key,
                    .interval_ms = hide_window_delay_ms,
                    .mode = .one_shot,
                    .on_fire = Effects.timerMsg(.hide_main_tick),
                });
            }
        },
        .hide_main_tick => |timer| {
            if (timer.outcome != .fired) return;
            // Minimize (not close): window stays alive for Preferences… / showWindow.
            fx.minimizeWindow(window_label);
        },
    }
}

fn handlePsDone(model: *Model, fx: *Effects, exit: native_sdk.EffectExit) void {
    if (exit.reason == .rejected or exit.reason == .spawn_failed) {
        model.setError("ps probe failed");
        model.probe_in_flight = false;
        return;
    }
    if (exit.reason == .cancelled) {
        model.probe_in_flight = false;
        return;
    }
    model.staged_scan = probe.scanPs(exit.output);
    fx.spawn(.{
        .key = probe_cli_key,
        .argv = &.{ "claude", "agents", "--json" },
        .output = .collect,
        .on_exit = Effects.exitMsg(.probe_cli_done),
    });
}

fn handleCliDone(model: *Model, fx: *Effects, exit: native_sdk.EffectExit) void {
    var scan = model.staged_scan;
    var soft_err: []const u8 = "";
    if (exit.reason == .cancelled) {
        model.probe_in_flight = false;
        return;
    } else if (exit.reason == .exited and exit.code == 0) {
        const agents = probe.parseAgentsJson(exit.output);
        if (agents.parsed) {
            probe.applyClaudeAgents(&scan, agents);
        } else soft_err = "agents json unparsed";
    } else if (exit.reason == .rejected or exit.reason == .spawn_failed) {
        // no claude CLI — fine
    } else if (exit.reason == .exited and exit.code != 0) {
        soft_err = "claude agents failed";
    }

    var buf: [summary_cap]u8 = undefined;
    const summary = std.fmt.bufPrint(&buf, "agents={d}; rules={d}", .{ scan.count, probe.rules.len }) catch "probe ok";
    const became_idle = model.applyScan(scan, summary);
    if (soft_err.len > 0) model.setError(soft_err);
    model.probe_in_flight = false;
    model.staged_scan = .{};
    if (became_idle and model.notify_on_idle) notifyAllIdle(model, fx);
    spawnActivityScan(model, fx);
}

fn spawnActivityScan(model: *Model, fx: *Effects) void {
    var path_buf: [512]u8 = undefined;
    const script: []const u8 = blk: {
        const sp = model.settingsPath();
        if (sp.len > 0) {
            if (std.mem.lastIndexOfScalar(u8, sp, '/')) |slash| {
                break :blk std.fmt.bufPrint(&path_buf, "{s}/activity_scan.py", .{sp[0..slash]}) catch "src/activity_scan.py";
            }
        }
        break :blk "src/activity_scan.py";
    };
    // Best-effort install scanner next to settings for packaged runs.
    if (model.settingsPath().len > 0 and script.ptr == path_buf[0..].ptr) {
        fx.writeFile(.{
            .key = activity_script_key,
            .path = script,
            .bytes = activity_scan_py,
            .on_result = null,
        });
    }
    fx.spawn(.{
        .key = activity_scan_key,
        .argv = &.{ "python3", script },
        .output = .collect,
        .on_exit = Effects.exitMsg(.activity_done),
    });
}

fn handleActivityDone(model: *Model, exit: native_sdk.EffectExit) void {
    if (exit.reason != .exited or exit.code != 0) {
        var stubs: [activity.max_activities]activity.Activity = undefined;
        const empty: []const activity.Activity = &.{};
        const n = activity.filterToScan(&model.last_scan, empty, stubs[0..]);
        model.applyActivities(stubs[0..n]);
        return;
    }
    var parsed: [activity.max_activities]activity.Activity = undefined;
    const pn = activity.parseTsvAll(exit.output, parsed[0..]);
    var filtered: [activity.max_activities]activity.Activity = undefined;
    const fn_count = activity.filterToScan(&model.last_scan, parsed[0..pn], filtered[0..]);
    model.applyActivities(filtered[0..fn_count]);
}


// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

pub fn command(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, open_command)) return .open_window;
    if (std.mem.eql(u8, name, quit_command)) return .quit;
    if (std.mem.eql(u8, name, refresh_command)) return .refresh;
    if (std.mem.eql(u8, name, auto_command)) return .toggle_auto_probe;
    if (std.mem.eql(u8, name, install_hooks_command)) return .install_hooks;
    if (std.mem.eql(u8, name, clear_attention_command)) return .clear_attention;
    if (std.mem.startsWith(u8, name, open_project_command_prefix)) {
        const id_s = name[open_project_command_prefix.len..];
        if (activity.parseAgentId(id_s)) |id| return .{ .open_agent_project = id };
    }
    return null;
}

/// Fallback tray before first rebuild (English; rebuilt immediately with locale).
pub const status_items = [_]native_sdk.TrayMenuItem{
    .{ .id = 1, .label = "Refresh", .command = refresh_command },
    .{ .id = 2, .label = "Preferences…", .command = open_command },
    .{ .separator = true },
    .{ .id = 3, .label = "Quit Pulse", .command = quit_command },
};

pub const PulseApp = native_sdk.UiApp(Model, Msg);

pub fn designTokens(model: *const Model) canvas.DesignTokens {
    var tokens = canvas.DesignTokens.theme(.{});
    if (model.locale() == .zh and cjk_font.available()) {
        tokens.typography.font_id = cjk_font.font_id;
        tokens.typography.button_font_id = cjk_font.font_id;
    }
    return tokens;
}

pub fn statusItem(model: *const Model, scratch: *PulseApp.StatusItemScratch) PulseApp.StatusItemState {
    const items = if (model.tray_item_count > 0)
        model.tray_items[0..model.tray_item_count]
    else
        status_items[0..];
    const raw = model.statusTitle();
    const title = if (raw.len <= scratch.title_buffer.len)
        raw
    else blk: {
        const n = scratch.title_buffer.len;
        @memcpy(scratch.title_buffer[0..n], raw[0..n]);
        break :blk scratch.title_buffer[0..n];
    };
    return .{
        .title = title,
        .items = items,
    };
}

pub fn initialModel() Model {
    var model: Model = .{};
    model.rebuildTrayMenu();
    return model;
}

/// Tall hidden-inset geometry before first paint and on chrome changes.
pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

/// Filled before options() when a system CJK TTF was loaded.
var cjk_font_regs: [1]PulseApp.FontRegistration = undefined;

pub fn options(io: std.Io) PulseApp.Options {
    var fonts: []const PulseApp.FontRegistration = &.{};
    if (cjk_font.available()) {
        cjk_font_regs[0] = .{
            .id = cjk_font.font_id,
            .name = "cjk",
            .ttf = cjk_font.bytes,
        };
        fonts = cjk_font_regs[0..1];
    }
    return .{
        .name = "pulse",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .on_command = command,
        .on_chrome = onChrome,
        .tokens_fn = designTokens,
        .fonts = fonts,
        .status_item = .{
            .title = "Pulse",
            .icon_path = tray_icon_path,
            .tooltip = "AI coding agent status",
            .items = &status_items,
        },
        .status_item_fn = statusItem,
        .markup = .{
            .source = app_markup,
            .watch_path = "src/app.native",
            .io = io,
        },
    };
}

pub fn main(init: std.process.Init) !void {
    // Prefer system CJK face so zh Preferences is not tofu.
    cjk_font.tryLoad(std.heap.page_allocator, init.io);

    // Absolute icon path before tray install — packaged apps start with cwd `/`.
    tray_icon_path = resolveTrayIconPath(init.io, &tray_icon_path_buf);

    const app_state = try PulseApp.create(std.heap.page_allocator, options(init.io));
    defer app_state.destroy();
    app_state.model = initialModel();
    app_state.model.system_locale = i18n.detectSystemLocale(init.environ_map);
    app_state.model.rebuildTrayMenu();
    if (init.environ_map.get("HOME")) |home| {
        if (resolveSettingsPath(&app_state.model.settings_path_buf, home)) |path| {
            app_state.model.setSettingsPath(path);
        }
    }

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "pulse",
        .window_title = "Pulse",
        .bundle_id = "com.pulse.app",
        .icon_path = tray_icon_path,
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
    _ = @import("probe.zig");
    _ = @import("activity.zig");
    _ = @import("attention.zig");
    _ = @import("version.zig");
    _ = @import("i18n.zig");
}
