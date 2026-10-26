//! Generic Audio Unit (v2) wrapper. `Wrapper(P)` exposes a plugin type (see
//! plugin.zig) as a music device for GarageBand, Logic and other AU hosts.
//!
//! The host loads the .component bundle, calls the factory named in its
//! Info.plist and then dispatches through `lookup`, which maps selectors to
//! the functions below. A plugin's AU root file exports the entry points:
//!
//!   const W = common.au.Wrapper(@import("plugin.zig"));
//!   comptime { W.exportEntryPoints(); }
//!
//! and the build compiles au_view.m with that plugin's view class names.

const std = @import("std");
const plugin = @import("plugin.zig");
const param = @import("param.zig");
const objc = @import("gui/objc.zig");

const allocator = std.heap.c_allocator;

// CoreAudio types and constants -------------------------------------------------

const OSStatus = i32;
const no_err: OSStatus = 0;
const param_err: OSStatus = -50;
const unimplemented: OSStatus = -4;
const err_invalid_property: OSStatus = -10879;
const err_invalid_parameter: OSStatus = -10878;
const err_invalid_element: OSStatus = -10877;
const err_too_many_frames: OSStatus = -10874;
const err_format_not_supported: OSStatus = -10868;
const err_uninitialized: OSStatus = -10867;
const err_invalid_scope: OSStatus = -10866;
const err_property_not_writable: OSStatus = -10865;
const err_invalid_property_value: OSStatus = -10851;
const err_initialized: OSStatus = -10849;

const scope_global = 0;
const scope_input = 1;
const scope_output = 2;

const prop_class_info = 0;
const prop_sample_rate = 2;
const prop_parameter_list = 3;
const prop_parameter_info = 4;
const prop_parameter_value_strings = 16;
const prop_stream_format = 8;
const prop_element_count = 11;
const prop_latency = 12;
const prop_supported_num_channels = 13;
const prop_maximum_frames_per_slice = 14;
const prop_tail_time = 20;
const prop_last_render_error = 22;
const prop_cocoa_ui = 31;
const prop_present_preset = 36;
const prop_offline_render = 37;
const prop_should_allocate_buffer = 51;
const prop_instrument_count = 1000;
/// Private: lets the view factory find the instance behind an AudioUnit.
const prop_instance_pointer = 64000;

const action_pre_render: u32 = 1 << 2;
const action_post_render: u32 = 1 << 3;

const format_linear_pcm: u32 = fourCC("lpcm");
const flag_is_float: u32 = 1 << 0;
const flag_is_packed: u32 = 1 << 3;
const flag_is_non_interleaved: u32 = 1 << 5;

fn fourCC(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

const AudioUnit = ?*anyopaque;

const AudioComponentDescription = extern struct {
    componentType: u32,
    componentSubType: u32,
    componentManufacturer: u32,
    componentFlags: u32,
    componentFlagsMask: u32,
};

const PlugInInterface = extern struct {
    open: *const fn (self: *anyopaque, instance: AudioUnit) callconv(.c) OSStatus,
    close: *const fn (self: *anyopaque) callconv(.c) OSStatus,
    lookup: *const fn (selector: i16) callconv(.c) ?*const anyopaque,
    reserved: ?*anyopaque = null,
};

const StreamFormat = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32 = 0,
};

const AudioBuffer = extern struct {
    mNumberChannels: u32,
    mDataByteSize: u32,
    mData: ?*anyopaque,
};

const AudioBufferList = extern struct {
    mNumberBuffers: u32,
    mBuffers: [1]AudioBuffer, // actually mNumberBuffers long

    fn buffers(l: *AudioBufferList) []AudioBuffer {
        const first: [*]AudioBuffer = &l.mBuffers;
        return first[0..l.mNumberBuffers];
    }
};

const ChannelInfo = extern struct { inChannels: i16, outChannels: i16 };

const ParameterInfo = extern struct {
    name: [52]u8 = @splat(0),
    unitName: CFTypeRef = null,
    clumpID: u32 = 0,
    cfNameString: CFTypeRef = null,
    unit: u32 = 0,
    minValue: f32 = 0,
    maxValue: f32 = 0,
    defaultValue: f32 = 0,
    flags: u32 = 0,
};

const param_flag_readable: u32 = 0x40000000;
const param_flag_writable: u32 = 0x80000000;
const param_flag_has_cf_name: u32 = 0x08000000;
const param_flag_cf_name_release: u32 = 0x10;
const param_flag_display_cubed: u32 = 0x30000;

const unit_indexed: u32 = 1;
const unit_percent: u32 = 3;
const unit_decibels: u32 = 13;
const unit_milliseconds: u32 = 24;

const ParameterEvent = extern struct {
    scope: u32,
    element: u32,
    parameter: u32,
    event_type: u32, // 1 = immediate, 2 = ramped
    args: extern union {
        ramp: extern struct { start_offset: i32, duration: u32, start_value: f32, end_value: f32 },
        immediate: extern struct { offset: u32, value: f32 },
    },
};

