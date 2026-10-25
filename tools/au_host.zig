//! Tiny Audio Unit host for smoke-testing MathSynth.component.
//!
//!   au-host <bundle.component> info
//!   au-host <bundle.component> render <out.wav> [formula from to]
//!   au-host <bundle.component> snapshot <out.png> [formula [from [to]]]
//!
//! The bundle is loaded and registered in-process, so it doesn't need to be
//! installed. After that the host only uses the public AudioUnit API: state
//! goes through kAudioUnitProperty_ClassInfo and the editor is created the
//! way Logic/GarageBand do it, via kAudioUnitProperty_CocoaUI.

const std = @import("std");
const objc = @import("objc");

const Id = objc.Id;
const msg = objc.msg;
const OSStatus = i32;
const AudioUnit = ?*anyopaque;
const CFTypeRef = ?*anyopaque;

const Desc = extern struct {
    componentType: u32,
    componentSubType: u32,
    componentManufacturer: u32,
    componentFlags: u32 = 0,
    componentFlagsMask: u32 = 0,
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
const AudioBuffer = extern struct { mNumberChannels: u32, mDataByteSize: u32, mData: ?*anyopaque };
const StereoBufferList = extern struct { mNumberBuffers: u32, mBuffers: [2]AudioBuffer };
const AudioTimeStamp = extern struct {
    mSampleTime: f64 = 0,
    mHostTime: u64 = 0,
    mRateScalar: f64 = 0,
    mWordClockTime: u64 = 0,
    mSMPTETime: [24]u8 = @splat(0),
    mFlags: u32 = 1, // sample time valid
    mReserved: u32 = 0,
};
const CocoaViewInfo = extern struct { bundle_location: CFTypeRef, view_class: [1]CFTypeRef };

extern fn AudioComponentRegister(desc: *const Desc, name: CFTypeRef, version: u32, factory: *const anyopaque) ?*anyopaque;
extern fn AudioComponentInstanceNew(component: ?*anyopaque, out: *AudioUnit) OSStatus;
extern fn AudioComponentInstanceDispose(unit: AudioUnit) OSStatus;
extern fn AudioUnitInitialize(unit: AudioUnit) OSStatus;
extern fn AudioUnitUninitialize(unit: AudioUnit) OSStatus;
extern fn AudioUnitGetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: *anyopaque, size: *u32) OSStatus;
extern fn AudioUnitSetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: ?*const anyopaque, size: u32) OSStatus;
extern fn AudioUnitRender(unit: AudioUnit, flags: *u32, ts: *const AudioTimeStamp, bus: u32, frames: u32, data: *StereoBufferList) OSStatus;
extern fn MusicDeviceMIDIEvent(unit: AudioUnit, status: u32, data1: u32, data2: u32, offset: u32) OSStatus;

extern fn CFRelease(cf: CFTypeRef) void;
extern fn CFStringCreateWithCString(alloc: CFTypeRef, s: [*:0]const u8, encoding: u32) CFTypeRef;
extern fn CFDictionaryGetValue(dict: CFTypeRef, key: CFTypeRef) CFTypeRef;
extern fn CFDictionaryCreateMutableCopy(alloc: CFTypeRef, capacity: isize, dict: CFTypeRef) CFTypeRef;
extern fn CFDictionarySetValue(dict: CFTypeRef, key: CFTypeRef, value: CFTypeRef) void;
extern fn CFDataGetLength(data: CFTypeRef) isize;
extern fn CFDataGetBytePtr(data: CFTypeRef) [*]const u8;
extern fn CFDataCreate(alloc: CFTypeRef, bytes: [*]const u8, len: isize) CFTypeRef;

extern fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern fn dlerror() ?[*:0]const u8;
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fwrite(ptr: *const anyopaque, size: usize, n: usize, f: ?*anyopaque) usize;
extern fn fclose(f: ?*anyopaque) c_int;

const scope_global = 0;
const scope_output = 2;
const prop_class_info = 0;
const prop_stream_format = 8;
const prop_element_count = 11;
const prop_max_frames = 14;
const prop_tail_time = 20;
const prop_cocoa_ui = 31;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn check(status: OSStatus, what: []const u8) void {
    if (status != 0) fail("{s} returned {d}", .{ what, status });
}

