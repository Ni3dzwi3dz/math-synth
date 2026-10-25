//! Minimal Objective-C runtime bridge: enough to create AppKit views, send
//! messages and define small NSView subclasses from Zig.

const std = @import("std");
const builtin = @import("builtin");

pub const Id = ?*anyopaque;
pub const Sel = ?*anyopaque;
pub const Class = ?*anyopaque;
pub const Ivar = ?*anyopaque;

pub const CGFloat = f64;
pub const NSPoint = extern struct { x: CGFloat, y: CGFloat };
pub const NSSize = extern struct { width: CGFloat, height: CGFloat };
pub const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,

    pub fn make(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) NSRect {
        return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
    }
};

extern fn objc_getClass(name: [*:0]const u8) Class;
extern fn sel_registerName(name: [*:0]const u8) Sel;
extern fn objc_msgSend() void;
extern fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra_bytes: usize) Class;
extern fn objc_registerClassPair(cls: Class) void;
extern fn class_addMethod(cls: Class, name: Sel, imp: *const anyopaque, types: [*:0]const u8) bool;
extern fn class_addIvar(cls: Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) bool;
extern fn class_getInstanceVariable(cls: Class, name: [*:0]const u8) Ivar;
extern fn ivar_getOffset(v: Ivar) isize;
extern fn object_getClass(obj: Id) Class;
extern fn objc_autoreleasePoolPush() ?*anyopaque;
extern fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

pub const autoreleasePoolPush = objc_autoreleasePoolPush;
pub const autoreleasePoolPop = objc_autoreleasePoolPop;

pub fn getClass(name: [*:0]const u8) Class {
    return objc_getClass(name);
}

extern fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;

pub fn getProtocol(name: [*:0]const u8) ?*anyopaque {
    return objc_getProtocol(name);
}

pub fn sel(name: [*:0]const u8) Sel {
    return sel_registerName(name);
}

/// `[target selector:args...]`. Argument types are taken from `args`, so pass
/// concretely typed values (e.g. `@as(CGFloat, 1)`), never comptime literals.
/// Methods returning large structs (NSRect) are not supported on x86_64.
pub fn msg(comptime Ret: type, target: anytype, selector: [*:0]const u8, args: anytype) Ret {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    const t: Id = @ptrCast(target);
    const s = sel(selector);
    const f = &objc_msgSend;
    switch (fields.len) {
        0 => return @as(*const fn (Id, Sel) callconv(.c) Ret, @ptrCast(f))(t, s),
        1 => return @as(*const fn (Id, Sel, fields[0].type) callconv(.c) Ret, @ptrCast(f))(t, s, args[0]),
        2 => return @as(*const fn (Id, Sel, fields[0].type, fields[1].type) callconv(.c) Ret, @ptrCast(f))(t, s, args[0], args[1]),
        3 => return @as(*const fn (Id, Sel, fields[0].type, fields[1].type, fields[2].type) callconv(.c) Ret, @ptrCast(f))(t, s, args[0], args[1], args[2]),
        4 => return @as(*const fn (Id, Sel, fields[0].type, fields[1].type, fields[2].type, fields[3].type) callconv(.c) Ret, @ptrCast(f))(t, s, args[0], args[1], args[2], args[3]),
        5 => return @as(*const fn (Id, Sel, fields[0].type, fields[1].type, fields[2].type, fields[3].type, fields[4].type) callconv(.c) Ret, @ptrCast(f))(t, s, args[0], args[1], args[2], args[3], args[4]),
        else => @compileError("too many arguments"),
    }
}

/// `[ClassName selector:args...]`
pub fn classMsg(comptime Ret: type, class_name: [*:0]const u8, selector: [*:0]const u8, args: anytype) Ret {
    return msg(Ret, getClass(class_name), selector, args);
}

pub fn alloc(class: Class) Id {
    return msg(Id, class, "alloc", .{});
}

pub fn release(obj: Id) void {
    msg(void, obj, "release", .{});
}

/// Autoreleased NSString from UTF-8 bytes.
pub fn nsString(text: []const u8) Id {
    const str = alloc(getClass("NSString"));
    const NSUTF8StringEncoding: usize = 4;
    const s = msg(Id, str, "initWithBytes:length:encoding:", .{ @as(?*const anyopaque, text.ptr), text.len, NSUTF8StringEncoding });
    return msg(Id, s, "autorelease", .{});
}

