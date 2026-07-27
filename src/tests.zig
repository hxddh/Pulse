//! Pulse product tests: drive shipped Model/Msg/probe/settings/tray paths.

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const probe = @import("probe.zig");
const activity = @import("activity.zig");
const i18n = @import("i18n.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Effects = main.Effects;
const PulseApp = main.PulseApp;
const AppMarkup = canvas.MarkupView(Model, main.Msg);

fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    var view = try AppMarkup.init(arena, main.app_markup);
    var ui = AppUi.init(arena);
    const node = view.build(&ui, model) catch |err| {
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    return ui.finalize(node);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

fn expectByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) !canvas.Widget {
    return findByText(widget, kind, text) orelse {
        std.debug.print("no {t} with text \"{s}\" in the view\n", .{ kind, text });
        return error.WidgetNotFound;
    };
}

fn findByLabel(widget: canvas.Widget, kind: canvas.WidgetKind, label: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, kind, label)) |found| return found;
    }
    return null;
}

fn expectByLabel(widget: canvas.Widget, kind: canvas.WidgetKind, label: []const u8) !canvas.Widget {
    return findByLabel(widget, kind, label) orelse {
        std.debug.print("no {t} with label \"{s}\" in the view\n", .{ kind, label });
        return error.WidgetNotFound;
    };
}

test "statusTitle idle and short glance paths for probe and simulate" {
    var model = main.initialModel();
    model.lang_pref = .zh;
    model.rebuildTrayMenu();
    try testing.expectEqualStrings("", model.statusTitle());

    var scan: probe.ScanResult = .{};
    scan.addProcess(.claude);
    _ = model.applyScan(scan, "ps ok");
    try testing.expectEqualStrings("Claude", model.statusTitle());
    try testing.expectEqual(main.Source.probe, model.source);

    model.applyManualAgent(.gemini);
    try testing.expectEqualStrings("Gemini", model.statusTitle());
    try testing.expectEqual(main.Source.manual, model.source);
}

test "Pi and Grok probe fixtures produce Running titles" {
    var saw_pi_rule = false;
    var saw_grok_rule = false;
    for (probe.rules) |rule| {
        if (rule.id == .pi) {
            saw_pi_rule = true;
            try testing.expect(probe.matchRule(rule, "/opt/homebrew/bin/pi"));
            try testing.expect(probe.matchRule(rule, "node .../pi-coding-agent/dist/cli.js"));
            try testing.expect(!probe.matchRule(rule, "/opt/homebrew/bin/pip3"));
        }
        if (rule.id == .grok) {
            saw_grok_rule = true;
            try testing.expect(probe.matchRule(rule, "/Users/me/.grok/bin/grok"));
            try testing.expect(probe.matchRule(rule, "/bin/zsh -c GROK_AGENT=1 session"));
        }
    }
    try testing.expect(saw_pi_rule);
    try testing.expect(saw_grok_rule);

    const sample =
        \\  11 /opt/homebrew/bin/pi
        \\  22 /Users/me/.grok/bin/grok
        \\
    ;
    const scan = probe.scanPs(sample);
    try testing.expect(scan.contains(.pi));
    try testing.expect(scan.contains(.grok));
    try testing.expectEqualStrings("Grok · Running", probe.statusTitle(&scan));

    var model = main.initialModel();
    _ = model.applyScan(scan, "multi");
    try testing.expectEqualStrings("2", model.statusTitle());
    try testing.expect(std.mem.indexOf(u8, model.agentsLine(), "Pi") != null);
    try testing.expect(std.mem.indexOf(u8, model.agentsLine(), "Grok") != null);
}

test "applyScan multi agent primary is highest priority" {
    var model = main.initialModel();
    var scan: probe.ScanResult = .{};
    scan.addProcess(.cursor);
    scan.addProcess(.claude);
    scan.addProcess(.warp);
    _ = model.applyScan(scan, "test");
    // Cursor/Warp are IDE shells — Glance shows Claude only.
    try testing.expectEqualStrings("Claude", model.statusTitle());
    try testing.expectEqual(@as(usize, 1), model.agentCount());
}

