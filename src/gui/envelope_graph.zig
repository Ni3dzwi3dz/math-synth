//! Geometry of the interactive ADSR graph, kept free of Cocoa so it can be
//! unit tested.
//!
//! Time runs linearly left to right with a fixed-width sustain hold between
//! decay and release. The visible time span zooms to fit the envelope; the
//! editor keeps it fixed while a point is being dragged so nothing moves
//! under the cursor, and refits afterwards.

const std = @import("std");
const params = @import("../params.zig");

pub const Point = struct { x: f64, y: f64 };

pub const Values = struct {
    attack_ms: f32,
    decay_ms: f32,
    sustain_pct: f32,
    release_ms: f32,
};

/// The draggable points. `peak` sets attack, `decay` sets decay and sustain,
/// `sustain` sets sustain, `end` sets release.
pub const Handle = enum { peak, decay, sustain, end };

pub fn affected(h: Handle) []const params.Id {
    return switch (h) {
        .peak => &.{.attack},
        .decay => &.{ .decay, .sustain },
        .sustain => &.{.sustain},
        .end => &.{.release},
    };
}

/// Plot area inside a view of the given size (y pointing up).
pub const Layout = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    /// Milliseconds shown across the width, not counting the sustain hold.
    span_ms: f64,

    pub const pad = 14;

    pub fn init(view_w: f64, view_h: f64, span_ms: f64) Layout {
        return .{ .x = pad, .y = pad, .w = view_w - 2 * pad, .h = view_h - 2 * pad, .span_ms = span_ms };
    }

    /// A span that shows `v` with some room to drag further out, rounded to
    /// a tidy value.
    pub fn fitSpan(v: Values) f64 {
        const total = @as(f64, v.attack_ms) + v.decay_ms + v.release_ms;
        const wanted = @max(total * 1.4, 100);
        for (nice_spans) |span| {
            if (span >= wanted) return span;
        }
        return nice_spans[nice_spans.len - 1];
    }

    const nice_spans = [_]f64{ 100, 150, 200, 300, 400, 500, 750, 1000, 1500, 2000, 3000, 4000, 5000, 7500, 10_000, 15_000, 20_000, 30_000, 40_000 };

    /// Spacing of the labelled time ticks: 3 to 8 of them across the span.
    pub fn tickStep(l: Layout) f64 {
        for ([_]f64{ 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000, 10_000 }) |step| {
            if (l.span_ms / step <= 8) return step;
        }
        return 10_000;
    }

    /// X of time `ms` on the axis before the sustain hold.
    pub fn timeX(l: Layout, ms: f64) f64 {
        return l.x + ms / l.span_ms * l.timeWidth();
    }

    fn hold(l: Layout) f64 {
        return l.w * 0.16;
    }

    fn timeWidth(l: Layout) f64 {
        return l.w - l.hold();
    }

    fn pxToMs(l: Layout, px: f64) f64 {
        return px / l.timeWidth() * l.span_ms;
    }

    fn msToPx(l: Layout, ms: f32) f64 {
        return @as(f64, ms) / l.span_ms * l.timeWidth();
    }

    fn level(l: Layout, pct: f32) f64 {
        return l.y + l.h * @as(f64, pct) / 100.0;
    }

    /// Start, peak, end of decay, end of sustain hold, end of release.
    pub fn points(l: Layout, v: Values) [5]Point {
        const a = l.msToPx(v.attack_ms);
        const d = l.msToPx(v.decay_ms);
        const r = l.msToPx(v.release_ms);
        const s = l.level(v.sustain_pct);
        const p0: Point = .{ .x = l.x, .y = l.y };
        const p1: Point = .{ .x = p0.x + a, .y = l.y + l.h };
        const p2: Point = .{ .x = p1.x + d, .y = s };
        const p3: Point = .{ .x = p2.x + l.hold(), .y = s };
        const p4: Point = .{ .x = p3.x + r, .y = l.y };
        return .{ p0, p1, p2, p3, p4 };
    }

    pub fn handlePoint(l: Layout, v: Values, h: Handle) Point {
        return l.points(v)[@as(usize, @intFromEnum(h)) + 1];
    }

    /// The handle under `p`, if any. When handles overlap (e.g. a zero
    /// attack) the one drawn last (rightmost) wins, so stacked points can
    /// still be pulled apart.
    pub fn hit(l: Layout, v: Values, p: Point, radius: f64) ?Handle {
        var best: ?Handle = null;
        var best_d = radius * radius;
        for (std.enums.values(Handle)) |h| {
            const q = l.handlePoint(v, h);
            const dx = q.x - p.x;
            const dy = q.y - p.y;
            const d = dx * dx + dy * dy;
            if (d <= best_d) {
                best = h;
                best_d = d;
            }
        }
        return best;
    }

    /// New values after moving handle `h` to `p`.
    pub fn drag(l: Layout, v: Values, h: Handle, p: Point) Values {
        var out = v;
        const pts = l.points(v);
        const sustain: f32 = @floatCast(std.math.clamp((p.y - l.y) / l.h, 0, 1) * 100.0);
        // Points can't be dragged past the right edge of the plot.
        const right = l.x + l.w;
        const time = struct {
            fn at(layout: Layout, id: params.Id, dx: f64) f32 {
                return params.info(id).clamp(@floatCast(layout.pxToMs(@max(dx, 0))));
            }
        }.at;
        switch (h) {
            .peak => out.attack_ms = time(l, .attack, @min(p.x, right - (pts[4].x - pts[1].x)) - pts[0].x),
            .decay => {
                out.decay_ms = time(l, .decay, @min(p.x, right - (pts[4].x - pts[2].x)) - pts[1].x);
                out.sustain_pct = sustain;
            },
            .sustain => out.sustain_pct = sustain,
            .end => out.release_ms = time(l, .release, @min(p.x, right) - pts[3].x),
        }
        return out;
    }
};

