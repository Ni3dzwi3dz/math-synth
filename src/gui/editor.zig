//! Native Cocoa editor: two formula + range inputs with live validation, a
//! mix slider, a waveform preview, an interactive ADSR envelope and a gain
//! knob.
//! Everything here runs on the host's UI (main) thread.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const wt = @import("../wavetable.zig");
const params = @import("../params.zig");
const graph = @import("envelope_graph.zig");

const Id = objc.Id;
const NSRect = objc.NSRect;
const CGFloat = objc.CGFloat;

pub const width = 660;
pub const height = 720;

const wave_count = 2;
/// Settings for both waves.
pub const Waves = [wave_count]wt.Settings;

const margin = 20;
/// Top of each wave's row: formula, from and to side by side, with the
/// error caret underneath.
const wave_row_y = [wave_count]CGFloat{ 52, 98 };
const status_y = 146;
const mix_y = 190;
const slider_rect = NSRect.make(104, mix_y, 390, 22);
const wave_rect = NSRect.make(margin, 226, width - 2 * margin, 176);
const section_y = 434;
const env_rect = NSRect.make(margin, 458, 470, 150);
const knob_rect = NSRect.make(522, 458, 100, 100);
const env_fields_y = 616;

const accent = [3]CGFloat{ 0.36, 0.78, 1.0 };
/// Line colours of the two source waves; the mix is drawn in `accent`.
const wave_colors = [wave_count][3]CGFloat{ .{ 0.98, 0.66, 0.35 }, .{ 0.80, 0.58, 1.0 } };
const wave_names = [wave_count][]const u8{ "f\u{2081}", "f\u{2082}" };

const NSTextAlignmentRight: isize = if (builtin.cpu.arch == .x86_64) 1 else 2;

/// What the editor needs from the plugin.
pub const Model = struct {
    ctx: *anyopaque,
    /// Called with one wave's settings once they pass validation, and the
    /// table built from them.
    apply: *const fn (ctx: *anyopaque, wave: usize, settings: *const wt.Settings, table: *const wt.Table) void,
    /// Current parameter value in plain units.
    get_param: *const fn (ctx: *anyopaque, id: params.Id) f32,
    /// A user edit of one parameter: `begin_edit`, any number of
    /// `set_param`, then `end_edit` (hosts record this as one automation
    /// gesture).
    begin_edit: *const fn (ctx: *anyopaque, id: params.Id) void,
    set_param: *const fn (ctx: *anyopaque, id: params.Id, plain: f32) void,
    end_edit: *const fn (ctx: *anyopaque, id: params.Id) void,
};

const Classes = struct { root: objc.Class, wave: objc.Class, envelope: objc.Class, knob: objc.Class, slider: objc.Class };
var classes: ?Classes = null;

