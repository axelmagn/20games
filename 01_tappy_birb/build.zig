const std = @import("std");
const zigglgen = @import("zigglgen");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lto = optimize != .Debug;

    const app_mod = b.createModule(.{
        // .root_source_file = b.path("tbirb.zig"),
        .root_source_file = b.path("src/rgfw_quad.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // const sdl_dep = b.dependency("sdl", .{
    //     .target = target,
    //     .optimize = optimize,
    //     .lto = lto,
    // });
    // const sdl_lib = sdl_dep.artifact("SDL3");
    // app_mod.linkLibrary(sdl_lib);

    app_mod.addIncludePath(b.path("include"));
    app_mod.addCSourceFile(.{ .file = b.path("src/rgfw.c") });
    app_mod.linkSystemLibrary("opengl32", .{});
    app_mod.linkSystemLibrary("gdi32", .{});

    const gl_mod = zigglgen.generateBindingsModule(b, .{
        .api = .gl,
        // .version = .@"4.1", // The last OpenGL version supported on macOS
        .version = .@"3.3", // for rgfw_quad
        .profile = .core,
    });
    app_mod.addImport("gl", gl_mod);

    const app_exe = b.addExecutable(.{
        .name = "tbirb",
        .root_module = app_mod,
    });
    app_exe.want_lto = lto;

    b.installArtifact(app_exe);

    const run = b.step("run", "Run the app");

    const run_app = b.addRunArtifact(app_exe);
    if (b.args) |args| run_app.addArgs(args);
    run_app.step.dependOn(b.getInstallStep());

    run.dependOn(&run_app.step);
}
