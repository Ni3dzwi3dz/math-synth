//! Tiny VST3 host for smoke-testing MathSynth without a DAW.
//!
//!   vst3-host <bundle.vst3> info
//!   vst3-host <bundle.vst3> render <out.wav> [formula from to]
//!   vst3-host <bundle.vst3> snapshot <out.png> [formula [from [to]]]
//!   vst3-host <bundle.vst3> gui
//!
//! `render` loads the formula through IComponent::setState and plays a short
//! arpeggio. `snapshot` opens the editor off-screen, optionally types into its
//! fields like a user would, saves a PNG and prints the resulting plugin state.

const std = @import("std");
const c = @import("vst3");
const objc = @import("objc");

const tresult = c.Steinberg_tresult;
const ok = c.Steinberg_kResultOk;

extern fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern fn dlerror() ?[*:0]const u8;
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fwrite(ptr: *const anyopaque, size: usize, n: usize, f: ?*anyopaque) usize;
extern fn fclose(f: ?*anyopaque) c_int;

const RTLD_NOW = 2;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn check(r: tresult, what: []const u8) void {
    if (r != ok) fail("{s} returned {d}", .{ what, r });
}

fn vt(obj: anytype) @TypeOf(obj.*.lpVtbl.*) {
    return obj.*.lpVtbl.*;
}

fn query(comptime T: type, obj: anytype, iid: *const c.Steinberg_TUID) ?*T {
    var out: ?*anyopaque = null;
    if (vt(obj).queryInterface.?(obj, iid, &out) != ok) return null;
    return @ptrCast(@alignCast(out));
}

// Host-side COM objects --------------------------------------------------------

/// Growable in-memory IBStream.
const MemStream = struct {
    iface: c.struct_Steinberg_IBStream = .{ .lpVtbl = &vtbl },
    buf: [4096]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,

    var vtbl: c.struct_Steinberg_IBStreamVtbl = .{
        .queryInterface = noQuery,
        .addRef = staticRef,
        .release = staticRef,
        .read = read,
        .write = write,
        .seek = seek,
        .tell = tell,
    };

    fn from(this: ?*anyopaque) *MemStream {
        return @fieldParentPtr("iface", @as(*c.struct_Steinberg_IBStream, @ptrCast(@alignCast(this.?))));
    }
    fn read(this: ?*anyopaque, buffer: ?*anyopaque, n: i32, got: [*c]i32) callconv(.c) tresult {
        const s = from(this);
        const k = @min(@as(usize, @intCast(n)), s.len - s.pos);
        @memcpy(@as([*]u8, @ptrCast(buffer.?))[0..k], s.buf[s.pos..][0..k]);
        s.pos += k;
        if (got != null) got.* = @intCast(k);
        return ok;
    }
    fn write(this: ?*anyopaque, buffer: ?*anyopaque, n: i32, put: [*c]i32) callconv(.c) tresult {
        const s = from(this);
        const k = @min(@as(usize, @intCast(n)), s.buf.len - s.pos);
        @memcpy(s.buf[s.pos..][0..k], @as([*]const u8, @ptrCast(buffer.?))[0..k]);
        s.pos += k;
        s.len = @max(s.len, s.pos);
        if (put != null) put.* = @intCast(k);
        return ok;
    }
    fn seek(this: ?*anyopaque, pos: i64, mode: i32, result: [*c]i64) callconv(.c) tresult {
        const s = from(this);
        const base: i64 = switch (mode) {
            0 => 0,
            1 => @intCast(s.pos),
            else => @intCast(s.len),
        };
        s.pos = @intCast(std.math.clamp(base + pos, 0, @as(i64, @intCast(s.len))));
        if (result != null) result.* = @intCast(s.pos);
        return ok;
    }
    fn tell(this: ?*anyopaque, pos: [*c]i64) callconv(.c) tresult {
        pos.* = @intCast(from(this).pos);
        return ok;
    }
};

