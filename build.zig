const std = @import("std");

const plugin_name = "MathSynth";
const version = "0_1_0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.os.tag != .macos) {
        std.debug.panic("MathSynth currently builds for macOS only (the editor is Cocoa)", .{});
    }

    const objc_mod = b.createModule(.{ .root_source_file = b.path("src/gui/objc.zig") });
    const home = b.graph.environ_map.get("HOME") orelse "~";
    const plugins_dir = b.pathJoin(&.{ home, "Library/Audio/Plug-Ins" });

    // VST3 ---------------------------------------------------------------------

    const vst3 = b.addTranslateC(.{
        .root_source_file = b.path("vendor/vst3_c_api/vst3_c_api.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();

    const vst3_mod = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "vst3", .module = vst3 }},
    });
    linkCocoa(vst3_mod);
    const vst3_lib = b.addLibrary(.{ .name = plugin_name, .linkage = .dynamic, .root_module = vst3_mod });
    const vst3_bundle = installBundle(b, vst3_lib, plugin_name ++ ".vst3", "bundle/vst3/Info.plist");
    const install_vst3 = b.step("install-vst3", "Build, sign and copy MathSynth.vst3 to ~/Library/Audio/Plug-Ins/VST3");
    install_vst3.dependOn(copyToPlugins(b, vst3_bundle, b.pathJoin(&.{ plugins_dir, "VST3" }), null));

    // Audio Unit ---------------------------------------------------------------

    const au_mod = b.createModule(.{
        .root_source_file = b.path("src/au.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    au_mod.addCSourceFile(.{
        .file = b.path("src/au_view.m"),
        .flags = &.{
            "-fno-objc-arc",
            // Versioned names so two builds loaded in one host don't clash.
            // The factory name must match `view_factory_class` in src/au.zig.
            "-DMATHSYNTH_VIEW_FACTORY=MathSynthAUViewFactory_" ++ version,
            "-DMATHSYNTH_VIEW_CONTAINER=MathSynthAUView_" ++ version,
        },
    });
    linkCocoa(au_mod);
    au_mod.linkFramework("AudioToolbox", .{});
    au_mod.linkFramework("CoreFoundation", .{});
    const au_lib = b.addLibrary(.{ .name = plugin_name ++ "AU", .linkage = .dynamic, .root_module = au_mod });
    const au_bundle = installBundle(b, au_lib, plugin_name ++ ".component", "bundle/au/Info.plist");
    const install_au = b.step("install-au", "Build, sign and copy MathSynth.component to ~/Library/Audio/Plug-Ins/Components");
    // macOS caches the list of Audio Units; restarting the registrar makes
    // hosts and auval see the new build straight away.
    install_au.dependOn(copyToPlugins(b, au_bundle, b.pathJoin(&.{ plugins_dir, "Components" }), "killall -9 AudioComponentRegistrar 2>/dev/null || true"));

    const install_plugin = b.step("install-plugin", "Install both the VST3 and the Audio Unit");
    install_plugin.dependOn(install_vst3);
    install_plugin.dependOn(install_au);

    // Test hosts ---------------------------------------------------------------

    const host = addTool(b, "vst3-host", "tools/host.zig", target, objc_mod, vst3);
    const run_host = b.addRunArtifact(host);
    run_host.step.dependOn(b.getInstallStep());
    run_host.addArg(b.getInstallPath(.prefix, plugin_name ++ ".vst3"));
    if (b.args) |args| run_host.addArgs(args);
    b.step("host", "Run the VST3 test host against the built bundle (pass args after --)").dependOn(&run_host.step);

    const au_host = addTool(b, "au-host", "tools/au_host.zig", target, objc_mod, null);
    au_host.root_module.linkFramework("AudioToolbox", .{});
    au_host.root_module.linkFramework("CoreFoundation", .{});
    const run_au_host = b.addRunArtifact(au_host);
    run_au_host.step.dependOn(b.getInstallStep());
    run_au_host.addArg(b.getInstallPath(.prefix, plugin_name ++ ".component"));
    if (b.args) |args| run_au_host.addArgs(args);
    b.step("au-host", "Run the Audio Unit test host against the built bundle (pass args after --)").dependOn(&run_au_host.step);

    // Tests --------------------------------------------------------------------

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = vst3_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = au_mod })).step);
}

fn linkCocoa(m: *std.Build.Module) void {
    m.linkSystemLibrary("objc", .{});
    m.linkFramework("AppKit", .{});
    m.linkFramework("CoreGraphics", .{});
    m.linkFramework("Foundation", .{});
}

/// Lays out <name>/Contents/{Info.plist,PkgInfo,MacOS/MathSynth} under the
/// install prefix and returns the bundle's path.
fn installBundle(b: *std.Build, lib: *std.Build.Step.Compile, comptime name: []const u8, comptime plist: []const u8) []const u8 {
    const contents = name ++ "/Contents/";
    const steps = [_]*std.Build.Step.InstallFile{
        b.addInstallFileWithDir(lib.getEmittedBin(), .prefix, contents ++ "MacOS/" ++ plugin_name),
        b.addInstallFileWithDir(b.path(plist), .prefix, contents ++ "Info.plist"),
        b.addInstallFileWithDir(b.path("bundle/PkgInfo"), .prefix, contents ++ "PkgInfo"),
    };
    for (steps) |s| b.getInstallStep().dependOn(&s.step);
    return b.getInstallPath(.prefix, name);
}

/// Signs the bundle ad hoc and replaces any copy in `dest_dir`.
fn copyToPlugins(b: *std.Build, bundle_path: []const u8, dest_dir: []const u8, after: ?[]const u8) *std.Build.Step {
    const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", bundle_path });
    sign.step.dependOn(b.getInstallStep());
    const name = std.fs.path.basename(bundle_path);
    const copy = b.addSystemCommand(&.{
        "sh", "-c", b.fmt("mkdir -p '{s}' && rm -rf '{s}/{s}' && cp -R '{s}' '{s}/' && echo 'installed {s}/{s}'{s}{s}", .{
            dest_dir,    dest_dir, name, bundle_path, dest_dir, dest_dir, name,
            if (after != null) " && " else "", after orelse "",
        }),
    });
    copy.step.dependOn(&sign.step);
    return &copy.step;
}

fn addTool(b: *std.Build, name: []const u8, path: []const u8, target: std.Build.ResolvedTarget, objc_mod: *std.Build.Module, vst3: ?*std.Build.Module) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    mod.addImport("objc", objc_mod);
    if (vst3) |m| mod.addImport("vst3", m);
    linkCocoa(mod);
    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    b.installArtifact(exe);
    return exe;
}