test "tray command names map through on_command" {
    try testing.expectEqual(main.Msg.refresh, main.command(main.refresh_command).?);
    try testing.expectEqual(main.Msg.open_window, main.command(main.open_command).?);
    try testing.expectEqual(main.Msg.quit, main.command(main.quit_command).?);
    try testing.expect(main.command("unknown.cmd") == null);
}

test "open_window and quit hit real window verbs" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model = main.initialModel();
    main.update(&model, .open_window, &fx);
    try testing.expectEqual(@as(u32, 1), fx.windowActionState().show_count);
    try testing.expectEqualStrings(main.window_label, fx.windowActionState().lastLabel());
    main.update(&model, .quit, &fx);
    try testing.expectEqual(@as(u32, 1), fx.windowActionState().quit_count);
}

test "refresh spawns ps collect probe" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model = main.initialModel();
    main.update(&model, .refresh, &fx);
    try testing.expect(model.probe_in_flight);
    const req = fx.pendingSpawnAt(0).?;
    try testing.expectEqual(main.probe_ps_key, req.key);
    try testing.expectEqualStrings("ps", req.argv[0]);
}

test "scene close_policy is hide (menu-bar product shape)" {
    try testing.expectEqual(native_sdk.app_manifest.WindowClosePolicy.hide, main.shell_scene.windows[0].close_policy);
    try testing.expectEqualStrings(main.window_label, main.shell_scene.windows[0].label);
}

test "settings encode/apply round-trip on shipped functions" {
    var model = main.initialModel();
    model.auto_probe = false;
    model.notify_on_idle = true;
    model.lang_pref = .auto;
    var buf: [80]u8 = undefined;
    const enc = main.encodeSettings(&model, &buf);
    try testing.expectEqualStrings("auto=0\nnotify=1\nlang=auto\nlogin=0\n", enc);

    model.auto_probe = true;
    model.notify_on_idle = true;
    main.applySettingsBytes(&model, "auto=0\nnotify=0\nlang=zh\n");
    try testing.expect(!model.auto_probe);
    try testing.expect(!model.notify_on_idle);
    try testing.expectEqual(i18n.LangPref.zh, model.lang_pref);
    main.applySettingsBytes(&model, "auto=1\nnotify=1\nlang=en\n");
    try testing.expect(model.auto_probe);
    try testing.expect(model.notify_on_idle);
    try testing.expectEqual(i18n.LangPref.en, model.lang_pref);
}

test "toggle auto saves real settings bytes through writeFile" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model = main.initialModel();
    model.setSettingsPath("/Users/me/Library/Application Support/Pulse/settings.txt");
    model.auto_probe = true;
    model.notify_on_idle = true;
    model.lang_pref = .auto;
    main.update(&model, .toggle_auto_probe, &fx);
    try testing.expect(!model.auto_probe);

    const req = fx.pendingFileAt(0).?;
    try testing.expectEqual(main.settings_save_key, req.key);
    try testing.expectEqual(native_sdk.EffectFileOp.write, req.op);
    try testing.expectEqualStrings(model.settingsPath(), req.path);
    try testing.expectEqualStrings("auto=0\nnotify=1\nlang=auto\nlogin=0\n", req.bytes);
}

test "settings_loaded Msg applies prefs then starts probe loop" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model = main.initialModel();
    model.auto_probe = true;
    model.setSettingsPath("/Users/me/Library/Application Support/Pulse/settings.txt");

    const loaded = native_sdk.EffectFileResult{
        .key = main.settings_load_key,
        .op = .read,
        .outcome = .ok,
        .bytes = "auto=0\n",
    };
    main.update(&model, .{ .settings_loaded = loaded }, &fx);
    try testing.expect(!model.auto_probe);
    try testing.expect(fx.pendingSpawnAt(0) == null);

    model.auto_probe = false;
    const loaded_on = native_sdk.EffectFileResult{
        .key = main.settings_load_key,
        .op = .read,
        .outcome = .ok,
        .bytes = "auto=1\n",
    };
    main.update(&model, .{ .settings_loaded = loaded_on }, &fx);
    try testing.expect(model.auto_probe);
    try testing.expect(model.probe_in_flight);
    try testing.expectEqual(main.probe_ps_key, fx.pendingSpawnAt(0).?.key);
}

