//! Legacy Zig shell's copy of the product version.
//! NOT the source of truth — that is `PulseVersion.semver` in
//! `PulseBar/Sources/PulseBar/Models.swift`. `scripts/version_check.py`
//! keeps this file and `app.zon` from drifting away from it.

const std = @import("std");

/// Marketing / package version (MAJOR.MINOR.PATCH).
pub const semver: []const u8 = "0.22.0";

pub const major: u32 = 0;
pub const minor: u32 = 22;
pub const patch: u32 = 0;

/// Product line for About / status-bar.
pub fn aboutLine(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "Pulse {s}", .{semver}) catch "Pulse";
}

/// Compact badge for menus / logs.
pub fn shortLabel(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "v{s}", .{semver}) catch "v?";
}

test "semver parts match string" {
    var buf: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{ major, minor, patch });
    try std.testing.expectEqualStrings(expected, semver);
}