fn fourCC(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

fn cfStr(s: [*:0]const u8) CFTypeRef {
    return CFStringCreateWithCString(null, s, 0x08000100);
}

fn open(bundle: []const u8) AudioUnit {
    var buf: [1024]u8 = undefined;
    const ns_bundle = objc.classMsg(Id, "NSBundle", "bundleWithPath:", .{objc.nsString(bundle)});
    if (ns_bundle == null or !msg(bool, ns_bundle, "load", .{})) fail("could not load bundle {s}", .{bundle});
    const bin = std.fmt.bufPrintZ(&buf, "{s}/Contents/MacOS/MathSynth", .{bundle}) catch fail("path too long", .{});
    const handle = dlopen(bin, 2) orelse fail("dlopen: {s}", .{dlerror() orelse "?"});
    const factory = dlsym(handle, "MathSynthAUFactory") orelse fail("no MathSynthAUFactory export", .{});

    // A test subtype, so an installed copy of the plugin can't be picked instead.
    const desc: Desc = .{ .componentType = fourCC("aumu"), .componentSubType = fourCC("MSyT"), .componentManufacturer = fourCC("Mthx") };
    const component = AudioComponentRegister(&desc, cfStr("MathSynth: MathSynth (test)"), 256, factory) orelse fail("AudioComponentRegister failed", .{});
    var unit: AudioUnit = null;
    check(AudioComponentInstanceNew(component, &unit), "AudioComponentInstanceNew");

    var count: u32 = 0;
    var size: u32 = 4;
    check(AudioUnitGetProperty(unit, prop_element_count, scope_output, 0, &count, &size), "ElementCount");
    var fmt: StreamFormat = undefined;
    size = @sizeOf(StreamFormat);
    check(AudioUnitGetProperty(unit, prop_stream_format, scope_output, 0, &fmt, &size), "StreamFormat");
    var tail: f64 = 0;
    size = 8;
    check(AudioUnitGetProperty(unit, prop_tail_time, scope_global, 0, &tail, &size), "TailTime");
    std.debug.print("unit: outputs={d} format={d}Hz {d}ch flags=0x{x} tail={d}s\n", .{ count, fmt.mSampleRate, fmt.mChannelsPerFrame, fmt.mFormatFlags, tail });
    return unit;
}

/// +1 ClassInfo dictionary.
fn getClassInfo(unit: AudioUnit) CFTypeRef {
    var dict: CFTypeRef = null;
    var size: u32 = @sizeOf(CFTypeRef);
    check(AudioUnitGetProperty(unit, prop_class_info, scope_global, 0, @ptrCast(&dict), &size), "get ClassInfo");
    return dict;
}

fn printState(unit: AudioUnit) void {
    const dict = getClassInfo(unit);
    defer CFRelease(dict);
    const data = CFDictionaryGetValue(dict, cfStr("data")) orelse fail("ClassInfo has no data", .{});
    const bytes = CFDataGetBytePtr(data)[0..@intCast(CFDataGetLength(data))];
    var pos: usize = 4;
    std.debug.print("plugin state:", .{});
    for ([_][]const u8{ "formula", "from", "to" }) |label| {
        const n = bytes[pos];
        std.debug.print(" {s}=\"{s}\"", .{ label, bytes[pos + 1 ..][0..n] });
        pos += 1 + n;
    }
    std.debug.print("\n", .{});
}

/// Loads a formula the way a host restores a project: take the current
/// ClassInfo, replace its data and set it back.
fn setFormula(unit: AudioUnit, texts: [3][]const u8) void {
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..4], "MSY1");
    var n: usize = 4;
    for (texts) |t| {
        buf[n] = @intCast(t.len);
        @memcpy(buf[n + 1 ..][0..t.len], t);
        n += 1 + t.len;
    }
    const current = getClassInfo(unit);
    defer CFRelease(current);
    const dict = CFDictionaryCreateMutableCopy(null, 0, current);
    defer CFRelease(dict);
    const data = CFDataCreate(null, &buf, @intCast(n));
    defer CFRelease(data);
    CFDictionarySetValue(dict, cfStr("data"), data);
    const status = AudioUnitSetProperty(unit, prop_class_info, scope_global, 0, @ptrCast(&dict), @sizeOf(CFTypeRef));
    if (status != 0) fail("set ClassInfo rejected '{s}' ({d})", .{ texts[0], status });
}