pub const Editor = struct {
    model: Model,
    root: Id = null,
    /// Formula, from and to of each wave, indexed by wt.Field.
    fields: [wave_count][3]Id = @splat(@splat(null)),
    carets: [wave_count]Id = @splat(null),
    statuses: [wave_count]Id = @splat(null),
    wave: Id = null,
    /// Last valid table of each wave, for the plot.
    tables: [wave_count]wt.Table = @splat(@splat(0)),
    has_table: [wave_count]bool = @splat(false),
    valid: [wave_count]bool = @splat(false),
    slider_view: Id = null,
    slider_dragging: bool = false,

    env_view: Id = null,
    knob_view: Id = null,
    param_fields: [params.count]Id = @splat(null),
    /// Values currently shown, so the refresh timer only redraws on change.
    shown: [params.count]f32 = @splat(std.math.nan(f32)),
    timer: Id = null,
    env_drag: ?struct { handle: graph.Handle, dx: CGFloat, dy: CGFloat } = null,
    /// Visible envelope time span; refitted except while dragging.
    env_span: f64 = 1000,
    knob_drag: ?struct { start_y: CGFloat, start: f64 } = null,

    pub fn create(allocator: std.mem.Allocator, parent: Id, model: Model, settings: *const Waves) !*Editor {
        const cls = registerClasses() orelse return error.ObjcClassRegistration;
        const self = try allocator.create(Editor);
        self.* = .{ .model = model };

        const pool = objc.autoreleasePoolPush();
        defer objc.autoreleasePoolPop(pool);

        const root = msg(Id, objc.alloc(cls.root), "initWithFrame:", .{NSRect.make(0, 0, width, height)});
        objc.setUserdata(root, self);
        self.root = root;
        // Layer-backed so the editor also shows up when a host displays it
        // remotely (out-of-process plugins).
        msg(void, root, "setWantsLayer:", .{objc.YES});
        const dark = objc.classMsg(Id, "NSAppearance", "appearanceNamed:", .{NSAppearanceNameDarkAqua});
        msg(void, root, "setAppearance:", .{dark});

        _ = self.label("MathSynth", NSRect.make(margin, 14, 200, 28), boldFont(20), labelColor());
        _ = self.label("formula wavetable synth", NSRect.make(136, 22, 300, 18), systemFont(12), secondaryColor());

        for (0..wave_count) |w| {
            const y = wave_row_y[w];
            var buf: [32]u8 = undefined;
            const color = objc.color(wave_colors[w][0], wave_colors[w][1], wave_colors[w][2], 1);
            _ = self.label(std.fmt.bufPrint(&buf, "{s}(x) =", .{wave_names[w]}) catch "", NSRect.make(margin, y + 3, 64, 20), monoFont(14), color);
            const placeholder = if (w == 0) "e.g. sin(x) + 0.3sin(3x)" else "e.g. sign(sin(x))";
            self.fields[w][@intFromEnum(wt.Field.formula)] = self.input(NSRect.make(84, y, 330, 26), monoFont(14), placeholder, fieldId(&buf, "formula", w));
            self.carets[w] = self.label("", NSRect.make(87, y + 27, 327, 16), monoFont(14), redColor());

            // The x range that is played as one period of this wave.
            _ = self.label("from", NSRect.make(424, y + 4, 40, 20), systemFont(12), secondaryColor());
            self.fields[w][@intFromEnum(wt.Field.from)] = self.input(NSRect.make(458, y + 1, 72, 24), monoFont(13), "0", fieldId(&buf, "from", w));
            _ = self.label("to", NSRect.make(540, y + 4, 20, 20), systemFont(12), secondaryColor());
            self.fields[w][@intFromEnum(wt.Field.to)] = self.input(NSRect.make(560, y + 1, 80, 24), monoFont(13), "2*pi", fieldId(&buf, "to", w));

            self.statuses[w] = self.label("", NSRect.make(margin, status_y + @as(CGFloat, @floatFromInt(w)) * 18, width - 2 * margin, 18), systemFont(12), labelColor());
        }

        // Mix slider: f1 on the left, f2 on the right.
        _ = self.label("Mix", NSRect.make(margin, mix_y + 2, 40, 18), boldFont(13), labelColor());
        _ = self.label(wave_names[0], NSRect.make(slider_rect.origin.x - 20, mix_y + 2, 18, 18), monoFont(13), objc.color(wave_colors[0][0], wave_colors[0][1], wave_colors[0][2], 1));
        _ = self.label(wave_names[1], NSRect.make(slider_rect.origin.x + slider_rect.size.width + 4, mix_y + 2, 18, 18), monoFont(13), objc.color(wave_colors[1][0], wave_colors[1][1], wave_colors[1][2], 1));
        self.slider_view = self.customView(cls.slider, slider_rect);
        msg(void, self.slider_view, "setToolTip:", .{objc.nsString("Drag to blend the two waves. Double-click to reset to f\u{2081} only.")});
        const mix_field_x = slider_rect.origin.x + slider_rect.size.width + 30;
        self.param_fields[@intFromEnum(params.Id.mix)] = self.input(NSRect.make(mix_field_x, mix_y, 52, 22), monoFont(12), "", "mix");
        msg(void, self.param_fields[@intFromEnum(params.Id.mix)], "setAlignment:", .{NSTextAlignmentRight});
        _ = self.label("%", NSRect.make(mix_field_x + 56, mix_y + 3, 20, 16), systemFont(11), secondaryColor());

        const wave = msg(Id, objc.alloc(cls.wave), "initWithFrame:", .{wave_rect});
        objc.setUserdata(wave, self);
        msg(void, root, "addSubview:", .{wave});
        objc.release(wave);
        self.wave = wave;

        // Axis ends and the legend under the plot.
        const axis_y = wave_rect.origin.y + wave_rect.size.height + 4;
        _ = self.label("0", NSRect.make(margin, axis_y, 100, 16), monoFont(11), secondaryColor());
        const period_label = self.label("1 period", NSRect.make(width - margin - 100, axis_y, 100, 16), monoFont(11), secondaryColor());
        msg(void, period_label, "setAlignment:", .{NSTextAlignmentRight});
        const legend = [_]struct { []const u8, [3]CGFloat }{
            .{ "\u{2014} f\u{2081}", wave_colors[0] },
            .{ "\u{2014} f\u{2082}", wave_colors[1] },
            .{ "\u{2014} mix (what plays)", accent },
        };
        var lx: CGFloat = width / 2 - 120;
        for (legend) |item| {
            _ = self.label(item[0], NSRect.make(lx, axis_y, 140, 16), systemFont(11), objc.color(item[1][0], item[1][1], item[1][2], 1));
            lx += if (item[0].len < 12) 52 else 140;
        }

        // Envelope and gain -----------------------------------------------
        _ = self.label("Envelope", NSRect.make(margin, section_y, 200, 18), boldFont(13), labelColor());
        _ = self.label("drag the points", NSRect.make(margin + 72, section_y + 2, 200, 16), systemFont(11), secondaryColor());
        _ = self.label("Gain", NSRect.make(knob_rect.origin.x, section_y, 100, 18), boldFont(13), labelColor());

        self.env_view = self.customView(cls.envelope, env_rect);
        msg(void, self.env_view, "setToolTip:", .{objc.nsString("Drag a point to shape the envelope. Double-click a point to reset it.")});
        self.knob_view = self.customView(cls.knob, knob_rect);
        msg(void, self.knob_view, "setToolTip:", .{objc.nsString("Drag up or down (Shift for fine steps), scroll, or double-click to reset.")});

        const env_ids = [_]params.Id{ .attack, .decay, .sustain, .release };
        for (env_ids, 0..) |id, i| {
            const x = margin + @as(CGFloat, @floatFromInt(i)) * 120;
            const info = params.info(id);
            _ = self.label(info.name, NSRect.make(x, env_fields_y, 110, 16), systemFont(11), secondaryColor());
            self.param_fields[@intFromEnum(id)] = self.input(NSRect.make(x, env_fields_y + 17, 76, 22), monoFont(12), "", info.name);
            _ = self.label(info.unitLabel(), NSRect.make(x + 80, env_fields_y + 20, 30, 16), systemFont(11), secondaryColor());
        }
        const gain_x = knob_rect.origin.x + 6;
        const gain_y = knob_rect.origin.y + knob_rect.size.height + 6;
        self.param_fields[@intFromEnum(params.Id.gain)] = self.input(NSRect.make(gain_x, gain_y, 62, 22), monoFont(12), "", "gain");
        msg(void, self.param_fields[@intFromEnum(params.Id.gain)], "setAlignment:", .{NSTextAlignmentRight});
        _ = self.label("dB", NSRect.make(gain_x + 66, gain_y + 3, 30, 16), systemFont(11), secondaryColor());

        const help = objc.classMsg(Id, "NSTextField", "wrappingLabelWithString:", .{objc.nsString(
            "Functions: sin cos tan asin acos atan sinh cosh tanh exp ln log log2 sqrt cbrt abs floor ceil " ++
                "round trunc frac sign atan2 pow min max mod clamp   Constants: pi tau e   " ++
                "Operators: + - * / % ^ (and implicit multiplication, e.g. 2x)",
        )});
        self.place(help, NSRect.make(margin, height - 50, width - 2 * margin, 40), systemFont(11), secondaryColor());

        msg(void, parent, "addSubview:", .{root});
        self.load(settings);

        // Follows automation and host-side changes. Common modes keep it
        // running while the user drags.
        const timer = objc.classMsg(Id, "NSTimer", "timerWithTimeInterval:target:selector:userInfo:repeats:", .{
            @as(f64, 1.0 / 20.0), root, objc.sel("refreshTick:"), @as(Id, null), objc.YES,
        });
        msg(void, objc.classMsg(Id, "NSRunLoop", "currentRunLoop", .{}), "addTimer:forMode:", .{ timer, NSRunLoopCommonModes });
        self.timer = timer;
        return self;
    }

    pub fn destroy(self: *Editor, allocator: std.mem.Allocator) void {
        // The timer retains the root view; stop it first.
        msg(void, self.timer, "invalidate", .{});
        objc.setUserdata(self.root, null);
        objc.setUserdata(self.wave, null);
        objc.setUserdata(self.env_view, null);
        objc.setUserdata(self.knob_view, null);
        objc.setUserdata(self.slider_view, null);
        for (self.fields) |row| for (row) |f| msg(void, f, "setDelegate:", .{@as(Id, null)});
        for (self.param_fields) |f| msg(void, f, "setDelegate:", .{@as(Id, null)});
        msg(void, self.root, "removeFromSuperview", .{});
        objc.release(self.root);
        allocator.destroy(self);
    }

    /// Shows `waves` in the fields (e.g. after the host loaded a preset)
    /// without pushing them back to the plugin.
    pub fn load(self: *Editor, waves: *const Waves) void {
        const pool = objc.autoreleasePoolPush();
        defer objc.autoreleasePoolPop(pool);
        for (waves, 0..) |*settings, w| {
            for (std.enums.values(wt.Field)) |field| {
                msg(void, self.fields[w][@intFromEnum(field)], "setStringValue:", .{objc.nsString(settings.get(field))});
            }
            self.revalidate(w, settings, false);
        }
        self.refresh();
    }

    /// The wave whose formula or range field is `field`.
    fn waveForField(self: *const Editor, field: Id) ?usize {
        for (self.fields, 0..) |row, w| {
            for (row) |f| if (f == field) return w;
        }
        return null;
    }

    fn onTextChanged(self: *Editor, wave: usize) void {
        var settings: wt.Settings = .{};
        for (std.enums.values(wt.Field)) |field| {
            const value = msg(Id, self.fields[wave][@intFromEnum(field)], "stringValue", .{});
            settings.set(field, objc.utf8(value));
        }
        self.revalidate(wave, &settings, true);
    }

    fn revalidate(self: *Editor, w: usize, settings: *const wt.Settings, notify: bool) void {
        var buf: [512]u8 = undefined;
        const name = wave_names[w];
        switch (wt.build(settings, &self.tables[w])) {
            .ok => |info| {
                self.valid[w] = true;
                self.has_table[w] = true;
                var a: [32]u8 = undefined;
                var b: [32]u8 = undefined;
                var c: [32]u8 = undefined;
                var d: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "\u{2713} {s}: one period is x \u{2208} [{s}, {s})  \u{00B7}  raw range [{s}, {s}], normalised for playback", .{
                    name, fmtNum(&a, info.from), fmtNum(&b, info.to), fmtNum(&c, info.raw_min), fmtNum(&d, info.raw_max),
                }) catch buf[0..0];
                setText(self.statuses[w], text, greenColor());
                setText(self.carets[w], "", null);
                if (notify) self.model.apply(self.model.ctx, w, settings, &self.tables[w]);
            },
            .err => |problem| {
                self.valid[w] = false;
                const field_name = switch (problem.field) {
                    .formula => "formula",
                    .from => "from",
                    .to => "to",
                };
                const text = std.fmt.bufPrint(&buf, "\u{2717} {s} {s}: {s}", .{ name, field_name, problem.diag.message() }) catch buf[0..0];
                setText(self.statuses[w], text, redColor());
                const marker = if (problem.field == .formula)
                    caretMarker(&buf, settings.get(.formula), problem.diag.pos, problem.diag.len)
                else
                    "";
                setText(self.carets[w], marker, null);
            },
        }
        msg(void, self.wave, "setNeedsDisplay:", .{objc.YES});
    }

    // Parameters ---------------------------------------------------------------

    fn param(self: *const Editor, id: params.Id) f32 {
        return self.model.get_param(self.model.ctx, id);
    }

    fn envValues(self: *const Editor) graph.Values {
        return .{
            .attack_ms = self.param(.attack),
            .decay_ms = self.param(.decay),
            .sustain_pct = self.param(.sustain),
            .release_ms = self.param(.release),
        };
    }

    fn setParam(self: *Editor, id: params.Id, plain: f32) void {
        self.model.set_param(self.model.ctx, id, plain);
    }

    /// A complete one-shot edit (typed value, double-click reset, scroll).
    fn editParam(self: *Editor, id: params.Id, plain: f32) void {
        self.model.begin_edit(self.model.ctx, id);
        self.setParam(id, plain);
        self.model.end_edit(self.model.ctx, id);
    }

    /// Brings knob, graph and fields in line with the current values.
    fn refresh(self: *Editor) void {
        const pool = objc.autoreleasePoolPush();
        defer objc.autoreleasePoolPop(pool);
        var env_changed = false;
        for (std.enums.values(params.Id)) |id| {
            const i = @intFromEnum(id);
            const v = self.param(id);
            if (v == self.shown[i]) continue;
            self.shown[i] = v;
            switch (id) {
                .gain => msg(void, self.knob_view, "setNeedsDisplay:", .{objc.YES}),
                .mix => {
                    msg(void, self.slider_view, "setNeedsDisplay:", .{objc.YES});
                    msg(void, self.wave, "setNeedsDisplay:", .{objc.YES});
                },
                else => env_changed = true,
            }
            const field = self.param_fields[i];
            // Don't overwrite what the user is typing.
            if (msg(Id, field, "currentEditor", .{}) == null) {
                var buf: [32]u8 = undefined;
                msg(void, field, "setStringValue:", .{objc.nsString(params.info(id).format(&buf, v))});
            }
        }
        if (env_changed) {
            if (self.env_drag == null) self.env_span = graph.Layout.fitSpan(self.envValues());
            msg(void, self.env_view, "setNeedsDisplay:", .{objc.YES});
        }
    }

    fn paramForField(self: *const Editor, field: Id) ?params.Id {
        for (std.enums.values(params.Id)) |id| {
            if (self.param_fields[@intFromEnum(id)] == field) return id;
        }
        return null;
    }

    /// The user finished typing into a parameter field (Return, Tab or
    /// clicking elsewhere): apply it, or put the current value back if it
    /// doesn't parse.
    fn onFieldCommitted(self: *Editor, id: params.Id) void {
        const field = self.param_fields[@intFromEnum(id)];
        if (params.info(id).parse(objc.utf8(msg(Id, field, "stringValue", .{})))) |v| self.editParam(id, v);
        self.shown[@intFromEnum(id)] = std.math.nan(f32); // force the field to be rewritten
        self.refresh();
    }

    // Envelope view --------------------------------------------------------------

    fn envLayout(self: *const Editor) graph.Layout {
        return graph.Layout.init(env_rect.size.width, env_rect.size.height, self.env_span);
    }

    fn envMouseDown(self: *Editor, p: objc.NSPoint, clicks: isize) void {
        const values = self.envValues();
        const h = self.envLayout().hit(values, .{ .x = p.x, .y = p.y }, 12) orelse return;
        if (clicks >= 2) {
            for (graph.affected(h)) |id| self.editParam(id, params.info(id).default);
            self.refresh();
            return;
        }
        const q = self.envLayout().handlePoint(values, h);
        self.env_drag = .{ .handle = h, .dx = q.x - p.x, .dy = q.y - p.y };
        for (graph.affected(h)) |id| self.model.begin_edit(self.model.ctx, id);
        msg(void, self.env_view, "setNeedsDisplay:", .{objc.YES});
    }

    fn envMouseDragged(self: *Editor, p: objc.NSPoint) void {
        const d = self.env_drag orelse return;
        const values = self.envValues();
        const next = self.envLayout().drag(values, d.handle, .{ .x = p.x + d.dx, .y = p.y + d.dy });
        for (graph.affected(d.handle)) |id| {
            const v = switch (id) {
                .attack => next.attack_ms,
                .decay => next.decay_ms,
                .sustain => next.sustain_pct,
                .release => next.release_ms,
                .gain, .mix => unreachable,
            };
            self.setParam(id, v);
        }
        self.refresh();
    }

    fn envMouseUp(self: *Editor) void {
        const d = self.env_drag orelse return;
        for (graph.affected(d.handle)) |id| self.model.end_edit(self.model.ctx, id);
        self.env_drag = null;
        self.env_span = graph.Layout.fitSpan(self.envValues());
        msg(void, self.env_view, "setNeedsDisplay:", .{objc.YES});
    }

    fn drawEnvelope(self: *Editor) void {
        const ctx = objc.currentCGContext();
        const w = env_rect.size.width;
        const h = env_rect.size.height;
        const l = self.envLayout();
        const values = self.envValues();
        const pts = l.points(values);

        objc.CGContextSetRGBFillColor(ctx, 0.06, 0.07, 0.09, 1);
        objc.CGContextFillRect(ctx, NSRect.make(0, 0, w, h));

        // Level grid (0, 50, 100 %).
        objc.CGContextSetLineWidth(ctx, 1);
        objc.CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.06);
        objc.CGContextBeginPath(ctx);
        for ([_]CGFloat{ 0, 0.5, 1 }) |f| {
            const y = @round(l.y + f * l.h) + 0.5;
            objc.CGContextMoveToPoint(ctx, l.x, y);
            objc.CGContextAddLineToPoint(ctx, l.x + l.w, y);
        }
        objc.CGContextStrokePath(ctx);

        // Time ticks, labelled along the top: time since note-on up to the
        // sustain hold (which lasts as long as the key is held), then time
        // since note-off from the dashed line on.
        const step = l.tickStep();
        const step_px = l.timeX(step) - l.x;
        self.drawTicks(ctx, l.x, pts[2].x, step, step_px, "");
        self.drawTicks(ctx, pts[3].x, l.x + l.w, step, step_px, "+");
        objc.CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.25);
        const dash = [_]CGFloat{ 3, 3 };
        objc.CGContextSetLineDash(ctx, 0, &dash, dash.len);
        objc.CGContextBeginPath(ctx);
        objc.CGContextMoveToPoint(ctx, @round(pts[3].x) + 0.5, l.y);
        objc.CGContextAddLineToPoint(ctx, @round(pts[3].x) + 0.5, l.y + l.h);
        objc.CGContextStrokePath(ctx);
        objc.CGContextSetLineDash(ctx, 0, null, 0);
        objc.drawText("note off", pts[3].x + 3, h - 12, systemFont(9), objc.color(1, 1, 1, 0.45));

        // Shape: filled, then outlined.
        objc.CGContextBeginPath(ctx);
        objc.CGContextMoveToPoint(ctx, pts[0].x, pts[0].y);
        for (pts[1..]) |q| objc.CGContextAddLineToPoint(ctx, q.x, q.y);
        objc.CGContextClosePath(ctx);
        objc.CGContextSetRGBFillColor(ctx, accent[0], accent[1], accent[2], 0.16);
        objc.CGContextFillPath(ctx);

        objc.CGContextBeginPath(ctx);
        objc.CGContextMoveToPoint(ctx, pts[0].x, pts[0].y);
        for (pts[1..]) |q| objc.CGContextAddLineToPoint(ctx, q.x, q.y);
        objc.CGContextSetLineWidth(ctx, 2);
        objc.CGContextSetLineJoin(ctx, 1);
        objc.CGContextSetRGBStrokeColor(ctx, accent[0], accent[1], accent[2], 1);
        objc.CGContextStrokePath(ctx);

        // Segment letters along the bottom.
        const font = systemFont(10);
        const letter_color = objc.color(1, 1, 1, 0.35);
        for ([_][]const u8{ "A", "D", "S", "R" }, 0..) |letter, i| {
            const x0 = pts[i].x;
            const x1 = pts[i + 1].x;
            if (x1 - x0 < 12) continue;
            objc.drawText(letter, (x0 + x1) / 2 - 3, 1, font, letter_color);
        }

        // Handles.
        for (std.enums.values(graph.Handle)) |handle| {
            const q = l.handlePoint(values, handle);
            const active = if (self.env_drag) |d| d.handle == handle else false;
            const r: CGFloat = if (active) 7 else 5;
            const rect = NSRect.make(q.x - r, q.y - r, 2 * r, 2 * r);
            if (active) objc.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1) else objc.CGContextSetRGBFillColor(ctx, accent[0], accent[1], accent[2], 1);
            objc.CGContextFillEllipseInRect(ctx, rect);
            objc.CGContextSetLineWidth(ctx, 1.5);
            objc.CGContextSetRGBStrokeColor(ctx, 0.06, 0.07, 0.09, 1);
            objc.CGContextStrokeEllipseInRect(ctx, rect);
        }
    }

    /// Vertical ticks every `step` ms starting at x0 (exclusive) up to x1.
    fn drawTicks(_: *Editor, ctx: objc.CGContext, x0: CGFloat, x1: CGFloat, step: f64, step_px: CGFloat, prefix: []const u8) void {
        const font = systemFont(9);
        const text_color = objc.color(1, 1, 1, 0.3);
        objc.CGContextSetLineWidth(ctx, 1);
        const l_bottom: CGFloat = graph.Layout.pad;
        const l_top: CGFloat = env_rect.size.height - graph.Layout.pad;
        var i: f64 = 1;
        while (true) : (i += 1) {
            const x = x0 + i * step_px;
            // Leave room for the label before the next boundary.
            if (x > x1 - 8) break;
            const xr = @round(x) + 0.5;
            // Set every time: drawing a label changes the context's colors.
            objc.CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.05);
            objc.CGContextBeginPath(ctx);
            objc.CGContextMoveToPoint(ctx, xr, l_bottom);
            objc.CGContextAddLineToPoint(ctx, xr, l_top);
            objc.CGContextStrokePath(ctx);
            const t = i * step;
            var buf: [24]u8 = undefined;
            const text = if (t >= 1000)
                std.fmt.bufPrint(&buf, "{s}{d} s", .{ prefix, t / 1000 }) catch ""
            else
                std.fmt.bufPrint(&buf, "{s}{d} ms", .{ prefix, t }) catch "";
            if (x + objc.textWidth(text, font) + 3 <= x1) objc.drawText(text, x + 3, env_rect.size.height - 12, font, text_color);
        }
    }

    // Mix slider -------------------------------------------------------------------

    const slider_inset = 9;

    fn sliderValue(x: CGFloat) f32 {
        const t = (x - slider_inset) / (slider_rect.size.width - 2 * slider_inset);
        return @floatCast(std.math.clamp(t, 0, 1) * 100);
    }

    fn sliderMouseDown(self: *Editor, p: objc.NSPoint, clicks: isize) void {
        if (clicks >= 2) {
            self.editParam(.mix, params.info(.mix).default);
            self.refresh();
            return;
        }
        // Clicking anywhere on the track jumps there, then drags.
        self.slider_dragging = true;
        self.model.begin_edit(self.model.ctx, .mix);
        self.setParam(.mix, sliderValue(p.x));
        self.refresh();
    }

    fn sliderMouseDragged(self: *Editor, p: objc.NSPoint) void {
        if (!self.slider_dragging) return;
        self.setParam(.mix, sliderValue(p.x));
        self.refresh();
    }

    fn sliderMouseUp(self: *Editor) void {
        if (!self.slider_dragging) return;
        self.slider_dragging = false;
        self.model.end_edit(self.model.ctx, .mix);
    }

    fn sliderScroll(self: *Editor, delta: CGFloat) void {
        if (delta == 0) return;
        self.editParam(.mix, self.param(.mix) + @as(f32, @floatCast(delta)) * 0.5);
        self.refresh();
    }

    fn drawSlider(self: *Editor) void {
        const ctx = objc.currentCGContext();
        const w = slider_rect.size.width;
        const mid = slider_rect.size.height / 2;
        const x0: CGFloat = slider_inset;
        const x1 = w - slider_inset;
        const m: CGFloat = self.param(.mix) / 100.0;
        const x = x0 + (x1 - x0) * m;

        objc.CGContextSetLineCap(ctx, 1);
        objc.CGContextSetLineWidth(ctx, 4);
        objc.CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.1);
        objc.CGContextBeginPath(ctx);
        objc.CGContextMoveToPoint(ctx, x0, mid);
        objc.CGContextAddLineToPoint(ctx, x1, mid);
        objc.CGContextStrokePath(ctx);

        // The filled part takes the colour of the blend at the thumb.
        const c = mixColor(m);
        objc.CGContextSetRGBStrokeColor(ctx, c[0], c[1], c[2], 1);
        objc.CGContextBeginPath(ctx);
        objc.CGContextMoveToPoint(ctx, x0, mid);
        objc.CGContextAddLineToPoint(ctx, x, mid);
        objc.CGContextStrokePath(ctx);

        const r: CGFloat = if (self.slider_dragging) 8 else 7;
        objc.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
        objc.CGContextFillEllipseInRect(ctx, NSRect.make(x - r, mid - r, 2 * r, 2 * r));
    }

    // Gain knob ------------------------------------------------------------------

    fn knobMouseDown(self: *Editor, p: objc.NSPoint, clicks: isize) void {
        const info = params.info(.gain);
        if (clicks >= 2) {
            self.editParam(.gain, info.default);
            self.refresh();
            return;
        }
        self.knob_drag = .{ .start_y = p.y, .start = info.toNormalized(self.param(.gain)) };
        self.model.begin_edit(self.model.ctx, .gain);
    }

    fn knobMouseDragged(self: *Editor, p: objc.NSPoint, fine: bool) void {
        const d = self.knob_drag orelse return;
        // 200 px of travel covers the whole range; Shift makes it 10x finer.
        const per_px: f64 = if (fine) 1.0 / 2000.0 else 1.0 / 200.0;
        self.setParam(.gain, params.info(.gain).fromNormalized(d.start + (p.y - d.start_y) * per_px));
        self.refresh();
    }

    fn knobMouseUp(self: *Editor) void {
        if (self.knob_drag == null) return;
        self.knob_drag = null;
        self.model.end_edit(self.model.ctx, .gain);
    }

    fn knobScroll(self: *Editor, delta: CGFloat) void {
        if (delta == 0) return;
        const info = params.info(.gain);
        self.editParam(.gain, info.fromNormalized(info.toNormalized(self.param(.gain)) + delta * 0.004));
        self.refresh();
    }

    fn drawKnob(self: *Editor) void {
        const ctx = objc.currentCGContext();
        const cx = knob_rect.size.width / 2;
        const cy = knob_rect.size.height / 2;
        const r = @min(cx, cy) - 8;
        const start = 1.25 * std.math.pi;
        const sweep = 1.5 * std.math.pi;
        const n = params.info(.gain).toNormalized(self.param(.gain));
        const angle = start - n * sweep;

        objc.CGContextSetLineCap(ctx, 1); // round
        objc.CGContextSetLineWidth(ctx, 6);
        objc.CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.1);
        objc.CGContextBeginPath(ctx);
        objc.CGContextAddArc(ctx, cx, cy, r, start, start - sweep, 1);
        objc.CGContextStrokePath(ctx);

        objc.CGContextSetRGBStrokeColor(ctx, accent[0], accent[1], accent[2], 1);
        objc.CGContextBeginPath(ctx);
        objc.CGContextAddArc(ctx, cx, cy, r, start, angle, 1);
        objc.CGContextStrokePath(ctx);

        const inner = r - 10;
        objc.CGContextSetRGBFillColor(ctx, 0.17, 0.18, 0.21, 1);
        objc.CGContextFillEllipseInRect(ctx, NSRect.make(cx - inner, cy - inner, 2 * inner, 2 * inner));

        objc.CGContextSetLineWidth(ctx, 3);
        objc.CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.9);
        objc.CGContextBeginPath(ctx);
        objc.CGContextMoveToPoint(ctx, cx + @cos(angle) * inner * 0.35, cy + @sin(angle) * inner * 0.35);
        objc.CGContextAddLineToPoint(ctx, cx + @cos(angle) * (inner - 4), cy + @sin(angle) * (inner - 4));
        objc.CGContextStrokePath(ctx);
    }

    fn drawWave(self: *Editor) void {
        const ctx = objc.currentCGContext();
        const w = wave_rect.size.width;
        const h = wave_rect.size.height;
        const mid = h / 2;
        const amp = h / 2 - 12;

        objc.CGContextSetRGBFillColor(ctx, 0.06, 0.07, 0.09, 1);
        objc.CGContextFillRect(ctx, NSRect.make(0, 0, w, h));

        // Grid: eighths of the period and quarters of the amplitude.
        objc.CGContextSetLineWidth(ctx, 1);
        objc.CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.06);
        objc.CGContextBeginPath(ctx);
        for (1..8) |i| {
            const x = @round(w * @as(CGFloat, @floatFromInt(i)) / 8) + 0.5;
            objc.CGContextMoveToPoint(ctx, x, 0);
            objc.CGContextAddLineToPoint(ctx, x, h);
        }
        for ([_]CGFloat{ -1, -0.5, 0.5, 1 }) |v| {
            const y = @round(mid + v * amp) + 0.5;
            objc.CGContextMoveToPoint(ctx, 0, y);
            objc.CGContextAddLineToPoint(ctx, w, y);
        }
        objc.CGContextStrokePath(ctx);

        objc.CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.22);
        objc.CGContextBeginPath(ctx);
        objc.CGContextMoveToPoint(ctx, 0, @round(mid) + 0.5);
        objc.CGContextAddLineToPoint(ctx, w, @round(mid) + 0.5);
        objc.CGContextStrokePath(ctx);

        // One point per pixel column; the last point wraps to the start of
        // the table so the plot shows whether the cycle joins up. The two
        // source waves are thin lines, the mix (what plays) is bold.
        const steps: usize = @intFromFloat(w);
        const mix: f32 = self.param(.mix) / 100.0;
        for (0..wave_count) |wi| {
            if (!self.has_table[wi]) continue;
            const c = wave_colors[wi];
            objc.CGContextBeginPath(ctx);
            for (0..steps + 1) |px| {
                const p = self.wavePoint(px, steps, w, mid, amp, if (wi == 0) 0 else 1);
                if (px == 0) objc.CGContextMoveToPoint(ctx, p.x, p.y) else objc.CGContextAddLineToPoint(ctx, p.x, p.y);
            }
            objc.CGContextSetLineWidth(ctx, 1.2);
            objc.CGContextSetLineJoin(ctx, 1);
            const alpha: CGFloat = if (self.valid[wi]) 0.75 else 0.3;
            objc.CGContextSetRGBStrokeColor(ctx, c[0], c[1], c[2], alpha);
            objc.CGContextStrokePath(ctx);
        }

        if (self.has_table[0] and self.has_table[1]) {
            objc.CGContextBeginPath(ctx);
            objc.CGContextMoveToPoint(ctx, 0, mid);
            for (0..steps + 1) |px| {
                const p = self.wavePoint(px, steps, w, mid, amp, mix);
                objc.CGContextAddLineToPoint(ctx, p.x, p.y);
            }
            objc.CGContextAddLineToPoint(ctx, w, mid);
            objc.CGContextClosePath(ctx);
            objc.CGContextSetRGBFillColor(ctx, accent[0], accent[1], accent[2], 0.14);
            objc.CGContextFillPath(ctx);

            objc.CGContextBeginPath(ctx);
            for (0..steps + 1) |px| {
                const p = self.wavePoint(px, steps, w, mid, amp, mix);
                if (px == 0) objc.CGContextMoveToPoint(ctx, p.x, p.y) else objc.CGContextAddLineToPoint(ctx, p.x, p.y);
            }
            objc.CGContextSetLineWidth(ctx, 2.2);
            objc.CGContextSetRGBStrokeColor(ctx, accent[0], accent[1], accent[2], 1);
            objc.CGContextStrokePath(ctx);
        }
    }

    /// Plot point for pixel column `px` of the blend `mix` (0 = wave 1,
    /// 1 = wave 2), computed the same way the synth crossfades.
    fn wavePoint(self: *const Editor, px: usize, steps: usize, w: CGFloat, mid: CGFloat, amp: CGFloat, mix: f32) objc.NSPoint {
        const idx = (px * wt.size / steps) % wt.size;
        const v = self.tables[0][idx] + (self.tables[1][idx] - self.tables[0][idx]) * mix;
        return .{
            .x = w * @as(CGFloat, @floatFromInt(px)) / @as(CGFloat, @floatFromInt(steps)),
            .y = mid + @as(CGFloat, v) * amp,
        };
    }

    // View construction helpers ------------------------------------------------

    fn label(self: *Editor, text: []const u8, frame: NSRect, font: Id, color: Id) Id {
        const l = objc.classMsg(Id, "NSTextField", "labelWithString:", .{objc.nsString(text)});
        self.place(l, frame, font, color);
        return l;
    }

    fn place(self: *Editor, view: Id, frame: NSRect, font: Id, color: Id) void {
        msg(void, view, "setFrame:", .{frame});
        msg(void, view, "setFont:", .{font});
        msg(void, view, "setTextColor:", .{color});
        msg(void, self.root, "addSubview:", .{view});
    }

    fn customView(self: *Editor, class: objc.Class, frame: NSRect) Id {
        const v = msg(Id, objc.alloc(class), "initWithFrame:", .{frame});
        objc.setUserdata(v, self);
        msg(void, self.root, "addSubview:", .{v});
        objc.release(v);
        return v;
    }

    /// An editable field. `identifier` names it for test hosts and
    /// accessibility (e.g. "formula1", "attack").
    fn input(self: *Editor, frame: NSRect, font: Id, placeholder: []const u8, identifier: []const u8) Id {
        const f = msg(Id, objc.alloc(objc.getClass("NSTextField")), "initWithFrame:", .{frame});
        var lower: [32]u8 = undefined;
        const n = @min(identifier.len, lower.len);
        msg(void, f, "setIdentifier:", .{objc.nsString(std.ascii.lowerString(lower[0..n], identifier[0..n]))});
        msg(void, f, "setFont:", .{font});
        msg(void, f, "setPlaceholderString:", .{objc.nsString(placeholder)});
        msg(void, f, "setDelegate:", .{self.root});
        msg(void, msg(Id, f, "cell", .{}), "setScrollable:", .{objc.YES});
        msg(void, self.root, "addSubview:", .{f});
        objc.release(f);
        return f;
    }
};