test "preferences markup builds settings-first surface" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    const tree = try buildTree(arena, &model);
    // Brand in chrome (settings-first; not a hero Idle heading).
    _ = try expectByText(tree.root, .text, "Pulse");
    _ = try expectByLabel(tree.root, .button, "Refresh");
    _ = try expectByLabel(tree.root, .switch_control, "Live updates");
    _ = try expectByLabel(tree.root, .switch_control, "Notifications");
    _ = try expectByLabel(tree.root, .switch_control, "Launch at login");
    try testing.expect(findByText(tree.root, .text, "Simulate") == null);
    _ = try expectByText(tree.root, .text, "General");
}

test "manual agent still drives short glance title (debug path)" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model = main.initialModel();
    main.update(&model, .{ .sim_agent = .grok }, &fx);
    try testing.expectEqualStrings("Grok", model.statusTitle());
    try testing.expectEqualStrings("Grok", model.selectedAgentLabel());
}

test "chrome header fields default for utility layout" {
    const model = main.initialModel();
    try testing.expectEqual(main.header_natural_height, model.header_height);
    try testing.expectEqual(@as(f32, 0), model.chrome_leading);
    // Scene declares the same hidden-inset chrome as app.zon.
    try testing.expectEqual(native_sdk.app_manifest.WindowTitlebarStyle.hidden_inset_tall, main.shell_scene.windows[0].titlebar);
}

test "onChrome updates leading inset and header height" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model = main.initialModel();
    var chrome: native_sdk.WindowChrome = .{};
    chrome.insets.left = 78;
    chrome.insets.top = 52;
    main.update(&model, .{ .chrome_changed = chrome }, &fx);
    try testing.expectEqual(@as(f32, 78), model.chrome_leading);
    try testing.expectEqual(@as(f32, 52), model.header_height);
}

fn createApp() !*PulseApp {
    const io: std.Io = undefined;
    return try PulseApp.create(testing.allocator, main.options(io));
}

fn startedHarness(app_state: *PulseApp) !*native_sdk.TestHarness() {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = geometry.SizeF.init(360, 340) });
    errdefer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    app_state.effects.executor = .fake;
    const app = app_state.app();
    try harness.start(app);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = main.canvas_label,
        .size = geometry.SizeF.init(360, 340),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    return harness;
}

test "status item installs with empty idle title (icon-only)" {
    const app_state = try createApp();
    defer app_state.destroy();
    app_state.model.lang_pref = .en;
    app_state.model.rebuildTrayMenu();
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    try testing.expectEqual(@as(usize, 1), harness.null_platform.trayCreateCount());
    try testing.expectEqualStrings("", harness.null_platform.lastTrayTitle());
}

test "tray Refresh Open Quit and retitle drive product loop" {
    const app_state = try createApp();
    defer app_state.destroy();
    const harness = try startedHarness(app_state);
    defer harness.destroy(testing.allocator);
    const app = app_state.app();

    // Resolve action ids from the live dropdown (ids change when the menu rebuilds).
    const refresh_id = trayIdForCommand(&app_state.model, main.refresh_command) orelse 1;
    const open_id = trayIdForCommand(&app_state.model, main.open_command) orelse 2;

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = refresh_id });
    try testing.expect(app_state.model.probe_in_flight or app_state.model.refresh_count >= 1);

    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = open_id });
    try testing.expectEqual(@as(u32, 1), app_state.effects.windowActionState().show_count);

    try app_state.dispatch(&harness.runtime, 10, .{ .sim_agent = .codex });
    try testing.expectEqualStrings("Codex", harness.null_platform.lastTrayTitle());

    // IDs are rebuilt with the menu; resolve Quit after the retitle.
    const quit_id = trayIdForCommand(&app_state.model, main.quit_command) orelse return error.QuitMissing;
    try harness.runtime.dispatchPlatformEvent(app, .{ .tray_action = quit_id });
    try testing.expectEqual(@as(u32, 1), app_state.effects.windowActionState().quit_count);
    try harness.stop(app);
}