/// AudioUnitParameter, for AUParameterSet and parameter events.
const ParameterRef = extern struct { unit: AudioUnit, id: u32, scope: u32, element: u32 };
const UnitEvent = extern struct {
    event_type: u32, // 0 = value change, 1 = begin gesture, 2 = end gesture
    parameter: ParameterRef,
};
comptime {
    // Sizes measured against the macOS SDK headers.
    std.debug.assert(@sizeOf(ParameterInfo) == 104 and @offsetOf(ParameterInfo, "unit") == 80);
    std.debug.assert(@sizeOf(ParameterEvent) == 32);
    std.debug.assert(@sizeOf(ParameterRef) == 24 and @sizeOf(UnitEvent) == 32 and @offsetOf(UnitEvent, "parameter") == 8);
}
extern fn AUParameterSet(listener: ?*anyopaque, sender: ?*anyopaque, param: *const ParameterRef, value: f32, offset: u32) OSStatus;
extern fn AUParameterListenerNotify(listener: ?*anyopaque, sender: ?*anyopaque, param: *const ParameterRef) OSStatus;
extern fn AUEventListenerNotify(listener: ?*anyopaque, sender: ?*anyopaque, event: *const UnitEvent) OSStatus;
const CocoaViewInfo = extern struct { bundle_location: CFTypeRef, view_class: [1]CFTypeRef };
const Preset = extern struct { presetNumber: i32, presetName: CFTypeRef };

const PropertyListenerProc = *const fn (ref: ?*anyopaque, unit: AudioUnit, id: u32, scope: u32, element: u32) callconv(.c) void;
const RenderCallback = *const fn (ref: ?*anyopaque, flags: *u32, ts: ?*const anyopaque, bus: u32, frames: u32, data: ?*AudioBufferList) callconv(.c) OSStatus;

// CoreFoundation ---------------------------------------------------------------

const CFTypeRef = ?*anyopaque;
extern fn CFRelease(cf: CFTypeRef) void;
extern fn CFRetain(cf: CFTypeRef) CFTypeRef;
extern fn CFGetTypeID(cf: CFTypeRef) usize;
extern fn CFDataGetTypeID() usize;
extern fn CFDictionaryGetTypeID() usize;
extern fn CFDataCreate(alloc: CFTypeRef, bytes: [*]const u8, len: isize) CFTypeRef;
extern fn CFDataGetLength(data: CFTypeRef) isize;
extern fn CFDataGetBytePtr(data: CFTypeRef) [*]const u8;
extern fn CFStringCreateWithBytes(alloc: CFTypeRef, bytes: [*]const u8, len: isize, encoding: u32, external: bool) CFTypeRef;
extern fn CFNumberCreate(alloc: CFTypeRef, kind: isize, value: *const anyopaque) CFTypeRef;
extern fn CFDictionaryCreateMutable(alloc: CFTypeRef, capacity: isize, keys: *const anyopaque, values: *const anyopaque) CFTypeRef;
extern fn CFDictionarySetValue(dict: CFTypeRef, key: CFTypeRef, value: CFTypeRef) void;
extern fn CFDictionaryGetValue(dict: CFTypeRef, key: CFTypeRef) CFTypeRef;
extern fn CFArrayCreate(alloc: CFTypeRef, values: [*]const CFTypeRef, count: isize, callbacks: *const anyopaque) CFTypeRef;
extern var kCFTypeArrayCallBacks: u8;
extern fn CFURLCreateFromFileSystemRepresentation(alloc: CFTypeRef, path: [*]const u8, len: isize, is_dir: bool) CFTypeRef;
extern var kCFTypeDictionaryKeyCallBacks: u8;
extern var kCFTypeDictionaryValueCallBacks: u8;

const utf8_encoding: u32 = 0x08000100;
const number_sint32: isize = 3;

/// +1 CFString. Release with CFRelease.
fn cfString(s: []const u8) CFTypeRef {
    return CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), utf8_encoding, false);
}

fn dictSet(dict: CFTypeRef, key: []const u8, value: CFTypeRef) void {
    const k = cfString(key);
    CFDictionarySetValue(dict, k, value);
    CFRelease(k);
    CFRelease(value);
}

fn dictSetInt(dict: CFTypeRef, key: []const u8, v: i32) void {
    dictSet(dict, key, CFNumberCreate(null, number_sint32, &v));
}

fn dictGet(dict: CFTypeRef, key: []const u8) CFTypeRef {
    const k = cfString(key);
    defer CFRelease(k);
    return CFDictionaryGetValue(dict, k);
}

extern fn AudioUnitGetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: *anyopaque, size: *u32) OSStatus;

extern fn pthread_main_np() c_int;

const DlInfo = extern struct { dli_fname: ?[*:0]const u8, dli_fbase: ?*anyopaque, dli_sname: ?[*:0]const u8, dli_saddr: ?*anyopaque };
extern fn dladdr(addr: *const anyopaque, info: *DlInfo) c_int;

// Objective-C side (au_view.m) -------------------------------------------------

extern fn plugin_au_container_new(frame: objc.NSRect, ctx: *anyopaque) ?*anyopaque;
extern fn plugin_au_autorelease(view: ?*anyopaque) ?*anyopaque;

// MIDI input -------------------------------------------------------------------

const MidiEvent = struct { status: u8, data1: u8, data2: u8, offset: u32 };

