//! Turns the user's formula and range into a single-cycle wavetable.

const std = @import("std");
const common = @import("common");
const expr = common.expr;

pub const size = 2048;
pub const Table = [size]f32;

pub const max_formula_len = 255;
pub const max_range_len = 63;

pub const Field = enum { formula, from, to };

/// The three user inputs, stored inline so they can be copied around and
/// saved in the plugin state without allocation.
pub const Settings = struct {
    formula_buf: [max_formula_len]u8 = undefined,
    formula_len: u8 = 0,
    from_buf: [max_range_len]u8 = undefined,
    from_len: u8 = 0,
    to_buf: [max_range_len]u8 = undefined,
    to_len: u8 = 0,

    pub const default: Settings = init("sin(x)", "0", "2*pi");
    /// Default for the second wave: a square, so the mix is easy to hear.
    pub const default_second: Settings = init("sign(sin(x))", "0", "2*pi");

    pub fn init(formula: []const u8, from: []const u8, to: []const u8) Settings {
        var s: Settings = .{};
        s.set(.formula, formula);
        s.set(.from, from);
        s.set(.to, to);
        return s;
    }

    pub fn get(s: *const Settings, field: Field) []const u8 {
        return switch (field) {
            .formula => s.formula_buf[0..s.formula_len],
            .from => s.from_buf[0..s.from_len],
            .to => s.to_buf[0..s.to_len],
        };
    }

    /// Text longer than the field allows is truncated (never splitting a
    /// UTF-8 sequence).
    pub fn set(s: *Settings, field: Field, text: []const u8) void {
        const buf: []u8, const len: *u8 = switch (field) {
            .formula => .{ &s.formula_buf, &s.formula_len },
            .from => .{ &s.from_buf, &s.from_len },
            .to => .{ &s.to_buf, &s.to_len },
        };
        var n = @min(text.len, buf.len);
        while (n > 0 and n < text.len and text[n] & 0xC0 == 0x80) n -= 1;
        @memcpy(buf[0..n], text[0..n]);
        len.* = @intCast(n);
    }

    pub fn maxLen(field: Field) usize {
        return switch (field) {
            .formula => max_formula_len,
            .from, .to => max_range_len,
        };
    }
};

pub const Problem = struct {
    field: Field,
    diag: expr.Diagnostic,
};

pub const Info = struct {
    from: f64,
    to: f64,
    /// Raw minimum/maximum of the formula over the period, before the table
    /// is centred and normalised.
    raw_min: f64,
    raw_max: f64,
};

/// Validates the settings and, if they are valid, fills `table` with one
/// period of the waveform: DC removed and peak-normalised to [-1, 1] so any
/// formula plays at a sane volume. On failure returns the first problem found.
pub fn build(settings: *const Settings, table: *Table) union(enum) { ok: Info, err: Problem } {
    var problem: Problem = .{ .field = .formula, .diag = .{} };

    const from = evalConstant(settings.get(.from), &problem.diag) orelse {
        problem.field = .from;
        return .{ .err = problem };
    };
    const to = evalConstant(settings.get(.to), &problem.diag) orelse {
        problem.field = .to;
        return .{ .err = problem };
    };
    if (from == to) {
        problem.field = .to;
        problem.diag.set(0, 0, "Range is empty: 'from' and 'to' are equal", .{});
        return .{ .err = problem };
    }

    const prog = expr.compile(settings.get(.formula), .{}, &problem.diag) catch {
        problem.field = .formula;
        return .{ .err = problem };
    };

    var raw: [size]f64 = undefined;
    var sum: f64 = 0;
    var raw_min: f64 = std.math.inf(f64);
    var raw_max: f64 = -std.math.inf(f64);
    for (&raw, 0..) |*v, i| {
        const x = from + (to - from) * @as(f64, @floatFromInt(i)) / size;
        v.* = prog.eval(x);
        if (!std.math.isFinite(v.*)) {
            problem.field = .formula;
            problem.diag.set(0, 0, "Formula is not finite at x = {d:.4} (division by zero or out of domain?)", .{x});
            return .{ .err = problem };
        }
        sum += v.*;
        raw_min = @min(raw_min, v.*);
        raw_max = @max(raw_max, v.*);
    }

    const mean = sum / size;
    var peak: f64 = 0;
    for (raw) |v| peak = @max(peak, @abs(v - mean));
    const gain: f64 = if (peak > 1e-12) 1.0 / peak else 0.0;
    for (table, raw) |*out, v| out.* = @floatCast((v - mean) * gain);

    return .{ .ok = .{ .from = from, .to = to, .raw_min = raw_min, .raw_max = raw_max } };
}

fn evalConstant(text: []const u8, diag: *expr.Diagnostic) ?f64 {
    const prog = expr.compile(text, .{ .allow_x = false }, diag) catch return null;
    const v = prog.eval(0);
    if (!std.math.isFinite(v)) {
        diag.set(0, 0, "Range value is not a finite number", .{});
        return null;
    }
    return v;
}

/// Hands finished tables to the audio thread without locks.
pub const TripleBuffer = common.TripleBuffer(Table);

test "build sine table" {
    var t: Table = undefined;
    const s = Settings.default;
    const r = build(&s, &t);
    try std.testing.expect(r == .ok);
    try std.testing.expectApproxEqAbs(@as(f32, 0), t[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), t[size / 4], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -1), t[3 * size / 4], 1e-3);
}

test "saw over [0,1] is centred and normalised" {
    var t: Table = undefined;
    const s = Settings.init("x", "0", "1");
    const r = build(&s, &t);
    try std.testing.expect(r == .ok);
    try std.testing.expectApproxEqAbs(@as(f64, 1), r.ok.to, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f32, -1), t[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1), t[size - 1], 1e-2);
}

test "validation problems point at the right field" {
    var t: Table = undefined;
    var s = Settings.init("sin(x", "0", "1");
    try std.testing.expectEqual(Field.formula, build(&s, &t).err.field);
    s = Settings.init("sin(x)", "x", "1");
    try std.testing.expectEqual(Field.from, build(&s, &t).err.field);
    s = Settings.init("sin(x)", "1", "1");
    try std.testing.expectEqual(Field.to, build(&s, &t).err.field);
    s = Settings.init("1/x", "0", "1");
    const r = build(&s, &t);
    try std.testing.expectEqual(Field.formula, r.err.field);
    try std.testing.expect(std.mem.indexOf(u8, r.err.diag.message(), "not finite") != null);
}

test "settings truncate without splitting utf-8" {
    var s: Settings = .{};
    var long: [70]u8 = undefined;
    @memset(&long, 'a');
    long[62] = 0xC3; // 2-byte sequence straddling the 63-byte limit
    long[63] = 0xA9;
    s.set(.from, &long);
    try std.testing.expectEqual(@as(usize, 62), s.get(.from).len);
}