fn trayIdForCommand(model: *const main.Model, cmd: []const u8) ?u32 {
    for (model.tray_items[0..model.tray_item_count]) |item| {
        if (item.separator) continue;
        if (std.mem.eql(u8, item.command, cmd)) return item.id;
    }
    return null;
}

test "tray menu is scannable one-line agents without token dump" {
    var model = main.initialModel();
    model.lang_pref = .zh;
    var scan: probe.ScanResult = .{};
    scan.addProcess(.claude);
    scan.addProcess(.codex);
    scan.addProcess(.cursor); // IDE shell — must not appear
    scan.addProcess(.warp);
    _ = model.applyScan(scan, "t");
    var acts = [_]activity.Activity{
        blk: {
            var a: activity.Activity = .{ .id = .claude };
            a.setTask("Build UI");
            a.tokens_in = 1200;
            a.tokens_out = 80;
            a.setTool("Bash");
            a.setSkill("foo");
            a.setProject("Pulse");
            break :blk a;
        },
        blk: {
            var a: activity.Activity = .{ .id = .codex };
            a.setTask("Fix bug");
            a.setTool("exec_command");
            break :blk a;
        },
    };
    model.applyActivities(&acts);
    try testing.expectEqual(@as(usize, 2), model.agentCount());
    try testing.expectEqualStrings("2", model.statusTitle());
    try testing.expect(trayIdForCommand(&model, main.refresh_command) != null);
    try testing.expect(trayIdForCommand(&model, main.quit_command) != null);
    try testing.expect(trayIdForCommand(&model, main.open_command) != null);
    try testing.expect(trayIdForCommand(&model, main.auto_command) == null);
    var saw_claude_row = false;
    var saw_task = false;
    var saw_meta = false;
    var saw_project = false;
    var saw_cursor = false;
    var saw_live = false;
    var saw_running_glyph = false;
    for (model.tray_items[0..model.tray_item_count]) |item| {
        if (item.separator) continue;
        if (std.mem.indexOf(u8, item.label, "Claude") != null and std.mem.indexOf(u8, item.label, "●") != null)
            saw_claude_row = true;
        if (std.mem.indexOf(u8, item.label, "●") != null) saw_running_glyph = true;
        if (std.mem.indexOf(u8, item.label, "Build UI") != null) saw_task = true;
        if (std.mem.indexOf(u8, item.label, "↑") != null or std.mem.indexOf(u8, item.label, "Bash") != null)
            saw_meta = true;
        if (std.mem.indexOf(u8, item.label, "Pulse") != null and std.mem.indexOf(u8, item.label, "Claude") != null)
            saw_project = true;
        if (std.mem.indexOf(u8, item.label, "Cursor") != null or std.mem.indexOf(u8, item.label, "Warp") != null)
            saw_cursor = true;
        if (std.mem.indexOf(u8, item.label, "Live") != null) saw_live = true;
    }
    try testing.expect(saw_claude_row);
    try testing.expect(saw_running_glyph);
    try testing.expect(!saw_task); // tasks stay out of tray
    try testing.expect(!saw_meta); // tokens/tools stay out of tray
    try testing.expect(saw_project);
    try testing.expect(!saw_cursor);
    try testing.expect(!saw_live);
    // Header: "2 个运行中 · …" — no token dump
    try testing.expect(std.mem.indexOf(u8, model.tray_items[0].label, "2 个运行中") != null);
    try testing.expect(std.mem.indexOf(u8, model.tray_items[0].label, "↑") == null);
}

