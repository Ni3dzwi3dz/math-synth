//! Format-independent core shared by the VST3 and Audio Unit wrappers: the
//! synth, the wavetable handoff to the audio thread, the user's settings and
//! their serialised form.

const std = @import("std");
const wt = @import("wavetable.zig");
const Synth = @import("synth.zig").Synth;
const params = @import("params.zig");

pub const Engine = struct {
    synth: Synth = .{},
    tables: wt.TripleBuffer = .{},
    params: params.Values = .{},
    /// Output gain as currently applied, smoothed towards the parameter.
    gain: f32 = 1,

    /// Guards `settings`, which the UI writes and state saving may read from
    /// another thread.
    settings_lock: std.atomic.Value(bool) = .init(false),
    settings: wt.Settings = wt.Settings.default,

    pub fn init(e: *Engine) void {
        e.* = .{};
        var table: wt.Table = undefined;
        std.debug.assert(wt.build(&e.settings, &table) == .ok);
        e.tables.initWith(&table);
        e.synth.setSampleRate(44100);
    }

    pub fn currentSettings(e: *Engine) wt.Settings {
        e.lock();
        defer e.unlock();
        return e.settings;
    }

    /// Stores validated settings and hands the matching table to the audio
    /// thread.
    pub fn apply(e: *Engine, settings: *const wt.Settings, table: *const wt.Table) void {
        e.tables.beginWrite().* = table.*;
        e.tables.publish();
        e.lock();
        e.settings = settings.*;
        e.unlock();
    }

    /// Validates and applies saved state. Returns false (changing nothing)
    /// if the formula doesn't compile.
    pub fn load(e: *Engine, state: *const State) bool {
        var table: wt.Table = undefined;
        if (wt.build(&state.settings, &table) != .ok) return false;
        e.apply(&state.settings, &table);
        for (std.enums.values(params.Id), state.params) |id, v| e.params.set(id, v);
        return true;
    }

    pub fn saveState(e: *Engine) State {
        return .{ .settings = e.currentSettings(), .params = e.params.snapshot() };
    }

    /// Seconds a note keeps sounding after note-off.
    pub fn tailSeconds(e: *const Engine) f64 {
        return e.params.get(.release) / 1000.0;
    }

    /// Renders frames [from, to) into each channel. Audio thread only.
    pub fn render(e: *Engine, channels: []const [*]f32, from: usize, to: usize) void {
        if (to <= from) return;
        const table = e.tables.read();
        e.synth.setEnvelope(.{
            .attack_ms = e.params.get(.attack),
            .decay_ms = e.params.get(.decay),
            .sustain = e.params.get(.sustain) / 100.0,
            .release_ms = e.params.get(.release),
        });
        if (channels.len == 0) {
            // No output buffers: keep voices advancing anyway.
            var scratch: [256]f32 = undefined;
            var at = from;
            while (at < to) {
                const n = @min(scratch.len, to - at);
                e.synth.render(table, scratch[0..n]);
                at += n;
            }
            return;
        }
        const first = channels[0][from..to];
        e.synth.render(table, first);
        e.applyGain(first);
        for (channels[1..]) |ch| @memcpy(ch[from..to], first);
    }

    fn applyGain(e: *Engine, samples: []f32) void {
        const target = params.dbToGain(e.params.get(.gain));
        // One-pole smoothing with a ~10 ms time constant: no zipper noise
        // when the knob moves.
        const k: f32 = @floatCast(1.0 - @exp(-1.0 / (0.01 * e.synth.sample_rate)));
        var g = e.gain;
        for (samples) |*x| {
            g += (target - g) * k;
            x.* *= g;
        }
        e.gain = g;
    }

    fn lock(e: *Engine) void {
        while (e.settings_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(e: *Engine) void {
        e.settings_lock.store(false, .release);
    }
};

/// Everything saved with a project or preset.
pub const State = struct {
    settings: wt.Settings,
    params: [params.count]f32 = defaultParams(),

    fn defaultParams() [params.count]f32 {
        var out: [params.count]f32 = undefined;
        for (std.enums.values(params.Id)) |id| out[@intFromEnum(id)] = params.info(id).default;
        return out;
    }
};

// Saved state: "MSY2", then formula, from and to, each as a u8 length
// followed by UTF-8 bytes, then the parameters as little-endian f32 in
// `params.Id` order. "MSY1" is the same without parameters.
const magic_v1 = "MSY1";
const magic_v2 = "MSY2";
pub const max_state_len = 4 + 3 + wt.max_formula_len + 2 * wt.max_range_len + 4 * params.count;

pub fn serialize(state: *const State, buf: *[max_state_len]u8) []const u8 {
    @memcpy(buf[0..4], magic_v2);
    var n: usize = 4;
    for (std.enums.values(wt.Field)) |field| {
        const s = state.settings.get(field);
        buf[n] = @intCast(s.len);
        @memcpy(buf[n + 1 ..][0..s.len], s);
        n += 1 + s.len;
    }
    for (state.params) |v| {
        std.mem.writeInt(u32, buf[n..][0..4], @bitCast(v), .little);
        n += 4;
    }
    return buf[0..n];
}

pub fn deserialize(data: []const u8) ?State {
    if (data.len < 4) return null;
    const v2 = std.mem.eql(u8, data[0..4], magic_v2);
    if (!v2 and !std.mem.eql(u8, data[0..4], magic_v1)) return null;
    var state: State = .{ .settings = .{} };
    var n: usize = 4;
    for (std.enums.values(wt.Field)) |field| {
        if (n >= data.len) return null;
        const len = data[n];
        if (len > wt.Settings.maxLen(field) or n + 1 + len > data.len) return null;
        state.settings.set(field, data[n + 1 ..][0..len]);
        n += 1 + len;
    }
    if (v2) {
        // Tolerate states with fewer parameters (from an older version):
        // missing ones keep their defaults.
        for (std.enums.values(params.Id)) |id| {
            if (n + 4 > data.len) break;
            const v: f32 = @bitCast(std.mem.readInt(u32, data[n..][0..4], .little));
            state.params[@intFromEnum(id)] = params.info(id).clamp(v);
            n += 4;
        }
    }
    return state;
}

test "state round trip" {
    var buf: [max_state_len]u8 = undefined;
    var in: State = .{ .settings = wt.Settings.init("sin(x) + 0.5sin(2x)", "-pi", "pi") };
    in.params[@intFromEnum(params.Id.gain)] = -6;
    in.params[@intFromEnum(params.Id.release)] = 1234;
    const out = deserialize(serialize(&in, &buf)).?;
    for (std.enums.values(wt.Field)) |f| try std.testing.expectEqualStrings(in.settings.get(f), out.settings.get(f));
    try std.testing.expectEqualSlices(f32, &in.params, &out.params);
}

test "version 1 state loads with default parameters" {
    const out = deserialize("MSY1\x01x\x010\x011").?;
    try std.testing.expectEqualStrings("x", out.settings.get(.formula));
    try std.testing.expectEqual(params.info(.sustain).default, out.params[@intFromEnum(params.Id.sustain)]);
}

test "gain is applied and smoothed" {
    var e: Engine = undefined;
    e.init();
    e.params.set(.gain, -60); // silence
    var buf: [4410]f32 = @splat(1);
    e.gain = params.dbToGain(-60);
    e.applyGain(&buf);
    try std.testing.expectEqual(@as(f32, 0), buf[buf.len - 1]);
    e.params.set(.gain, 0);
    @memset(&buf, 1);
    e.applyGain(&buf);
    try std.testing.expect(buf[0] < 0.1); // ramps rather than jumps
    try std.testing.expectApproxEqAbs(@as(f32, 1), buf[buf.len - 1], 1e-3);
}

test "malformed state is rejected" {
    try std.testing.expect(deserialize("") == null);
    try std.testing.expect(deserialize("XXXX\x01a\x011\x011") == null);
    try std.testing.expect(deserialize("MSY1\x05abc") == null);
}
