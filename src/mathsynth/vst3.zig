//! MathSynth.vst3 entry point.

const common = @import("common");
const Plugin = @import("plugin.zig");

comptime {
    common.vst3.Wrapper(Plugin).exportEntryPoints();
}

test {
    _ = @import("tests.zig");
}
