//! Shared code for building plugins in this repository: the VST3 and Audio
//! Unit wrappers, parameters, DSP building blocks and Cocoa GUI helpers.
//! See plugin.zig for what a plugin provides.

/// The contract between a plugin and the wrappers, and the editor host API.
pub const plugin = @import("plugin.zig");
/// Plugin identity (names, IDs, versions) and Info.plist generation.
pub const meta = @import("meta.zig");
/// Parameter descriptions, formatting/parsing and a lock-free value store.
pub const param = @import("param.zig");
/// `Wrapper(P)` exposes a plugin as VST3.
pub const vst3 = @import("vst3.zig");
/// `Wrapper(P)` exposes a plugin as an Audio Unit (v2).
pub const au = @import("au.zig");

/// Linear ADSR envelope.
pub const adsr = @import("adsr.zig");
/// Lock-free handoff of large values from the UI to the audio thread.
pub const TripleBuffer = @import("triple_buffer.zig").TripleBuffer;
/// A small formula language in `x`, compiled to a stack machine.
pub const expr = @import("expr.zig");

/// Objective-C runtime and CoreGraphics bindings.
pub const objc = @import("gui/objc.zig");
/// Geometry of an interactive ADSR graph.
pub const envelope_graph = @import("gui/envelope_graph.zig");
/// Drawing of common controls (knob, slider).
pub const widgets = @import("gui/widgets.zig");

test {
    _ = param;
    _ = meta;
    _ = adsr;
    _ = @import("triple_buffer.zig");
    _ = expr;
    _ = envelope_graph;
    _ = au;
    _ = widgets;
}
