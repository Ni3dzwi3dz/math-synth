//! MathSynth.component (Audio Unit) entry point.

const common = @import("common");
const Plugin = @import("plugin.zig");

comptime {
    common.au.Wrapper(Plugin).exportEntryPoints();
}

test {
    _ = @import("tests.zig");
}
