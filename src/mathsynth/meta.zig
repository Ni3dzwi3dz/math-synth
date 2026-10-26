//! MathSynth's identity. It has no imports so build.zig can read it too:
//! callers pass in common/meta.zig's `Metadata` type.
//!
//! The IDs below are what hosts store in projects: never change them.

pub fn metadata(comptime Metadata: type) Metadata {
    return .{
        .name = "MathSynth",
        .vendor = "MathSynth",
        .version = "0.1.0",
        .kind = .instrument,
        .bundle_id = "com.mathsynth",
        .vst3 = .{
            .class_id = .{ 0xD2D7AE5B, 0x8233415A, 0x8F807A7A, 0x7E559156 },
            .subcategories = "Instrument|Synth",
        },
        .au = .{
            .type = "aumu",
            .subtype = "MSyn",
            .manufacturer = "Mthx",
            .factory = "MathSynthAUFactory",
            .description = "Formula wavetable synth",
            .tags = &.{"Synthesizer"},
        },
    };
}