const EventList = struct {
    iface: c.struct_Steinberg_Vst_IEventList = .{ .lpVtbl = &vtbl },
    events: [64]c.struct_Steinberg_Vst_Event = undefined,
    count: usize = 0,

    var vtbl: c.struct_Steinberg_Vst_IEventListVtbl = .{
        .queryInterface = noQuery,
        .addRef = staticRef,
        .release = staticRef,
        .getEventCount = getEventCount,
        .getEvent = getEvent,
        .addEvent = addEvent,
    };

    fn from(this: ?*anyopaque) *EventList {
        return @fieldParentPtr("iface", @as(*c.struct_Steinberg_Vst_IEventList, @ptrCast(@alignCast(this.?))));
    }
    fn getEventCount(this: ?*anyopaque) callconv(.c) i32 {
        return @intCast(from(this).count);
    }
    fn getEvent(this: ?*anyopaque, index: i32, e: [*c]c.struct_Steinberg_Vst_Event) callconv(.c) tresult {
        const l = from(this);
        if (index < 0 or index >= l.count) return c.Steinberg_kInvalidArgument;
        e.* = l.events[@intCast(index)];
        return ok;
    }
    fn addEvent(this: ?*anyopaque, e: [*c]c.struct_Steinberg_Vst_Event) callconv(.c) tresult {
        const l = from(this);
        l.events[l.count] = e.*;
        l.count += 1;
        return ok;
    }

    fn note(l: *EventList, on: bool, offset: i32, pitch: i16) void {
        var e: c.struct_Steinberg_Vst_Event = .{ .sampleOffset = offset };
        if (on) {
            e.type = c.Steinberg_Vst_Event_EventTypes_kNoteOnEvent;
            e.unnamed_0.Steinberg_Vst_Event_noteOn = .{ .pitch = pitch, .velocity = 0.9, .noteId = -1 };
        } else {
            e.type = c.Steinberg_Vst_Event_EventTypes_kNoteOffEvent;
            e.unnamed_0.Steinberg_Vst_Event_noteOff = .{ .pitch = pitch, .velocity = 0, .noteId = -1 };
        }
        _ = addEvent(&l.iface, &e);
    }
};

fn noQuery(_: ?*anyopaque, _: [*c]const u8, obj: [*c]?*anyopaque) callconv(.c) tresult {
    obj.* = null;
    return c.Steinberg_kNoInterface;
}
fn staticRef(_: ?*anyopaque) callconv(.c) u32 {
    return 1;
}

// Loading ----------------------------------------------------------------------

const Instance = struct {
    component: *c.struct_Steinberg_Vst_IComponent,
    processor: *c.struct_Steinberg_Vst_IAudioProcessor,
    controller: *c.struct_Steinberg_Vst_IEditController,
};

fn load(bundle: []const u8) Instance {
    var path_buf: [1024]u8 = undefined;
    const stem = std.fs.path.stem(std.mem.trimEnd(u8, bundle, "/"));
    const bin = std.fmt.bufPrintZ(&path_buf, "{s}/Contents/MacOS/{s}", .{ bundle, stem }) catch fail("path too long", .{});
    const handle = dlopen(bin, RTLD_NOW) orelse fail("dlopen {s}: {s}", .{ bin, dlerror() orelse "?" });

    const entry: *const fn (?*anyopaque) callconv(.c) bool = @ptrCast(@alignCast(dlsym(handle, "bundleEntry") orelse fail("no bundleEntry", .{})));
    if (!entry(null)) fail("bundleEntry failed", .{});
    const get_factory: *const fn () callconv(.c) ?*c.struct_Steinberg_IPluginFactory = @ptrCast(@alignCast(dlsym(handle, "GetPluginFactory") orelse fail("no GetPluginFactory", .{})));
    const factory = get_factory() orelse fail("GetPluginFactory returned null", .{});

    var finfo: c.struct_Steinberg_PFactoryInfo = .{};
    check(vt(factory).getFactoryInfo.?(factory, &finfo), "getFactoryInfo");
    const count = vt(factory).countClasses.?(factory);
    std.debug.print("factory: vendor={s} classes={d}\n", .{ std.mem.sliceTo(&finfo.vendor, 0), count });

    const factory2 = query(c.struct_Steinberg_IPluginFactory2, factory, &c.Steinberg_IPluginFactory2_iid) orelse fail("no IPluginFactory2", .{});
    var info: c.struct_Steinberg_PClassInfo2 = .{};
    check(vt(factory2).getClassInfo2.?(factory2, 0, &info), "getClassInfo2");
    std.debug.print("class 0: name={s} category={s} sub={s} version={s}\n", .{
        std.mem.sliceTo(&info.name, 0),          std.mem.sliceTo(&info.category, 0),
        std.mem.sliceTo(&info.subCategories, 0), std.mem.sliceTo(&info.version, 0),
    });

    var obj: ?*anyopaque = null;
    check(vt(factory).createInstance.?(factory, @ptrCast(&info.cid), @ptrCast(&c.Steinberg_Vst_IComponent_iid), &obj), "createInstance");
    const component: *c.struct_Steinberg_Vst_IComponent = @ptrCast(@alignCast(obj.?));
    check(vt(component).initialize.?(component, null), "IComponent::initialize");

    const processor = query(c.struct_Steinberg_Vst_IAudioProcessor, component, &c.Steinberg_Vst_IAudioProcessor_iid) orelse fail("no IAudioProcessor", .{});
    const controller = query(c.struct_Steinberg_Vst_IEditController, component, &c.Steinberg_Vst_IEditController_iid) orelse fail("no IEditController (single component expected)", .{});
    std.debug.print("buses: audio out={d} event in={d}\n", .{
        vt(component).getBusCount.?(component, c.Steinberg_Vst_MediaTypes_kAudio, c.Steinberg_Vst_BusDirections_kOutput),
        vt(component).getBusCount.?(component, c.Steinberg_Vst_MediaTypes_kEvent, c.Steinberg_Vst_BusDirections_kInput),
    });
    return .{ .component = component, .processor = processor, .controller = controller };
}