/// Lock-free queue from MusicDeviceMIDIEvent (any thread) to the render
/// thread. Producers are serialised by a spin lock; the consumer never waits.
const MidiQueue = struct {
    events: [512]MidiEvent = undefined,
    head: std.atomic.Value(usize) = .init(0), // next write, owned by producers
    tail: std.atomic.Value(usize) = .init(0), // next read, owned by the consumer
    producer_lock: std.atomic.Value(bool) = .init(false),

    fn push(q: *MidiQueue, e: MidiEvent) bool {
        while (q.producer_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        defer q.producer_lock.store(false, .release);
        const head = q.head.load(.monotonic);
        const next = (head + 1) % q.events.len;
        if (next == q.tail.load(.acquire)) return false; // full: drop
        q.events[head] = e;
        q.head.store(next, .release);
        return true;
    }

    fn pop(q: *MidiQueue) ?MidiEvent {
        const tail = q.tail.load(.monotonic);
        if (tail == q.head.load(.acquire)) return null;
        const e = q.events[tail];
        q.tail.store((tail + 1) % q.events.len, .release);
        return e;
    }
};

pub fn Wrapper(comptime P: type) type {
    comptime plugin.check(P);
    return struct {
        const meta = P.meta;
        const has_editor = plugin.hasEditor(P);
        const Host = plugin.EditorHost(P.Instance);

        /// Ties one editor view to its instance. The instance can be closed while a
        /// host still holds the view, and vice versa, so each side clears the other's
        /// pointer when it goes away.
        const ViewLink = struct {
            instance: ?*Unit,
            editor: if (has_editor) ?*P.Editor else void = if (has_editor) null else {},
        };

        pub const Unit = struct {
            iface: PlugInInterface = .{ .open = open, .close = close, .lookup = lookup },
            unit: AudioUnit = null,
            plugin: P.Instance = undefined,

            initialized: bool = false,
            sample_rate: f64 = 44100,
            channels: u32 = 2,
            max_frames: u32 = 1156,
            allocate_buffers: bool = true,
            offline: bool = false,
            /// Used when the host passes buffers with null mData.
            own_buffers: []f32 = &.{},
            last_render_error: OSStatus = no_err,
            preset_name: CFTypeRef = null,

            midi: MidiQueue = .{},

            listeners: [32]struct { id: u32, proc: PropertyListenerProc, ref: ?*anyopaque } = undefined,
            listener_count: usize = 0,
            notify_lock: std.atomic.Value(bool) = .init(false),
            notifies: [8]struct { proc: RenderCallback, ref: ?*anyopaque } = undefined,
            notify_count: usize = 0,

            views: [8]?*ViewLink = @splat(null),

            fn from(self: *anyopaque) *Unit {
                return @fieldParentPtr("iface", @as(*PlugInInterface, @ptrCast(@alignCast(self))));
            }

            fn format(inst: *const Unit) StreamFormat {
                return .{
                    .mSampleRate = inst.sample_rate,
                    .mFormatID = format_linear_pcm,
                    .mFormatFlags = flag_is_float | flag_is_packed | flag_is_non_interleaved,
                    .mBytesPerPacket = 4,
                    .mFramesPerPacket = 1,
                    .mBytesPerFrame = 4,
                    .mChannelsPerFrame = inst.channels,
                    .mBitsPerChannel = 32,
                };
            }

            fn propertyChanged(inst: *Unit, id: u32, scope: u32, element: u32) void {
                for (inst.listeners[0..inst.listener_count]) |l| {
                    if (l.id == id) l.proc(l.ref, inst.unit, id, scope, element);
                }
            }

            fn allocateBuffers(inst: *Unit) bool {
                inst.freeBuffers();
                inst.own_buffers = allocator.alloc(f32, @as(usize, inst.max_frames) * inst.channels) catch return false;
                return true;
            }

            fn freeBuffers(inst: *Unit) void {
                if (inst.own_buffers.len > 0) allocator.free(inst.own_buffers);
                inst.own_buffers = &.{};
            }

            fn lockNotifies(inst: *Unit) void {
                while (inst.notify_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
            }
            fn unlockNotifies(inst: *Unit) void {
                inst.notify_lock.store(false, .release);
            }

            fn callNotifies(inst: *Unit, flags: *u32, action: u32, ts: ?*const anyopaque, bus: u32, frames: u32, data: *AudioBufferList) void {
                inst.lockNotifies();
                defer inst.unlockNotifies();
                for (inst.notifies[0..inst.notify_count]) |n| {
                    var f = flags.* | action;
                    _ = n.proc(n.ref, &f, ts, bus, frames, data);
                }
            }

            fn paramRef(inst: *const Unit, index: u32) ParameterRef {
                return .{ .unit = inst.unit, .id = index, .scope = scope_global, .element = 0 };
            }

            /// State was loaded from a project or preset: refresh open editors.
            fn refreshEditors(inst: *Unit) void {
                if (!has_editor) return;
                if (pthread_main_np() == 0) return; // Cocoa views are main-thread only
                for (inst.views) |maybe| {
                    if (maybe) |link| if (link.editor) |e| e.stateLoaded();
                }
            }

            fn handleMidi(inst: *Unit, e: MidiEvent) void {
                const pitch: i16 = e.data1;
                switch (e.status & 0xF0) {
                    0x90 => if (e.data2 == 0) inst.plugin.noteOff(pitch, -1) else inst.plugin.noteOn(pitch, 0, @as(f32, @floatFromInt(e.data2)) / 127.0, -1),
                    0x80 => inst.plugin.noteOff(pitch, -1),
                    // All sound off / all notes off.
                    0xB0 => if (e.data1 == 120) inst.plugin.reset() else if (e.data1 == 123) inst.plugin.allNotesOff(),
                    else => {},
                }
            }
        };

        // Factory and component entry points -------------------------------------------

        /// Exports the factory named in Info.plist and the functions au_view.m
        /// calls. Call from a `comptime` block in the plugin's AU root file.
        pub fn exportEntryPoints() void {
            @export(&factory, .{ .name = meta.au.factory });
            if (has_editor) {
                @export(&makeView, .{ .name = "plugin_au_make_view" });
                @export(&viewGone, .{ .name = "plugin_au_view_gone" });
            }
        }

        fn factory(_: *const AudioComponentDescription) callconv(.c) ?*PlugInInterface {
            const inst = allocator.create(Unit) catch return null;
            inst.* = .{};
            inst.plugin.init();
            inst.preset_name = cfString("Untitled");
            return &inst.iface;
        }

        fn open(self: *anyopaque, unit: AudioUnit) callconv(.c) OSStatus {
            Unit.from(self).unit = unit;
            return no_err;
        }

        fn close(self: *anyopaque) callconv(.c) OSStatus {
            const inst = Unit.from(self);
            for (inst.views) |maybe| {
                if (maybe) |link| link.instance = null;
            }
            inst.freeBuffers();
            CFRelease(inst.preset_name);
            allocator.destroy(inst);
            return no_err;
        }

        fn lookup(selector: i16) callconv(.c) ?*const anyopaque {
            return switch (selector) {
                0x0001 => &initialize,
                0x0002 => &uninitialize,
                0x0003 => &getPropertyInfo,
                0x0004 => &getProperty,
                0x0005 => &setProperty,
                0x0006 => &getParameter,
                0x0007 => &setParameter,
                0x0009 => &reset,
                0x000A => &addPropertyListener,
                0x000B => &removePropertyListener,
                0x000E => &render,
                0x000F => &addRenderNotify,
                0x0010 => &removeRenderNotify,
                0x0011 => &scheduleParameters,
                0x0012 => &removePropertyListenerWithUserData,
                0x0101 => &midiEvent,
                0x0102 => &sysEx,
                0x0105 => &startNote,
                0x0106 => &stopNote,
                else => null,
            };
        }

        fn initialize(self: *anyopaque) callconv(.c) OSStatus {
            const inst = Unit.from(self);
            if (inst.initialized) return no_err;
            if (!inst.allocateBuffers()) return param_err;
            inst.plugin.setSampleRate(inst.sample_rate);
            inst.plugin.reset();
            inst.initialized = true;
            return no_err;
        }

        fn uninitialize(self: *anyopaque) callconv(.c) OSStatus {
            const inst = Unit.from(self);
            inst.initialized = false;
            inst.freeBuffers();
            return no_err;
        }

        fn reset(self: *anyopaque, _: u32, _: u32) callconv(.c) OSStatus {
            const inst = Unit.from(self);
            inst.plugin.reset();
            while (inst.midi.pop()) |_| {}
            return no_err;
        }

        // Properties -------------------------------------------------------------------

        const PropInfo = struct { size: u32, writable: bool };
        const Described = union(enum) { info: PropInfo, err: OSStatus };

        /// Size and writability of a property on the given scope/element, or an error
        /// code. Shared by GetPropertyInfo, GetProperty and SetProperty so all three
        /// agree.
        pub fn describe(id: u32, scope: u32, element: u32) Described {
            const global_only = scope == scope_global;
            const output_el0 = scope == scope_output and element == 0;
            const info = struct {
                fn of(comptime T: type, writable: bool) Described {
                    return .{ .info = .{ .size = @sizeOf(T), .writable = writable } };
                }
            }.of;
            const bad: Described = .{ .err = if (scope > scope_output) err_invalid_scope else err_invalid_element };

            return switch (id) {
                prop_class_info => if (global_only) info(CFTypeRef, true) else bad,
                prop_sample_rate => if (output_el0 or global_only) info(f64, true) else bad,
                prop_stream_format => if (output_el0) info(StreamFormat, true) else bad,
                prop_should_allocate_buffer => if (output_el0) info(u32, true) else bad,
                prop_parameter_list => if (global_only)
                    .{ .info = .{ .size = 4 * P.params.len, .writable = false } }
                else if (scope <= scope_output) .{ .info = .{ .size = 0, .writable = false } } else bad,
                prop_parameter_info => if (global_only and element < P.params.len) info(ParameterInfo, false) else .{ .err = err_invalid_parameter },
                // Names of list parameters' values.
                prop_parameter_value_strings => if (global_only and isListParam(element)) info(CFTypeRef, false) else .{ .err = err_invalid_property },
                prop_element_count => if (scope <= scope_output) info(u32, false) else bad,
                prop_latency, prop_tail_time => if (global_only) info(f64, false) else bad,
                prop_supported_num_channels => if (global_only) .{ .info = .{ .size = @sizeOf(ChannelInfo) * supported_channels.len, .writable = false } } else bad,
                prop_maximum_frames_per_slice => if (global_only) info(u32, true) else bad,
                prop_last_render_error => if (global_only) info(OSStatus, false) else bad,
                prop_cocoa_ui => if (global_only and has_editor) info(CocoaViewInfo, false) else if (global_only) .{ .err = err_invalid_property } else bad,
                prop_present_preset => if (global_only) info(Preset, true) else bad,
                prop_offline_render => if (global_only) info(u32, true) else bad,
                prop_instrument_count => if (global_only) info(u32, false) else bad,
                prop_instance_pointer => if (global_only) info(*Unit, false) else bad,
                else => .{ .err = err_invalid_property },
            };
        }

        const supported_channels = [_]ChannelInfo{ .{ .inChannels = 0, .outChannels = 2 }, .{ .inChannels = 0, .outChannels = 1 } };

        fn getPropertyInfo(_: *anyopaque, id: u32, scope: u32, element: u32, size: ?*u32, writable: ?*u8) callconv(.c) OSStatus {
            switch (describe(id, scope, element)) {
                .err => |e| return e,
                .info => |i| {
                    if (size) |s| s.* = i.size;
                    if (writable) |w| w.* = @intFromBool(i.writable);
                    return no_err;
                },
            }
        }

        fn getProperty(self: *anyopaque, id: u32, scope: u32, element: u32, out: ?*anyopaque, size: ?*u32) callconv(.c) OSStatus {
            const inst = Unit.from(self);
            const info = switch (describe(id, scope, element)) {
                .err => |e| return e,
                .info => |i| i,
            };
            const io_size = size orelse return param_err;
            if (info.size == 0) {
                io_size.* = 0;
                return no_err;
            }
            if (io_size.* < info.size) return param_err;
            const dst = out orelse return param_err;
            io_size.* = info.size;

            switch (id) {
                prop_class_info => write(CFTypeRef, dst, classInfo(inst)),
                prop_sample_rate => write(f64, dst, inst.sample_rate),
                prop_stream_format => write(StreamFormat, dst, inst.format()),
                prop_should_allocate_buffer => write(u32, dst, @intFromBool(inst.allocate_buffers)),
                prop_element_count => write(u32, dst, if (scope == scope_input) 0 else 1),
                prop_latency => write(f64, dst, 0),
                prop_tail_time => write(f64, dst, inst.plugin.tailSeconds()),
                prop_parameter_list => for (0..P.params.len) |i| {
                    @as([*]align(1) u32, @ptrCast(dst))[i] = @intCast(i);
                },
                prop_parameter_info => write(ParameterInfo, dst, parameterInfo(P.params[element])),
                prop_parameter_value_strings => write(CFTypeRef, dst, valueStrings(P.params[element])),
                prop_supported_num_channels => @as(*[supported_channels.len]ChannelInfo, @ptrCast(@alignCast(dst))).* = supported_channels,
                prop_maximum_frames_per_slice => write(u32, dst, inst.max_frames),
                prop_last_render_error => {
                    write(OSStatus, dst, inst.last_render_error);
                    inst.last_render_error = no_err;
                },
                prop_cocoa_ui => write(CocoaViewInfo, dst, cocoaViewInfo() orelse return err_invalid_property),
                prop_present_preset => write(Preset, dst, .{ .presetNumber = -1, .presetName = CFRetain(inst.preset_name) }),
                prop_offline_render => write(u32, dst, @intFromBool(inst.offline)),
                prop_instrument_count => write(u32, dst, 0),
                prop_instance_pointer => write(*Unit, dst, inst),
                else => return err_invalid_property,
            }
            return no_err;
        }

        fn write(comptime T: type, dst: *anyopaque, value: T) void {
            @as(*align(1) T, @ptrCast(dst)).* = value;
        }

        fn read(comptime T: type, src: *const anyopaque) T {
            return @as(*align(1) const T, @ptrCast(src)).*;
        }

        fn setProperty(self: *anyopaque, id: u32, scope: u32, element: u32, data: ?*const anyopaque, size: u32) callconv(.c) OSStatus {
            const inst = Unit.from(self);
            const info = switch (describe(id, scope, element)) {
                .err => |e| return e,
                .info => |i| i,
            };
            if (!info.writable) return err_property_not_writable;
            const src = data orelse return param_err;
            if (size < info.size) return param_err;

            switch (id) {
                prop_class_info => {
                    const state = stateFromClassInfo(read(CFTypeRef, src)) orelse return err_invalid_property_value;
                    if (!inst.plugin.loadState(state)) return err_invalid_property_value;
                    inst.refreshEditors();
                    inst.propertyChanged(prop_class_info, scope_global, 0);
                    // Let hosts (and their generic controls) pick up the restored values.
                    for (0..P.params.len) |i| _ = AUParameterListenerNotify(null, null, &inst.paramRef(@intCast(i)));
                },
                prop_sample_rate => {
                    const rate = read(f64, src);
                    if (!(rate > 0)) return err_invalid_property_value;
                    if (rate == inst.sample_rate) return no_err;
                    if (inst.initialized) return err_initialized;
                    inst.sample_rate = rate;
                    inst.propertyChanged(prop_sample_rate, scope_output, 0);
                    inst.propertyChanged(prop_stream_format, scope_output, 0);
                },
                prop_stream_format => {
                    const f = read(StreamFormat, src);
                    const flags_needed = flag_is_float | flag_is_non_interleaved;
                    if (f.mFormatID != format_linear_pcm or f.mFormatFlags & flags_needed != flags_needed or
                        f.mBitsPerChannel != 32 or f.mChannelsPerFrame < 1 or f.mChannelsPerFrame > 2 or !(f.mSampleRate > 0))
                        return err_format_not_supported;
                    if (f.mSampleRate == inst.sample_rate and f.mChannelsPerFrame == inst.channels) return no_err;
                    if (inst.initialized) return err_initialized;
                    inst.sample_rate = f.mSampleRate;
                    inst.channels = f.mChannelsPerFrame;
                    inst.propertyChanged(prop_stream_format, scope_output, 0);
                },
                prop_should_allocate_buffer => inst.allocate_buffers = read(u32, src) != 0,
                prop_maximum_frames_per_slice => {
                    const frames = read(u32, src);
                    if (frames == 0) return err_invalid_property_value;
                    inst.max_frames = frames;
                    if (inst.initialized and !inst.allocateBuffers()) return param_err;
                    inst.propertyChanged(prop_maximum_frames_per_slice, scope_global, 0);
                },
                prop_present_preset => {
                    const p = read(Preset, src);
                    if (p.presetName) |name| {
                        CFRelease(inst.preset_name);
                        inst.preset_name = CFRetain(name);
                    }
                    inst.propertyChanged(prop_present_preset, scope_global, 0);
                },
                prop_offline_render => inst.offline = read(u32, src) != 0,
                else => return err_property_not_writable,
            }
            return no_err;
        }

        /// +1 CFDictionary in the standard AU preset layout, with our state in "data".
        fn classInfo(inst: *Unit) CFTypeRef {
            const dict = CFDictionaryCreateMutable(null, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            dictSetInt(dict, "version", 0);
            dictSetInt(dict, "type", @bitCast(fourCC(meta.au.type)));
            dictSetInt(dict, "subtype", @bitCast(fourCC(meta.au.subtype)));
            dictSetInt(dict, "manufacturer", @bitCast(fourCC(meta.au.manufacturer)));
            dictSet(dict, "name", CFRetain(inst.preset_name));
            var buf: [P.Instance.max_state_len]u8 = undefined;
            const bytes = inst.plugin.saveState(&buf);
            dictSet(dict, "data", CFDataCreate(null, bytes.ptr, @intCast(bytes.len)));
            return dict;
        }

        /// The plugin's state bytes from a ClassInfo dictionary (valid while the
        /// dictionary is).
        fn stateFromClassInfo(dict: CFTypeRef) ?[]const u8 {
            if (dict == null or CFGetTypeID(dict) != CFDictionaryGetTypeID()) return null;
            const data = dictGet(dict, "data");
            if (data == null or CFGetTypeID(data) != CFDataGetTypeID()) return null;
            const len: usize = @intCast(CFDataGetLength(data));
            return CFDataGetBytePtr(data)[0..len];
        }

        /// Bundle URL and class name of the view factory, both +1 for the host.
        fn cocoaViewInfo() ?CocoaViewInfo {
            // Derive the bundle path from this binary: .../X.component/Contents/MacOS/X
            var dl: DlInfo = undefined;
            if (dladdr(@ptrCast(&cocoaViewInfo), &dl) == 0) return null;
            var path: []const u8 = std.mem.span(dl.dli_fname orelse return null);
            for (0..3) |_| path = std.fs.path.dirname(path) orelse return null;
            const url = CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), true) orelse return null;
            return .{ .bundle_location = url, .view_class = .{cfString(comptime meta.auViewFactoryClass())} };
        }

        // Listeners and notifications -------------------------------------------------

        fn addPropertyListener(self: *anyopaque, id: u32, proc: PropertyListenerProc, ref: ?*anyopaque) callconv(.c) OSStatus {
            const inst = Unit.from(self);
            if (inst.listener_count == inst.listeners.len) return param_err;
            inst.listeners[inst.listener_count] = .{ .id = id, .proc = proc, .ref = ref };
            inst.listener_count += 1;
            return no_err;
        }

        fn removeListeners(inst: *Unit, id: u32, proc: PropertyListenerProc, ref: ?*anyopaque, match_ref: bool) void {
            var kept: usize = 0;
            for (inst.listeners[0..inst.listener_count]) |l| {
                const matches = l.id == id and l.proc == proc and (!match_ref or l.ref == ref);
                if (!matches) {
                    inst.listeners[kept] = l;
                    kept += 1;
                }
            }
            inst.listener_count = kept;
        }

        fn removePropertyListener(self: *anyopaque, id: u32, proc: PropertyListenerProc) callconv(.c) OSStatus {
            removeListeners(Unit.from(self), id, proc, null, false);
            return no_err;
        }

        fn removePropertyListenerWithUserData(self: *anyopaque, id: u32, proc: PropertyListenerProc, ref: ?*anyopaque) callconv(.c) OSStatus {
            removeListeners(Unit.from(self), id, proc, ref, true);
            return no_err;
        }

        fn addRenderNotify(self: *anyopaque, proc: RenderCallback, ref: ?*anyopaque) callconv(.c) OSStatus {
            const inst = Unit.from(self);
            inst.lockNotifies();
            defer inst.unlockNotifies();
            if (inst.notify_count == inst.notifies.len) return param_err;
            inst.notifies[inst.notify_count] = .{ .proc = proc, .ref = ref };
            inst.notify_count += 1;
            return no_err;
        }

        fn removeRenderNotify(self: *anyopaque, proc: RenderCallback, ref: ?*anyopaque) callconv(.c) OSStatus {
            const inst = Unit.from(self);
            inst.lockNotifies();
            defer inst.unlockNotifies();
            var kept: usize = 0;
            for (inst.notifies[0..inst.notify_count]) |n| {
                if (n.proc != proc or n.ref != ref) {
                    inst.notifies[kept] = n;
                    kept += 1;
                }
            }
            inst.notify_count = kept;
            return no_err;
        }

        // Parameters -------------------------------------------------------------------

        fn parameterInfo(i: param.Info) ParameterInfo {
            var out: ParameterInfo = .{
                .unit = switch (i.unit) {
                    .decibels => unit_decibels,
                    .milliseconds => unit_milliseconds,
                    .percent => unit_percent,
                    .list => unit_indexed,
                },
                .minValue = i.min,
                .maxValue = i.max,
                .defaultValue = i.default,
                .flags = param_flag_readable | param_flag_writable | param_flag_has_cf_name | param_flag_cf_name_release |
                    (if (i.cubic) param_flag_display_cubed else 0),
                .cfNameString = cfString(i.name), // released by the host (CFNameRelease)
            };
            @memcpy(out.name[0..i.name.len], i.name);
            return out;
        }

        fn isListParam(element: u32) bool {
            return element < P.params.len and P.params[element].unit == .list;
        }

        /// +1 CFArray of the value names, for the host to release.
        fn valueStrings(info: param.Info) CFTypeRef {
            const choices = info.choices;
            var strings: [8]CFTypeRef = undefined;
            for (choices, 0..) |choice, i| strings[i] = cfString(choice);
            const array = CFArrayCreate(null, &strings, @intCast(choices.len), &kCFTypeArrayCallBacks);
            for (strings[0..choices.len]) |str| CFRelease(str); // the array retains them
            return array;
        }

        fn getParameter(self: *anyopaque, raw_id: u32, scope: u32, element: u32, out: ?*f32) callconv(.c) OSStatus {
            if (scope != scope_global) return err_invalid_scope;
            if (element != 0) return err_invalid_element;
            if (raw_id >= P.params.len) return err_invalid_parameter;
            (out orelse return param_err).* = Unit.from(self).plugin.getParam(raw_id);
            return no_err;
        }

        fn setParameter(self: *anyopaque, raw_id: u32, scope: u32, element: u32, value: f32, _: u32) callconv(.c) OSStatus {
            if (scope != scope_global) return err_invalid_scope;
            if (element != 0) return err_invalid_element;
            if (raw_id >= P.params.len) return err_invalid_parameter;
            // Values are applied per render call, so the buffer offset is ignored.
            Unit.from(self).plugin.setParam(raw_id, value);

            return no_err;
        }

        fn scheduleParameters(self: *anyopaque, events: ?[*]const ParameterEvent, count: u32) callconv(.c) OSStatus {
            if (count == 0) return no_err;
            const list = events orelse return param_err;
            for (list[0..count]) |e| {
                // Ramps jump straight to their end value; the gain smoothing and the
                // envelope hide the step.
                const value = if (e.event_type == 2) e.args.ramp.end_value else e.args.immediate.value;
                const r = setParameter(self, e.parameter, e.scope, e.element, value, 0);
                if (r != no_err) return r;
            }
            return no_err;
        }

        // MIDI -------------------------------------------------------------------------

        fn midiEvent(self: *anyopaque, status: u32, data1: u32, data2: u32, offset: u32) callconv(.c) OSStatus {
            _ = Unit.from(self).midi.push(.{
                .status = @truncate(status),
                .data1 = @truncate(data1 & 0x7F),
                .data2 = @truncate(data2 & 0x7F),
                .offset = offset,
            });
            return no_err;
        }

        fn sysEx(_: *anyopaque, _: ?[*]const u8, _: u32) callconv(.c) OSStatus {
            return no_err;
        }

        fn startNote(_: *anyopaque, _: u32, _: u32, _: ?*u32, _: u32, _: ?*const anyopaque) callconv(.c) OSStatus {
            return unimplemented;
        }

        fn stopNote(_: *anyopaque, _: u32, _: u32, _: u32) callconv(.c) OSStatus {
            return unimplemented;
        }

        // Rendering --------------------------------------------------------------------

        fn render(self: *anyopaque, flags: ?*u32, ts: ?*const anyopaque, bus: u32, frames: u32, data: ?*AudioBufferList) callconv(.c) OSStatus {
            const inst = Unit.from(self);
            const result = renderInner(inst, flags, ts, bus, frames, data);
            if (result != no_err) inst.last_render_error = result;
            return result;
        }

        fn renderInner(inst: *Unit, flags_ptr: ?*u32, ts: ?*const anyopaque, bus: u32, frames: u32, data: ?*AudioBufferList) OSStatus {
            if (!inst.initialized) return err_uninitialized;
            if (bus != 0) return err_invalid_element;
            if (frames > inst.max_frames) return err_too_many_frames;
            const list = data orelse return param_err;
            var dummy_flags: u32 = 0;
            const flags = flags_ptr orelse &dummy_flags;

            const bufs = list.buffers();
            if (bufs.len != inst.channels) return param_err;
            var channel_ptrs: [2][*]f32 = undefined;
            for (bufs, 0..) |*b, i| {
                if (b.mData == null) {
                    if (!inst.allocate_buffers) return param_err;
                    b.mData = inst.own_buffers[i * inst.max_frames ..].ptr;
                } else if (b.mDataByteSize < frames * 4) {
                    return param_err;
                }
                b.mDataByteSize = frames * 4;
                channel_ptrs[i] = @ptrCast(@alignCast(b.mData.?));
            }
            const channels = channel_ptrs[0..bufs.len];

            if (inst.notify_count > 0) inst.callNotifies(flags, action_pre_render, ts, bus, frames, list);

            var pos: usize = 0;
            while (inst.midi.pop()) |e| {
                const at = @min(@as(usize, e.offset), frames);
                if (at > pos) {
                    inst.plugin.render(channels, pos, at);
                    pos = at;
                }
                inst.handleMidi(e);
            }
            inst.plugin.render(channels, pos, frames);

            if (inst.notify_count > 0) inst.callNotifies(flags, action_post_render, ts, bus, frames, list);
            return no_err;
        }

        // Editor -----------------------------------------------------------------------

        fn makeView(unit: AudioUnit) callconv(.c) ?*anyopaque {
            var inst: *Unit = undefined;
            var size: u32 = @sizeOf(*Unit);
            if (AudioUnitGetProperty(unit, prop_instance_pointer, scope_global, 0, @ptrCast(&inst), &size) != no_err) return null;

            const slot = for (&inst.views) |*v| {
                if (v.* == null) break v;
            } else return null;
            const link = allocator.create(ViewLink) catch return null;
            link.* = .{ .instance = inst };

            const container = plugin_au_container_new(.make(0, 0, P.Editor.view_width, P.Editor.view_height), link) orelse {
                allocator.destroy(link);
                return null;
            };
            slot.* = link;
            link.editor = P.Editor.create(allocator, container, .{ .ctx = link, .vtable = &host_vtable }) catch null;
            return plugin_au_autorelease(container);
        }

        fn viewGone(ctx: *anyopaque) callconv(.c) void {
            const link: *ViewLink = @ptrCast(@alignCast(ctx));
            if (link.editor) |e| e.destroy(allocator);
            if (link.instance) |inst| {
                for (&inst.views) |*v| {
                    if (v.* == link) v.* = null;
                }
            }
            allocator.destroy(link);
        }

        const host_vtable: Host.VTable = .{
            .instance = hostInstance,
            .begin_edit = hostBeginEdit,
            .set_param = hostSetParam,
            .end_edit = hostEndEdit,
            .state_changed = hostStateChanged,
        };

        fn linkUnit(ctx: *anyopaque) ?*Unit {
            const link: *ViewLink = @ptrCast(@alignCast(ctx));
            return link.instance; // null once the host closed the unit
        }

        fn hostInstance(ctx: *anyopaque) ?*P.Instance {
            const inst = linkUnit(ctx) orelse return null;
            return &inst.plugin;
        }

        // Edits go through the AudioUnit API so hosts see them: AUParameterSet calls
        // our SetParameter and notifies parameter listeners (automation, Smart
        // Controls); the gesture events mark the start and end of a drag.
        fn hostBeginEdit(ctx: *anyopaque, index: u32) void {
            const inst = linkUnit(ctx) orelse return;
            _ = AUEventListenerNotify(null, null, &.{ .event_type = 1, .parameter = inst.paramRef(index) });
        }

        fn hostSetParam(ctx: *anyopaque, index: u32, plain: f32) void {
            const inst = linkUnit(ctx) orelse return;
            _ = AUParameterSet(null, null, &inst.paramRef(index), P.params[index].clamp(plain), 0);
        }

        fn hostEndEdit(ctx: *anyopaque, index: u32) void {
            const inst = linkUnit(ctx) orelse return;
            _ = AUEventListenerNotify(null, null, &.{ .event_type = 2, .parameter = inst.paramRef(index) });
        }

        fn hostStateChanged(ctx: *anyopaque) void {
            const inst = linkUnit(ctx) orelse return;
            // Lets hosts that watch the state notice the change.
            inst.propertyChanged(prop_class_info, scope_global, 0);
        }
    };
}

test "midi queue keeps order and drops when full" {
    var q: MidiQueue = .{};
    try std.testing.expect(q.push(.{ .status = 0x90, .data1 = 60, .data2 = 100, .offset = 3 }));
    try std.testing.expect(q.push(.{ .status = 0x80, .data1 = 60, .data2 = 0, .offset = 9 }));
    try std.testing.expectEqual(@as(u32, 3), q.pop().?.offset);
    try std.testing.expectEqual(@as(u32, 9), q.pop().?.offset);
    try std.testing.expect(q.pop() == null);
    var pushed: usize = 0;
    while (q.push(.{ .status = 0x90, .data1 = 1, .data2 = 1, .offset = 0 })) pushed += 1;
    try std.testing.expectEqual(q.events.len - 1, pushed);
}
