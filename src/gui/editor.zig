//! Native Cocoa editor: formula + range inputs with live validation, a
//! waveform preview, an interactive ADSR envelope and a gain knob.
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
pub const height = 690;

const margin = 20;
const wave_rect = NSRect.make(margin, 166, width - 2 * margin, 200);
const section_y = 398;
const env_rect = NSRect.make(margin, 422, 470, 150);
const knob_rect = NSRect.make(522, 422, 100, 100);
const env_fields_y = 580;

const accent = [3]CGFloat{ 0.36, 0.78, 1.0 };

const NSTextAlignmentRight: isize = if (builtin.cpu.arch == .x86_64) 1 else 2;

/// What the editor needs from the plugin.
pub const Model = struct {
    ctx: *anyopaque,
    /// Called with settings that passed validation and the table built from
    /// them.
    apply: *const fn (ctx: *anyopaque, settings: *const wt.Settings, table: *const wt.Table) void,
    /// Current parameter value in plain units.
    get_param: *const fn (ctx: *anyopaque, id: params.Id) f32,
    /// A user edit of one parameter: `begin_edit`, any number of
    /// `set_param`, then `end_edit` (hosts record this as one automation
    /// gesture).
    begin_edit: *const fn (ctx: *anyopaque, id: params.Id) void,
    set_param: *const fn (ctx: *anyopaque, id: params.Id, plain: f32) void,
    end_edit: *const fn (ctx: *anyopaque, id: params.Id) void,
};

const Classes = struct { root: objc.Class, wave: objc.Class, envelope: objc.Class, knob: objc.Class };
var classes: ?Classes = null;

