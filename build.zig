const std = @import("std");
const meta = @import("src/common/meta.zig");

/// Every plugin in the repository: its folder under src/ and its metadata.
/// To add one, create src/<dir>/ with meta.zig, plugin.zig, vst3.zig and
/// au.zig (see src/mathsynth) and list it here.
const plugins = .{
    .{ .dir = "mathsynth", .meta = @import("src/mathsynth/meta.zig").metadata(meta.Metadata) },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.os.tag != .macos) {
        std.debug.panic("plugins currently build for macOS only (the editors are Cocoa)", .{});
    }

    const home = b.graph.environ_map.get("HOME") orelse "~";
    const plugins_dir = b.pathJoin(&.{ home, "Library/Audio/Plug-Ins" });

    const vst3_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/vst3_c_api/vst3_c_api.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();

    const common = b.createModule(.{
        .root_source_file = b.path("src/common/common.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "vst3", .module = vst3_c }},
    });
    linkFrameworks(common);

    const install_vst3 = b.step("install-vst3", "Build, sign and copy every plugin's .vst3 to ~/Library/Audio/Plug-Ins/VST3");
    const install_au = b.step("install-au", "Build, sign and copy every plugin's .component to ~/Library/Audio/Plug-Ins/Components");
    const install_all = b.step("install-plugin", "Install every plugin in both formats");
    install_all.dependOn(install_vst3);
    install_all.dependOn(install_au);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "common-test", .root_module = common })).step);

    // -Dplugin selects which plugin the test hosts run against.
    const selected = b.option([]const u8, "plugin", "Plugin for the host/au-host/au-oop steps (folder under src/, default: first)") orelse plugins[0].dir;
    var host_vst3_bundle: ?[]const u8 = null;
    var host_au_bundle: ?[]const u8 = null;

    inline for (plugins) |p| {
        const m = p.meta;
        const src = "src/" ++ p.dir ++ "/";

        // VST3
        const vst3_mod = b.createModule(.{
            .root_source_file = b.path(src ++ "vst3.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "common", .module = common }},
        });
        const vst3_lib = b.addLibrary(.{ .name = m.name, .linkage = .dynamic, .root_module = vst3_mod });
        const vst3_bundle = installBundle(b, vst3_lib, m.name, m.name ++ ".vst3", comptime meta.infoPlist(m, .vst3));

        // Audio Unit: the view factory is compiled per plugin, with class
        // names that include its name and version.
        const au_mod = b.createModule(.{
            .root_source_file = b.path(src ++ "au.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "common", .module = common }},
        });
        au_mod.addCSourceFile(.{
            .file = b.path("src/common/au_view.m"),
            .flags = &.{
                "-fno-objc-arc",
                "-DPLUGIN_VIEW_FACTORY=" ++ comptime m.auViewFactoryClass(),
                "-DPLUGIN_VIEW_CONTAINER=" ++ comptime m.auViewContainerClass(),
                "-DPLUGIN_NAME=\"" ++ m.name ++ "\"",
            },
        });
        linkFrameworks(au_mod);
        const au_lib = b.addLibrary(.{ .name = m.name ++ "AU", .linkage = .dynamic, .root_module = au_mod });
        const au_bundle = installBundle(b, au_lib, m.name, m.name ++ ".component", comptime meta.infoPlist(m, .au));

        const vst3_copy = copyToPlugins(b, vst3_bundle, b.pathJoin(&.{ plugins_dir, "VST3" }), null);
        // macOS caches the list of Audio Units; restarting the registrar
        // makes hosts and auval see the new build straight away.
        const au_copy = copyToPlugins(b, au_bundle, b.pathJoin(&.{ plugins_dir, "Components" }), "killall -9 AudioComponentRegistrar 2>/dev/null || true");
        install_vst3.dependOn(vst3_copy);
        install_au.dependOn(au_copy);
        const install_one = b.step("install-" ++ p.dir, "Install " ++ m.name ++ " in both formats");
        install_one.dependOn(vst3_copy);
        install_one.dependOn(au_copy);

        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = p.dir ++ "-test", .root_module = vst3_mod })).step);

        if (std.mem.eql(u8, selected, p.dir)) {
            host_vst3_bundle = vst3_bundle;
            host_au_bundle = au_bundle;
        }
    }

    // Test hosts ---------------------------------------------------------------

    const vst3_bundle = host_vst3_bundle orelse std.debug.panic("-Dplugin={s}: no such plugin", .{selected});
    const au_bundle = host_au_bundle.?;
    const objc_mod = b.createModule(.{ .root_source_file = b.path("src/common/gui/objc.zig") });

    const host = addTool(b, "vst3-host", "tools/host.zig", target, objc_mod, vst3_c);
    const run_host = b.addRunArtifact(host);
    run_host.step.dependOn(b.getInstallStep());
    run_host.addArg(vst3_bundle);
    if (b.args) |args| run_host.addArgs(args);
    b.step("host", "Run the VST3 test host against the built bundle (pass args after --)").dependOn(&run_host.step);

    const au_host = addTool(b, "au-host", "tools/au_host.zig", target, objc_mod, null);
    const run_au_host = b.addRunArtifact(au_host);
    run_au_host.step.dependOn(b.getInstallStep());
    run_au_host.addArg(au_bundle);
    if (b.args) |args| run_au_host.addArgs(args);
    b.step("au-host", "Run the Audio Unit test host against the built bundle (pass args after --)").dependOn(&run_au_host.step);

    // Loads the *installed* AU out of process, like GarageBand, and asks for
    // its editor. Run `zig build install-au` first.
    const oop_mod = b.createModule(.{ .target = target, .optimize = .Debug, .link_libc = true });
    oop_mod.addCSourceFile(.{ .file = b.path("tools/au_oop.m"), .flags = &.{"-fobjc-arc"} });
    for ([_][]const u8{ "AppKit", "AudioToolbox", "CoreAudioKit", "AVFoundation" }) |f| oop_mod.linkFramework(f, .{});
    const au_oop = b.addExecutable(.{ .name = "au-oop", .root_module = oop_mod });
    b.installArtifact(au_oop);
    const run_au_oop = b.addRunArtifact(au_oop);
    run_au_oop.step.dependOn(b.getInstallStep());
    run_au_oop.addArg(au_bundle);
    if (b.args) |args| run_au_oop.addArgs(args);
    b.step("au-oop", "Open the installed Audio Unit out of process and request its editor").dependOn(&run_au_oop.step);
}

