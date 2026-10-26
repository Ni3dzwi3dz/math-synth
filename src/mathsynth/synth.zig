//! Polyphonic wavetable oscillator bank with a linear ADSR envelope.

const std = @import("std");
const adsr = @import("common").adsr;
const wavetable = @import("wavetable.zig");
const blend = @import("blend.zig");
const Mode = @import("params.zig").Mode;

pub const max_voices = 16;

/// Headroom so a handful of full-scale voices don't clip.
const output_gain = 0.25;

const Voice = struct {
    active: bool = false,
    pitch: i16 = 0,
    note_id: i32 = -1,
    phase: f64 = 0,
    phase_inc: f64 = 0,
    velocity: f32 = 0,
    env: adsr.Envelope = .{},
    /// Order in which voices were started, used to steal the oldest.
    age: u64 = 0,
};

pub const Synth = struct {
    voices: [max_voices]Voice = @splat(.{}),
    sample_rate: f64 = 44100,
    envelope: adsr.Settings = .{},
    shape: adsr.Shape = .{},
    counter: u64 = 0,

    pub fn setSampleRate(s: *Synth, rate: f64) void {
        s.sample_rate = rate;
        s.setEnvelope(s.envelope);
    }

    /// Cheap enough to call once per audio block.
    pub fn setEnvelope(s: *Synth, e: adsr.Settings) void {
        s.envelope = e;
        s.shape = adsr.Shape.init(e, s.sample_rate);
    }

    pub fn reset(s: *Synth) void {
        for (&s.voices) |*v| v.* = .{};
    }

    pub fn noteOn(s: *Synth, pitch: i16, tuning_cents: f32, velocity: f32, note_id: i32) void {
        const v = s.pickVoice();
        const semis = @as(f64, @floatFromInt(pitch)) - 69.0 + @as(f64, tuning_cents) / 100.0;
        const freq = 440.0 * std.math.pow(f64, 2.0, semis / 12.0);
        s.counter += 1;
        // Retriggering a stolen voice ramps from its current level instead
        // of jumping, which avoids clicks.
        var env: adsr.Envelope = if (v.active) v.env else .{};
        env.trigger();
        v.* = .{
            .active = true,
            .pitch = pitch,
            .note_id = note_id,
            .phase = 0,
            .phase_inc = freq / s.sample_rate,
            .velocity = velocity,
            .env = env,
            .age = s.counter,
        };
    }

    pub fn noteOff(s: *Synth, pitch: i16, note_id: i32) void {
        for (&s.voices) |*v| {
            if (!v.active or v.env.releasing()) continue;
            const matches = if (note_id != -1 and v.note_id != -1) v.note_id == note_id else v.pitch == pitch;
            if (matches) v.env.release(&s.shape);
        }
    }

    pub fn allNotesOff(s: *Synth) void {
        for (&s.voices) |*v| {
            if (v.active and !v.env.releasing()) v.env.release(&s.shape);
        }
    }

    fn pickVoice(s: *Synth) *Voice {
        var oldest: *Voice = &s.voices[0];
        for (&s.voices) |*v| {
            if (!v.active) return v;
            // Prefer stealing voices that are already fading out.
            const v_rel = v.env.releasing();
            const o_rel = oldest.env.releasing();
            const better = (v_rel and !o_rel) or (v_rel == o_rel and v.age < oldest.age);
            if (better) oldest = v;
        }
        return oldest;
    }

    /// Writes `out.len` samples of output to `out` (mono; caller copies to
    /// other channels). The two tables are combined by `mode` (see
    /// blend.zig); its amount ramps linearly from `mix_from` to `mix_to`
    /// across the block.
    pub fn render(s: *Synth, tables: [2]*const wavetable.Table, mode: Mode, mix_from: f32, mix_to: f32, out: []f32) void {
        @memset(out, 0);
        const mix_step = if (out.len > 0) (mix_to - mix_from) / @as(f32, @floatFromInt(out.len)) else 0;
        for (&s.voices) |*v| {
            if (!v.active) continue;
            var mix = mix_from;
            for (out) |*sample| {
                if (!v.env.step(&s.shape)) {
                    v.active = false;
                    break;
                }
                const value = blend.sample(mode, tables, v.phase, mix);
                sample.* += value * v.env.level * v.velocity * output_gain;
                v.phase += v.phase_inc;
                v.phase -= @floor(v.phase);
                mix += mix_step;
            }
        }
    }
};

test "note plays and releases to silence" {
    var t: wavetable.Table = undefined;
    _ = wavetable.build(&wavetable.Settings.default, &t);
    var s: Synth = .{};
    s.setSampleRate(48000);
    s.setEnvelope(.{ .attack_ms = 5, .decay_ms = 10, .sustain = 1, .release_ms = 50 });
    var buf: [4800]f32 = undefined;

    s.noteOn(69, 0, 1, -1);
    s.render(.{ &t, &t }, .sum, 0, 0, &buf);
    var peak: f32 = 0;
    for (buf) |x| peak = @max(peak, @abs(x));
    try std.testing.expect(peak > 0.2 and peak <= output_gain + 1e-4);

    s.noteOff(69, -1);
    s.render(.{ &t, &t }, .sum, 0, 0, &buf); // 100 ms > release time
    try std.testing.expect(!s.voices[0].active);
    s.render(.{ &t, &t }, .sum, 0, 0, &buf);
    for (buf) |x| try std.testing.expectEqual(@as(f32, 0), x);
}

test "mix crossfades between the two tables" {
    var ones: wavetable.Table = @splat(1);
    var minus: wavetable.Table = @splat(-1);
    var s: Synth = .{};
    s.setSampleRate(1000);
    s.setEnvelope(.{ .attack_ms = 0, .decay_ms = 0, .sustain = 1, .release_ms = 100 });
    var buf: [4]f32 = undefined;
    s.noteOn(69, 0, 1, -1);
    s.render(.{ &ones, &minus }, .sum, 0, 0, &buf); // ramps up in 1 sample
    try std.testing.expectApproxEqAbs(output_gain, buf[3], 1e-5);
    s.render(.{ &ones, &minus }, .sum, 1, 1, &buf);
    try std.testing.expectApproxEqAbs(-output_gain, buf[3], 1e-5);
    s.render(.{ &ones, &minus }, .sum, 0.5, 0.5, &buf);
    try std.testing.expectApproxEqAbs(@as(f32, 0), buf[3], 1e-5);
    // A ramp moves linearly across the block.
    s.render(.{ &ones, &minus }, .sum, 0, 1, &buf);
    try std.testing.expectApproxEqAbs(output_gain * (1 - 2 * 0.75), buf[3], 1e-5);
}

test "voice stealing reuses the oldest voice" {
    var s: Synth = .{};
    s.setSampleRate(48000);
    for (0..max_voices + 1) |i| s.noteOn(@intCast(40 + i), 0, 1, -1);
    var active: usize = 0;
    for (s.voices) |v| active += @intFromBool(v.active);
    try std.testing.expectEqual(@as(usize, max_voices), active);
    try std.testing.expectEqual(@as(i16, 40 + max_voices), s.voices[0].pitch);
}
