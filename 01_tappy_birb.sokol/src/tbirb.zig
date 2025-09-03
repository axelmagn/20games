//------------------------------------------------------------------------------
//  Tappy Birb
//
//  A small demake of Flappy Bird
//------------------------------------------------------------------------------
const std = @import("std");
const mem = std.mem;
const math = std.math;
const debug = std.debug;
const heap = std.heap;
const sokol = @import("sokol");
const slog = sokol.log;
const sgfx = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const stime = sokol.time;
const za = @import("zalgebra");
const shd_solid = @import("shaders/solid.glsl.zig");

/// root global for app state
var main_app: *App = undefined;

var main_app_config = AppConfig{};

const AppConfig = struct {
    tile_size: i32 = 8,
    aspect_width: i32 = 10,
    aspect_height: i32 = 16,
    aspect_factor: i32 = 4,

    fn window_width(self: AppConfig) i32 {
        return self.tile_size * self.aspect_width * self.aspect_factor;
    }

    fn window_height(self: AppConfig) i32 {
        return self.tile_size * self.aspect_height * self.aspect_factor;
    }
};

pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .width = main_app_config.window_width(),
        .height = main_app_config.window_height(),
        .sample_count = 4,
        .icon = .{ .sokol_default = true },
        .window_title = "cube.zig",
        .logger = .{ .func = slog.func },
    });
}

const Error = error{} || mem.Allocator.Error;

export fn init() void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    main_app = allocator.create(App) catch |err| {
        const trace = @errorReturnTrace().?.*;
        debug.dumpStackTrace(trace);
        debug.panic("initialization error: {any}", .{err});
    };
    main_app.* = .{};
    main_app.init(allocator, main_app_config);
}
export fn frame() void {
    main_app.frame();
}
export fn cleanup() void {
    main_app.cleanup();
}