fn render(unit: AudioUnit, path: [:0]const u8) void {
    const rate = 44100;
    const block = 512;
    var frames_per_slice: u32 = block;
    check(AudioUnitSetProperty(unit, prop_max_frames, scope_global, 0, &frames_per_slice, 4), "MaximumFramesPerSlice");
    check(AudioUnitInitialize(unit), "AudioUnitInitialize");

    const pitches = [_]u32{ 60, 64, 67, 72 };
    const note_len = rate * 4 / 10;
    const total = note_len * 6;
    const audio = std.heap.page_allocator.alloc(f32, total * 2) catch fail("oom", .{});

    var t: usize = 0;
    while (t < total) : (t += block) {
        const n: usize = @min(block, total - t);
        // Notes are scheduled with sample offsets inside the next block,
        // like a host's sequencer does.
        for (0..pitches.len + 2) |i| {
            const start = i * note_len;
            if (start < t or start >= t + n) continue;
            const off: u32 = @intCast(start - t);
            if (i > 0 and i <= pitches.len) check(MusicDeviceMIDIEvent(unit, 0x80, pitches[i - 1], 0, off), "note off");
            if (i < pitches.len) check(MusicDeviceMIDIEvent(unit, 0x90, pitches[i], 110, off), "note on");
            if (i == pitches.len) for (pitches[0..3]) |p| check(MusicDeviceMIDIEvent(unit, 0x90, p, 110, off), "chord on");
            if (i == pitches.len + 1) for (pitches[0..3]) |p| check(MusicDeviceMIDIEvent(unit, 0x90, p, 0, off), "chord off (vel 0)");
        }
        // Null mData: the unit must render into its own buffers.
        var list: StereoBufferList = .{ .mNumberBuffers = 2, .mBuffers = .{
            .{ .mNumberChannels = 1, .mDataByteSize = @intCast(n * 4), .mData = null },
            .{ .mNumberChannels = 1, .mDataByteSize = @intCast(n * 4), .mData = null },
        } };
        var flags: u32 = 0;
        const ts: AudioTimeStamp = .{ .mSampleTime = @floatFromInt(t) };
        check(AudioUnitRender(unit, &flags, &ts, 0, @intCast(n), &list), "AudioUnitRender");
        const l: [*]const f32 = @ptrCast(@alignCast(list.mBuffers[0].mData.?));
        const r: [*]const f32 = @ptrCast(@alignCast(list.mBuffers[1].mData.?));
        for (0..n) |i| {
            audio[(t + i) * 2] = l[i];
            audio[(t + i) * 2 + 1] = r[i];
        }
    }
    check(AudioUnitUninitialize(unit), "AudioUnitUninitialize");

    var peak: f32 = 0;
    var sum: f64 = 0;
    var bad: usize = 0;
    for (audio) |s| {
        if (!std.math.isFinite(s)) bad += 1;
        peak = @max(peak, @abs(s));
        sum += s * s;
    }
    var tail_peak: f32 = 0;
    for (audio[audio.len - rate / 10 * 2 ..]) |s| tail_peak = @max(tail_peak, @abs(s));
    std.debug.print("rendered {d:.2}s: peak={d:.3} rms={d:.3} non-finite={d} tail-peak={d:.5}\n", .{
        @as(f64, @floatFromInt(total)) / rate, peak, @sqrt(sum / @as(f64, @floatFromInt(audio.len))), bad, tail_peak,
    });
    writeWav(path, audio, rate);
    std.debug.print("wrote {s}\n", .{path});
}

fn writeWav(path: [:0]const u8, samples: []const f32, rate: u32) void {
    const f = fopen(path, "wb") orelse fail("cannot open {s}", .{path});
    defer _ = fclose(f);
    const data_bytes: u32 = @intCast(samples.len * 2);
    var hdr: [44]u8 = undefined;
    @memcpy(hdr[0..4], "RIFF");
    std.mem.writeInt(u32, hdr[4..8], 36 + data_bytes, .little);
    @memcpy(hdr[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, hdr[16..20], 16, .little);
    std.mem.writeInt(u16, hdr[20..22], 1, .little);
    std.mem.writeInt(u16, hdr[22..24], 2, .little);
    std.mem.writeInt(u32, hdr[24..28], rate, .little);
    std.mem.writeInt(u32, hdr[28..32], rate * 4, .little);
    std.mem.writeInt(u16, hdr[32..34], 4, .little);
    std.mem.writeInt(u16, hdr[34..36], 16, .little);
    @memcpy(hdr[36..40], "data");
    std.mem.writeInt(u32, hdr[40..44], data_bytes, .little);
    _ = fwrite(&hdr, 1, hdr.len, f);
    for (samples) |s| {
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, @intFromFloat(std.math.clamp(s, -1, 1) * 32767), .little);
        _ = fwrite(&b, 1, 2, f);
    }
}

