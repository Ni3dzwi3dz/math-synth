//! Generic VST3 wrapper. `Wrapper(P)` turns a plugin type (see plugin.zig)
//! into a VST3 "single component" plugin: one object implements IComponent,
//! IAudioProcessor and IEditController, so the editor and the audio engine
//! share state directly instead of passing messages.
//!
//! A plugin's VST3 entry file exports the module entry points:
//!
//!   const W = common.vst3.Wrapper(@import("plugin.zig"));
//!   comptime { W.exportEntryPoints(); }

const std = @import("std");
const builtin = @import("builtin");
const c = @import("vst3");
const plugin = @import("plugin.zig");
const param = @import("param.zig");

const tresult = c.Steinberg_tresult;
const ok = c.Steinberg_kResultOk;
const false_result = c.Steinberg_kResultFalse;
const no_interface = c.Steinberg_kNoInterface;
const not_implemented = c.Steinberg_kNotImplemented;
const invalid_argument = c.Steinberg_kInvalidArgument;

const TUID = c.Steinberg_TUID;

const allocator = std.heap.c_allocator;

pub fn uid(words: [4]u32) TUID {
    // Non-COM byte order (macOS/Linux): each 32-bit word big-endian.
    var out: TUID = undefined;
    for (words, 0..) |word, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], word, .big);
    return out;
}

fn iidEql(iid: [*c]const u8, ref: *const TUID) bool {
    return std.mem.eql(u8, iid[0..16], ref);
}