test "tray wait row includes kind and age" {
    var model = main.initialModel();
    model.lang_pref = .en;
    const now = @import("native_sdk").nowMs();
    const ts = now - 120_000; // ~2 minutes ago
    var tsv_buf: [96]u8 = undefined;
    const tsv = std.fmt.bufPrint(&tsv_buf, "claude\tpermission\t{d}\tAllow Bash?\n", .{ts}) catch return error.Fmt;
    try testing.expect(model.applyAttentionBytes(tsv));
    var saw_kind = false;
    var saw_msg = false;
    var saw_age = false;
    for (model.tray_items[0..model.tray_item_count]) |item| {
        if (item.separator) continue;
        if (std.mem.indexOf(u8, item.label, "Permission") != null) saw_kind = true;
        if (std.mem.indexOf(u8, item.label, "Allow Bash") != null) saw_msg = true;
        if (std.mem.indexOf(u8, item.label, "2m") != null or std.mem.indexOf(u8, item.label, "1m") != null or std.mem.indexOf(u8, item.label, "3m") != null)
            saw_age = true;
    }
    try testing.expect(saw_kind);
    try testing.expect(saw_msg);
    try testing.expect(saw_age);
}

test "applyScan active-to-idle edge is detected for notify" {
    var model = main.initialModel();
    model.lang_pref = .en;
    var scan: probe.ScanResult = .{};
    scan.addProcess(.claude);
    try testing.expect(!model.applyScan(scan, "on"));
    try testing.expectEqual(@as(usize, 1), model.prev_agent_count);

    const empty: probe.ScanResult = .{};
    try testing.expect(model.applyScan(empty, "off"));
    try testing.expectEqual(@as(usize, 0), model.prev_agent_count);
    try testing.expectEqualStrings("", model.statusTitle());
}

test "notify_on_idle toggle persists" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model = main.initialModel();
    model.setSettingsPath("/Users/me/Library/Application Support/Pulse/settings.txt");
    model.lang_pref = .auto;
    try testing.expect(model.notify_on_idle);
    main.update(&model, .toggle_notify_idle, &fx);
    try testing.expect(!model.notify_on_idle);
    const req = fx.pendingFileAt(0).?;
    try testing.expectEqualStrings("auto=1\nnotify=0\nlang=auto\nlogin=0\n", req.bytes);
}

test "set language pref en -> zh -> auto" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model = main.initialModel();
    model.lang_pref = .en;
    main.update(&model, .set_lang_zh, &fx);
    try testing.expectEqual(i18n.LangPref.zh, model.lang_pref);
    try testing.expectEqualStrings("", model.statusTitle());
    main.update(&model, .set_lang_auto, &fx);
    try testing.expectEqual(i18n.LangPref.auto, model.lang_pref);
}

test "first chrome schedules deferred minimize for dropdown-first UX" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model = main.initialModel();
    try testing.expect(model.hide_main_on_start);
    var chrome: native_sdk.WindowChrome = .{};
    chrome.insets.left = 78;
    chrome.insets.top = 52;
    main.update(&model, .{ .chrome_changed = chrome }, &fx);
    try testing.expect(!model.hide_main_on_start);
    // Chrome only arms a one-shot timer — minimize waits so tray can install.
    try testing.expectEqual(@as(u32, 0), fx.windowActionState().minimize_count);
    try testing.expectEqual(@as(u32, 0), fx.windowActionState().close_count);

    main.update(&model, .{ .hide_main_tick = .{ .key = main.hide_window_timer_key, .outcome = .fired } }, &fx);
    try testing.expectEqual(@as(u32, 1), fx.windowActionState().minimize_count);
    try testing.expectEqual(@as(u32, 0), fx.windowActionState().close_count);
    try testing.expectEqualStrings(main.window_label, fx.windowActionState().lastLabel());
}

