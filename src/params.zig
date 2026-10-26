//! Automatable parameters (gain and the ADSR envelope), shared by the engine,
//! both plugin formats and the editor.
//!
//! Values are kept in plain units (dB, milliseconds, percent). "Normalized"
//! values in [0, 1] are what VST3 hosts and the editor controls work with;
//! time parameters use a cubic curve so short times get most of the range.

const std = @import("std");

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

pub const Unit = enum { decibels, milliseconds, percent, list };

pub const Info = struct {
    name: []const u8,
    short_name: []const u8,
    unit: Unit,
    min: f32,
    max: f32,
    default: f32,
    /// Normalized = ((plain - min) / (max - min)) ^ (1 / 3) when true.
    cubic: bool = false,
    /// For `.list`: the name of each value 0, 1, 2...
    choices: []const []const u8 = &.{},

    pub fn unitLabel(self: Info) []const u8 {
        return switch (self.unit) {
            .decibels => "dB",
            .milliseconds => "ms",
            .percent => "%",
            .list => "",
        };
    }

    /// Number of discrete steps between min and max (VST3 stepCount); 0 for
    /// continuous parameters.
    pub fn steps(self: Info) u32 {
        return if (self.unit == .list) @intCast(self.choices.len - 1) else 0;
    }

    pub fn clamp(self: Info, plain: f32) f32 {
        if (std.math.isNan(plain)) return self.default;
        const v = std.math.clamp(plain, self.min, self.max);
        return if (self.unit == .list) @round(v) else v;
    }

    pub fn toNormalized(self: Info, plain: f32) f64 {
        const t: f64 = (self.clamp(plain) - self.min) / (self.max - self.min);
        return if (self.cubic) std.math.cbrt(t) else t;
    }

    pub fn fromNormalized(self: Info, normalized: f64) f32 {
        const n = std.math.clamp(normalized, 0, 1);
        const t = if (self.cubic) n * n * n else n;
        return self.clamp(@floatCast(self.min + t * (self.max - self.min)));
    }

    /// Display text without the unit, e.g. "-6.0" or "250". Times stay in
    /// milliseconds so the text fields round-trip through `parse`.
    pub fn format(self: Info, buf: []u8, plain: f32) []const u8 {
        var v = self.clamp(plain);
        // Round-tripping through normalized values can leave -0.00001,
        // which would print as "-0.0".
        if (@abs(v) < 0.05) v = 0;
        return switch (self.unit) {
            .list => self.choices[@intFromFloat(v)],
            .decibels => if (v <= self.min) "-inf" else std.fmt.bufPrint(buf, "{d:.1}", .{v}) catch "?",
            .milliseconds => if (v < 10)
                std.fmt.bufPrint(buf, "{d:.1}", .{v}) catch "?"
            else
                std.fmt.bufPrint(buf, "{d:.0}", .{v}) catch "?",
            .percent => std.fmt.bufPrint(buf, "{d:.0}", .{v}) catch "?",
        };
    }

    /// Parses user input. Accepts an optional unit suffix ("250ms", "1.5 s",
    /// "-6 dB", "70%"). Returns null for anything else.
    pub fn parse(self: Info, text: []const u8) ?f32 {
        var s = std.mem.trim(u8, text, " \t");
        if (self.unit == .decibels and std.ascii.eqlIgnoreCase(s, "-inf")) return self.min;
        if (self.unit == .list) {
            for (self.choices, 0..) |choice, i| {
                if (std.ascii.eqlIgnoreCase(s, choice)) return @floatFromInt(i);
            }
        }
        var scale: f32 = 1;
        const suffixes = switch (self.unit) {
            .decibels => &[_]struct { []const u8, f32 }{.{ "db", 1 }},
            .milliseconds => &[_]struct { []const u8, f32 }{ .{ "ms", 1 }, .{ "s", 1000 } },
            .percent => &[_]struct { []const u8, f32 }{.{ "%", 1 }},
            .list => &[_]struct { []const u8, f32 }{},
        };
        for (suffixes) |suffix| {
            if (s.len > suffix[0].len and std.ascii.endsWithIgnoreCase(s, suffix[0])) {
                s = std.mem.trimEnd(u8, s[0 .. s.len - suffix[0].len], " ");
                scale = suffix[1];
                break;
            }
        }
        const v = std.fmt.parseFloat(f32, s) catch return null;
        if (!std.math.isFinite(v)) return null;
        return self.clamp(v * scale);
    }
};

const max_time_ms = 10_000;

