//! Plugin identity: names, versions and the IDs hosts use to find a plugin.
//!
//! Depends only on `std`, so build.zig can import it too and generate the
//! bundles' Info.plist files and Objective-C class names from the same data
//! the plugin code uses.

const std = @import("std");

pub const Kind = enum { instrument, effect };

pub const Metadata = struct {
    name: []const u8,
    vendor: []const u8,
    /// "major.minor.patch"
    version: []const u8,
    kind: Kind,
    /// Prefix for bundle identifiers: "<prefix>.vst3" and "<prefix>.au".
    bundle_id: []const u8,
    vst3: Vst3,
    au: Au,

    pub const Vst3 = struct {
        /// Class ID as four 32-bit words. Never change it once released:
        /// hosts use it to find the plugin in saved projects.
        class_id: [4]u32,
        /// e.g. "Instrument|Synth" or "Fx|Delay".
        subcategories: []const u8,
    };

    pub const Au = struct {
        /// "aumu" (instrument) or "aufx" (effect).
        type: *const [4]u8,
        subtype: *const [4]u8,
        /// Needs at least one non-lowercase character (all-lowercase codes
        /// are reserved for Apple).
        manufacturer: *const [4]u8,
        /// Name of the exported factory function, listed in Info.plist.
        factory: []const u8,
        description: []const u8,
        tags: []const []const u8 = &.{},
    };

    /// Version as Audio Units encode it: 0xMMMMmmbb.
    pub fn auVersion(comptime m: Metadata) u32 {
        const v = std.SemanticVersion.parse(m.version) catch @compileError("bad version " ++ m.version);
        return @intCast((v.major << 16) | (v.minor << 8) | v.patch);
    }

    /// "0.1.0" -> "0_1_0", for class names.
    pub fn versionTag(comptime m: Metadata) []const u8 {
        comptime {
            var out: [m.version.len]u8 = m.version[0..m.version.len].*;
            for (&out) |*ch| {
                if (ch.* == '.') ch.* = '_';
            }
            const final = out;
            return &final;
        }
    }

    /// Objective-C class names of the AU view factory and its container
    /// view. They share one namespace across everything loaded in a host,
    /// so they include the plugin name and version.
    pub fn auViewFactoryClass(comptime m: Metadata) []const u8 {
        return m.name ++ "AUViewFactory_" ++ comptime m.versionTag();
    }

    pub fn auViewContainerClass(comptime m: Metadata) []const u8 {
        return m.name ++ "AUView_" ++ comptime m.versionTag();
    }
};

pub const BundleFormat = enum { vst3, au };

/// Info.plist for the plugin's .vst3 or .component bundle. The executable is
/// always named after the plugin.
pub fn infoPlist(comptime m: Metadata, comptime format: BundleFormat) []const u8 {
    const id = m.bundle_id ++ switch (format) {
        .vst3 => ".vst3",
        .au => ".au",
    };
    const components = switch (format) {
        .vst3 => "",
        .au => blk: {
            var tags: []const u8 = "";
            for (m.au.tags) |tag| tags = tags ++ "        <string>" ++ tag ++ "</string>\n";
            break :blk
            \\  <key>AudioComponents</key>
            \\  <array>
            \\    <dict>
            \\      <key>type</key>
            \\      <string>
            ++ m.au.type ++
                \\</string>
                \\      <key>subtype</key>
                \\      <string>
            ++ m.au.subtype ++
                \\</string>
                \\      <key>manufacturer</key>
                \\      <string>
            ++ m.au.manufacturer ++
                \\</string>
                \\      <key>name</key>
                \\      <string>
            ++ m.vendor ++ ": " ++ m.name ++
                \\</string>
                \\      <key>description</key>
                \\      <string>
            ++ m.au.description ++
                \\</string>
                \\      <key>version</key>
                \\      <integer>
            ++ std.fmt.comptimePrint("{d}", .{m.auVersion()}) ++
                \\</integer>
                \\      <key>factoryFunction</key>
                \\      <string>
            ++ m.au.factory ++
                \\</string>
                \\      <key>sandboxSafe</key>
                \\      <true/>
                \\      <key>tags</key>
                \\      <array>
                \\
            ++ tags ++
                \\      </array>
                \\    </dict>
                \\  </array>
                \\
            ;
        },
    };
    return
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\<dict>
    \\  <key>CFBundleDevelopmentRegion</key>
    \\  <string>English</string>
    \\  <key>CFBundleExecutable</key>
    \\  <string>
    ++ m.name ++
        \\</string>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>
    ++ id ++
        \\</string>
        \\  <key>CFBundleInfoDictionaryVersion</key>
        \\  <string>6.0</string>
        \\  <key>CFBundleName</key>
        \\  <string>
    ++ m.name ++
        \\</string>
        \\  <key>CFBundlePackageType</key>
        \\  <string>BNDL</string>
        \\  <key>CFBundleShortVersionString</key>
        \\  <string>
    ++ m.version ++
        \\</string>
        \\  <key>CFBundleSignature</key>
        \\  <string>????</string>
        \\  <key>CFBundleVersion</key>
        \\  <string>
    ++ m.version ++
        \\</string>
        \\  <key>NSHighResolutionCapable</key>
        \\  <true/>
        \\
    ++ components ++
        \\</dict>
        \\</plist>
        \\
    ;
}

const test_meta: Metadata = .{
    .name = "Test",
    .vendor = "Acme",
    .version = "1.2.3",
    .kind = .effect,
    .bundle_id = "com.acme.test",
    .vst3 = .{ .class_id = .{ 1, 2, 3, 4 }, .subcategories = "Fx" },
    .au = .{ .type = "aufx", .subtype = "Test", .manufacturer = "Acme", .factory = "TestFactory", .description = "A test", .tags = &.{"Effects"} },
};

test "derived names and versions" {
    try std.testing.expectEqual(@as(u32, 0x010203), comptime test_meta.auVersion());
    try std.testing.expectEqualStrings("TestAUViewFactory_1_2_3", comptime test_meta.auViewFactoryClass());
    try std.testing.expectEqualStrings("TestAUView_1_2_3", comptime test_meta.auViewContainerClass());
}

test "info plists" {
    const au = comptime infoPlist(test_meta, .au);
    try std.testing.expect(std.mem.indexOf(u8, au, "<string>com.acme.test.au</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, au, "<string>Acme: Test</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, au, "<integer>66051</integer>") != null);
    try std.testing.expect(std.mem.indexOf(u8, au, "<string>Effects</string>") != null);
    const vst3 = comptime infoPlist(test_meta, .vst3);
    try std.testing.expect(std.mem.indexOf(u8, vst3, "AudioComponents") == null);
    try std.testing.expect(std.mem.indexOf(u8, vst3, "<string>com.acme.test.vst3</string>") != null);
}