pub const Editor = struct {
    model: Model,
    root: Id = null,
    fields: [3]Id = .{ null, null, null }, // indexed by wt.Field
    caret: Id = null,
    status: Id = null,
    wave: Id = null,
    from_label: Id = null,
    to_label: Id = null,
    table: wt.Table = @splat(0),
    has_table: bool = false,
    valid: bool = false,

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

    pub fn create(allocator: std.mem.Allocator, parent: Id, model: Model, settings: *const wt.Settings) !*Editor {
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

        _ = self.label("f(x) =", NSRect.make(margin, 57, 60, 20), monoFont(14), labelColor());
        self.fields[@intFromEnum(wt.Field.formula)] = self.input(NSRect.make(84, 54, width - 84 - margin, 26), monoFont(14), "e.g. sin(x) + 0.3sin(3x)");
        self.caret = self.label("", NSRect.make(87, 82, width - 87 - margin, 16), monoFont(14), redColor());

        _ = self.label("from", NSRect.make(margin, 107, 60, 20), systemFont(13), labelColor());
        self.fields[@intFromEnum(wt.Field.from)] = self.input(NSRect.make(84, 104, 140, 24), monoFont(13), "0");
        _ = self.label("to", NSRect.make(240, 107, 30, 20), systemFont(13), labelColor());
        self.fields[@intFromEnum(wt.Field.to)] = self.input(NSRect.make(266, 104, 140, 24), monoFont(13), "2*pi");
        _ = self.label("x range played as one period", NSRect.make(420, 108, 220, 18), systemFont(11), secondaryColor());

        self.status = self.label("", NSRect.make(margin, 140, width - 2 * margin, 18), systemFont(12), labelColor());

        const wave = msg(Id, objc.alloc(cls.wave), "initWithFrame:", .{wave_rect});
        objc.setUserdata(wave, self);
        msg(void, root, "addSubview:", .{wave});
        objc.release(wave);
        self.wave = wave;

        const axis_y = wave_rect.origin.y + wave_rect.size.height + 4;
        self.from_label = self.label("", NSRect.make(margin, axis_y, 200, 16), monoFont(11), secondaryColor());
        self.to_label = self.label("", NSRect.make(width - margin - 200, axis_y, 200, 16), monoFont(11), secondaryColor());
        msg(void, self.to_label, "setAlignment:", .{NSTextAlignmentRight});

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
            self.param_fields[@intFromEnum(id)] = self.input(NSRect.make(x, env_fields_y + 17, 76, 22), monoFont(12), "");
            _ = self.label(info.unitLabel(), NSRect.make(x + 80, env_fields_y + 20, 30, 16), systemFont(11), secondaryColor());
        }
        const gain_x = knob_rect.origin.x + 6;
        const gain_y = knob_rect.origin.y + knob_rect.size.height + 6;
        self.param_fields[@intFromEnum(params.Id.gain)] = self.input(NSRect.make(gain_x, gain_y, 62, 22), monoFont(12), "");
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
        for (self.fields) |f| msg(void, f, "setDelegate:", .{@as(Id, null)});
        for (self.param_fields) |f| msg(void, f, "setDelegate:", .{@as(Id, null)});
        msg(void, self.root, "removeFromSuperview", .{});
        objc.release(self.root);
        allocator.destroy(self);
    }

    /// Shows `settings` in the fields (e.g. after the host loaded a preset)
    /// without pushing them back to the plugin.
    pub fn load(self: *Editor, settings: *const wt.Settings) void {
        const pool = objc.autoreleasePoolPush();
        defer objc.autoreleasePoolPop(pool);
        for (std.enums.values(wt.Field)) |field| {
            msg(void, self.fields[@intFromEnum(field)], "setStringValue:", .{objc.nsString(settings.get(field))});
        }
        self.revalidate(settings, false);
        self.refresh();
    }

    fn onTextChanged(self: *Editor) void {
        var settings: wt.Settings = .{};
        for (std.enums.values(wt.Field)) |field| {
            const value = msg(Id, self.fields[@intFromEnum(field)], "stringValue", .{});
            settings.set(field, objc.utf8(value));
        }
        self.revalidate(&settings, true);
    }

    fn revalidate(self: *Editor, settings: *const wt.Settings, notify: bool) void {
        var buf: [512]u8 = undefined;
        switch (wt.build(settings, &self.table)) {
            .ok => |info| {
                self.valid = true;
                self.has_table = true;
                var a: [32]u8 = undefined;
                var b: [32]u8 = undefined;
                var c: [32]u8 = undefined;
                var d: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "\u{2713} Valid \u{00B7} one period is x \u{2208} [{s}, {s})  \u{00B7}  raw range [{s}, {s}], normalised for playback", .{
                    fmtNum(&a, info.from), fmtNum(&b, info.to), fmtNum(&c, info.raw_min), fmtNum(&d, info.raw_max),
                }) catch buf[0..0];
                setText(self.status, text, greenColor());
                setText(self.caret, "", null);
                setText(self.from_label, std.fmt.bufPrint(&buf, "x = {s}", .{fmtNum(&a, info.from)}) catch "", null);
                setText(self.to_label, std.fmt.bufPrint(&buf, "x = {s}", .{fmtNum(&a, info.to)}) catch "", null);
                if (notify) self.model.apply(self.model.ctx, settings, &self.table);
            },
            .err => |problem| {
                self.valid = false;
                const field_name = switch (problem.field) {
                    .formula => "Formula",
                    .from => "From",
                    .to => "To",
                };
                const text = std.fmt.bufPrint(&buf, "\u{2717} {s}: {s}", .{ field_name, problem.diag.message() }) catch buf[0..0];
                setText(self.status, text, redColor());
                const marker = if (problem.field == .formula)
                    caretMarker(&buf, settings.get(.formula), problem.diag.pos, problem.diag.len)
                else
                    "";
                setText(self.caret, marker, null);
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
            if (id == .gain) {
                msg(void, self.knob_view, "setNeedsDisplay:", .{objc.YES});
            } else env_changed = true;
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
                .gain => unreachable,
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

        if (!self.has_table) return;

        // One point per pixel column; the last point wraps to the start of
        // the table so the plot shows whether the cycle joins up.
        const steps: usize = @intFromFloat(w);
        const line: [3]CGFloat = if (self.valid) accent else .{ 0.55, 0.55, 0.58 };

        objc.CGContextBeginPath(ctx);
        objc.CGContextMoveToPoint(ctx, 0, mid);
        for (0..steps + 1) |px| self.addWavePoint(ctx, px, steps, w, mid, amp);
        objc.CGContextAddLineToPoint(ctx, w, mid);
        objc.CGContextClosePath(ctx);
        objc.CGContextSetRGBFillColor(ctx, line[0], line[1], line[2], if (self.valid) 0.16 else 0.06);
        objc.CGContextFillPath(ctx);

        objc.CGContextBeginPath(ctx);
        for (0..steps + 1) |px| {
            if (px == 0) {
                const p = self.wavePoint(0, steps, w, mid, amp);
                objc.CGContextMoveToPoint(ctx, p.x, p.y);
            } else self.addWavePoint(ctx, px, steps, w, mid, amp);
        }
        objc.CGContextSetLineWidth(ctx, 2);
        objc.CGContextSetLineJoin(ctx, 1); // round
        objc.CGContextSetRGBStrokeColor(ctx, line[0], line[1], line[2], 1);
        objc.CGContextStrokePath(ctx);
    }

    fn wavePoint(self: *const Editor, px: usize, steps: usize, w: CGFloat, mid: CGFloat, amp: CGFloat) objc.NSPoint {
        const idx = (px * wt.size / steps) % wt.size;
        return .{
            .x = w * @as(CGFloat, @floatFromInt(px)) / @as(CGFloat, @floatFromInt(steps)),
            .y = mid + @as(CGFloat, self.table[idx]) * amp,
        };
    }

    fn addWavePoint(self: *const Editor, ctx: objc.CGContext, px: usize, steps: usize, w: CGFloat, mid: CGFloat, amp: CGFloat) void {
        const p = self.wavePoint(px, steps, w, mid, amp);
        objc.CGContextAddLineToPoint(ctx, p.x, p.y);
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

    fn input(self: *Editor, frame: NSRect, font: Id, placeholder: []const u8) Id {
        const f = msg(Id, objc.alloc(objc.getClass("NSTextField")), "initWithFrame:", .{frame});
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

    classes = .{ .root = root.finish(), .wave = wave.finish(), .envelope = env.finish(), .knob = knob.finish() };
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
    // Parameter fields apply when editing ends; only the formula and range
    // fields validate as you type.
    if (editor.paramForField(notificationField(notification)) != null) return;
    editor.onTextChanged();
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
