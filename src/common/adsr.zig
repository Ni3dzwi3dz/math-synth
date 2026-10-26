//! Linear ADSR envelope: `Shape` holds the settings converted to per-sample
//! steps (one per synth), `Envelope` is the running state (one per voice).

const std = @import("std");

/// Attack, decay and release never go below this, so even "0 ms" doesn't
/// click.
const min_segment_seconds = 0.001;

/// Envelope settings in user units.
pub const Settings = struct {
    attack_ms: f32 = 5,
    decay_ms: f32 = 250,
    /// 0..1
    sustain: f32 = 0.7,
    release_ms: f32 = 300,
};

pub const Shape = struct {
    sustain: f32 = 0.7,
    attack_step: f32 = 0,
    decay_step: f32 = 0,
    release_samples: f32 = 1,

    /// Cheap enough to call once per audio block.
    pub fn init(settings: Settings, sample_rate: f64) Shape {
        const sustain = std.math.clamp(settings.sustain, 0, 1);
        return .{
            .sustain = sustain,
            .attack_step = 1.0 / segmentSamples(settings.attack_ms, sample_rate),
            .decay_step = (1.0 - sustain) / segmentSamples(settings.decay_ms, sample_rate),
            .release_samples = segmentSamples(settings.release_ms, sample_rate),
        };
    }

    fn segmentSamples(ms: f32, sample_rate: f64) f32 {
        const seconds = @max(@as(f64, ms) / 1000.0, min_segment_seconds);
        return @floatCast(seconds * sample_rate);
    }
};

pub const Stage = enum { attack, decay, sustain, release };

pub const Envelope = struct {
    stage: Stage = .attack,
    level: f32 = 0,
    /// Per-sample decrement during release, fixed at note-off so the release
    /// time holds from whatever level the note was at.
    release_step: f32 = 0,

    /// Starts (or restarts) the attack from the current level, so retriggering
    /// a sounding voice doesn't click.
    pub fn trigger(e: *Envelope) void {
        e.stage = .attack;
    }

    pub fn release(e: *Envelope, shape: *const Shape) void {
        e.stage = .release;
        e.release_step = @max(e.level, 1e-4) / shape.release_samples;
    }

    pub fn releasing(e: *const Envelope) bool {
        return e.stage == .release;
    }

    /// Advances by one sample. Returns false when the envelope has finished.
    pub fn step(e: *Envelope, shape: *const Shape) bool {
        switch (e.stage) {
            .attack => {
                e.level += shape.attack_step;
                if (e.level >= 1) {
                    e.level = 1;
                    e.stage = .decay;
                }
            },
            .decay => {
                e.level -= shape.decay_step;
                if (e.level <= shape.sustain) {
                    e.level = shape.sustain;
                    e.stage = .sustain;
                }
            },
            // Glide (~5 ms) to the sustain level so moving it while a note
            // is held doesn't click.
            .sustain => e.level += (shape.sustain - e.level) * 0.005,
            .release => {
                e.level -= e.release_step;
                if (e.level <= 0) {
                    e.level = 0;
                    return false;
                }
            },
        }
        return true;
    }
};

/// Runs `samples` steps; at 1000 Hz one step is one millisecond.
fn levelAfter(e: *Envelope, shape: *const Shape, samples: usize) ?f32 {
    for (0..samples) |_| {
        if (!e.step(shape)) return null;
    }
    return e.level;
}

test "adsr shape" {
    const shape = Shape.init(.{ .attack_ms = 10, .decay_ms = 20, .sustain = 0.5, .release_ms = 40 }, 1000);
    var e: Envelope = .{};
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), levelAfter(&e, &shape, 5).?, 1e-5); // halfway up
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), levelAfter(&e, &shape, 5).?, 1e-5); // peak
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), levelAfter(&e, &shape, 10).?, 1e-5); // halfway down
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), levelAfter(&e, &shape, 10).?, 1e-5); // sustain
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), levelAfter(&e, &shape, 100).?, 1e-5); // held
    e.release(&shape);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), levelAfter(&e, &shape, 20).?, 1e-5); // halfway out
    try std.testing.expectEqual(@as(?f32, null), levelAfter(&e, &shape, 25)); // finished
}

test "release during attack starts from the current level" {
    const shape = Shape.init(.{ .attack_ms = 100, .decay_ms = 10, .sustain = 1, .release_ms = 10 }, 1000);
    var e: Envelope = .{};
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), levelAfter(&e, &shape, 20).?, 1e-5);
    e.release(&shape);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), levelAfter(&e, &shape, 5).?, 1e-5);
}

test "zero times still ramp" {
    const shape = Shape.init(.{ .attack_ms = 0, .decay_ms = 0, .sustain = 0.3, .release_ms = 0 }, 1000);
    var e: Envelope = .{};
    try std.testing.expectApproxEqAbs(@as(f32, 1), levelAfter(&e, &shape, 1).?, 1e-5); // 1 ms minimum = 1 step here
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), levelAfter(&e, &shape, 1).?, 1e-5);
}