fn printState(inst: Instance) void {
    var s: MemStream = .{};
    check(vt(inst.component).getState.?(inst.component, &s.iface), "getState");
    // MSY1 + three length-prefixed strings.
    var pos: usize = 4;
    const labels = [_][]const u8{ "formula", "from", "to" };
    std.debug.print("plugin state:", .{});
    for (labels) |label| {
        const n = s.buf[pos];
        std.debug.print(" {s}=\"{s}\"", .{ label, s.buf[pos + 1 ..][0..n] });
        pos += 1 + n;
    }
    std.debug.print("\n", .{});
}

fn setFormula(inst: Instance, formula: []const u8, from: []const u8, to: []const u8) void {
    var s: MemStream = .{};
    _ = MemStream.write(&s.iface, @constCast("MSY1"), 4, null);
    for ([_][]const u8{ formula, from, to }) |text| {
        var n: u8 = @intCast(text.len);
        _ = MemStream.write(&s.iface, &n, 1, null);
        _ = MemStream.write(&s.iface, @constCast(text.ptr), @intCast(text.len), null);
    }
    s.pos = 0;
    const r = vt(inst.component).setState.?(inst.component, &s.iface);
    if (r != ok) fail("setState rejected formula '{s}' (result {d})", .{ formula, r });
}

// Commands ---------------------------------------------------------------------