const msg = objc.msg;

extern var NSAppearanceNameDarkAqua: Id;
extern var NSRunLoopCommonModes: Id;
extern fn NSRectFill(rect: NSRect) void;

fn fieldId(buf: []u8, name: []const u8, wave: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}", .{ name, wave + 1 }) catch name;
}

/// Colour of the blend between the two wave colours.
fn mixColor(m: CGFloat) [3]CGFloat {
    var out: [3]CGFloat = undefined;
    for (&out, wave_colors[0], wave_colors[1]) |*o, a, b| o.* = a + (b - a) * m;
    return out;
}

fn setText(field: Id, text: []const u8, color: Id) void {
    msg(void, field, "setStringValue:", .{objc.nsString(text)});
    if (color != null) msg(void, field, "setTextColor:", .{color});
}

fn systemFont(size: CGFloat) Id {
    return objc.classMsg(Id, "NSFont", "systemFontOfSize:", .{size});
}
fn boldFont(size: CGFloat) Id {
    return objc.classMsg(Id, "NSFont", "boldSystemFontOfSize:", .{size});
}
fn monoFont(size: CGFloat) Id {
    return objc.classMsg(Id, "NSFont", "monospacedSystemFontOfSize:weight:", .{ size, @as(CGFloat, 0) });
}
fn labelColor() Id {
    return objc.classMsg(Id, "NSColor", "labelColor", .{});
}
fn secondaryColor() Id {
    return objc.classMsg(Id, "NSColor", "secondaryLabelColor", .{});
}
fn redColor() Id {
    return objc.classMsg(Id, "NSColor", "systemRedColor", .{});
}
fn greenColor() Id {
    return objc.classMsg(Id, "NSColor", "systemGreenColor", .{});
}