const test_values: Values = .{ .attack_ms = 5, .decay_ms = 250, .sustain_pct = 70, .release_ms = 300 };

test "points run left to right and match the levels" {
    const l = Layout.init(470, 150, Layout.fitSpan(test_values));
    const pts = l.points(test_values);
    for (pts[0 .. pts.len - 1], pts[1..]) |a, b| try std.testing.expect(b.x >= a.x);
    try std.testing.expectEqual(l.y + l.h, pts[1].y);
    try std.testing.expectApproxEqAbs(l.y + 0.7 * l.h, pts[2].y, 1e-9);
    try std.testing.expectEqual(pts[2].y, pts[3].y);
    try std.testing.expectEqual(l.y, pts[4].y);
    // The fitted span leaves room on the right, and always fits.
    try std.testing.expect(pts[4].x < l.x + l.w);
    const max: Values = .{ .attack_ms = 10_000, .decay_ms = 10_000, .sustain_pct = 100, .release_ms = 10_000 };
    const lm = Layout.init(470, 150, Layout.fitSpan(max));
    try std.testing.expect(lm.points(max)[4].x <= lm.x + lm.w);
}

test "fitted spans and ticks are tidy" {
    try std.testing.expectEqual(@as(f64, 1000), Layout.fitSpan(test_values)); // 555 ms * 1.4
    try std.testing.expectEqual(@as(f64, 100), Layout.fitSpan(.{ .attack_ms = 0, .decay_ms = 0, .sustain_pct = 0, .release_ms = 0 }));
    const l = Layout.init(470, 150, 1000);
    try std.testing.expectEqual(@as(f64, 200), l.tickStep());
}

test "dragging a handle onto its own position changes nothing" {
    const l = Layout.init(470, 150, 1000);
    for (std.enums.values(Handle)) |h| {
        const out = l.drag(test_values, h, l.handlePoint(test_values, h));
        try std.testing.expectApproxEqAbs(test_values.attack_ms, out.attack_ms, 0.01);
        try std.testing.expectApproxEqAbs(test_values.decay_ms, out.decay_ms, 0.01);
        try std.testing.expectApproxEqAbs(test_values.sustain_pct, out.sustain_pct, 0.01);
        try std.testing.expectApproxEqAbs(test_values.release_ms, out.release_ms, 0.01);
    }
}

test "drags clamp to the plot and the parameter ranges" {
    const l = Layout.init(470, 150, 1000);
    // Release can go as far as the right edge: 1000 ms - attack - decay.
    const far = l.drag(test_values, .end, .{ .x = 10_000, .y = 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 745), far.release_ms, 0.01);
    // With the span at its widest, release reaches its 10 s maximum.
    const wide = Layout.init(470, 150, 40_000);
    try std.testing.expectEqual(@as(f32, 10_000), wide.drag(test_values, .end, .{ .x = 10_000, .y = 0 }).release_ms);
    const back = l.drag(test_values, .peak, .{ .x = -50, .y = 0 });
    try std.testing.expectEqual(@as(f32, 0), back.attack_ms);
    const low = l.drag(test_values, .decay, .{ .x = l.handlePoint(test_values, .decay).x, .y = -100 });
    try std.testing.expectEqual(@as(f32, 0), low.sustain_pct);
}

test "hit testing" {
    const l = Layout.init(470, 150, 1000);
    const p = l.handlePoint(test_values, .sustain);
    try std.testing.expectEqual(@as(?Handle, .sustain), l.hit(test_values, .{ .x = p.x + 3, .y = p.y - 3 }, 10));
    try std.testing.expectEqual(@as(?Handle, null), l.hit(test_values, .{ .x = p.x, .y = p.y + 40 }, 10));
}
