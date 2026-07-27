//! Optional system CJK face for Chinese Preferences text.
//! Loaded once at process start from macOS Supplemental fonts (Zig 0.16 Io API).

const std = @import("std");
const canvas = @import("native_sdk").canvas;

/// Registered canvas font id (must be >= min_registered_font_id).
pub const font_id: canvas.FontId = canvas.min_registered_font_id;

/// Owned process-lifetime bytes (empty if load failed).
pub var bytes: []const u8 = &.{};

const candidates = [_][]const u8{
    "/System/Library/Fonts/Supplemental/NISC18030.ttf",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
};

/// Best-effort load via std.Io (Zig 0.16). Call from main before UiApp.create.
pub fn tryLoad(allocator: std.mem.Allocator, io: std.Io) void {
    if (bytes.len > 0) return;
    for (candidates) |path| {
        const data = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(40 * 1024 * 1024)) catch continue;
        if (data.len < 1000) {
            allocator.free(data);
            continue;
        }
        bytes = data;
        return;
    }
}

pub fn available() bool {
    return bytes.len > 0;
}