test "simAgents includes Pi and Grok among product presets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = main.initialModel();
    const items = model.simAgents(arena_state.allocator());
    try testing.expect(items.len >= 15);
    var saw_pi = false;
    var saw_grok = false;
    for (items) |it| {
        if (it.id == .pi) saw_pi = true;
        if (it.id == .grok) saw_grok = true;
    }
    try testing.expect(saw_pi);
    try testing.expect(saw_grok);
}


test "activity TSV drives concurrent agent detail rows" {
    const text =
        "claude\tBuild UI\t1000\t50\tBash\tcreate-skill\n" ++
        "codex\tFix bug\t2000\t80\texec_command\t\n";
    var parsed: [8]activity.Activity = undefined;
    const n = activity.parseTsvAll(text, &parsed);
    try testing.expectEqual(@as(usize, 2), n);

    var model = main.initialModel();
    var scan: probe.ScanResult = .{};
    scan.addProcess(.claude);
    scan.addProcess(.codex);
    _ = model.applyScan(scan, "test");
    try testing.expectEqualStrings("2", model.statusTitle());

    var filtered: [8]activity.Activity = undefined;
    const fn_count = activity.filterToScan(&scan, parsed[0..n], &filtered);
    model.applyActivities(filtered[0..fn_count]);
    try testing.expect(model.hasActivities());
    try testing.expectEqual(@as(usize, 2), model.activityRows().len);
    try testing.expectEqualStrings("Build UI", model.activityRows()[0].task());
    try testing.expectEqualStrings("Bash", model.activityRows()[0].tool());
    try testing.expectEqualStrings("create-skill", model.activityRows()[0].skill());
}

test "idle tray menu validates against SDK rules" {
    var model = main.initialModel();
    try testing.expect(model.tray_item_count > 0);
    // Must not exceed 32; separators id=0 ok; commands need non-zero ids
    try testing.expect(model.tray_item_count <= 32);
    var ids_seen: [33]bool = .{false} ** 33;
    for (model.tray_items[0..model.tray_item_count]) |item| {
        if (item.separator) continue;
        try testing.expect(item.label.len > 0);
        try testing.expect(item.label.len <= 256);
        if (item.command.len > 0) {
            try testing.expect(item.id != 0);
            try testing.expect(item.command.len <= 128);
        }
        if (item.id != 0 and item.id < 33) {
            try testing.expect(!ids_seen[item.id]);
            ids_seen[item.id] = true;
        }
    }
    const title = model.statusTitle();
    try testing.expect(title.len <= 64);
}

test "setSettingsPath accepts resolveSettingsPath output (no alias panic)" {
    var model = main.initialModel();
    const path = main.resolveSettingsPath(&model.settings_path_buf, "/Users/me") orelse return error.PathFailed;
    model.setSettingsPath(path);
    try testing.expect(std.mem.endsWith(u8, model.settingsPath(), "Pulse/settings.txt"));
}

test "product version is semver 0.5.0 with about line" {
    try testing.expectEqualStrings("0.5.0", main.app_version);
    var buf: [32]u8 = undefined;
    const about = @import("version.zig").aboutLine(&buf);
    try testing.expectEqualStrings("Pulse 0.5.0", about);
    try testing.expectEqual(@as(u32, 0), @import("version.zig").major);
    try testing.expectEqual(@as(u32, 5), @import("version.zig").minor);
    try testing.expectEqual(@as(u32, 0), @import("version.zig").patch);
}

test "resolveTrayIconPath finds project assets or stays relative" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = main.resolveTrayIconPath(io, &buf);
    try testing.expect(path.len > 0);
    // Under `native test` cwd is the project root — expect absolute assets path.
    if (std.Io.Dir.cwd().access(io, main.tray_icon_relpath, .{})) |_| {
        try testing.expect(std.fs.path.isAbsolute(path));
        try testing.expect(std.mem.endsWith(u8, path, main.tray_icon_relpath));
    } else |_| {
        try testing.expectEqualStrings(main.tray_icon_relpath, path);
    }
}

