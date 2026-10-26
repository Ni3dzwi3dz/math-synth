//! How the two waves are combined. Used by the synth for every sample and by
//! the editor for the plot, so the plot shows exactly what plays.

const std = @import("std");
const wt = @import("wavetable.zig");
const Mode = @import("params.zig").Mode;

/// FM depth at 100 %: how far f2 can push f1's phase, in cycles
/// (2 cycles = 4π ≈ 12.6 rad, a bright, busy spectrum).
pub const fm_max_cycles = 2.0;

/// Table value at `phase` (in cycles; any value, it wraps), with linear
/// interpolation.
pub fn lookup(table: *const wt.Table, phase: f64) f32 {
    const pos = (phase - @floor(phase)) * wt.size;
    const idx: usize = @intFromFloat(pos);
    const frac: f32 = @floatCast(pos - @floor(pos));
    const a = table[idx % wt.size];
    const b = table[(idx + 1) % wt.size];
    return a + (b - a) * frac;
}

/// Output at `phase` for the given mode and amount (0..1):
/// - sum: crossfade, f1 at 0 to f2 at 1
/// - fm: f1 read at a phase pushed by f2, up to `fm_max_cycles`
/// - ring: f1 at 0 to f1 × f2 at 1
pub fn sample(mode: Mode, tables: [2]*const wt.Table, phase: f64, amount: f32) f32 {
    const b = lookup(tables[1], phase);
    return switch (mode) {
        .sum => {
            const a = lookup(tables[0], phase);
            return a + (b - a) * amount;
        },
        .fm => lookup(tables[0], phase + @as(f64, amount) * fm_max_cycles * b),
        .ring => {
            const a = lookup(tables[0], phase);
            return a + (a * b - a) * amount;
        },
    };
}

fn sine() wt.Table {
    var t: wt.Table = undefined;
    for (&t, 0..) |*v, i| v.* = @floatCast(@sin(std.math.tau * @as(f64, @floatFromInt(i)) / wt.size));
    return t;
}

test "lookup wraps and interpolates" {
    var t: wt.Table = undefined;
    for (&t, 0..) |*v, i| v.* = @floatFromInt(i);
    try std.testing.expectEqual(@as(f32, 0), lookup(&t, 0));
    try std.testing.expectEqual(@as(f32, 0), lookup(&t, 3)); // whole cycles wrap
    try std.testing.expectApproxEqAbs(@as(f32, 10.5), lookup(&t, 10.5 / @as(f64, wt.size)), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, wt.size - 1), lookup(&t, -1.0 / @as(f64, wt.size)), 1e-3);
}

test "amount 0 is plain f1 in every mode" {
    const a = sine();
    var b: wt.Table = @splat(0.8);
    for (std.enums.values(Mode)) |mode| {
        for ([_]f64{ 0, 0.1, 0.37, 0.75 }) |phase| {
            try std.testing.expectApproxEqAbs(lookup(&a, phase), sample(mode, .{ &a, &b }, phase, 0), 1e-6);
        }
    }
}

test "sum, ring and fm at full amount" {
    const a = sine();
    var b: wt.Table = @splat(0.5);
    const phase = 0.1;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sample(.sum, .{ &a, &b }, phase, 1), 1e-6);
    try std.testing.expectApproxEqAbs(lookup(&a, phase) * 0.5, sample(.ring, .{ &a, &b }, phase, 1), 1e-6);
    // A constant modulator of 0.5 shifts f1 by 0.5 * 2 = 1 cycle: no change.
    try std.testing.expectApproxEqAbs(lookup(&a, phase), sample(.fm, .{ &a, &b }, phase, 1), 1e-5);
    // At 25 % it shifts by a quarter cycle: sin -> cos.
    try std.testing.expectApproxEqAbs(@as(f32, @floatCast(@cos(std.math.tau * phase))), sample(.fm, .{ &a, &b }, phase, 0.25), 1e-3);
}