/// Formats a number compactly: at most 4 decimals, trailing zeros removed.
fn fmtNum(buf: []u8, v: f64) []const u8 {
    var s: []const u8 = std.fmt.bufPrint(buf, "{d:.4}", .{v}) catch return "?";
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        s = std.mem.trimEnd(u8, s, "0");
        s = std.mem.trimEnd(u8, s, ".");
    }
    if (std.mem.eql(u8, s, "-0")) return "0";
    return s;
}

/// A line of spaces and carets that sits under the (monospaced) formula
/// field, pointing at the problem. Counts code points, not bytes.
fn caretMarker(buf: []u8, src: []const u8, pos: usize, len: usize) []const u8 {
    const start = @min(pos, src.len);
    const end = @min(start + len, src.len);
    var n: usize = 0;
    for (src[0..start]) |ch| {
        if (ch & 0xC0 == 0x80) continue;
        if (n >= buf.len - 1) break;
        buf[n] = ' ';
        n += 1;
    }
    var carets: usize = 0;
    for (src[start..end]) |ch| carets += @intFromBool(ch & 0xC0 != 0x80);
    carets = @max(carets, 1);
    while (carets > 0 and n < buf.len) : (carets -= 1) {
        buf[n] = '^';
        n += 1;
    }
    return buf[0..n];
}