test "Cursor session activity surfaces without IDE process count" {
    var model = main.initialModel();
    model.lang_pref = .en;
    var scan: probe.ScanResult = .{};
    scan.addProcess(.cursor); // IDE shell alone — not listed
    scan.addProcess(.cursor_agent);
    _ = model.applyScan(scan, "t");
    // Process-only: Cursor Agent shows, Cursor IDE does not inflate as Cursor
    try testing.expectEqual(@as(usize, 1), model.agentCount());
    try testing.expectEqualStrings("Cursor Agent", model.statusTitle());

    var acts = [_]activity.Activity{
        blk: {
            var a: activity.Activity = .{ .id = .cursor };
            a.setTask("Pulse macOS project evaluation");
            a.setProject("Pulse");
            a.setCwd("/Users/me/Pulse");
            break :blk a;
        },
    };
    model.applyActivities(&acts);
    // Session replaces worker double-count → still one Cursor row preferred
    try testing.expectEqual(@as(usize, 1), model.agentCount());
    try testing.expectEqualStrings("Cursor", model.statusTitle());
    var saw_cursor = false;
    var saw_agent_worker = false;
    var saw_title = false;
    for (model.tray_items[0..model.tray_item_count]) |item| {
        if (item.separator) continue;
        if (std.mem.indexOf(u8, item.label, "Cursor Agent") != null) saw_agent_worker = true;
        if (std.mem.indexOf(u8, item.label, "Cursor") != null and std.mem.indexOf(u8, item.label, "Pulse") != null)
            saw_cursor = true;
        if (std.mem.indexOf(u8, item.label, "Pulse macOS") != null) saw_title = true;
    }
    try testing.expect(saw_cursor);
    try testing.expect(!saw_agent_worker);
    try testing.expect(saw_title);
}

test "attention sets 等待中 rows and glance wait marker" {
    var model = main.initialModel();
    model.lang_pref = .zh;
    const tsv = "claude\tpermission\t9999999999999\tAllow Bash?\n";
    try testing.expect(model.applyAttentionBytes(tsv));
    try testing.expect(model.hasAttention());
    try testing.expectEqualStrings("Claude 等", model.statusTitle());
    try testing.expectEqualStrings("等待中", model.rowStatus(.claude));
    var saw_waiting = false;
    var saw_detail = false;
    for (model.tray_items[0..model.tray_item_count]) |item| {
        if (item.separator) continue;
        if (std.mem.indexOf(u8, item.label, "⏸") != null and std.mem.indexOf(u8, item.label, "Claude") != null)
            saw_waiting = true;
        if (std.mem.indexOf(u8, item.label, "Allow Bash") != null) saw_detail = true;
    }
    try testing.expect(saw_waiting);
    try testing.expect(saw_detail);
    _ = model.applyAttentionBytes("claude\tstop\t9999999999999\t\n");
    try testing.expect(!model.hasAttention());
    try testing.expectEqualStrings("", model.statusTitle());
}

test "english locale tray strings" {
    var model = main.initialModel();
    model.lang_pref = .en;
    model.rebuildTrayMenu();
    try testing.expectEqualStrings("", model.statusTitle());
    try testing.expect(std.mem.indexOf(u8, model.tray_items[0].label, "No coding agents") != null);
    var scan: probe.ScanResult = .{};
    scan.addProcess(.claude);
    _ = model.applyScan(scan, "t");
    try testing.expectEqualStrings("Claude", model.statusTitle());
    try testing.expect(std.mem.indexOf(u8, model.tray_items[0].label, "1 running") != null);
}

test "idle tray shows empty hint not only headline" {
    var model = main.initialModel();
    model.lang_pref = .en;
    model.rebuildTrayMenu();
    var saw_hint = false;
    for (model.tray_items[0..model.tray_item_count]) |item| {
        if (item.separator) continue;
        if (std.mem.indexOf(u8, item.label, "No coding agents") != null) saw_hint = true;
    }
    try testing.expect(saw_hint);
}

test "install_hooks command maps" {
    try testing.expectEqual(main.Msg.install_hooks, main.command(main.install_hooks_command).?);
}
