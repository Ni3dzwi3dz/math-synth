//! MathSynth as a plugin for the common VST3 and Audio Unit wrappers (see
//! common/plugin.zig for the contract).

const common = @import("common");

pub const meta = @import("meta.zig").metadata(common.meta.Metadata);
pub const params: []const common.param.Info = &@import("params.zig").infos;
pub const Instance = @import("engine.zig").Engine;
pub const Editor = @import("editor.zig").Editor;