// Runtime-defined NSView subclasses -------------------------------------------

fn registerClasses() ?Classes {
    if (classes) |c| return c;
    // Unique per load of this binary: if a host unloads and reloads the
    // plugin, the old classes still point at the old (unmapped) code.
    var name_buf: [64]u8 = undefined;
    const tag = @intFromPtr(&classes);

    const root_name = std.fmt.bufPrintZ(&name_buf, "MathSynthRootView_{x}", .{tag}) catch return null;
    const root = objc.ClassBuilder.begin("NSView", root_name) orelse return null;
    root.method("isFlipped", @ptrCast(&yes), objc.bool_getter_types);
    root.method("drawRect:", @ptrCast(&rootDrawRect), objc.draw_rect_types);
    root.method("controlTextDidChange:", @ptrCast(&rootTextDidChange), "v@:@");

    root.method("controlTextDidEndEditing:", @ptrCast(&rootTextDidEndEditing), "v@:@");
    root.method("refreshTick:", @ptrCast(&rootRefreshTick), "v@:@");

    const wave_name = std.fmt.bufPrintZ(&name_buf, "MathSynthWaveView_{x}", .{tag}) catch return null;
    const wave = objc.ClassBuilder.begin("NSView", wave_name) orelse return null;
    wave.method("drawRect:", @ptrCast(&waveDrawRect), objc.draw_rect_types);
    wave.method("isOpaque", @ptrCast(&yes), objc.bool_getter_types);

    const env_name = std.fmt.bufPrintZ(&name_buf, "MathSynthEnvelopeView_{x}", .{tag}) catch return null;
    const env = objc.ClassBuilder.begin("NSView", env_name) orelse return null;
    env.method("drawRect:", @ptrCast(&envDrawRect), objc.draw_rect_types);
    env.method("isOpaque", @ptrCast(&yes), objc.bool_getter_types);
    env.method("acceptsFirstMouse:", @ptrCast(&yesFor), "B@:@");
    env.method("mouseDown:", @ptrCast(&envMouseDown), "v@:@");
    env.method("mouseDragged:", @ptrCast(&envMouseDragged), "v@:@");
    env.method("mouseUp:", @ptrCast(&envMouseUp), "v@:@");

    const knob_name = std.fmt.bufPrintZ(&name_buf, "MathSynthKnobView_{x}", .{tag}) catch return null;
    const knob = objc.ClassBuilder.begin("NSView", knob_name) orelse return null;
    knob.method("drawRect:", @ptrCast(&knobDrawRect), objc.draw_rect_types);
    knob.method("acceptsFirstMouse:", @ptrCast(&yesFor), "B@:@");
    knob.method("mouseDown:", @ptrCast(&knobMouseDown), "v@:@");
    knob.method("mouseDragged:", @ptrCast(&knobMouseDragged), "v@:@");
    knob.method("mouseUp:", @ptrCast(&knobMouseUp), "v@:@");
    knob.method("scrollWheel:", @ptrCast(&knobScrollWheel), "v@:@");

    const slider_name = std.fmt.bufPrintZ(&name_buf, "MathSynthSliderView_{x}", .{tag}) catch return null;
    const slider = objc.ClassBuilder.begin("NSView", slider_name) orelse return null;
    slider.method("drawRect:", @ptrCast(&sliderDrawRect), objc.draw_rect_types);
    slider.method("acceptsFirstMouse:", @ptrCast(&yesFor), "B@:@");
    slider.method("mouseDown:", @ptrCast(&sliderMouseDown), "v@:@");
    slider.method("mouseDragged:", @ptrCast(&sliderMouseDragged), "v@:@");
    slider.method("mouseUp:", @ptrCast(&sliderMouseUp), "v@:@");
    slider.method("scrollWheel:", @ptrCast(&sliderScrollWheel), "v@:@");

    classes = .{ .root = root.finish(), .wave = wave.finish(), .envelope = env.finish(), .knob = knob.finish(), .slider = slider.finish() };
    return classes;
}

