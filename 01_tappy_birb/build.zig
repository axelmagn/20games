const std = @import("std");
const Build = std.Build;
const Module = std.Build.Module;
const Step = std.Build.Step;
const ResolvedTarget = std.Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const LazyPath = std.Build.LazyPath;
const Dependency = std.Build.Dependency;
const sokol = @import("sokol");

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tbirb = AppConfig{
        .name = "tbirb",
        .target = target,
        .optimize = optimize,
        .root_src = b.path("src/tbirb.zig"),
        .shader_srcs = &.{
            "src/shaders/solid.glsl",
        },
    };
    const run_step_inner = try tbirb.build(b);
    b.step("run", "Run tbirb").dependOn(run_step_inner);
}

const AppConfig = struct {
    name: []const u8,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    root_src: LazyPath,
    shader_srcs: []const []const u8,

    fn build(self: AppConfig, b: *Build) !*Step {
        const is_wasm = self.target.result.cpu.arch.isWasm();

        const dep_sokol = b.dependency("sokol", .{
            .target = self.target,
            .optimize = self.optimize,
            // force gl backend on non-web targets
            // DirectX / metal have different transform bounds
            .gl = !is_wasm,
        });

        // var mod_sokol = dep_sokol.module("sokol");
        const dep_zalgebra = b.dependency("zalgebra", .{
            .target = self.target,
            .optimize = self.optimize,
        });

        try patch_sokol_with_fontstash(b, dep_sokol);

        const shader_src_steps: []*Step =
            try b.allocator.alloc(*Step, self.shader_srcs.len);

        for (self.shader_srcs, shader_src_steps) |src, *step| {
            step.* = try createShaderSource(b, src, dep_sokol);
        }

        const mod = b.createModule(.{
            .root_source_file = self.root_src,
            .target = self.target,
            .optimize = self.optimize,
            .imports = &.{
                .{ .name = "sokol", .module = dep_sokol.module("sokol") },
                .{ .name = "zalgebra", .module = dep_zalgebra.module("zalgebra") },
            },
        });
        mod.linkLibrary(dep_sokol.artifact("sokol_clib"));

        if (is_wasm) {
            return self.buildWeb(b, mod, shader_src_steps, dep_sokol);
        } else {
            return self.buildNative(b, mod, shader_src_steps);
        }
    }

    fn buildNative(self: AppConfig, b: *Build, mod: *Module, shdc_steps: []*Step) !*Step {
        const exe = b.addExecutable(.{
            .name = self.name,
            .root_module = mod,
        });
        b.installArtifact(exe);

        for (shdc_steps) |shd| {
            exe.step.dependOn(shd);
        }

        const run = b.addRunArtifact(exe);
        const run_step = b.step(
            b.fmt("run-{s}", .{self.name}),
            b.fmt("Run {s}", .{self.name}),
        );
        run_step.dependOn(&run.step);

        const mod_test = b.addTest(.{
            .root_module = mod,
        });
        const run_test = b.addRunArtifact(mod_test);
        const test_step = b.step(
            b.fmt("test-{s}", .{self.name}),
            b.fmt("Test {s}", .{self.name}),
        );
        test_step.dependOn(&run_test.step);

        return run_step;
    }

    fn buildWeb(
        self: AppConfig,
        b: *Build,
        mod: *Module,
        shdc_steps: []*Step,
        dep_sokol: *Dependency,
    ) !*Step {
        const lib = b.addLibrary(.{
            .name = self.name,
            .root_module = mod,
        });

        // create a build step
        const emsdk = dep_sokol.builder.dependency("emsdk", .{});
        const link_step = try sokol.emLinkStep(b, .{
            .lib_main = lib,
            .target = mod.resolved_target.?,
            .optimize = mod.optimize.?,
            .emsdk = emsdk,
            .use_webgl2 = true,
            .use_emmalloc = true,
            .use_filesystem = false,
            .use_offset_converter = true,
            .shell_file_path = dep_sokol.path("src/sokol/web/shell.html"),
        });
        for (shdc_steps) |shd| {
            link_step.step.dependOn(shd);
        }

        // attach emscripten linker output to default install step
        b.getInstallStep().dependOn(&link_step.step);
        // and a special run step to start the web output
        const run = sokol.emRunStep(b, .{ .name = self.name, .emsdk = emsdk });
        run.step.dependOn(&link_step.step);
        var run_step = b.step(
            b.fmt("run-{s}", .{self.name}),
            b.fmt("Run {s}", .{self.name}),
        );
        run_step.dependOn(&run.step);
        return run_step;
    }

    fn patch_sokol_with_fontstash(b: *Build, dep_sokol: *Dependency) !void {
        const mod_sokol = dep_sokol.module("mod_sokol_clib");

        mod_sokol.addIncludePath(b.path("src/c/sokol_patch/"));
        mod_sokol.addIncludePath(dep_sokol.path("src/sokol/c"));

        const cflags = try extract_sokol_cflags(dep_sokol);
        mod_sokol.addCSourceFile(.{
            .file = b.path("src/c/sokol_patch/fontstash.c"),
            .flags = cflags,
            .language = .c,
        });
        mod_sokol.link_libc = true;
    }

    /// just grab the cflags of the first file we find
    fn extract_sokol_cflags(dep_sokol: *Dependency) ![]const []const u8 {
        const mod_sokol = dep_sokol.module("mod_sokol_clib");
        for (mod_sokol.link_objects.items) |lobj| {
            if (lobj == .c_source_file) {
                return lobj.c_source_file.flags;
            }
        }
        return error.no_csrc_found;
    }
};

fn createShaderModule(
    b: *Build,
    mod_name: []const u8,
    shader_path: []const u8,
    dep_sokol: *Build.Dependency,
) !*Build.Module {
    // extract the sokol module and shdc dependency from sokol dependency
    const mod_sokol = dep_sokol.module("sokol");
    const dep_shdc = dep_sokol.builder.dependency("shdc", .{});

    // call shdc.createModule() helper function, this returns a `!*Build.Module`:
    const mod_shd = try sokol.shdc.createModule(b, mod_name, mod_sokol, .{
        .shdc_dep = dep_shdc,
        .input = shader_path,
        .output = "shader.zig",
        .slang = .{
            .glsl410 = true,
            .glsl300es = true,
            // .hlsl4 = true,
            // .metal_macos = true,
            // .wgsl = true,
        },
    });
    return mod_shd;
}

fn createShaderSource(
    b: *Build,
    shader_path: []const u8,
    dep_sokol: *Build.Dependency,
) !*Build.Step {
    const dep_shdc = dep_sokol.builder.dependency("shdc", .{});
    const shdc_step = try sokol.shdc.createSourceFile(b, .{
        .shdc_dep = dep_shdc,
        .input = shader_path,
        .output = b.fmt("{s}.zig", .{shader_path}),
        .slang = .{
            .glsl410 = true,
            .glsl300es = true,
            .hlsl4 = true,
            .metal_macos = true,
            .wgsl = true,
        },
    });
    return shdc_step;
}
