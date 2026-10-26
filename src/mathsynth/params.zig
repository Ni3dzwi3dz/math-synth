//! MathSynth's automatable parameters: gain, the ADSR envelope and how the
//! two waves are combined.

const std = @import("std");
const common = @import("common");
const param = common.param;

/// Numbering is part of saved projects and automation: only append.
pub const Id = enum(u32) {
    gain,
    attack,
    decay,
    sustain,
    release,
    /// Amount for the selected `mode`: blend, FM depth or ring amount.
    mix,
    /// How the two waves are combined; a `Mode` index.
    mode,
};

/// Ways of combining the two waves. Order is saved: only append.
pub const Mode = enum(u8) {
    /// Crossfade from f1 to f2.
    sum,
    /// f2 modulates the phase of f1.
    fm,
    /// f1 multiplied by f2, blended with plain f1.
    ring,
};

pub const mode_names = [_][]const u8{ "Sum", "FM", "Ring" };

pub const count = std.enums.values(Id).len;

const max_time_ms = 10_000;

/// Indexed by `Id`.
pub const infos = std.enums.EnumArray(Id, param.Info).init(.{
    .gain = .{ .name = "Gain", .short_name = "Gain", .unit = .decibels, .min = -60, .max = 12, .default = 0 },
    .attack = .{ .name = "Attack", .short_name = "Atk", .unit = .milliseconds, .min = 0, .max = max_time_ms, .default = 5, .cubic = true },
    .decay = .{ .name = "Decay", .short_name = "Dec", .unit = .milliseconds, .min = 0, .max = max_time_ms, .default = 250, .cubic = true },
    .sustain = .{ .name = "Sustain", .short_name = "Sus", .unit = .percent, .min = 0, .max = 100, .default = 70 },
    .release = .{ .name = "Release", .short_name = "Rel", .unit = .milliseconds, .min = 0, .max = max_time_ms, .default = 300, .cubic = true },
    .mix = .{ .name = "Mix", .short_name = "Mix", .unit = .percent, .min = 0, .max = 100, .default = 0 },
    .mode = .{ .name = "Mode", .short_name = "Mode", .unit = .list, .min = 0, .max = mode_names.len - 1, .default = 0, .choices = &mode_names },
}).values;

pub const Values = param.Store(Id, &infos);

pub fn info(id: Id) param.Info {
    return infos[@intFromEnum(id)];
}

pub fn fromIndex(index: anytype) ?Id {
    return param.fromIndex(Id, index);
}

pub fn mode(v: *const Values) Mode {
    return @enumFromInt(@as(u8, @intFromFloat(v.get(.mode))));
}

pub fn dbToGain(db: f32) f32 {
    return param.dbToGain(db, info(.gain).min);
}

test "mode follows the stored value" {
    var v: Values = .{};
    try std.testing.expectEqual(Mode.sum, mode(&v));
    v.set(.mode, 2.4);
    try std.testing.expectEqual(Mode.ring, mode(&v));
    try std.testing.expectEqual(@as(f32, 70), v.get(.sustain));
}
