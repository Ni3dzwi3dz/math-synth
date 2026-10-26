//! Polyphonic wavetable oscillator bank with a linear ADSR envelope.

const std = @import("std");
const wavetable = @import("wavetable.zig");

pub const max_voices = 16;

/// Headroom so a handful of full-scale voices don't clip.
const output_gain = 0.25;
/// Attack, decay and release never go below this, so even "0 ms" doesn't
/// click.
const min_segment_seconds = 0.001;

/// Envelope settings in user units.
pub const Envelope = struct {
    attack_ms: f32 = 5,
    decay_ms: f32 = 250,
    /// 0..1
    sustain: f32 = 0.7,
    release_ms: f32 = 300,
};

const Stage = enum { attack, decay, sustain, release };

const Voice = struct {
    active: bool = false,
    stage: Stage = .attack,
    pitch: i16 = 0,
    note_id: i32 = -1,
    phase: f64 = 0,
    phase_inc: f64 = 0,
    velocity: f32 = 0,
    env: f32 = 0,
    /// Per-sample decrement during release, fixed at note-off so the release
    /// time holds from whatever level the note was at.
    release_step: f32 = 0,
    /// Order in which voices were started, used to steal the oldest.
    age: u64 = 0,
};

pub const Synth = struct {
    voices: [max_voices]Voice = @splat(.{}),
    sample_rate: f64 = 44100,
    envelope: Envelope = .{},
    attack_step: f32 = 0,
    decay_step: f32 = 0,
    release_samples: f32 = 1,
    counter: u64 = 0,

    pub fn setSampleRate(s: *Synth, rate: f64) void {
        s.sample_rate = rate;
        s.setEnvelope(s.envelope);
    }

    /// Cheap enough to call once per audio block.
    pub fn setEnvelope(s: *Synth, e: Envelope) void {
        s.envelope = e;
        s.envelope.sustain = std.math.clamp(e.sustain, 0, 1);
        s.attack_step = 1.0 / s.segmentSamples(e.attack_ms);
        s.decay_step = (1.0 - s.envelope.sustain) / s.segmentSamples(e.decay_ms);
        s.release_samples = s.segmentSamples(e.release_ms);
    }

    fn segmentSamples(s: *const Synth, ms: f32) f32 {
        const seconds = @max(@as(f64, ms) / 1000.0, min_segment_seconds);
        return @floatCast(seconds * s.sample_rate);
    }

    pub fn reset(s: *Synth) void {
        for (&s.voices) |*v| v.* = .{};
    }

    pub fn noteOn(s: *Synth, pitch: i16, tuning_cents: f32, velocity: f32, note_id: i32) void {
        const v = s.pickVoice();
        const semis = @as(f64, @floatFromInt(pitch)) - 69.0 + @as(f64, tuning_cents) / 100.0;
        const freq = 440.0 * std.math.pow(f64, 2.0, semis / 12.0);
        s.counter += 1;
        v.* = .{
            .active = true,
            .stage = .attack,
            .pitch = pitch,
            .note_id = note_id,
            .phase = 0,
            .phase_inc = freq / s.sample_rate,
            .velocity = velocity,
            // Retriggering a stolen voice ramps from its current level
            // instead of jumping, which avoids clicks.
            .env = if (v.active) v.env else 0,
            .age = s.counter,
        };
    }

    pub fn noteOff(s: *Synth, pitch: i16, note_id: i32) void {
        for (&s.voices) |*v| {
            if (!v.active or v.stage == .release) continue;
            const matches = if (note_id != -1 and v.note_id != -1) v.note_id == note_id else v.pitch == pitch;
            if (matches) s.release(v);
        }
    }

    pub fn allNotesOff(s: *Synth) void {
        for (&s.voices) |*v| {
            if (v.active and v.stage != .release) s.release(v);
        }
    }

    fn release(s: *Synth, v: *Voice) void {
        v.stage = .release;
        v.release_step = @max(v.env, 1e-4) / s.release_samples;
    }

    fn pickVoice(s: *Synth) *Voice {
        var oldest: *Voice = &s.voices[0];
        for (&s.voices) |*v| {
            if (!v.active) return v;
            // Prefer stealing voices that are already fading out.
            const v_rel = v.stage == .release;
            const o_rel = oldest.stage == .release;
            const better = (v_rel and !o_rel) or (v_rel == o_rel and v.age < oldest.age);
            if (better) oldest = v;
        }
        return oldest;
    }

    /// Advances the envelope by one sample. Returns false when the voice has
    /// finished.
    fn stepEnvelope(s: *const Synth, v: *Voice) bool {
        switch (v.stage) {
            .attack => {
                v.env += s.attack_step;
                if (v.env >= 1) {
                    v.env = 1;
                    v.stage = .decay;
                }
            },
            .decay => {
                v.env -= s.decay_step;
                if (v.env <= s.envelope.sustain) {
                    v.env = s.envelope.sustain;
                    v.stage = .sustain;
                }
            },
            // Glide (~5 ms) to the sustain level so moving it while a note
            // is held doesn't click.
            .sustain => v.env += (s.envelope.sustain - v.env) * 0.005,
            .release => {
                v.env -= v.release_step;
                if (v.env <= 0) {
                    v.env = 0;
                    return false;
                }
            },
        }
        return true;
    }

    /// Writes `out.len` samples of output to `out` (mono; caller copies to
    /// other channels). The two tables are crossfaded: `mix` is the share of
    /// the second one, ramping linearly from `mix_from` to `mix_to` across
    /// the block.
    pub fn render(s: *Synth, tables: [2]*const wavetable.Table, mix_from: f32, mix_to: f32, out: []f32) void {
        @memset(out, 0);
        const mix_step = if (out.len > 0) (mix_to - mix_from) / @as(f32, @floatFromInt(out.len)) else 0;
        const only_first = mix_from == 0 and mix_to == 0;
        for (&s.voices) |*v| {
            if (!v.active) continue;
            var mix = mix_from;
            for (out) |*sample| {
                if (!s.stepEnvelope(v)) {
                    v.active = false;
                    break;
                }
                const pos = v.phase * wavetable.size;
                const idx: usize = @intFromFloat(pos);
                const frac: f32 = @floatCast(pos - @floor(pos));
                const at = idx % wavetable.size;
                const next = (idx + 1) % wavetable.size;
                var value = lerp(tables[0][at], tables[0][next], frac);
                if (!only_first) value = lerp(value, lerp(tables[1][at], tables[1][next], frac), mix);
                sample.* += value * v.env * v.velocity * output_gain;
                v.phase += v.phase_inc;
                v.phase -= @floor(v.phase);
                mix += mix_step;
            }
        }
    }
};

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn testSynth(e: Envelope) Synth {
    var s: Synth = .{};
    s.setSampleRate(1000); // 1 sample = 1 ms keeps the numbers readable
    s.setEnvelope(e);
    return s;
}