fn copyCString(dst: []u8, src: []const u8) void {
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

fn copyString128(dst: *c.Steinberg_Vst_String128, src: []const u8) void {
    const n = @min(src.len, dst.len - 1);
    for (dst[0..n], src[0..n]) |*d, s| d.* = s;
    dst[n] = 0;
}

pub fn Wrapper(comptime P: type) type {
    comptime plugin.check(P);
    const meta = P.meta;
    const Instance = P.Instance;
    const has_editor = plugin.hasEditor(P);
    const Host = plugin.EditorHost(Instance);

    return struct {
        const class_id = uid(meta.vst3.class_id);

        /// Exports GetPluginFactory, bundleEntry and bundleExit. Call from a
        /// `comptime` block in the plugin's VST3 root file.
        pub fn exportEntryPoints() void {
            @export(&getPluginFactory, .{ .name = "GetPluginFactory" });
            @export(&bundleEntry, .{ .name = "bundleEntry" });
            @export(&bundleExit, .{ .name = "bundleExit" });
        }

        fn getPluginFactory() callconv(.c) ?*anyopaque {
            return &factory;
        }
        // macOS bundle entry points, required by the VST3 module spec.
        fn bundleEntry(_: ?*anyopaque) callconv(.c) bool {
            return true;
        }
        fn bundleExit() callconv(.c) bool {
            return true;
        }

        // Plugin factory --------------------------------------------------------

        var factory_vtbl: c.struct_Steinberg_IPluginFactory2Vtbl = .{
            .queryInterface = factoryQueryInterface,
            .addRef = staticRef,
            .release = staticRef,
            .getFactoryInfo = getFactoryInfo,
            .countClasses = countClasses,
            .getClassInfo = getClassInfo,
            .createInstance = createInstance,
            .getClassInfo2 = getClassInfo2,
        };
        var factory: c.struct_Steinberg_IPluginFactory2 = .{ .lpVtbl = &factory_vtbl };

        fn factoryQueryInterface(this: ?*anyopaque, iid: [*c]const u8, obj: [*c]?*anyopaque) callconv(.c) tresult {
            if (iidEql(iid, &c.Steinberg_FUnknown_iid) or
                iidEql(iid, &c.Steinberg_IPluginFactory_iid) or
                iidEql(iid, &c.Steinberg_IPluginFactory2_iid))
            {
                obj.* = this;
                return ok;
            }
            obj.* = null;
            return no_interface;
        }

        // The factory is a static object; reference counting is a no-op.
        fn staticRef(_: ?*anyopaque) callconv(.c) u32 {
            return 1;
        }

        fn getFactoryInfo(_: ?*anyopaque, info: [*c]c.struct_Steinberg_PFactoryInfo) callconv(.c) tresult {
            info.* = .{};
            copyCString(info.*.vendor[0..], meta.vendor);
            copyCString(info.*.url[0..], "");
            copyCString(info.*.email[0..], "");
            info.*.flags = c.Steinberg_PFactoryInfo_FactoryFlags_kNoFlags;
            return ok;
        }

        fn countClasses(_: ?*anyopaque) callconv(.c) i32 {
            return 1;
        }

        fn getClassInfo(_: ?*anyopaque, index: i32, info: [*c]c.struct_Steinberg_PClassInfo) callconv(.c) tresult {
            if (index != 0) return invalid_argument;
            info.* = .{ .cid = class_id, .cardinality = c.Steinberg_PClassInfo_ClassCardinality_kManyInstances };
            copyCString(info.*.category[0..], "Audio Module Class");
            copyCString(info.*.name[0..], meta.name);
            return ok;
        }

        fn getClassInfo2(_: ?*anyopaque, index: i32, info: [*c]c.struct_Steinberg_PClassInfo2) callconv(.c) tresult {
            if (index != 0) return invalid_argument;
            info.* = .{ .cid = class_id, .cardinality = c.Steinberg_PClassInfo_ClassCardinality_kManyInstances };
            copyCString(info.*.category[0..], "Audio Module Class");
            copyCString(info.*.name[0..], meta.name);
            copyCString(info.*.subCategories[0..], meta.vst3.subcategories);
            copyCString(info.*.vendor[0..], meta.vendor);
            copyCString(info.*.version[0..], meta.version);
            copyCString(info.*.sdkVersion[0..], "VST 3.7.14");
            return ok;
        }

        fn createInstance(_: ?*anyopaque, cid: c.Steinberg_FIDString, iid: c.Steinberg_FIDString, obj: [*c]?*anyopaque) callconv(.c) tresult {
            obj.* = null;
            if (!iidEql(@ptrCast(cid), &class_id)) return no_interface;
            const p = Plugin.create() catch return false_result;
            // queryInterface adds a reference; drop the one from create().
            const result = p.queryInterface(@ptrCast(iid), obj);
            _ = p.release();
            return result;
        }

        // The plugin object ---------------------------------------------------

        const Plugin = struct {
            component: c.struct_Steinberg_Vst_IComponent = .{ .lpVtbl = &component_vtbl },
            processor: c.struct_Steinberg_Vst_IAudioProcessor = .{ .lpVtbl = &processor_vtbl },
            controller: c.struct_Steinberg_Vst_IEditController = .{ .lpVtbl = &controller_vtbl },

            ref_count: std.atomic.Value(u32) = .init(1),
            /// Hosts may call initialize() through both IComponent and
            /// IEditController on a single-component plugin.
            init_count: u32 = 0,

            instance: Instance = undefined,
            sample_rate: f64 = 44100,

            handler: ?*c.struct_Steinberg_Vst_IComponentHandler = null,
            editor: if (has_editor) ?*P.Editor else void = if (has_editor) null else {},

            fn create() !*Plugin {
                const p = try allocator.create(Plugin);
                p.* = .{};
                p.instance.init();
                return p;
            }

            fn addRef(p: *Plugin) u32 {
                return p.ref_count.fetchAdd(1, .monotonic) + 1;
            }

            fn release(p: *Plugin) u32 {
                const n = p.ref_count.fetchSub(1, .acq_rel) - 1;
                if (n == 0) {
                    p.setHandler(null);
                    allocator.destroy(p);
                }
                return n;
            }

            fn queryInterface(p: *Plugin, iid: [*c]const u8, obj: [*c]?*anyopaque) tresult {
                const iface: ?*anyopaque = if (iidEql(iid, &c.Steinberg_FUnknown_iid) or
                    iidEql(iid, &c.Steinberg_IPluginBase_iid) or
                    iidEql(iid, &c.Steinberg_Vst_IComponent_iid))
                    &p.component
                else if (iidEql(iid, &c.Steinberg_Vst_IAudioProcessor_iid))
                    &p.processor
                else if (iidEql(iid, &c.Steinberg_Vst_IEditController_iid))
                    &p.controller
                else
                    null;
                obj.* = iface;
                if (iface == null) return no_interface;
                _ = p.addRef();
                return ok;
            }

            fn setHandler(p: *Plugin, handler: ?*c.struct_Steinberg_Vst_IComponentHandler) void {
                if (handler) |h| _ = h.lpVtbl.*.addRef.?(h);
                if (p.handler) |h| _ = h.lpVtbl.*.release.?(h);
                p.handler = handler;
            }

            fn fromIface(comptime field: []const u8, this: ?*anyopaque) *Plugin {
                const iface: *@FieldType(Plugin, field) = @ptrCast(@alignCast(this.?));
                return @fieldParentPtr(field, iface);
            }

            /// Automation and host-side edits arrive as parameter changes in
            /// process(). Only the last point of each queue is used.
            fn readParameterChanges(p: *Plugin, changes: *c.struct_Steinberg_Vst_IParameterChanges) void {
                const n = changes.lpVtbl.*.getParameterCount.?(changes);
                var i: i32 = 0;
                while (i < n) : (i += 1) {
                    const queue = changes.lpVtbl.*.getParameterData.?(changes, i) orelse continue;
                    const id = queue.*.lpVtbl.*.getParameterId.?(queue);
                    if (id >= P.params.len) continue;
                    const points = queue.*.lpVtbl.*.getPointCount.?(queue);
                    if (points <= 0) continue;
                    var offset: i32 = 0;
                    var value: f64 = 0;
                    if (queue.*.lpVtbl.*.getPoint.?(queue, points - 1, &offset, &value) != ok) continue;
                    p.instance.setParam(id, P.params[id].fromNormalized(value));
                }
            }

            /// Tells the host the project has unsaved changes.
            fn markDirty(p: *Plugin) void {
                const h = p.handler orelse return;
                var h2: ?*anyopaque = null;
                if (h.lpVtbl.*.queryInterface.?(h, &c.Steinberg_Vst_IComponentHandler2_iid, &h2) != ok) return;
                const handler2: *c.struct_Steinberg_Vst_IComponentHandler2 = @ptrCast(@alignCast(h2.?));
                _ = handler2.lpVtbl.*.setDirty.?(handler2, 1);
                _ = handler2.lpVtbl.*.release.?(handler2);
            }

            fn process(p: *Plugin, data: *c.struct_Steinberg_Vst_ProcessData) void {
                const frames: usize = @intCast(@max(data.numSamples, 0));
                if (data.inputParameterChanges) |changes| p.readParameterChanges(changes);

                var channels: []const [*]f32 = &.{};
                if (data.numOutputs > 0 and data.outputs != null and data.outputs[0].numChannels > 0) {
                    const bus = &data.outputs[0];
                    const bufs = bus.unnamed_0.Steinberg_Vst_AudioBusBuffers_channelBuffers32;
                    if (bufs != null) channels = @ptrCast(bufs[0..@intCast(bus.numChannels)]);
                    bus.silenceFlags = 0;
                }

                var pos: usize = 0;
                if (data.inputEvents) |events| {
                    const count = events.*.lpVtbl.*.getEventCount.?(events);
                    var i: i32 = 0;
                    while (i < count) : (i += 1) {
                        var e: c.struct_Steinberg_Vst_Event = .{};
                        if (events.*.lpVtbl.*.getEvent.?(events, i, &e) != ok) continue;
                        const at: usize = @min(@as(usize, @intCast(@max(e.sampleOffset, 0))), frames);
                        if (at > pos) {
                            p.instance.render(channels, pos, at);
                            pos = at;
                        }
                        switch (e.type) {
                            c.Steinberg_Vst_Event_EventTypes_kNoteOnEvent => {
                                const on = e.unnamed_0.Steinberg_Vst_Event_noteOn;
                                // A note-on with zero velocity is a note-off by MIDI convention.
                                if (on.velocity <= 0) {
                                    p.instance.noteOff(on.pitch, on.noteId);
                                } else {
                                    p.instance.noteOn(on.pitch, on.tuning, on.velocity, on.noteId);
                                }
                            },
                            c.Steinberg_Vst_Event_EventTypes_kNoteOffEvent => {
                                const off = e.unnamed_0.Steinberg_Vst_Event_noteOff;
                                p.instance.noteOff(off.pitch, off.noteId);
                            },
                            else => {},
                        }
                    }
                }
                p.instance.render(channels, pos, frames);
            }

            // Editor host: edits go straight into the shared instance (single
            // component) and are reported to the host so it can record
            // automation.
            const host_vtable: Host.VTable = .{
                .instance = hostInstance,
                .begin_edit = hostBeginEdit,
                .set_param = hostSetParam,
                .end_edit = hostEndEdit,
                .state_changed = hostStateChanged,
            };

            fn editorHost(p: *Plugin) Host {
                return .{ .ctx = p, .vtable = &host_vtable };
            }

            fn fromCtx(ctx: *anyopaque) *Plugin {
                return @ptrCast(@alignCast(ctx));
            }
            fn hostInstance(ctx: *anyopaque) ?*Instance {
                return &fromCtx(ctx).instance;
            }
            fn hostBeginEdit(ctx: *anyopaque, index: u32) void {
                const p = fromCtx(ctx);
                if (p.handler) |h| _ = h.lpVtbl.*.beginEdit.?(h, index);
            }
            fn hostSetParam(ctx: *anyopaque, index: u32, plain: f32) void {
                const p = fromCtx(ctx);
                p.instance.setParam(index, plain);
                const normalized = P.params[index].toNormalized(p.instance.getParam(index));
                if (p.handler) |h| _ = h.lpVtbl.*.performEdit.?(h, index, normalized);
            }
            fn hostEndEdit(ctx: *anyopaque, index: u32) void {
                const p = fromCtx(ctx);
                if (p.handler) |h| _ = h.lpVtbl.*.endEdit.?(h, index);
            }
            fn hostStateChanged(ctx: *anyopaque) void {
                fromCtx(ctx).markDirty();
            }
        };

        fn writeState(stream: [*c]c.struct_Steinberg_IBStream, p: *Plugin) tresult {
            var buf: [Instance.max_state_len]u8 = undefined;
            const data = p.instance.saveState(&buf);
            var written: i32 = 0;
            const r = stream.*.lpVtbl.*.write.?(stream, @constCast(data.ptr), @intCast(data.len), &written);
            return if (r == ok and written == data.len) ok else false_result;
        }

        fn readState(stream: [*c]c.struct_Steinberg_IBStream, buf: []u8) []const u8 {
            var total: usize = 0;
            while (total < buf.len) {
                var got: i32 = 0;
                const r = stream.*.lpVtbl.*.read.?(stream, &buf[total], @intCast(buf.len - total), &got);
                if (r != ok or got <= 0) break;
                total += @intCast(got);
            }
            return buf[0..total];
        }

        // IComponent ----------------------------------------------------------

        var component_vtbl: c.struct_Steinberg_Vst_IComponentVtbl = .{
            .queryInterface = componentQueryInterface,
            .addRef = componentAddRef,
            .release = componentRelease,
            .initialize = initialize,
            .terminate = terminate,
            .getControllerClassId = getControllerClassId,
            .setIoMode = setIoMode,
            .getBusCount = getBusCount,
            .getBusInfo = getBusInfo,
            .getRoutingInfo = getRoutingInfo,
            .activateBus = activateBus,
            .setActive = setActive,
            .setState = componentSetState,
            .getState = componentGetState,
        };

        fn componentQueryInterface(this: ?*anyopaque, iid: [*c]const u8, obj: [*c]?*anyopaque) callconv(.c) tresult {
            return Plugin.fromIface("component", this).queryInterface(iid, obj);
        }
        fn componentAddRef(this: ?*anyopaque) callconv(.c) u32 {
            return Plugin.fromIface("component", this).addRef();
        }
        fn componentRelease(this: ?*anyopaque) callconv(.c) u32 {
            return Plugin.fromIface("component", this).release();
        }

        fn initialize(this: ?*anyopaque, _: [*c]c.struct_Steinberg_FUnknown) callconv(.c) tresult {
            Plugin.fromIface("component", this).init_count += 1;
            return ok;
        }

        fn terminate(this: ?*anyopaque) callconv(.c) tresult {
            const p = Plugin.fromIface("component", this);
            if (p.init_count > 0) p.init_count -= 1;
            if (p.init_count == 0) p.setHandler(null);
            return ok;
        }

        fn getControllerClassId(_: ?*anyopaque, _: [*c]u8) callconv(.c) tresult {
            // Single component: the host finds IEditController via queryInterface.
            return not_implemented;
        }

        fn setIoMode(_: ?*anyopaque, _: c.Steinberg_Vst_IoMode) callconv(.c) tresult {
            return ok;
        }

        fn getBusCount(_: ?*anyopaque, media: c.Steinberg_Vst_MediaType, dir: c.Steinberg_Vst_BusDirection) callconv(.c) i32 {
            if (media == c.Steinberg_Vst_MediaTypes_kAudio and dir == c.Steinberg_Vst_BusDirections_kOutput) return 1;
            if (media == c.Steinberg_Vst_MediaTypes_kEvent and dir == c.Steinberg_Vst_BusDirections_kInput) return 1;
            return 0;
        }

        fn getBusInfo(this: ?*anyopaque, media: c.Steinberg_Vst_MediaType, dir: c.Steinberg_Vst_BusDirection, index: i32, bus: [*c]c.struct_Steinberg_Vst_BusInfo) callconv(.c) tresult {
            if (index != 0 or getBusCount(this, media, dir) == 0) return invalid_argument;
            bus.* = .{
                .mediaType = media,
                .direction = dir,
                .channelCount = if (media == c.Steinberg_Vst_MediaTypes_kAudio) 2 else 1,
                .busType = c.Steinberg_Vst_BusTypes_kMain,
                .flags = c.Steinberg_Vst_BusInfo_BusFlags_kDefaultActive,
            };
            copyString128(&bus.*.name, if (media == c.Steinberg_Vst_MediaTypes_kAudio) "Output" else "MIDI In");
            return ok;
        }

        fn getRoutingInfo(_: ?*anyopaque, _: [*c]c.struct_Steinberg_Vst_RoutingInfo, _: [*c]c.struct_Steinberg_Vst_RoutingInfo) callconv(.c) tresult {
            return not_implemented;
        }

        fn activateBus(_: ?*anyopaque, _: c.Steinberg_Vst_MediaType, _: c.Steinberg_Vst_BusDirection, _: i32, _: c.Steinberg_TBool) callconv(.c) tresult {
            return ok;
        }

        fn setActive(this: ?*anyopaque, state: c.Steinberg_TBool) callconv(.c) tresult {
            if (state == 0) Plugin.fromIface("component", this).instance.reset();
            return ok;
        }

        fn componentSetState(this: ?*anyopaque, stream: [*c]c.struct_Steinberg_IBStream) callconv(.c) tresult {
            if (stream == null) return invalid_argument;
            const p = Plugin.fromIface("component", this);
            var buf: [Instance.max_state_len + 64]u8 = undefined;
            if (!p.instance.loadState(readState(stream, &buf))) return false_result;
            // VST3 calls setState on the UI thread, so the editor can be
            // updated here.
            if (has_editor) {
                if (p.editor) |e| e.stateLoaded();
            }
            return ok;
        }

        fn componentGetState(this: ?*anyopaque, stream: [*c]c.struct_Steinberg_IBStream) callconv(.c) tresult {
            if (stream == null) return invalid_argument;
            return writeState(stream, Plugin.fromIface("component", this));
        }

        // IAudioProcessor -----------------------------------------------------

        var processor_vtbl: c.struct_Steinberg_Vst_IAudioProcessorVtbl = .{
            .queryInterface = processorQueryInterface,
            .addRef = processorAddRef,
            .release = processorRelease,
            .setBusArrangements = setBusArrangements,
            .getBusArrangement = getBusArrangement,
            .canProcessSampleSize = canProcessSampleSize,
            .getLatencySamples = getLatencySamples,
            .setupProcessing = setupProcessing,
            .setProcessing = setProcessing,
            .process = processAudio,
            .getTailSamples = getTailSamples,
        };

        fn processorQueryInterface(this: ?*anyopaque, iid: [*c]const u8, obj: [*c]?*anyopaque) callconv(.c) tresult {
            return Plugin.fromIface("processor", this).queryInterface(iid, obj);
        }
        fn processorAddRef(this: ?*anyopaque) callconv(.c) u32 {
            return Plugin.fromIface("processor", this).addRef();
        }
        fn processorRelease(this: ?*anyopaque) callconv(.c) u32 {
            return Plugin.fromIface("processor", this).release();
        }

        fn setBusArrangements(_: ?*anyopaque, _: [*c]c.Steinberg_Vst_SpeakerArrangement, num_ins: i32, outputs: [*c]c.Steinberg_Vst_SpeakerArrangement, num_outs: i32) callconv(.c) tresult {
            if (num_ins != 0 or num_outs != 1) return false_result;
            const arr = outputs[0];
            if (arr == c.Steinberg_Vst_SpeakerArr_kStereo or arr == c.Steinberg_Vst_SpeakerArr_kMono) return ok;
            return false_result;
        }

        fn getBusArrangement(_: ?*anyopaque, dir: c.Steinberg_Vst_BusDirection, index: i32, arr: [*c]c.Steinberg_Vst_SpeakerArrangement) callconv(.c) tresult {
            if (dir != c.Steinberg_Vst_BusDirections_kOutput or index != 0) return invalid_argument;
            arr.* = c.Steinberg_Vst_SpeakerArr_kStereo;
            return ok;
        }

        fn canProcessSampleSize(_: ?*anyopaque, size: i32) callconv(.c) tresult {
            return if (size == c.Steinberg_Vst_SymbolicSampleSizes_kSample32) ok else false_result;
        }

        fn getLatencySamples(_: ?*anyopaque) callconv(.c) u32 {
            return 0;
        }

        fn setupProcessing(this: ?*anyopaque, setup: [*c]c.struct_Steinberg_Vst_ProcessSetup) callconv(.c) tresult {
            if (setup == null or setup.*.sampleRate <= 0) return invalid_argument;
            if (setup.*.symbolicSampleSize != c.Steinberg_Vst_SymbolicSampleSizes_kSample32) return false_result;
            const p = Plugin.fromIface("processor", this);
            p.sample_rate = setup.*.sampleRate;
            p.instance.setSampleRate(setup.*.sampleRate);
            return ok;
        }

        fn setProcessing(this: ?*anyopaque, state: c.Steinberg_TBool) callconv(.c) tresult {
            if (state == 0) Plugin.fromIface("processor", this).instance.allNotesOff();
            return ok;
        }

        fn processAudio(this: ?*anyopaque, data: [*c]c.struct_Steinberg_Vst_ProcessData) callconv(.c) tresult {
            if (data == null) return invalid_argument;
            if (data.*.symbolicSampleSize != c.Steinberg_Vst_SymbolicSampleSizes_kSample32) return false_result;
            Plugin.fromIface("processor", this).process(data);
            return ok;
        }

        fn getTailSamples(this: ?*anyopaque) callconv(.c) u32 {
            const p = Plugin.fromIface("processor", this);
            return @intFromFloat(@ceil(p.sample_rate * p.instance.tailSeconds()) + 64);
        }

        // IEditController -----------------------------------------------------

        var controller_vtbl: c.struct_Steinberg_Vst_IEditControllerVtbl = .{
            .queryInterface = controllerQueryInterface,
            .addRef = controllerAddRef,
            .release = controllerRelease,
            .initialize = controllerInitialize,
            .terminate = controllerTerminate,
            .setComponentState = controllerSetComponentState,
            .setState = controllerSetState,
            .getState = controllerGetState,
            .getParameterCount = getParameterCount,
            .getParameterInfo = getParameterInfo,
            .getParamStringByValue = getParamStringByValue,
            .getParamValueByString = getParamValueByString,
            .normalizedParamToPlain = normalizedParamToPlain,
            .plainParamToNormalized = plainParamToNormalized,
            .getParamNormalized = getParamNormalized,
            .setParamNormalized = setParamNormalized,
            .setComponentHandler = setComponentHandler,
            .createView = createView,
        };

        fn controllerQueryInterface(this: ?*anyopaque, iid: [*c]const u8, obj: [*c]?*anyopaque) callconv(.c) tresult {
            return Plugin.fromIface("controller", this).queryInterface(iid, obj);
        }
        fn controllerAddRef(this: ?*anyopaque) callconv(.c) u32 {
            return Plugin.fromIface("controller", this).addRef();
        }
        fn controllerRelease(this: ?*anyopaque) callconv(.c) u32 {
            return Plugin.fromIface("controller", this).release();
        }
        fn controllerInitialize(this: ?*anyopaque, context: [*c]c.struct_Steinberg_FUnknown) callconv(.c) tresult {
            return initialize(&Plugin.fromIface("controller", this).component, context);
        }
        fn controllerTerminate(this: ?*anyopaque) callconv(.c) tresult {
            return terminate(&Plugin.fromIface("controller", this).component);
        }

        // The component state already holds everything; there is no
        // separate controller state.
        fn controllerSetComponentState(_: ?*anyopaque, _: [*c]c.struct_Steinberg_IBStream) callconv(.c) tresult {
            return ok;
        }
        fn controllerSetState(_: ?*anyopaque, _: [*c]c.struct_Steinberg_IBStream) callconv(.c) tresult {
            return ok;
        }
        fn controllerGetState(_: ?*anyopaque, _: [*c]c.struct_Steinberg_IBStream) callconv(.c) tresult {
            return ok;
        }

        fn paramInfo(id: c.Steinberg_Vst_ParamID) ?param.Info {
            return if (id < P.params.len) P.params[id] else null;
        }

        fn getParameterCount(_: ?*anyopaque) callconv(.c) i32 {
            return P.params.len;
        }

        fn getParameterInfo(_: ?*anyopaque, index: i32, out: [*c]c.struct_Steinberg_Vst_ParameterInfo) callconv(.c) tresult {
            if (index < 0 or out == null) return invalid_argument;
            const i = paramInfo(@intCast(index)) orelse return invalid_argument;
            out.* = .{
                .id = @intCast(index),
                .stepCount = @intCast(i.steps()),
                .defaultNormalizedValue = i.toNormalized(i.default),
                .unitId = c.Steinberg_Vst_kRootUnitId,
                .flags = c.Steinberg_Vst_ParameterInfo_ParameterFlags_kCanAutomate |
                    (if (i.unit == .list) c.Steinberg_Vst_ParameterInfo_ParameterFlags_kIsList else 0),
            };
            copyString128(&out.*.title, i.name);
            copyString128(&out.*.shortTitle, i.short_name);
            copyString128(&out.*.units, i.unitLabel());
            return ok;
        }

        fn getParamStringByValue(_: ?*anyopaque, id: c.Steinberg_Vst_ParamID, normalized: c.Steinberg_Vst_ParamValue, out: [*c]c.Steinberg_Vst_TChar) callconv(.c) tresult {
            const i = paramInfo(id) orelse return invalid_argument;
            if (out == null) return invalid_argument;
            var buf: [32]u8 = undefined;
            copyString128(@ptrCast(out), i.format(&buf, i.fromNormalized(normalized)));
            return ok;
        }

        fn getParamValueByString(_: ?*anyopaque, id: c.Steinberg_Vst_ParamID, text: [*c]c.Steinberg_Vst_TChar, out: [*c]c.Steinberg_Vst_ParamValue) callconv(.c) tresult {
            const i = paramInfo(id) orelse return invalid_argument;
            if (text == null or out == null) return invalid_argument;
            // UTF-16 to ASCII; anything else can't be a value anyway.
            var buf: [64]u8 = undefined;
            var n: usize = 0;
            while (n < buf.len and text[n] != 0) : (n += 1) {
                const ch: u16 = @bitCast(text[n]);
                buf[n] = if (ch < 128) @intCast(ch) else '?';
            }
            const plain = i.parse(buf[0..n]) orelse return false_result;
            out.* = i.toNormalized(plain);
            return ok;
        }

        fn normalizedParamToPlain(_: ?*anyopaque, id: c.Steinberg_Vst_ParamID, v: c.Steinberg_Vst_ParamValue) callconv(.c) c.Steinberg_Vst_ParamValue {
            const i = paramInfo(id) orelse return v;
            return i.fromNormalized(v);
        }

        fn plainParamToNormalized(_: ?*anyopaque, id: c.Steinberg_Vst_ParamID, v: c.Steinberg_Vst_ParamValue) callconv(.c) c.Steinberg_Vst_ParamValue {
            const i = paramInfo(id) orelse return v;
            return i.toNormalized(@floatCast(v));
        }

        fn getParamNormalized(this: ?*anyopaque, id: c.Steinberg_Vst_ParamID) callconv(.c) c.Steinberg_Vst_ParamValue {
            const i = paramInfo(id) orelse return 0;
            return i.toNormalized(Plugin.fromIface("controller", this).instance.getParam(id));
        }

        fn setParamNormalized(this: ?*anyopaque, id: c.Steinberg_Vst_ParamID, v: c.Steinberg_Vst_ParamValue) callconv(.c) tresult {
            const i = paramInfo(id) orelse return invalid_argument;
            // Editors are expected to poll parameter values, so they follow
            // this too.
            Plugin.fromIface("controller", this).instance.setParam(id, i.fromNormalized(v));
            return ok;
        }

        fn setComponentHandler(this: ?*anyopaque, handler: [*c]c.struct_Steinberg_Vst_IComponentHandler) callconv(.c) tresult {
            Plugin.fromIface("controller", this).setHandler(handler);
            return ok;
        }

        fn createView(this: ?*anyopaque, view_name: c.Steinberg_FIDString) callconv(.c) [*c]c.struct_Steinberg_IPlugView {
            if (!has_editor or builtin.os.tag != .macos) return null;
            if (view_name == null or !std.mem.eql(u8, std.mem.span(view_name), "editor")) return null;
            const view = View.create(Plugin.fromIface("controller", this)) catch return null;
            return &view.iface;
        }

        // IPlugView -----------------------------------------------------------

        const View = struct {
            iface: c.struct_Steinberg_IPlugView = .{ .lpVtbl = &view_vtbl },
            ref_count: std.atomic.Value(u32) = .init(1),
            plugin: *Plugin,

            fn create(p: *Plugin) !*View {
                const v = try allocator.create(View);
                _ = p.addRef();
                v.* = .{ .plugin = p };
                return v;
            }

            fn from(this: ?*anyopaque) *View {
                const iface: *c.struct_Steinberg_IPlugView = @ptrCast(@alignCast(this.?));
                return @fieldParentPtr("iface", iface);
            }

            fn detach(v: *View) void {
                if (!has_editor) return;
                if (v.plugin.editor) |e| {
                    e.destroy(allocator);
                    v.plugin.editor = null;
                }
            }
        };

        var view_vtbl: c.struct_Steinberg_IPlugViewVtbl = .{
            .queryInterface = viewQueryInterface,
            .addRef = viewAddRef,
            .release = viewRelease,
            .isPlatformTypeSupported = isPlatformTypeSupported,
            .attached = viewAttached,
            .removed = viewRemoved,
            .onWheel = viewOnWheel,
            .onKeyDown = viewOnKey,
            .onKeyUp = viewOnKey,
            .getSize = viewGetSize,
            .onSize = viewOnSize,
            .onFocus = viewOnFocus,
            .setFrame = viewSetFrame,
            .canResize = viewCanResize,
            .checkSizeConstraint = viewCheckSizeConstraint,
        };

        const editor_width = if (has_editor) P.Editor.view_width else 0;
        const editor_height = if (has_editor) P.Editor.view_height else 0;

        fn viewQueryInterface(this: ?*anyopaque, iid: [*c]const u8, obj: [*c]?*anyopaque) callconv(.c) tresult {
            if (iidEql(iid, &c.Steinberg_FUnknown_iid) or iidEql(iid, &c.Steinberg_IPlugView_iid)) {
                obj.* = this;
                _ = viewAddRef(this);
                return ok;
            }
            obj.* = null;
            return no_interface;
        }
        fn viewAddRef(this: ?*anyopaque) callconv(.c) u32 {
            return View.from(this).ref_count.fetchAdd(1, .monotonic) + 1;
        }
        fn viewRelease(this: ?*anyopaque) callconv(.c) u32 {
            const v = View.from(this);
            const n = v.ref_count.fetchSub(1, .acq_rel) - 1;
            if (n == 0) {
                v.detach();
                _ = v.plugin.release();
                allocator.destroy(v);
            }
            return n;
        }

        fn isPlatformTypeSupported(_: ?*anyopaque, platform: c.Steinberg_FIDString) callconv(.c) tresult {
            if (platform != null and std.mem.eql(u8, std.mem.span(platform), "NSView")) return ok;
            return false_result;
        }

        fn viewAttached(this: ?*anyopaque, parent: ?*anyopaque, platform: c.Steinberg_FIDString) callconv(.c) tresult {
            if (!has_editor) return false_result;
            if (parent == null or isPlatformTypeSupported(this, platform) != ok) return false_result;
            const v = View.from(this);
            v.detach();
            const p = v.plugin;
            p.editor = P.Editor.create(allocator, parent, p.editorHost()) catch return false_result;
            return ok;
        }

        fn viewRemoved(this: ?*anyopaque) callconv(.c) tresult {
            View.from(this).detach();
            return ok;
        }

        fn viewOnWheel(_: ?*anyopaque, _: f32) callconv(.c) tresult {
            return false_result;
        }
        fn viewOnKey(_: ?*anyopaque, _: c.Steinberg_char16, _: i16, _: i16) callconv(.c) tresult {
            // Not handled: lets text fields receive keys through Cocoa.
            return false_result;
        }
        fn viewGetSize(_: ?*anyopaque, size: [*c]c.struct_Steinberg_ViewRect) callconv(.c) tresult {
            if (size == null) return invalid_argument;
            size.* = .{ .left = 0, .top = 0, .right = editor_width, .bottom = editor_height };
            return ok;
        }
        fn viewOnSize(_: ?*anyopaque, _: [*c]c.struct_Steinberg_ViewRect) callconv(.c) tresult {
            return ok;
        }
        fn viewOnFocus(_: ?*anyopaque, _: c.Steinberg_TBool) callconv(.c) tresult {
            return ok;
        }
        fn viewSetFrame(_: ?*anyopaque, _: [*c]c.struct_Steinberg_IPlugFrame) callconv(.c) tresult {
            return ok;
        }
        fn viewCanResize(_: ?*anyopaque) callconv(.c) tresult {
            return false_result;
        }
        fn viewCheckSizeConstraint(_: ?*anyopaque, rect: [*c]c.struct_Steinberg_ViewRect) callconv(.c) tresult {
            if (rect == null) return invalid_argument;
            rect.* = .{ .left = rect.*.left, .top = rect.*.top, .right = rect.*.left + editor_width, .bottom = rect.*.top + editor_height };
            return ok;
        }
    };
}
