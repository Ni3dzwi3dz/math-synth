//! All of MathSynth's unit tests, plus checks that it fits both wrappers.

const std = @import("std");
const common = @import("common");
const Plugin = @import("plugin.zig");

test {
    _ = @import("params.zig");
    _ = @import("engine.zig");
    _ = @import("synth.zig");
    _ = @import("wavetable.zig");
    _ = @import("blend.zig");
    _ = @import("editor.zig");
}

test "IDs hosts depend on are unchanged" {
    try std.testing.expectEqual(@as(u32, 256), comptime Plugin.meta.auVersion());
    try std.testing.expectEqualStrings("MathSynthAUViewFactory_0_1_0", comptime Plugin.meta.auViewFactoryClass());
    try std.testing.expectEqualStrings("MathSynthAUView_0_1_0", comptime Plugin.meta.auViewContainerClass());
    try std.testing.expectEqual(@as(usize, 7), Plugin.params.len);
}

test "AU property table" {
    const W = common.au.Wrapper(Plugin);
    try std.testing.expectEqual(@as(i32, -10877), W.describe(8, 1, 0).err); // stream format, input scope
    try std.testing.expectEqual(@as(u32, 4 * 7), W.describe(3, 0, 0).info.size); // parameter list
    try std.testing.expectEqual(@as(i32, -10879), W.describe(9999, 0, 0).err);
    try std.testing.expect(!W.describe(12, 0, 0).info.writable); // latency
    try std.testing.expectEqual(@as(i32, -10879), W.describe(16, 0, 0).err); // value strings: gain isn't a list
    try std.testing.expect(W.describe(16, 0, 6).info.size > 0); // ...mode is
}