fn render(inst: Instance, path: [:0]const u8) void {
    const rate = 44100;
    const block = 512;
    var setup: c.struct_Steinberg_Vst_ProcessSetup = .{
        .processMode = c.Steinberg_Vst_ProcessModes_kOffline,
        .symbolicSampleSize = c.Steinberg_Vst_SymbolicSampleSizes_kSample32,
        .maxSamplesPerBlock = block,
        .sampleRate = rate,
    };
    check(vt(inst.processor).setupProcessing.?(inst.processor, &setup), "setupProcessing");
    check(vt(inst.component).setActive.?(inst.component, 1), "setActive");
    check(vt(inst.processor).setProcessing.?(inst.processor, 1), "setProcessing");

    // C4, E4, G4, C5: 0.4 s each, then a 0.4 s chord, then release.
    const pitches = [_]i16{ 60, 64, 67, 72 };
    const note_len = rate * 4 / 10;
    const total = note_len * 6;
    const audio = std.heap.page_allocator.alloc(f32, total * 2) catch fail("oom", .{});

    var left: [block]f32 = undefined;
    var right: [block]f32 = undefined;
    var chans = [_][*c]f32{ &left, &right };
    var out_bus: c.struct_Steinberg_Vst_AudioBusBuffers = .{ .numChannels = 2 };
    out_bus.unnamed_0.Steinberg_Vst_AudioBusBuffers_channelBuffers32 = &chans;

    var t: usize = 0;
    while (t < total) : (t += block) {
        const n = @min(block, total - t);
        var events: EventList = .{};
        for (0..pitches.len + 1) |i| {
            const start = i * note_len;
            if (start >= t and start < t + n) {
                if (i < pitches.len) {
                    if (i > 0) events.note(false, @intCast(start - t), pitches[i - 1]);
                    events.note(true, @intCast(start - t), pitches[i]);
                } else {
                    events.note(false, @intCast(start - t), pitches[i - 1]);
                    for (pitches[0..3]) |p| events.note(true, @intCast(start - t), p);
                }
            }
        }
        const chord_end = (pitches.len + 1) * note_len;
        if (chord_end >= t and chord_end < t + n) {
            for (pitches[0..3]) |p| events.note(false, @intCast(chord_end - t), p);
        }

        var data: c.struct_Steinberg_Vst_ProcessData = .{
            .processMode = setup.processMode,
            .symbolicSampleSize = setup.symbolicSampleSize,
            .numSamples = @intCast(n),
            .numOutputs = 1,
            .outputs = &out_bus,
            .inputEvents = &events.iface,
        };
        check(vt(inst.processor).process.?(inst.processor, &data), "process");
        for (0..n) |i| {
            audio[(t + i) * 2] = left[i];
            audio[(t + i) * 2 + 1] = right[i];
        }
    }
    _ = vt(inst.processor).setProcessing.?(inst.processor, 0);
    _ = vt(inst.component).setActive.?(inst.component, 0);

    var peak: f32 = 0;
    var sum: f64 = 0;
    var bad: usize = 0;
    for (audio) |s| {
        if (!std.math.isFinite(s)) bad += 1;
        peak = @max(peak, @abs(s));
        sum += s * s;
    }
    const tail_peak = blk: {
        var p: f32 = 0;
        for (audio[audio.len - rate / 10 * 2 ..]) |s| p = @max(p, @abs(s));
        break :blk p;
    };
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
    std.mem.writeInt(u16, hdr[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, hdr[22..24], 2, .little);
    std.mem.writeInt(u32, hdr[24..28], rate, .little);
    std.mem.writeInt(u32, hdr[28..32], rate * 4, .little);
    std.mem.writeInt(u16, hdr[32..34], 4, .little);
    std.mem.writeInt(u16, hdr[34..36], 16, .little);
    @memcpy(hdr[36..40], "data");
    std.mem.writeInt(u32, hdr[40..44], data_bytes, .little);
    _ = fwrite(&hdr, 1, hdr.len, f);
    for (samples) |s| {
        const v: i16 = @intFromFloat(std.math.clamp(s, -1, 1) * 32767);
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, v, .little);
        _ = fwrite(&b, 1, 2, f);
    }
}

const Id = objc.Id;
const msg = objc.msg;

fn openEditor(inst: Instance, visible: bool) struct { window: Id, content: Id, view: *c.struct_Steinberg_IPlugView, rect: objc.NSRect } {
    const app = objc.classMsg(Id, "NSApplication", "sharedApplication", .{});
    msg(void, app, "setActivationPolicy:", .{@as(isize, if (visible) 0 else 2)});

    const view = vt(inst.controller).createView.?(inst.controller, "editor") orelse fail("createView returned null", .{});
    if (vt(view).isPlatformTypeSupported.?(view, "NSView") != ok) fail("NSView not supported", .{});
    var size: c.struct_Steinberg_ViewRect = .{};
    check(vt(view).getSize.?(view, &size), "getSize");
    const rect = objc.NSRect.make(200, 200, @floatFromInt(size.right - size.left), @floatFromInt(size.bottom - size.top));

    const style: usize = 1 | 2; // titled | closable
    const window = msg(Id, objc.alloc(objc.getClass("NSWindow")), "initWithContentRect:styleMask:backing:defer:", .{ rect, style, @as(usize, 2), objc.NO });
    msg(void, window, "setTitle:", .{objc.nsString("MathSynth (vst3-host)")});
    msg(void, window, "setReleasedWhenClosed:", .{objc.NO});
    const content = msg(Id, window, "contentView", .{});
    check(vt(view).attached.?(view, content, "NSView"), "IPlugView::attached");
    return .{ .window = window, .content = content, .view = view, .rect = objc.NSRect.make(0, 0, rect.size.width, rect.size.height) };
}

