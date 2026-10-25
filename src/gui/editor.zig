//! Native Cocoa editor: formula + range inputs with live validation and a
//! waveform preview. Everything here runs on the host's UI (main) thread.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const wt = @import("../wavetable.zig");

const Id = objc.Id;
const NSRect = objc.NSRect;
const CGFloat = objc.CGFloat;

pub const width = 660;
pub const height = 480;

const margin = 20;
const wave_rect = NSRect.make(margin, 166, width - 2 * margin, 240);

const NSTextAlignmentRight: isize = if (builtin.cpu.arch == .x86_64) 1 else 2;

/// What the editor needs from the plugin.
pub const Model = struct {
    ctx: *anyopaque,
    /// Called with settings that passed validation and the table built from
    /// them.
    apply: *const fn (ctx: *anyopaque, settings: *const wt.Settings, table: *const wt.Table) void,
};

const Classes = struct { root: objc.Class, wave: objc.Class };
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

    pub fn create(allocator: std.mem.Allocator, parent: Id, model: Model, settings: *const wt.Settings) !*Editor {
        const cls = registerClasses() orelse return error.ObjcClassRegistration;
        const self = try allocator.create(Editor);
        self.* = .{ .model = model };

        const pool = objc.autoreleasePoolPush();
        defer objc.autoreleasePoolPop(pool);

        const root = msg(Id, objc.alloc(cls.root), "initWithFrame:", .{NSRect.make(0, 0, width, height)});
        objc.setUserdata(root, self);
        self.root = root;
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

        const help = objc.classMsg(Id, "NSTextField", "wrappingLabelWithString:", .{objc.nsString(
            "Functions: sin cos tan asin acos atan sinh cosh tanh exp ln log log2 sqrt cbrt abs floor ceil " ++
                "round trunc frac sign atan2 pow min max mod clamp   Constants: pi tau e   " ++
                "Operators: + - * / % ^ (and implicit multiplication, e.g. 2x)",
        )});
        self.place(help, NSRect.make(margin, 430, width - 2 * margin, 40), systemFont(11), secondaryColor());

        msg(void, parent, "addSubview:", .{root});
        self.load(settings);
        return self;
    }

    pub fn destroy(self: *Editor, allocator: std.mem.Allocator) void {
        objc.setUserdata(self.root, null);
        objc.setUserdata(self.wave, null);
        for (self.fields) |f| msg(void, f, "setDelegate:", .{@as(Id, null)});
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

    fn drawWave(self: *Editor) void {
        const ctx = objc.currentCGContext();
        const w = wave_rect.size.width;
        const h = wave_rect.size.height;
        const mid = h / 2;
        const amp = h / 2 - 14;

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
        const accent: [3]CGFloat = if (self.valid) .{ 0.36, 0.78, 1.0 } else .{ 0.55, 0.55, 0.58 };

        objc.CGContextBeginPath(ctx);
        objc.CGContextMoveToPoint(ctx, 0, mid);
        for (0..steps + 1) |px| self.addWavePoint(ctx, px, steps, w, mid, amp);
        objc.CGContextAddLineToPoint(ctx, w, mid);
        objc.CGContextClosePath(ctx);
        objc.CGContextSetRGBFillColor(ctx, accent[0], accent[1], accent[2], if (self.valid) 0.16 else 0.06);
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
        objc.CGContextSetRGBStrokeColor(ctx, accent[0], accent[1], accent[2], 1);
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

    const wave_name = std.fmt.bufPrintZ(&name_buf, "MathSynthWaveView_{x}", .{tag}) catch return null;
    const wave = objc.ClassBuilder.begin("NSView", wave_name) orelse return null;
    wave.method("drawRect:", @ptrCast(&waveDrawRect), objc.draw_rect_types);
    wave.method("isOpaque", @ptrCast(&yes), objc.bool_getter_types);

    classes = .{ .root = root.finish(), .wave = wave.finish() };
    return classes;
}

fn yes(_: Id, _: objc.Sel) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn rootDrawRect(_: Id, _: objc.Sel, dirty: NSRect) callconv(.c) void {
    msg(void, objc.color(0.11, 0.12, 0.14, 1), "setFill", .{});
    NSRectFill(dirty);
}

fn rootTextDidChange(self: Id, _: objc.Sel, _: Id) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.onTextChanged();
}

fn waveDrawRect(self: Id, _: objc.Sel, _: NSRect) callconv(.c) void {
    if (objc.getUserdata(Editor, self)) |editor| editor.drawWave();
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
