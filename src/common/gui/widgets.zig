//! Drawing of common controls, for use inside a view's drawRect:. Views are
//! assumed not flipped (y up). Mouse handling stays with the editor; these
//! helpers also map positions to values so drawing and dragging agree.

const std = @import("std");
const objc = @import("objc.zig");

const CGFloat = objc.CGFloat;
const NSRect = objc.NSRect;

pub const Color = [3]CGFloat;

/// Rotary knob filling a view of `size`: a 270° track, the value arc in
/// `color`, and a pointer. `normalized` is 0..1.
pub fn drawKnob(size: objc.NSSize, normalized: f64, color: Color) void {
    const ctx = objc.currentCGContext();
    const cx = size.width / 2;
    const cy = size.height / 2;
    const r = @min(cx, cy) - 8;
    const start = 1.25 * std.math.pi;
    const sweep = 1.5 * std.math.pi;
    const angle = start - std.math.clamp(normalized, 0, 1) * sweep;

    objc.CGContextSetLineCap(ctx, 1); // round
    objc.CGContextSetLineWidth(ctx, 6);
    objc.CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.1);
    objc.CGContextBeginPath(ctx);
    objc.CGContextAddArc(ctx, cx, cy, r, start, start - sweep, 1);
    objc.CGContextStrokePath(ctx);

    objc.CGContextSetRGBStrokeColor(ctx, color[0], color[1], color[2], 1);
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

/// Pixels of drag for the full knob range (Shift-drags use 10x this).
pub const knob_drag_range = 200;

/// Horizontal slider filling a view of `size`: track, filled part in
/// `color` up to the thumb, and the thumb (larger while `active`).
/// `value` is 0..1.
pub fn drawSlider(size: objc.NSSize, value: CGFloat, color: Color, active: bool) void {
    const ctx = objc.currentCGContext();
    const mid = size.height / 2;
    const x0: CGFloat = slider_inset;
    const x1 = size.width - slider_inset;
    const x = x0 + (x1 - x0) * std.math.clamp(value, 0, 1);

    objc.CGContextSetLineCap(ctx, 1);
    objc.CGContextSetLineWidth(ctx, 4);
    objc.CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.1);
    objc.CGContextBeginPath(ctx);
    objc.CGContextMoveToPoint(ctx, x0, mid);
    objc.CGContextAddLineToPoint(ctx, x1, mid);
    objc.CGContextStrokePath(ctx);

    objc.CGContextSetRGBStrokeColor(ctx, color[0], color[1], color[2], 1);
    objc.CGContextBeginPath(ctx);
    objc.CGContextMoveToPoint(ctx, x0, mid);
    objc.CGContextAddLineToPoint(ctx, x, mid);
    objc.CGContextStrokePath(ctx);

    const r: CGFloat = if (active) 8 else 7;
    objc.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    objc.CGContextFillEllipseInRect(ctx, NSRect.make(x - r, mid - r, 2 * r, 2 * r));
}

/// Space at each end of a slider's track, so the thumb fits.
pub const slider_inset = 9;

/// The 0..1 value at x in a slider of the given width.
pub fn sliderValue(x: CGFloat, width: CGFloat) f64 {
    return std.math.clamp((x - slider_inset) / (width - 2 * slider_inset), 0, 1);
}

test "slider mapping" {
    try std.testing.expectEqual(@as(f64, 0), sliderValue(0, 276));
    try std.testing.expectEqual(@as(f64, 0.25), sliderValue(9 + 0.25 * 258, 276));
    try std.testing.expectEqual(@as(f64, 1), sliderValue(500, 276));
}
