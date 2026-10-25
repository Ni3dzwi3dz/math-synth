const std = @import("std");

const plugin_name = "MathSynth";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.os.tag != .macos) {
        std.debug.panic("MathSynth currently builds for macOS only (the editor is Cocoa)", .{});
    }

    const vst3 = b.addTranslateC(.{
        .root_source_file = b.path("vendor/vst3_c_api/vst3_c_api.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();

    const plugin_mod = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "vst3", .module = vst3 }},
    });
    linkCocoa(plugin_mod);

    const lib = b.addLibrary(.{
        .name = plugin_name,
        .linkage = .dynamic,
        .root_module = plugin_mod,
    });

    // MathSynth.vst3/Contents/{Info.plist,PkgInfo,MacOS/MathSynth}
    const contents = plugin_name ++ ".vst3/Contents/";
    const install_bin = b.addInstallFileWithDir(lib.getEmittedBin(), .prefix, contents ++ "MacOS/" ++ plugin_name);
    const install_plist = b.addInstallFileWithDir(b.path("bundle/Info.plist"), .prefix, contents ++ "Info.plist");
    const install_pkginfo = b.addInstallFileWithDir(b.path("bundle/PkgInfo"), .prefix, contents ++ "PkgInfo");
    b.getInstallStep().dependOn(&install_bin.step);
    b.getInstallStep().dependOn(&install_plist.step);
    b.getInstallStep().dependOn(&install_pkginfo.step);

    const bundle_path = b.getInstallPath(.prefix, plugin_name ++ ".vst3");

    // zig build install-plugin: sign ad hoc and copy to the user's VST3 folder.
    const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", bundle_path });
    sign.step.dependOn(b.getInstallStep());
    const home = b.graph.environ_map.get("HOME") orelse "~";
    const vst3_dir = b.pathJoin(&.{ home, "Library/Audio/Plug-Ins/VST3" });
    const copy = b.addSystemCommand(&.{
        "sh", "-c", b.fmt("mkdir -p '{s}' && rm -rf '{s}/{s}.vst3' && cp -R '{s}' '{s}/'", .{
            vst3_dir, vst3_dir, plugin_name, bundle_path, vst3_dir,
        }),
    });
    copy.step.dependOn(&sign.step);
    const install_plugin = b.step("install-plugin", "Build, sign and copy MathSynth.vst3 to ~/Library/Audio/Plug-Ins/VST3");
    install_plugin.dependOn(&copy.step);

    // Minimal VST3 host used to smoke-test the bundle without a DAW.
    const host_mod = b.createModule(.{
        .root_source_file = b.path("tools/host.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
        .imports = &.{
            .{ .name = "vst3", .module = vst3 },
            .{ .name = "objc", .module = b.createModule(.{ .root_source_file = b.path("src/gui/objc.zig") }) },
        },
    });
    linkCocoa(host_mod);
    const host = b.addExecutable(.{ .name = "vst3-host", .root_module = host_mod });
    b.installArtifact(host);

    const run_host = b.addRunArtifact(host);
    run_host.step.dependOn(b.getInstallStep());
    run_host.addArg(bundle_path);
    if (b.args) |args| run_host.addArgs(args);
    const host_step = b.step("host", "Run the test host against the built bundle (pass args after --)");
    host_step.dependOn(&run_host.step);

    const tests = b.addTest(.{ .root_module = plugin_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn linkCocoa(m: *std.Build.Module) void {
    m.linkSystemLibrary("objc", .{});
    m.linkFramework("AppKit", .{});
    m.linkFramework("CoreGraphics", .{});
    m.linkFramework("Foundation", .{});
}