fn snapshot(unit: AudioUnit, path: [:0]const u8, texts: []const [:0]const u8) void {
    _ = objc.classMsg(Id, "NSApplication", "sharedApplication", .{});

    var info: CocoaViewInfo = undefined;
    var size: u32 = @sizeOf(CocoaViewInfo);
    check(AudioUnitGetProperty(unit, prop_cocoa_ui, scope_global, 0, &info, &size), "CocoaUI");
    defer CFRelease(info.bundle_location);
    defer CFRelease(info.view_class[0]);

    // The same lookup Apple's sample hosts use: the class must belong to the
    // bundle and conform to AUCocoaUIBase.
    const url: Id = @ptrCast(info.bundle_location);
    const view_bundle = objc.classMsg(Id, "NSBundle", "bundleWithURL:", .{url});
    const class_name: Id = @ptrCast(info.view_class[0]);
    const factory_class = msg(objc.Class, view_bundle, "classNamed:", .{class_name}) orelse
        fail("bundle has no class {s}", .{objc.utf8(class_name)});
    const protocol = objc.getProtocol("AUCocoaUIBase") orelse fail("AUCocoaUIBase protocol not found", .{});
    if (!msg(bool, factory_class, "conformsToProtocol:", .{protocol})) fail("factory does not conform to AUCocoaUIBase", .{});
    std.debug.print("view factory: {s} in {s}\n", .{ objc.utf8(class_name), objc.utf8(msg(Id, url, "path", .{})) });

    const factory = msg(Id, objc.alloc(factory_class), "init", .{});
    const view = msg(Id, factory, "uiViewForAudioUnit:withSize:", .{ unit, objc.NSSize{ .width = 0, .height = 0 } }) orelse
        fail("uiViewForAudioUnit returned nil", .{});
    _ = msg(Id, view, "retain", .{});

    const rect = objc.NSRect.make(0, 0, 660, 480);
    const window = msg(Id, objc.alloc(objc.getClass("NSWindow")), "initWithContentRect:styleMask:backing:defer:", .{ rect, @as(usize, 1), @as(usize, 2), objc.NO });
    msg(void, window, "setReleasedWhenClosed:", .{objc.NO});
    const content = msg(Id, window, "contentView", .{});
    msg(void, content, "addSubview:", .{view});

    if (texts.len > 0) {
        // Container -> editor root -> fields.
        const root = msg(Id, msg(Id, view, "subviews", .{}), "firstObject", .{});
        const subviews = msg(Id, root, "subviews", .{});
        const text_field = objc.getClass("NSTextField");
        var field_index: usize = 0;
        for (0..msg(usize, subviews, "count", .{})) |i| {
            const v = msg(Id, subviews, "objectAtIndex:", .{i});
            if (!msg(bool, v, "isKindOfClass:", .{text_field}) or !msg(bool, v, "isEditable", .{})) continue;
            if (field_index < texts.len) msg(void, v, "setStringValue:", .{objc.nsString(texts[field_index])});
            field_index += 1;
        }
        msg(void, root, "controlTextDidChange:", .{@as(Id, null)});
    }

    const rep = msg(Id, content, "bitmapImageRepForCachingDisplayInRect:", .{rect});
    msg(void, content, "cacheDisplayInRect:toBitmapImageRep:", .{ rect, rep });
    const png = msg(Id, rep, "representationUsingType:properties:", .{ @as(usize, 4), objc.classMsg(Id, "NSDictionary", "dictionary", .{}) });
    if (!msg(bool, png, "writeToFile:atomically:", .{ objc.nsString(path), objc.YES })) fail("could not write {s}", .{path});
    std.debug.print("wrote {s}\n", .{path});

    // Close the editor like a host would: remove and release the view.
    msg(void, view, "removeFromSuperview", .{});
    objc.release(view);
    objc.release(factory);
    printState(unit);
}

pub fn main(init: std.process.Init.Minimal) void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const args = init.args.toSlice(arena_state.allocator()) catch fail("args", .{});
    if (args.len < 3) {
        fail("usage: au-host <bundle.component> info | render <out.wav> [formula from to] | snapshot <out.png> [formula [from [to]]]", .{});
    }

    const pool = objc.autoreleasePoolPush();
    const unit = open(args[1]);
    const cmd = args[2];
    if (std.mem.eql(u8, cmd, "info")) {
        printState(unit);
    } else if (std.mem.eql(u8, cmd, "render") and args.len >= 4) {
        if (args.len >= 7) setFormula(unit, .{ args[4], args[5], args[6] });
        printState(unit);
        render(unit, args[3]);
    } else if (std.mem.eql(u8, cmd, "snapshot") and args.len >= 4) {
        snapshot(unit, args[3], args[4..]);
    } else {
        fail("unknown command '{s}'", .{cmd});
    }
    // Drain views (and their editors) before the unit goes away.
    objc.autoreleasePoolPop(pool);
    check(AudioComponentInstanceDispose(unit), "AudioComponentInstanceDispose");
}
