//! Polyphonic wavetable oscillator bank with a simple attack/release envelope.

const std = @import("std");
const wavetable = @import("wavetable.zig");

pub const max_voices = 16;

const attack_seconds = 0.005;
const release_seconds = 0.08;
/// Headroom so a handful of full-scale voices don't clip.
const output_gain = 0.25;

const Voice = struct {
    active: bool = false,
    releasing: bool = false,
    pitch: i16 = 0,
    note_id: i32 = -1,
    phase: f64 = 0,
    phase_inc: f64 = 0,
    velocity: f32 = 0,
    env: f32 = 0,
    /// Order in which voices were started, used to steal the oldest.
    age: u64 = 0,
};

pub const Synth = struct {
    voices: [max_voices]Voice = @splat(.{}),
    sample_rate: f64 = 44100,
    attack_step: f32 = 0,
    release_step: f32 = 0,
    counter: u64 = 0,

    pub fn setSampleRate(s: *Synth, rate: f64) void {
        s.sample_rate = rate;
        s.attack_step = @floatCast(1.0 / (attack_seconds * rate));
        s.release_step = @floatCast(1.0 / (release_seconds * rate));
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
            if (!v.active or v.releasing) continue;
            const matches = if (note_id != -1 and v.note_id != -1) v.note_id == note_id else v.pitch == pitch;
            if (matches) v.releasing = true;
        }
    }

    pub fn allNotesOff(s: *Synth) void {
        for (&s.voices) |*v| v.releasing = true;
    }

    fn pickVoice(s: *Synth) *Voice {
        var oldest: *Voice = &s.voices[0];
        for (&s.voices) |*v| {
            if (!v.active) return v;
            // Prefer stealing voices that are already fading out.
            const better = (v.releasing and !oldest.releasing) or
                (v.releasing == oldest.releasing and v.age < oldest.age);
            if (better) oldest = v;
        }
        return oldest;
    }

    /// Adds `frames` samples of output to `out` (mono; caller copies to other
    /// channels).
    pub fn render(s: *Synth, table: *const wavetable.Table, out: []f32) void {
        @memset(out, 0);
        for (&s.voices) |*v| {
            if (!v.active) continue;
            for (out) |*sample| {
                if (v.releasing) {
                    v.env -= s.release_step;
                    if (v.env <= 0) {
                        v.active = false;
                        break;
                    }
                } else if (v.env < 1) {
                    v.env = @min(1, v.env + s.attack_step);
                }
                const pos = v.phase * wavetable.size;
                const idx: usize = @intFromFloat(pos);
                const frac: f32 = @floatCast(pos - @floor(pos));
                const a = table[idx % wavetable.size];
                const b = table[(idx + 1) % wavetable.size];
                sample.* += (a + (b - a) * frac) * v.env * v.velocity * output_gain;
                v.phase += v.phase_inc;
                v.phase -= @floor(v.phase);
            }
        }
    }
};

test "note plays and releases to silence" {
    var t: wavetable.Table = undefined;
    _ = wavetable.build(&wavetable.Settings.default, &t);
    var s: Synth = .{};
    s.setSampleRate(48000);
    var buf: [4800]f32 = undefined;

    s.noteOn(69, 0, 1, -1);
    s.render(&t, &buf);
    var peak: f32 = 0;
    for (buf) |x| peak = @max(peak, @abs(x));
    try std.testing.expect(peak > 0.2 and peak <= output_gain + 1e-4);

    s.noteOff(69, -1);
    s.render(&t, &buf); // 100 ms > release time
    try std.testing.expect(!s.voices[0].active);
    s.render(&t, &buf);
    for (buf) |x| try std.testing.expectEqual(@as(f32, 0), x);
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