/// Types into the editor's text fields (formula, from, to in order) and
/// fires the same delegate callback Cocoa sends on each keystroke.
fn typeIntoEditor(content: Id, texts: []const [:0]const u8) void {
    const root = msg(Id, msg(Id, content, "subviews", .{}), "firstObject", .{});
    const subviews = msg(Id, root, "subviews", .{});
    const n = msg(usize, subviews, "count", .{});
    const text_field = objc.getClass("NSTextField");
    var field_index: usize = 0;
    for (0..n) |i| {
        const v = msg(Id, subviews, "objectAtIndex:", .{i});
        if (!msg(bool, v, "isKindOfClass:", .{text_field}) or !msg(bool, v, "isEditable", .{})) continue;
        if (field_index < texts.len) {
            msg(void, v, "setStringValue:", .{objc.nsString(texts[field_index])});
        }
        field_index += 1;
    }
    msg(void, root, "controlTextDidChange:", .{@as(Id, null)});
}

fn snapshot(inst: Instance, path: [:0]const u8, texts: []const [:0]const u8) void {
    const ed = openEditor(inst, false);
    if (texts.len > 0) typeIntoEditor(ed.content, texts);

    const rep = msg(Id, ed.content, "bitmapImageRepForCachingDisplayInRect:", .{ed.rect});
    msg(void, ed.content, "cacheDisplayInRect:toBitmapImageRep:", .{ ed.rect, rep });
    const NSBitmapImageFileTypePNG: usize = 4;
    const props = objc.classMsg(Id, "NSDictionary", "dictionary", .{});
    const png = msg(Id, rep, "representationUsingType:properties:", .{ NSBitmapImageFileTypePNG, props });
    if (!msg(bool, png, "writeToFile:atomically:", .{ objc.nsString(path), objc.YES })) fail("could not write {s}", .{path});
    std.debug.print("wrote {s}\n", .{path});

    check(vt(ed.view).removed.?(ed.view), "IPlugView::removed");
    _ = vt(ed.view).release.?(ed.view);
    printState(inst);
}

fn gui(inst: Instance) void {
    const ed = openEditor(inst, true);
    const app = objc.classMsg(Id, "NSApplication", "sharedApplication", .{});
    msg(void, ed.window, "center", .{});
    msg(void, ed.window, "makeKeyAndOrderFront:", .{@as(Id, null)});
    msg(void, app, "activateIgnoringOtherApps:", .{objc.YES});
    std.debug.print("editor open; close the app with Cmd-Q or Ctrl-C (no audio in this mode)\n", .{});
    msg(void, app, "run", .{});
}

pub fn main(init: std.process.Init.Minimal) void {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const args = init.args.toSlice(arena_state.allocator()) catch fail("args", .{});
    if (args.len < 3) {
        fail("usage: vst3-host <bundle.vst3> info | render <out.wav> [formula from to] | snapshot <out.png> [formula [from [to]]] | gui", .{});
    }
    const inst = load(args[1]);
    const cmd = args[2];
    if (std.mem.eql(u8, cmd, "info")) {
        printState(inst);
    } else if (std.mem.eql(u8, cmd, "render") and args.len >= 4) {
        if (args.len >= 7) setFormula(inst, args[4], args[5], args[6]);
        printState(inst);
        render(inst, args[3]);
    } else if (std.mem.eql(u8, cmd, "snapshot") and args.len >= 4) {
        snapshot(inst, args[3], args[4..]);
    } else if (std.mem.eql(u8, cmd, "gui")) {
        gui(inst);
    } else {
        fail("unknown command '{s}'", .{cmd});
    }

    _ = vt(inst.controller).release.?(inst.controller);
    _ = vt(inst.processor).release.?(inst.processor);
    check(vt(inst.component).terminate.?(inst.component), "terminate");
    _ = vt(inst.component).release.?(inst.component);
}
