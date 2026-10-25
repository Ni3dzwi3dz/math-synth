//! Format-independent core shared by the VST3 and Audio Unit wrappers: the
//! synth, the wavetable handoff to the audio thread, the user's settings and
//! their serialised form.

const std = @import("std");
const wt = @import("wavetable.zig");
const Synth = @import("synth.zig").Synth;

pub const tail_seconds = 0.1;

pub const Engine = struct {
    synth: Synth = .{},
    tables: wt.TripleBuffer = .{},

    /// Guards `settings`, which the UI writes and state saving may read from
    /// another thread.
    settings_lock: std.atomic.Value(bool) = .init(false),
    settings: wt.Settings = wt.Settings.default,

    pub fn init(e: *Engine) void {
        e.* = .{};
        var table: wt.Table = undefined;
        std.debug.assert(wt.build(&e.settings, &table) == .ok);
        e.tables.initWith(&table);
        e.synth.setSampleRate(44100);
    }

    pub fn currentSettings(e: *Engine) wt.Settings {
        e.lock();
        defer e.unlock();
        return e.settings;
    }

    /// Stores validated settings and hands the matching table to the audio
    /// thread.
    pub fn apply(e: *Engine, settings: *const wt.Settings, table: *const wt.Table) void {
        e.tables.beginWrite().* = table.*;
        e.tables.publish();
        e.lock();
        e.settings = settings.*;
        e.unlock();
    }

    /// Validates and applies settings, e.g. from a saved project. Returns
    /// false (changing nothing) if they don't compile.
    pub fn load(e: *Engine, settings: *const wt.Settings) bool {
        var table: wt.Table = undefined;
        if (wt.build(settings, &table) != .ok) return false;
        e.apply(settings, &table);
        return true;
    }

    /// Renders frames [from, to) into each channel. Audio thread only.
    pub fn render(e: *Engine, channels: []const [*]f32, from: usize, to: usize) void {
        if (to <= from) return;
        const table = e.tables.read();
        if (channels.len == 0) {
            // No output buffers: keep voices advancing anyway.
            var scratch: [256]f32 = undefined;
            var at = from;
            while (at < to) {
                const n = @min(scratch.len, to - at);
                e.synth.render(table, scratch[0..n]);
                at += n;
            }
            return;
        }
        const first = channels[0][from..to];
        e.synth.render(table, first);
        for (channels[1..]) |ch| @memcpy(ch[from..to], first);
    }

    fn lock(e: *Engine) void {
        while (e.settings_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(e: *Engine) void {
        e.settings_lock.store(false, .release);
    }
};

// Saved state: "MSY1", then formula, from and to, each as a u8 length
// followed by UTF-8 bytes.
const state_magic = "MSY1";
pub const max_state_len = 4 + 3 + wt.max_formula_len + 2 * wt.max_range_len;

pub fn serialize(settings: *const wt.Settings, buf: *[max_state_len]u8) []const u8 {
    @memcpy(buf[0..4], state_magic);
    var n: usize = 4;
    for (std.enums.values(wt.Field)) |field| {
        const s = settings.get(field);
        buf[n] = @intCast(s.len);
        @memcpy(buf[n + 1 ..][0..s.len], s);
        n += 1 + s.len;
    }
    return buf[0..n];
}

pub fn deserialize(data: []const u8) ?wt.Settings {
    if (data.len < 4 or !std.mem.eql(u8, data[0..4], state_magic)) return null;
    var settings: wt.Settings = .{};
    var n: usize = 4;
    for (std.enums.values(wt.Field)) |field| {
        if (n >= data.len) return null;
        const len = data[n];
        if (len > wt.Settings.maxLen(field) or n + 1 + len > data.len) return null;
        settings.set(field, data[n + 1 ..][0..len]);
        n += 1 + len;
    }
    return settings;
}

test "state round trip" {
    var buf: [max_state_len]u8 = undefined;
    const in = wt.Settings.init("sin(x) + 0.5sin(2x)", "-pi", "pi");
    const out = deserialize(serialize(&in, &buf)).?;
    for (std.enums.values(wt.Field)) |f| try std.testing.expectEqualStrings(in.get(f), out.get(f));
}

test "malformed state is rejected" {
    try std.testing.expect(deserialize("") == null);
    try std.testing.expect(deserialize("XXXX\x01a\x011\x011") == null);
    try std.testing.expect(deserialize("MSY1\x05abc") == null);
}