/// UTF-8 contents of an NSString. Valid until the enclosing autorelease pool
/// is drained.
pub fn utf8(str: Id) []const u8 {
    if (str == null) return "";
    const p = msg(?[*:0]const u8, str, "UTF8String", .{}) orelse return "";
    return std.mem.span(p);
}

pub fn color(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) Id {
    return classMsg(Id, "NSColor", "colorWithSRGBRed:green:blue:alpha:", .{ r, g, b, a });
}

/// Builder for a runtime-defined subclass that stores one pointer-sized
/// "userdata" ivar per instance.
pub const ClassBuilder = struct {
    cls: Class,

    pub fn begin(superclass: [*:0]const u8, name: [*:0]const u8) ?ClassBuilder {
        const cls = objc_allocateClassPair(getClass(superclass), name, 0) orelse return null;
        _ = class_addIvar(cls, userdata_ivar, @sizeOf(usize), std.math.log2_int(usize, @alignOf(usize)), "^v");
        return .{ .cls = cls };
    }

    pub fn method(b: ClassBuilder, selector: [*:0]const u8, imp: *const anyopaque, types: [*:0]const u8) void {
        _ = class_addMethod(b.cls, sel(selector), imp, types);
    }

    pub fn finish(b: ClassBuilder) Class {
        objc_registerClassPair(b.cls);
        return b.cls;
    }
};

const userdata_ivar = "zigUserdata";

fn userdataSlot(obj: Id) *?*anyopaque {
    const ivar = class_getInstanceVariable(object_getClass(obj), userdata_ivar);
    const base: [*]u8 = @ptrCast(obj.?);
    return @ptrCast(@alignCast(base + @as(usize, @intCast(ivar_getOffset(ivar)))));
}

pub fn setUserdata(obj: Id, ptr: ?*anyopaque) void {
    userdataSlot(obj).* = ptr;
}

pub fn getUserdata(comptime T: type, obj: Id) ?*T {
    return @ptrCast(@alignCast(userdataSlot(obj).*));
}

/// Type encoding of `-(void)drawRect:(NSRect)r`.
pub const draw_rect_types = "v@:{CGRect={CGPoint=dd}{CGSize=dd}}";
/// Type encoding of `-(BOOL)method`.
pub const bool_getter_types = if (builtin.cpu.arch == .x86_64) "c@:" else "B@:";
/// ObjC BOOL as returned from method implementations.
pub const BOOL = if (builtin.cpu.arch == .x86_64) i8 else bool;
pub const YES: BOOL = if (builtin.cpu.arch == .x86_64) 1 else true;
pub const NO: BOOL = if (builtin.cpu.arch == .x86_64) 0 else false;

// CoreGraphics -------------------------------------------------------------

pub const CGContext = ?*anyopaque;
pub extern fn CGContextSaveGState(c: CGContext) void;
pub extern fn CGContextRestoreGState(c: CGContext) void;
pub extern fn CGContextSetRGBFillColor(c: CGContext, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
pub extern fn CGContextSetRGBStrokeColor(c: CGContext, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
pub extern fn CGContextFillRect(c: CGContext, rect: NSRect) void;
pub extern fn CGContextSetLineWidth(c: CGContext, w: CGFloat) void;
pub extern fn CGContextSetLineDash(c: CGContext, phase: CGFloat, lengths: ?[*]const CGFloat, count: usize) void;
pub extern fn CGContextBeginPath(c: CGContext) void;
pub extern fn CGContextMoveToPoint(c: CGContext, x: CGFloat, y: CGFloat) void;
pub extern fn CGContextAddLineToPoint(c: CGContext, x: CGFloat, y: CGFloat) void;
pub extern fn CGContextClosePath(c: CGContext) void;
pub extern fn CGContextFillPath(c: CGContext) void;
pub extern fn CGContextStrokePath(c: CGContext) void;
pub extern fn CGContextSetLineJoin(c: CGContext, join: i32) void;

pub fn currentCGContext() CGContext {
    const ns_ctx = classMsg(Id, "NSGraphicsContext", "currentContext", .{});
    return msg(CGContext, ns_ctx, "CGContext", .{});
}