fn yes(_: Id, _: objc.Sel) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn rootDrawRect(_: Id, _: objc.Sel, dirty: NSRect) callconv(.c) void {
    msg(void, objc.color(0.11, 0.12, 0.14, 1), "setFill", .{});
    NSRectFill(dirty);
}

fn yesFor(_: Id, _: objc.Sel, _: Id) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn notificationField(notification: Id) Id {
    return if (notification == null) null else msg(Id, notification, "object", .{});
}

fn rootTextDidChange(self: Id, _: objc.Sel, notification: Id) callconv(.c) void {
    const editor = objc.getUserdata(Editor, self) orelse return;
    // Formula and range fields validate as you type; parameter fields apply
    // when editing ends. Without a sender (test hosts), check both waves.
    const field = notificationField(notification);
    if (field == null) {
        for (0..wave_count) |w| editor.onTextChanged(w);
    } else if (editor.waveForField(field)) |w| editor.onTextChanged(w);
}

fn rootTextDidEndEditing(self: Id, _: objc.Sel, notification: Id) callconv(.c) void {
    const editor = objc.getUserdata(Editor, self) orelse return;
    if (editor.paramForField(notificationField(notification))) |id| editor.onFieldCommitted(id);
}

fn rootRefreshTick(self: Id, _: objc.Sel, _: Id) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.refresh();
}