pub const App = struct {
    /// general purpose allocator
    gpa: mem.Allocator = undefined,
    arena: mem.Allocator = undefined,

    /// game state
    game: Game = .{},

    /// graphics subsystems
    gfx: struct {
        pipe: sgfx.Pipeline = .{},
        bind: sgfx.Bindings = .{},
        pass_action: sgfx.PassAction = .{},
        view: za.Mat4 = undefined,

        // vertex buffer bindings
        const VB_quad = 0;
    } = .{},
    /// window information
    win: struct {
        // go for 16:9 aspect ratios
        width: i32 = 540,
        height: i32 = 960,
    } = .{},

    pub fn init(self: *App, gpa: mem.Allocator, app_config: AppConfig) void {
        self.gpa = gpa;

        // TODO: arena allocator

        self.win.width = app_config.window_width();
        self.win.height = app_config.window_height();

        stime.setup();
        sgfx.setup(.{
            .environment = sglue.environment(),
            .logger = .{ .func = slog.func },
        });

        // quad vertex buffer
        self.gfx.bind.vertex_buffers[0] = sgfx.makeBuffer(.{
            .data = sgfx.asRange(&[_]f32{
                // positions
                -0.5, 0.5, // top left
                0.5, 0.5, // top right
                0.5, -0.5, // bottom right
                -0.5, -0.5, // bottom left
                // -1.0, 1.0, // top left
                // 1.0, 1.0, // top right
                // 1.0, -1.0, // bottom right
                // -1.0, -1.0, // bottom left
            }),
        });

        // quad index buffer
        self.gfx.bind.index_buffer = sgfx.makeBuffer(.{
            .usage = .{ .index_buffer = true },
            .data = sgfx.asRange(&[_]u16{
                0, 1, 2,
                2, 3, 0,
            }),
        });

        // shader pipeline
        const backend = sgfx.queryBackend();
        const shader = sgfx.makeShader(shd_solid.solidShaderDesc(backend));
        var vert_layout = sgfx.VertexLayoutState{};
        vert_layout.attrs[shd_solid.ATTR_solid_position_in].format = .FLOAT2;
        self.gfx.pipe = sgfx.makePipeline(.{
            .shader = shader,
            .layout = vert_layout,
            .index_type = .UINT16,
            .depth = .{
                .compare = .LESS_EQUAL,
                .write_enabled = true,
            },
            // TODO: revert culling when quads render
            // .cull_mode = .BACK,
            .cull_mode = .NONE,
        });

        // framebuffer clear color
        self.gfx.pass_action.colors[0] = .{
            .load_action = .CLEAR,
            // TODO: real colors
            .clear_value = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1 },
        };
    }

    pub fn frame(self: *App) void {
        // prep draw parameters
        const t: f32 = @floatCast(stime.sec(stime.now()));
        const model_xform = za.Mat4.identity().scale(
            za.Vec3.new(200 + math.cos(t) * 100, 200 + math.sin(t) * 100, 1),
        ).translate(
            za.Vec3.new(
                ncast(f32, self.win.width) / 2 + math.cos(t) * 100,
                ncast(f32, self.win.height) / 2 + math.sin(t) * 100,
                0,
            ),
        );
        const vs_params = shd_solid.VsParams{
            .model = model_xform,
            .view = za.orthographic(
                0,
                ncast(f32, self.win.width),
                0,
                ncast(f32, self.win.height),
                -1,
                1,
            ),
        };
        const fs_params = shd_solid.FsParams{
            .color = za.Vec4.new(0.9, 0.9, 0.9, 1.0).data,
        };

        // draw call
        sgfx.beginPass(.{
            .action = self.gfx.pass_action,
            .swapchain = sglue.swapchain(),
        });
        sgfx.applyPipeline(self.gfx.pipe);
        sgfx.applyBindings(self.gfx.bind);
        sgfx.applyUniforms(shd_solid.UB_vs_params, sgfx.asRange(&vs_params));
        sgfx.applyUniforms(shd_solid.UB_fs_params, sgfx.asRange(&fs_params));
        sgfx.draw(0, 6, 1);
        sgfx.endPass();
        sgfx.commit();
    }

    pub fn cleanup(_: *App) void {
        sgfx.shutdown();
    }
};

const Game = struct {
    camera: Camera = undefined,
    entities: [max_entities]?Entity = .{null} ** max_entities,

    const max_entities = 256;

    pub fn init(self: *Game, app_config: AppConfig) void {
        self.camera.size = za.Vec2.new(
            app_config.window_width(),
            app_config.window_height(),
        );
    }
};

const Camera = struct {
    position: za.Vec2 = za.Vec2.zero(),
    size: za.Vec2,
};

const Entity = struct {
    position: za.Vec2,
    z_layer: u8,
    color_quad: ?ColorQuad,
};

/// a component for entities that correspond to a drawable quad
const ColorQuad = struct {
    size: za.Vec2,
    color: za.Vec4,
};

const ColorQuadPipeline = struct {
    pipe: sgfx.Pipeline = .{},
    bind: sgfx.Bindings = .{},

    // vertex buffer bindings
    const VB_quad = 0;

    const quad_verts = [_]f32{
        0, 0,
        0, 1,
        1, 1,
        1, 0,
    };

    fn init() 
};

/// cast a numeric type to another
pub fn ncast(T: type, x: anytype) T {
    const in_tinfo = @typeInfo(@TypeOf(x));
    const out_tinfo = @typeInfo(T);

    if (out_tinfo == .int and in_tinfo == .int) {
        return @intCast(x);
    }
    if (out_tinfo == .float and in_tinfo == .float) {
        return @floatCast(x);
    }
    if (out_tinfo == .int and in_tinfo == .float) {
        return @intFromFloat(x);
    }
    if (out_tinfo == .float and in_tinfo == .int) {
        return @floatFromInt(x);
    }
    @compileError("unhandled numeric type conversion");
}
