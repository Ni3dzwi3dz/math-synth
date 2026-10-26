//! MathSynth's plugin instance (see common/plugin.zig): the synth, the
//! wavetable handoff to the audio thread, the user's settings for both waves,
//! the parameters and the saved state.

const std = @import("std");
const wt = @import("wavetable.zig");
const Synth = @import("synth.zig").Synth;
const params = @import("params.zig");

pub const wave_count = 2;
/// Formula settings for both waves.
pub const Waves = [wave_count]wt.Settings;
pub const default_waves: Waves = .{ wt.Settings.default, wt.Settings.default_second };

pub const Engine = struct {
    synth: Synth = .{},
    tables: [wave_count]wt.TripleBuffer = .{ .{}, .{} },
    params: params.Values = .{},
    /// Output gain as currently applied, smoothed towards the parameter.
    gain: f32 = 1,
    /// Wave 2 share (0..1) as currently applied, smoothed towards the mix
    /// parameter.
    mix: f32 = 0,

    /// Guards `settings`, which the UI writes and state saving may read from
    /// another thread.
    settings_lock: std.atomic.Value(bool) = .init(false),
    settings: Waves = default_waves,

    pub fn init(e: *Engine) void {
        e.* = .{};
        for (&e.tables, &e.settings) |*tb, *settings| {
            var table: wt.Table = undefined;
            std.debug.assert(wt.build(settings, &table) == .ok);
            tb.initWith(&table);
        }
        e.mix = e.params.get(.mix) / 100.0;
        e.synth.setSampleRate(44100);
    }

    pub fn currentSettings(e: *Engine) Waves {
        e.lock();
        defer e.unlock();
        return e.settings;
    }

    /// Stores validated settings for one wave and hands the matching table
    /// to the audio thread.
    pub fn apply(e: *Engine, wave: usize, settings: *const wt.Settings, table: *const wt.Table) void {
        e.tables[wave].beginWrite().* = table.*;
        e.tables[wave].publish();
        e.lock();
        e.settings[wave] = settings.*;
        e.unlock();
    }

    /// Validates and applies saved state. Returns false (changing nothing)
    /// if either formula doesn't compile.
    pub fn applyState(e: *Engine, state: *const State) bool {
        var tables: [wave_count]wt.Table = undefined;
        for (&state.settings, &tables) |*settings, *table| {
            if (wt.build(settings, table) != .ok) return false;
        }
        for (&state.settings, &tables, 0..) |*settings, *table, wave| e.apply(wave, settings, table);
        for (std.enums.values(params.Id), state.params) |id, v| e.params.set(id, v);
        return true;
    }

    pub fn currentState(e: *Engine) State {
        return .{ .settings = e.currentSettings(), .params = e.params.snapshot() };
    }

    // Plugin interface (common/plugin.zig) ---------------------------------------

    pub const max_state_len = engine_max_state_len;

    pub fn saveState(e: *Engine, buf: *[max_state_len]u8) []const u8 {
        const state = e.currentState();
        return serialize(&state, buf);
    }

    pub fn loadState(e: *Engine, bytes: []const u8) bool {
        const state = deserialize(bytes) orelse return false;
        return e.applyState(&state);
    }

    pub fn getParam(e: *const Engine, index: u32) f32 {
        return e.params.getIndex(index);
    }

    pub fn setParam(e: *Engine, index: u32, plain: f32) void {
        e.params.setIndex(index, plain);
    }

    pub fn setSampleRate(e: *Engine, rate: f64) void {
        e.synth.setSampleRate(rate);
    }

    pub fn reset(e: *Engine) void {
        e.synth.reset();
    }

    pub fn noteOn(e: *Engine, pitch: i16, tuning_cents: f32, velocity: f32, note_id: i32) void {
        e.synth.noteOn(pitch, tuning_cents, velocity, note_id);
    }

    pub fn noteOff(e: *Engine, pitch: i16, note_id: i32) void {
        e.synth.noteOff(pitch, note_id);
    }

    pub fn allNotesOff(e: *Engine) void {
        e.synth.allNotesOff();
    }

    /// Seconds a note keeps sounding after note-off.
    pub fn tailSeconds(e: *const Engine) f64 {
        return e.params.get(.release) / 1000.0;
    }

    /// Renders frames [from, to) into each channel. Audio thread only.
    pub fn render(e: *Engine, channels: []const [*]f32, from: usize, to: usize) void {
        if (to <= from) return;
        const tables = [wave_count]*const wt.Table{ e.tables[0].read(), e.tables[1].read() };
        // Move the mix towards its target with the same ~10 ms smoothing as
        // the gain, as a linear ramp across this segment.
        const mix_from = e.mix;
        const mix_target = e.params.get(.mix) / 100.0;
        const k = 1.0 - @exp(-1.0 / (0.01 * e.synth.sample_rate));
        const decay: f32 = @floatCast(std.math.pow(f64, 1.0 - k, @floatFromInt(to - from)));
        const mix_to = mix_target + (mix_from - mix_target) * decay;
        e.mix = mix_to;
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
                e.synth.render(tables, params.mode(&e.params), mix_to, mix_to, scratch[0..n]);
                at += n;
            }
            return;
        }
        const first = channels[0][from..to];
        e.synth.render(tables, params.mode(&e.params), mix_from, mix_to, first);
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
    settings: Waves = default_waves,
    params: [params.count]f32 = defaultParams(),

    fn defaultParams() [params.count]f32 {
        var out: [params.count]f32 = undefined;
        for (std.enums.values(params.Id)) |id| out[@intFromEnum(id)] = params.info(id).default;
        return out;
    }
};

