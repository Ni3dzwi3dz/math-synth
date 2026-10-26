//! Plugin parameters: description (units, range, default, curve), value
//! formatting and parsing, and a lock-free store for the current values.
//!
//! Values are kept in plain units (dB, milliseconds, percent, list index).
//! "Normalized" values in [0, 1] are what VST3 hosts and editor controls work
//! with; time parameters can use a cubic curve so short times get most of the
//! range.

const std = @import("std");

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

/// Current values of a plugin's parameters, written by the UI/host threads
/// and read by the audio thread. Each value is an independent atomic.
/// `Id` is an enum numbering the parameters; `infos[i]` describes the one
/// with value `i`.
pub fn Store(comptime Id: type, comptime infos: []const Info) type {
    std.debug.assert(std.enums.values(Id).len == infos.len);
    return struct {
        const Self = @This();
        pub const count = infos.len;

        bits: [count]std.atomic.Value(u32) = blk: {
            var b: [count]std.atomic.Value(u32) = undefined;
            for (infos, 0..) |i, n| b[n] = .init(@bitCast(i.default));
            break :blk b;
        },

        pub fn get(v: *const Self, id: Id) f32 {
            return v.getIndex(@intFromEnum(id));
        }

        pub fn set(v: *Self, id: Id, plain: f32) void {
            v.setIndex(@intFromEnum(id), plain);
        }

        pub fn getIndex(v: *const Self, index: usize) f32 {
            return @bitCast(v.bits[index].load(.monotonic));
        }

        pub fn setIndex(v: *Self, index: usize, plain: f32) void {
            v.bits[index].store(@bitCast(infos[index].clamp(plain)), .monotonic);
        }

        pub fn snapshot(v: *const Self) [count]f32 {
            var out: [count]f32 = undefined;
            for (&out, 0..) |*o, i| o.* = v.getIndex(i);
            return out;
        }
    };
}

/// The parameter numbered `index`, if there is one.
pub fn fromIndex(comptime Id: type, index: anytype) ?Id {
    const n = std.enums.values(Id).len;
    if (index < 0 or index >= n) return null;
    return @enumFromInt(index);
}

/// Linear gain for a level in dB; `floor_db` and below is silence.
pub fn dbToGain(db: f32, floor_db: f32) f32 {
    if (db <= floor_db) return 0;
    return std.math.pow(f32, 10, db / 20);
}

const test_gain: Info = .{ .name = "Gain", .short_name = "Gain", .unit = .decibels, .min = -60, .max = 12, .default = 0 };
const test_time: Info = .{ .name = "Release", .short_name = "Rel", .unit = .milliseconds, .min = 0, .max = 10_000, .default = 300, .cubic = true };
const test_pct: Info = .{ .name = "Sustain", .short_name = "Sus", .unit = .percent, .min = 0, .max = 100, .default = 70 };
const test_list: Info = .{ .name = "Mode", .short_name = "Mode", .unit = .list, .min = 0, .max = 2, .default = 0, .choices = &.{ "Sum", "FM", "Ring" } };

test "normalized round trip" {
    for ([_]Info{ test_gain, test_time, test_pct }) |i| {
        for ([_]f64{ 0, 0.1, 0.5, 0.9, 1 }) |n| {
            try std.testing.expectApproxEqAbs(n, i.toNormalized(i.fromNormalized(n)), 1e-5);
        }
        try std.testing.expectApproxEqAbs(i.default, i.fromNormalized(i.toNormalized(i.default)), i.max * 1e-5);
    }
    // Cubic: the middle of the range is 1/8 of max time.
    try std.testing.expectApproxEqAbs(@as(f32, 1250), test_time.fromNormalized(0.5), 0.5);
}

test "format and parse" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("-6.0", test_gain.format(&buf, -6));
    try std.testing.expectEqualStrings("-inf", test_gain.format(&buf, -60));
    try std.testing.expectEqualStrings("0.0", test_gain.format(&buf, -0.00001));
    try std.testing.expectEqualStrings("2.5", test_time.format(&buf, 2.5));
    try std.testing.expectEqualStrings("250", test_time.format(&buf, 250.2));
    try std.testing.expectEqualStrings("70", test_pct.format(&buf, 70));

    try std.testing.expectEqual(@as(?f32, 1500), test_time.parse("1.5 s"));
    try std.testing.expectEqual(@as(?f32, 250), test_time.parse(" 250ms "));
    try std.testing.expectEqual(@as(?f32, 10_000), test_time.parse("99999"));
    try std.testing.expectEqual(@as(?f32, -6), test_gain.parse("-6 dB"));
    try std.testing.expectEqual(@as(?f32, -60), test_gain.parse("-inf"));
    try std.testing.expectEqual(@as(?f32, 55), test_pct.parse("55%"));
    try std.testing.expectEqual(@as(?f32, null), test_pct.parse("abc"));
    try std.testing.expectEqual(@as(?f32, null), test_pct.parse(""));
}

test "list parameter" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 2), test_list.steps());
    try std.testing.expectEqualStrings("FM", test_list.format(&buf, 1));
    try std.testing.expectEqual(@as(?f32, 2), test_list.parse("ring"));
    try std.testing.expectEqual(@as(?f32, 1), test_list.parse("1"));
    try std.testing.expectEqual(@as(f32, 1), test_list.fromNormalized(0.6)); // nearest step
    try std.testing.expectEqual(@as(f64, 0.5), test_list.toNormalized(1));
}

test "store defaults and clamps" {
    const Id = enum(u32) { gain, sustain };
    var v: Store(Id, &.{ test_gain, test_pct }) = .{};
    try std.testing.expectEqual(@as(f32, 70), v.get(.sustain));
    v.set(.sustain, 150);
    try std.testing.expectEqual(@as(f32, 100), v.get(.sustain));
    try std.testing.expectEqual(@as(?Id, .sustain), fromIndex(Id, @as(i32, 1)));
    try std.testing.expectEqual(@as(?Id, null), fromIndex(Id, @as(i32, 2)));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5012), dbToGain(-6, -60), 1e-3);
    try std.testing.expectEqual(@as(f32, 0), dbToGain(-60, -60));
}
