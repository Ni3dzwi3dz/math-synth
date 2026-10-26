//! The contract between a plugin and the VST3 / Audio Unit wrappers.
//!
//! A plugin is a Zig type (usually its `plugin.zig` file) with:
//!
//!   pub const meta: common.meta.Metadata
//!   pub const params: []const common.param.Info    // index = parameter ID
//!   pub const Instance = struct { ... }            // DSP and state
//!   pub const Editor = struct { ... } or void      // optional Cocoa editor
//!
//! `Instance` must provide (all called by the wrappers):
//!
//!   fn init(*Instance) void                       // set up defaults
//!   fn getParam(*const Instance, u32) f32         // plain value
//!   fn setParam(*Instance, u32, f32) void         // from host or automation
//!   fn setSampleRate(*Instance, f64) void
//!   fn reset(*Instance) void                      // silence everything
//!   fn render(*Instance, []const [*]f32, usize, usize) void
//!       // write frames [from, to) to every output channel, audio thread
//!   fn tailSeconds(*const Instance) f64
//!   const max_state_len: usize
//!   fn saveState(*Instance, *[max_state_len]u8) []const u8
//!   fn loadState(*Instance, []const u8) bool      // false = rejected
//!
//! and, for `.instrument` plugins:
//!
//!   fn noteOn(*Instance, pitch: i16, tuning_cents: f32, velocity: f32, note_id: i32) void
//!   fn noteOff(*Instance, pitch: i16, note_id: i32) void
//!   fn allNotesOff(*Instance) void
//!
//! `Editor` (macOS) must provide:
//!
//!   const view_width: comptime_int, const view_height: comptime_int
//!   fn create(Allocator, parent: objc.Id, EditorHost(Instance)) !*Editor
//!   fn destroy(*Editor, Allocator) void
//!   fn stateLoaded(*Editor) void                  // host loaded a preset
//!
//! Effects (audio input) aren't supported by the wrappers yet.

const std = @import("std");

/// What an editor gets from the wrapper: access to the instance and a way
/// to report user edits so hosts can record automation and mark the project
/// as changed.
pub fn EditorHost(comptime Instance: type) type {
    return struct {
        const Self = @This();

        ctx: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            instance: *const fn (ctx: *anyopaque) ?*Instance,
            begin_edit: *const fn (ctx: *anyopaque, index: u32) void,
            set_param: *const fn (ctx: *anyopaque, index: u32, plain: f32) void,
            end_edit: *const fn (ctx: *anyopaque, index: u32) void,
            state_changed: *const fn (ctx: *anyopaque) void,
        };

        /// The plugin instance, or null if the host already closed it while
        /// the editor is still on screen (it can happen with Audio Units).
        pub fn instance(h: Self) ?*Instance {
            return h.vtable.instance(h.ctx);
        }

        /// A user edit of one parameter: `beginEdit`, any number of
        /// `setParam`, then `endEdit`. Hosts record it as one gesture.
        pub fn beginEdit(h: Self, index: u32) void {
            h.vtable.begin_edit(h.ctx, index);
        }

        pub fn setParam(h: Self, index: u32, plain: f32) void {
            h.vtable.set_param(h.ctx, index, plain);
        }

        pub fn endEdit(h: Self, index: u32) void {
            h.vtable.end_edit(h.ctx, index);
        }

        /// A one-shot edit (typed value, reset): begin, set, end.
        pub fn editParam(h: Self, index: u32, plain: f32) void {
            h.beginEdit(index);
            h.setParam(index, plain);
            h.endEdit(index);
        }

        /// Plugin state other than parameters changed (e.g. a formula), so
        /// the host should consider the project modified.
        pub fn stateChanged(h: Self) void {
            h.vtable.state_changed(h.ctx);
        }
    };
}

pub fn hasEditor(comptime P: type) bool {
    return @hasDecl(P, "Editor") and @TypeOf(P.Editor) == type and P.Editor != void;
}

/// Checks at compile time that `P` provides what the wrappers need, with a
/// readable error if not.
pub fn check(comptime P: type) void {
    inline for (.{ "meta", "params", "Instance" }) |decl| {
        if (!@hasDecl(P, decl)) @compileError(@typeName(P) ++ " must declare `" ++ decl ++ "`");
    }
    const I = P.Instance;
    var required: []const []const u8 = &.{ "init", "getParam", "setParam", "setSampleRate", "reset", "render", "tailSeconds", "max_state_len", "saveState", "loadState" };
    if (P.meta.kind == .instrument) required = required ++ &[_][]const u8{ "noteOn", "noteOff", "allNotesOff" };
    if (P.meta.kind == .effect) @compileError(P.meta.name ++ ": effects (audio input) aren't supported by the wrappers yet");
    for (required) |decl| {
        if (!@hasDecl(I, decl)) @compileError(@typeName(I) ++ " must declare `" ++ decl ++ "` (see common/plugin.zig)");
    }
    if (hasEditor(P)) {
        for ([_][]const u8{ "view_width", "view_height", "create", "destroy", "stateLoaded" }) |decl| {
            if (!@hasDecl(P.Editor, decl)) @compileError(@typeName(P.Editor) ++ " must declare `" ++ decl ++ "` (see common/plugin.zig)");
        }
    }
}