// Saved state, version 3: "MSY3", then for each wave the formula, from and
// to as a u8 length followed by UTF-8 bytes, then the parameters as
// little-endian f32 in `params.Id` order.
// Version 2 ("MSY2") has one wave; version 1 ("MSY1") also has no
// parameters. Older states load with defaults for what they lack.
const magic = "MSY3";
const engine_max_state_len = 4 + wave_count * (3 + wt.max_formula_len + 2 * wt.max_range_len) + 4 * params.count;

pub fn serialize(state: *const State, buf: *[engine_max_state_len]u8) []const u8 {
    @memcpy(buf[0..4], magic);
    var n: usize = 4;
    for (&state.settings) |*settings| {
        for (std.enums.values(wt.Field)) |field| {
            const s = settings.get(field);
            buf[n] = @intCast(s.len);
            @memcpy(buf[n + 1 ..][0..s.len], s);
            n += 1 + s.len;
        }
    }
    for (state.params) |v| {
        std.mem.writeInt(u32, buf[n..][0..4], @bitCast(v), .little);
        n += 4;
    }
    return buf[0..n];
}

pub fn deserialize(data: []const u8) ?State {
    if (data.len < 4 or !std.mem.eql(u8, data[0..3], "MSY")) return null;
    const version: u8 = switch (data[3]) {
        '1' => 1,
        '2' => 2,
        '3' => 3,
        else => return null,
    };
    var state: State = .{};
    var n: usize = 4;
    const waves: usize = if (version >= 3) wave_count else 1;
    for (state.settings[0..waves]) |*settings| {
        settings.* = .{};
        for (std.enums.values(wt.Field)) |field| {
            if (n >= data.len) return null;
            const len = data[n];
            if (len > wt.Settings.maxLen(field) or n + 1 + len > data.len) return null;
            settings.set(field, data[n + 1 ..][0..len]);
            n += 1 + len;
        }
    }
    if (version >= 2) {
        // Parameters missing at the end (added in a later version) keep
        // their defaults.
        for (std.enums.values(params.Id)) |id| {
            if (n + 4 > data.len) break;
            const v: f32 = @bitCast(std.mem.readInt(u32, data[n..][0..4], .little));
            state.params[@intFromEnum(id)] = params.info(id).clamp(v);
            n += 4;
        }
    }
    return state;
}

test {
    _ = @import("blend.zig");
}

test "state round trip" {
    var buf: [engine_max_state_len]u8 = undefined;
    var in: State = .{ .settings = .{
        wt.Settings.init("sin(x) + 0.5sin(2x)", "-pi", "pi"),
        wt.Settings.init("x", "0", "1"),
    } };
    in.params[@intFromEnum(params.Id.gain)] = -6;
    in.params[@intFromEnum(params.Id.release)] = 1234;
    in.params[@intFromEnum(params.Id.mix)] = 40;
    const out = deserialize(serialize(&in, &buf)).?;
    for (0..wave_count) |w| {
        for (std.enums.values(wt.Field)) |f| try std.testing.expectEqualStrings(in.settings[w].get(f), out.settings[w].get(f));
    }
    try std.testing.expectEqualSlices(f32, &in.params, &out.params);
}

test "version 1 state loads with defaults for the rest" {
    const out = deserialize("MSY1\x01x\x010\x011").?;
    try std.testing.expectEqualStrings("x", out.settings[0].get(.formula));
    try std.testing.expectEqualStrings(wt.Settings.default_second.get(.formula), out.settings[1].get(.formula));
    try std.testing.expectEqual(params.info(.sustain).default, out.params[@intFromEnum(params.Id.sustain)]);
}

test "version 2 state keeps its parameters and gets the default second wave" {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..10], "MSY2\x01x\x010\x011");
    var n: usize = 10;
    for (0..5) |i| { // v2 had five parameters
        std.mem.writeInt(u32, buf[n..][0..4], @bitCast(@as(f32, @floatFromInt(i)) + 1), .little);
        n += 4;
    }
    const out = deserialize(buf[0..n]).?;
    try std.testing.expectEqual(@as(f32, 1), out.params[@intFromEnum(params.Id.gain)]);
    try std.testing.expectEqual(@as(f32, 5), out.params[@intFromEnum(params.Id.release)]);
    try std.testing.expectEqual(@as(f32, 0), out.params[@intFromEnum(params.Id.mix)]);
    try std.testing.expectEqualStrings(wt.Settings.default_second.get(.formula), out.settings[1].get(.formula));
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
