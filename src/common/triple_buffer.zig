//! Single-producer / single-consumer triple buffer: lets a UI thread hand
//! the latest version of a large value (e.g. a wavetable) to the audio
//! thread. Neither side ever blocks.

const std = @import("std");

/// The writer fills `beginWrite()` and calls `publish()`; the reader calls
/// `read()` (e.g. once per audio block) and gets the newest published value.
pub fn TripleBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        slots: [3]T = undefined,
        /// Index of the slot in the middle, plus `dirty_bit` when it holds a
        /// value the reader has not seen yet.
        shared: std.atomic.Value(u8) = .init(1),
        back: u8 = 2, // owned by the writer
        front: u8 = 0, // owned by the reader
        writer_lock: std.atomic.Value(bool) = .init(false),

        const dirty_bit: u8 = 4;

        pub fn initWith(tb: *Self, value: *const T) void {
            for (&tb.slots) |*t| t.* = value.*;
        }

        /// Exclusive access to the back buffer. Call `publish` or `cancelWrite`
        /// afterwards. Writers on different threads serialise here.
        pub fn beginWrite(tb: *Self) *T {
            while (tb.writer_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
                std.atomic.spinLoopHint();
            }
            return &tb.slots[tb.back];
        }

        pub fn publish(tb: *Self) void {
            const prev = tb.shared.swap(tb.back | dirty_bit, .acq_rel);
            tb.back = prev & ~dirty_bit;
            tb.writer_lock.store(false, .release);
        }

        pub fn cancelWrite(tb: *Self) void {
            tb.writer_lock.store(false, .release);
        }

        /// Audio thread: returns the newest published table.
        pub fn read(tb: *Self) *const T {
            if (tb.shared.load(.monotonic) & dirty_bit != 0) {
                const prev = tb.shared.swap(tb.front, .acq_rel);
                tb.front = prev & ~dirty_bit;
            }
            return &tb.slots[tb.front];
        }
    };
}

test "triple buffer hands over the latest value" {
    var tb: TripleBuffer([4]f32) = .{};
    tb.initWith(&@as([4]f32, @splat(0)));
    try std.testing.expectEqual(@as(f32, 0), tb.read()[0]);
    tb.beginWrite()[0] = 1;
    tb.publish();
    tb.beginWrite()[0] = 2;
    tb.publish();
    try std.testing.expectEqual(@as(f32, 2), tb.read()[0]);
    try std.testing.expectEqual(@as(f32, 2), tb.read()[0]);
}