fn envAfter(s: *Synth, samples: usize) f32 {
    var v = &s.voices[0];
    for (0..samples) |_| {
        if (!s.stepEnvelope(v)) {
            v.active = false;
            break;
        }
    }
    return v.env;
}

test "adsr shape" {
    var s = testSynth(.{ .attack_ms = 10, .decay_ms = 20, .sustain = 0.5, .release_ms = 40 });
    s.noteOn(60, 0, 1, -1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), envAfter(&s, 5), 1e-5); // halfway up
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), envAfter(&s, 5), 1e-5); // peak
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), envAfter(&s, 10), 1e-5); // halfway down
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), envAfter(&s, 10), 1e-5); // sustain
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), envAfter(&s, 100), 1e-5); // held
    s.noteOff(60, -1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), envAfter(&s, 20), 1e-5); // halfway out
    _ = envAfter(&s, 25);
    try std.testing.expect(!s.voices[0].active);
}

test "release during attack starts from the current level" {
    var s = testSynth(.{ .attack_ms = 100, .decay_ms = 10, .sustain = 1, .release_ms = 10 });
    s.noteOn(60, 0, 1, -1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), envAfter(&s, 20), 1e-5);
    s.noteOff(60, -1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), envAfter(&s, 5), 1e-5);
}

test "zero times still ramp" {
    var s = testSynth(.{ .attack_ms = 0, .decay_ms = 0, .sustain = 0.3, .release_ms = 0 });
    s.noteOn(60, 0, 1, -1);
    try std.testing.expectApproxEqAbs(@as(f32, 1), envAfter(&s, 1), 1e-5); // 1 ms minimum = 1 sample here
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), envAfter(&s, 1), 1e-5);
}

test "note plays and releases to silence" {
    var t: wavetable.Table = undefined;
    _ = wavetable.build(&wavetable.Settings.default, &t);
    var s: Synth = .{};
    s.setSampleRate(48000);
    s.setEnvelope(.{ .attack_ms = 5, .decay_ms = 10, .sustain = 1, .release_ms = 50 });
    var buf: [4800]f32 = undefined;

    s.noteOn(69, 0, 1, -1);
    s.render(.{ &t, &t }, 0, 0, &buf);
    var peak: f32 = 0;
    for (buf) |x| peak = @max(peak, @abs(x));
    try std.testing.expect(peak > 0.2 and peak <= output_gain + 1e-4);

    s.noteOff(69, -1);
    s.render(.{ &t, &t }, 0, 0, &buf); // 100 ms > release time
    try std.testing.expect(!s.voices[0].active);
    s.render(.{ &t, &t }, 0, 0, &buf);
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
    s.render(.{ &ones, &minus }, 0, 0, &buf); // ramps up in 1 sample
    try std.testing.expectApproxEqAbs(output_gain, buf[3], 1e-5);
    s.render(.{ &ones, &minus }, 1, 1, &buf);
    try std.testing.expectApproxEqAbs(-output_gain, buf[3], 1e-5);
    s.render(.{ &ones, &minus }, 0.5, 0.5, &buf);
    try std.testing.expectApproxEqAbs(@as(f32, 0), buf[3], 1e-5);
    // A ramp moves linearly across the block.
    s.render(.{ &ones, &minus }, 0, 1, &buf);
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
