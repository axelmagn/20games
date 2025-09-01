const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const app_mod = b.createModule(.{
        .root_source_file = b.path("rgfw.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app_mod.addIncludePath(b.path("."));
    app_mod.addCSourceFile(.{ .file = b.path("RGFW.c") });
    app_mod.linkSystemLibrary("opengl32", .{});
    app_mod.linkSystemLibrary("gdi32", .{});

    const app_exe = b.addExecutable(.{
        .name = "rgfw_impl",
        .root_module = app_mod,
    });

    b.installArtifact(app_exe);
}