pub const infos = std.enums.EnumArray(Id, Info).init(.{
    .gain = .{ .name = "Gain", .short_name = "Gain", .unit = .decibels, .min = -60, .max = 12, .default = 0 },
    .attack = .{ .name = "Attack", .short_name = "Atk", .unit = .milliseconds, .min = 0, .max = max_time_ms, .default = 5, .cubic = true },
    .decay = .{ .name = "Decay", .short_name = "Dec", .unit = .milliseconds, .min = 0, .max = max_time_ms, .default = 250, .cubic = true },
    .sustain = .{ .name = "Sustain", .short_name = "Sus", .unit = .percent, .min = 0, .max = 100, .default = 70 },
    .release = .{ .name = "Release", .short_name = "Rel", .unit = .milliseconds, .min = 0, .max = max_time_ms, .default = 300, .cubic = true },
    .mix = .{ .name = "Mix", .short_name = "Mix", .unit = .percent, .min = 0, .max = 100, .default = 0 },
    .mode = .{ .name = "Mode", .short_name = "Mode", .unit = .list, .min = 0, .max = mode_names.len - 1, .default = 0, .choices = &mode_names },
});

pub fn mode(v: *const Values) Mode {
    return @enumFromInt(@as(u8, @intFromFloat(v.get(.mode))));
}

pub fn info(id: Id) Info {
    return infos.get(id);
}

pub fn fromIndex(index: anytype) ?Id {
    if (index < 0 or index >= count) return null;
    return @enumFromInt(index);
}

/// Current values, written by the UI/host threads and read by the audio
/// thread. Each value is an independent atomic.
pub const Values = struct {
    bits: [count]std.atomic.Value(u32) = blk: {
        var b: [count]std.atomic.Value(u32) = undefined;
        for (std.enums.values(Id)) |id| b[@intFromEnum(id)] = .init(@bitCast(info(id).default));
        break :blk b;
    },

    pub fn get(v: *const Values, id: Id) f32 {
        return @bitCast(v.bits[@intFromEnum(id)].load(.monotonic));
    }

    pub fn set(v: *Values, id: Id, plain: f32) void {
        v.bits[@intFromEnum(id)].store(@bitCast(info(id).clamp(plain)), .monotonic);
    }

    pub fn snapshot(v: *const Values) [count]f32 {
        var out: [count]f32 = undefined;
        for (std.enums.values(Id)) |id| out[@intFromEnum(id)] = v.get(id);
        return out;
    }
};

pub fn dbToGain(db: f32) f32 {
    if (db <= info(.gain).min) return 0;
    return std.math.pow(f32, 10, db / 20);
}

test "normalized round trip" {
    for (std.enums.values(Id)) |id| {
        const i = info(id);
        if (i.unit == .list) continue; // snaps to steps; tested separately
        for ([_]f64{ 0, 0.1, 0.5, 0.9, 1 }) |n| {
            try std.testing.expectApproxEqAbs(n, i.toNormalized(i.fromNormalized(n)), 1e-5);
        }
        try std.testing.expectApproxEqAbs(i.default, i.fromNormalized(i.toNormalized(i.default)), i.max * 1e-5);
    }
    // Cubic: the middle of the range is 1/8 of max time.
    try std.testing.expectApproxEqAbs(@as(f32, 1250), info(.attack).fromNormalized(0.5), 0.5);
}

test "format and parse" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("-6.0", info(.gain).format(&buf, -6));
    try std.testing.expectEqualStrings("-inf", info(.gain).format(&buf, -60));
    try std.testing.expectEqualStrings("2.5", info(.attack).format(&buf, 2.5));
    try std.testing.expectEqualStrings("250", info(.decay).format(&buf, 250.2));
    try std.testing.expectEqualStrings("70", info(.sustain).format(&buf, 70));

    try std.testing.expectEqual(@as(?f32, 1500), info(.release).parse("1.5 s"));
    try std.testing.expectEqual(@as(?f32, 250), info(.release).parse(" 250ms "));
    try std.testing.expectEqual(@as(?f32, 10_000), info(.release).parse("99999"));
    try std.testing.expectEqual(@as(?f32, -6), info(.gain).parse("-6 dB"));
    try std.testing.expectEqual(@as(?f32, -60), info(.gain).parse("-inf"));
    try std.testing.expectEqual(@as(?f32, 55), info(.sustain).parse("55%"));
    try std.testing.expectEqual(@as(?f32, null), info(.sustain).parse("abc"));
    try std.testing.expectEqual(@as(?f32, null), info(.sustain).parse(""));
}

test "list parameter" {
    const i = info(.mode);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 2), i.steps());
    try std.testing.expectEqualStrings("FM", i.format(&buf, 1));
    try std.testing.expectEqual(@as(?f32, 2), i.parse("ring"));
    try std.testing.expectEqual(@as(?f32, 1), i.parse("1"));
    try std.testing.expectEqual(@as(f32, 1), i.fromNormalized(0.6)); // nearest step
    try std.testing.expectEqual(@as(f64, 0.5), i.toNormalized(1));
    var v: Values = .{};
    v.set(.mode, 2.4);
    try std.testing.expectEqual(Mode.ring, mode(&v));
}

test "values default and clamp" {
    var v: Values = .{};
    try std.testing.expectEqual(@as(f32, 70), v.get(.sustain));
    v.set(.sustain, 150);
    try std.testing.expectEqual(@as(f32, 100), v.get(.sustain));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5012), dbToGain(-6), 1e-3);
    try std.testing.expectEqual(@as(f32, 0), dbToGain(-60));
}