/// Mouse position of `event` in `view`'s coordinates.
fn eventPoint(view: Id, event: Id) objc.NSPoint {
    const in_window = msg(objc.NSPoint, event, "locationInWindow", .{});
    return msg(objc.NSPoint, view, "convertPoint:fromView:", .{ in_window, @as(Id, null) });
}

fn clickCount(event: Id) isize {
    return msg(isize, event, "clickCount", .{});
}

fn envDrawRect(self: Id, _: objc.Sel, _: NSRect) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.drawEnvelope();
}
fn envMouseDown(self: Id, _: objc.Sel, event: Id) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.envMouseDown(eventPoint(self, event), clickCount(event));
}
fn envMouseDragged(self: Id, _: objc.Sel, event: Id) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.envMouseDragged(eventPoint(self, event));
}
fn envMouseUp(self: Id, _: objc.Sel, _: Id) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.envMouseUp();
}

fn sliderDrawRect(self: Id, _: objc.Sel, _: NSRect) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.drawSlider();
}
fn sliderMouseDown(self: Id, _: objc.Sel, event: Id) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.sliderMouseDown(eventPoint(self, event), clickCount(event));
}
fn sliderMouseDragged(self: Id, _: objc.Sel, event: Id) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.sliderMouseDragged(eventPoint(self, event));
}
fn sliderMouseUp(self: Id, _: objc.Sel, _: Id) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.sliderMouseUp();
}
fn sliderScrollWheel(self: Id, _: objc.Sel, event: Id) callconv(.c) void {
    // Horizontal or vertical scrolling both move it.
    const dx = msg(CGFloat, event, "scrollingDeltaX", .{});
    const dy = msg(CGFloat, event, "scrollingDeltaY", .{});
    if (objc.getUserdata(Editor, self)) |editor| editor.sliderScroll(if (@abs(dx) > @abs(dy)) dx else dy);
}