fn linkFrameworks(m: *std.Build.Module) void {
    m.linkSystemLibrary("objc", .{});
    for ([_][]const u8{ "AppKit", "CoreGraphics", "Foundation", "AudioToolbox", "CoreFoundation" }) |f| m.linkFramework(f, .{});
}

/// Lays out <bundle>/Contents/{Info.plist,PkgInfo,MacOS/<executable>} under
/// the install prefix and returns the bundle's path.
fn installBundle(b: *std.Build, lib: *std.Build.Step.Compile, executable: []const u8, bundle: []const u8, info_plist: []const u8) []const u8 {
    const files = b.addWriteFiles();
    const plist = files.add("Info.plist", info_plist);
    const pkginfo = files.add("PkgInfo", "BNDL????");
    const contents = b.fmt("{s}/Contents/", .{bundle});
    const steps = [_]*std.Build.Step.InstallFile{
        b.addInstallFileWithDir(lib.getEmittedBin(), .prefix, b.fmt("{s}MacOS/{s}", .{ contents, executable })),
        b.addInstallFileWithDir(plist, .prefix, b.fmt("{s}Info.plist", .{contents})),
        b.addInstallFileWithDir(pkginfo, .prefix, b.fmt("{s}PkgInfo", .{contents})),
    };
    for (steps) |s| b.getInstallStep().dependOn(&s.step);
    return b.getInstallPath(.prefix, bundle);
}

/// Signs the bundle ad hoc and replaces any copy in `dest_dir`.
fn copyToPlugins(b: *std.Build, bundle_path: []const u8, dest_dir: []const u8, after: ?[]const u8) *std.Build.Step {
    const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", bundle_path });
    sign.step.dependOn(b.getInstallStep());
    const name = std.fs.path.basename(bundle_path);
    const copy = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt("mkdir -p '{s}' && rm -rf '{s}/{s}' && cp -R '{s}' '{s}/' && echo 'installed {s}/{s}'{s}{s}", .{
            dest_dir,                          dest_dir,        name, bundle_path, dest_dir, dest_dir, name,
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
    linkFrameworks(mod);
    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    b.installArtifact(exe);
    return exe;
}