fn knobDrawRect(self: Id, _: objc.Sel, _: NSRect) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.drawKnob();
}
fn knobMouseDown(self: Id, _: objc.Sel, event: Id) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.knobMouseDown(eventPoint(self, event), clickCount(event));
}
fn knobMouseDragged(self: Id, _: objc.Sel, event: Id) callconv(.c) void {
    const shift: usize = 1 << 17;
    const fine = msg(usize, event, "modifierFlags", .{}) & shift != 0;
    if (objc.getUserdata(Editor, self)) |editor| editor.knobMouseDragged(eventPoint(self, event), fine);
}
fn knobMouseUp(self: Id, _: objc.Sel, _: Id) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.knobMouseUp();
}
fn knobScrollWheel(self: Id, _: objc.Sel, event: Id) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.knobScroll(msg(CGFloat, event, "scrollingDeltaY", .{}));
}

fn waveDrawRect(self: Id, _: objc.Sel, _: NSRect) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.drawWave();
}

test {
    _ = @import("envelope_graph.zig");
}

test "fmtNum" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("6.2832", fmtNum(&buf, std.math.tau));
    try std.testing.expectEqualStrings("0", fmtNum(&buf, 0));
    try std.testing.expectEqualStrings("-1", fmtNum(&buf, -1));
    try std.testing.expectEqualStrings("0.5", fmtNum(&buf, 0.5));
    try std.testing.expectEqualStrings("0", fmtNum(&buf, -0.00001));
}

test "caretMarker" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("         ^^^", caretMarker(&buf, "sin(x) + foo", 9, 3));
    try std.testing.expectEqualStrings("  ^", caretMarker(&buf, "\u{03C0}x$", 3, 1));
    try std.testing.expectEqualStrings("^", caretMarker(&buf, "", 0, 0));
}
