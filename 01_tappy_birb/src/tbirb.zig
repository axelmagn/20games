//------------------------------------------------------------------------------
//  Tappy Birb
//
//  A small demake of Flappy Bird
//------------------------------------------------------------------------------
const std = @import("std");
const mem = std.mem;
const math = std.math;
const debug = std.debug;
const assert = std.debug.assert;
const heap = std.heap;
const log = std.log;
const sokol = @import("sokol");
const slog = sokol.log;
const sgfx = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const stime = sokol.time;
const sdtx = sokol.debugtext;
const za = @import("zalgebra");
const lm32 = @import("zlm").as(f32);
const shd_solid = @import("shaders/solid.glsl.zig");
const fons = @import("fontstash.zig");

/// root global for app state
var main_app: *App = undefined;

var main_app_config = AppConfig{};

const AppConfig = struct {
    tile_size: i32 = 8,
    aspect_width: i32 = 10,
    aspect_height: i32 = 16,
    aspect_factor: i32 = 6,

    player: struct {
        size: f32 = 32,
        x0: f32 = 0.3,
        y0: f32 = 0.6,
        acc: f32 = -256,
        color: Color = Color.gray3,
    } = .{},

    ground: struct {
        height: f32 = 64,
        color: Color = Color.gray2,
    } = .{},

    wall: struct {
        width: f32 = 64,
        speed: f32 = -256,
        color: Color = Color.gray1,
    } = .{},

    fn window_width(self: AppConfig) i32 {
        return self.tile_size * self.aspect_width * self.aspect_factor;
    }

    fn window_height(self: AppConfig) i32 {
        return self.tile_size * self.aspect_height * self.aspect_factor;
    }
};

const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    fn new(r: f32, g: f32, b: f32, a: f32) Color {
        return Color{
            .r = r,
            .g = g,
            .b = b,
            .a = a,
        };
    }

    fn to(self: *const Color, T: type) T {
        return switch (T) {
            sgfx.Color => sgfx.Color{
                .r = self.r,
                .g = self.g,
                .b = self.b,
                .a = self.a,
            },
            za.Vec4 => za.Vec4.new(self.r, self.g, self.b, self.a),
            else => @compileError("unexpected color type: " ++ @typeName(T)),
        };
    }

    const white = Color.new(1.0, 1.0, 1.0, 1.0);
    const black = Color.new(0.0, 0.0, 0.0, 1.0);

    const gray0 = Color.new(0.2, 0.2, 0.2, 1.0);
    const gray1 = Color.new(0.4, 0.4, 0.4, 1.0);
    const gray2 = Color.new(0.6, 0.6, 0.6, 1.0);
    const gray3 = Color.new(0.8, 0.8, 0.8, 1.0);
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

    renderer: Renderer = .{},

    /// window information
    win: struct {
        // 16:9
        // width: i32 = 540,
        // 16:10
        width: i32 = 600,
        height: i32 = 960,
    } = .{},

    pub fn init(self: *App, gpa: mem.Allocator, app_config: AppConfig) void {
        self.gpa = gpa;

        // TODO: arena allocator

        self.win.width = app_config.window_width();
        self.win.height = app_config.window_height();

        stime.setup();
        self.game.init(app_config);
        self.renderer.init();
    }

    pub fn frame(self: *App) void {
        self.game.tick();
        self.renderer.draw(self.game);
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
        const win_width = app_config.window_width();
        const win_height = app_config.window_height();
        const win_widthf = ncast(f32, win_width);
        const win_heightf = ncast(f32, win_height);

        // set up camera based on window size
        // TODO: decouple canvas from window
        self.camera.position = za.Vec2.new(0, 0);
        self.camera.size = za.Vec2.new(win_widthf, win_heightf);

        // create some test entities at the center of the screen
        self.entities[0] = createPlayer(app_config);
        self.entities[1] = createGround(app_config);
        // TODO: dynamically spawn walls
        self.entities[2] = createBottomWall(app_config, 256);
        self.entities[3] = createTopWall(app_config, 256);
    }

    pub fn tick(self: *Game) void {
        const dt = sapp.frameDuration();

        for (0..self.entities.len) |i| {
            if (self.entities[i] == null) continue;
            var entity: *Entity = &(self.entities[i].?);
            entity.applyKinematics(dt);
        }
    }

    pub fn createPlayer(app_config: AppConfig) Entity {
        const size = app_config.player.size;
        const hsize = app_config.player.size / 2;
        const x = app_config.player.x0;
        const y = app_config.player.y0;
        const w = ncast(f32, app_config.window_width());
        const h = ncast(f32, app_config.window_height());

        return Entity{
            .position = za.Vec2.new(w * x - hsize, h * y - hsize),
            .acceleration = za.Vec2.new(0, app_config.player.acc),
            .size = za.Vec2.new(size, size),
            .z_layer = 30,
            .color_quad = .{
                .color = app_config.player.color,
            },
            .debug_text = .{
                .text = "birb",
            },
        };
    }

    /// create the ground obstacle
    pub fn createGround(app_config: AppConfig) Entity {
        const w = ncast(f32, app_config.window_width());
        const h = app_config.ground.height;

        const x = 0;
        const y = 0;

        return Entity{
            .position = za.Vec2.new(x, y),
            .size = za.Vec2.new(w, h),
            .z_layer = 20,
            .color_quad = .{
                .color = app_config.ground.color,
            },
        };
    }

    /// create a wall obstacle offscreen to the right, attached to the bottom of the screen
    pub fn createBottomWall(app_config: AppConfig, height: f32) Entity {
        const x = ncast(f32, app_config.window_width());
        return Entity{
            .position = za.Vec2.new(x, 0),
            .size = za.Vec2.new(app_config.wall.width, height),
            .velocity = za.Vec2.new(app_config.wall.speed, 0),
            .z_layer = 10,
            .color_quad = .{
                .color = app_config.wall.color,
            },
        };
    }

    /// create a wall obstacle offscreen to the right, attached to the top of the screen
    pub fn createTopWall(app_config: AppConfig, height: f32) Entity {
        const x = ncast(f32, app_config.window_width());
        const y = ncast(f32, app_config.window_height()) - height;
        return Entity{
            .position = za.Vec2.new(x, y),
            .size = za.Vec2.new(app_config.wall.width, height),
            .velocity = za.Vec2.new(app_config.wall.speed, 0),
            .z_layer = 10,
            .color_quad = .{
                .color = app_config.wall.color,
            },
        };
    }
};

const Camera = struct {
    position: za.Vec2 = za.Vec2.zero(),
    size: za.Vec2,

    fn viewTransform(self: Camera) za.Mat4 {
        return za.orthographic(
            self.position.x(),
            self.position.x() + self.size.x(),
            self.position.y(),
            self.position.y() + self.size.y(),
            -128,
            128,
        );
    }
};

const Entity = struct {
    position: za.Vec2 = za.Vec2.zero(),
    velocity: za.Vec2 = za.Vec2.zero(),
    acceleration: za.Vec2 = za.Vec2.zero(),
    size: za.Vec2 = za.Vec2.zero(),
    // higher on top
    z_layer: i8 = 0,
    color_quad: ?ColorQuad = null,
    debug_text: ?DebugText = null,

    pub fn applyKinematics(self: *Entity, dt: f64) void {
        const dtf = ncast(f32, dt);
        const dtv = za.Vec2.set(dtf);
        const dx = self.velocity.mul(dtv);
        self.position = self.position.add(dx);
        const dv = self.acceleration.mul(dtv);
        self.velocity = self.velocity.add(dv);
    }

    pub fn modelTransform(self: Entity) za.Mat4 {
        assert(self.color_quad != null);
        var model_xform = za.Mat4.identity();
        model_xform = model_xform.scale(za.Vec3.new(
            self.size.x(),
            self.size.y(),
            1,
        ));
        model_xform = model_xform.translate(za.Vec3.new(
            self.position.x(),
            self.position.y(),
            ncast(f32, self.z_layer),
        ));
        return model_xform;
    }

    pub fn debugTextTransform(self: Entity) za.Mat4 {
        assert(self.color_quad != null);
        var model_xform = za.Mat4.identity();
        model_xform = model_xform.translate(za.Vec3.new(
            self.position.x(),
            self.position.y(),
            ncast(f32, self.z_layer),
        ));
        return model_xform;
    }
};

/// a component for entities that correspond to a drawable quad
const ColorQuad = struct {
    color: Color,
};

const DebugText = struct {
    text: []const u8,
    font_idx: u8 = 0,
    grid_pos: za.Vec2 = za.Vec2.zero(),
    // alpha is ignored
    color: Color = Color.new(1, 1, 1, 1),
    offset: za.Vec2 = za.Vec2.zero(),
};

const Renderer = struct {
    color_quad_pipe: ColorQuadPipeline = .{},
    debug_text_pipe: DebugTextPipeline = .{},
    clear_color: Color = Color.gray0,

    fn init(self: *Renderer) void {
        sgfx.setup(.{
            .environment = sglue.environment(),
            .logger = .{ .func = slog.func },
        });

        self.color_quad_pipe.init();
        DebugTextPipeline.init();
    }

    fn draw(self: Renderer, game: Game) void {
        // DebugTextPipeline.hello_world();
        self.debug_text_pipe.resetCanvas();

        // begin pass
        var pass_action: sgfx.PassAction = .{};
        pass_action.colors[0] = .{
            .load_action = .CLEAR,
            .clear_value = self.clear_color.to(sgfx.Color),
        };
        sgfx.beginPass(.{ .action = pass_action, .swapchain = sglue.swapchain() });

        // draw quads
        for (game.entities) |entity_opt| {
            const entity = entity_opt orelse continue;
            self.color_quad_pipe.draw_quad(entity, game.camera);
            self.debug_text_pipe.print(entity, game.camera);
        }

        // draw debug text
        sdtx.draw();

        // finish and commit pass
        sgfx.endPass();
        sgfx.commit();
    }
};

const ColorQuadPipeline = struct {
    pipe: sgfx.Pipeline = .{},
    bind: sgfx.Bindings = .{},

    /// vertex buffer bindings.
    const VB_quad = 0;

    /// quad mesh, with bottom left corner at origin
    const quad_verts = [_]f32{
        0, 0,
        0, 1,
        1, 1,
        1, 0,
    };
    const quad_idxs = [_]u16{
        0, 1, 2,
        2, 3, 0,
    };

    fn init(self: *ColorQuadPipeline) void {
        // init quad buffers on gpu
        self.bind.vertex_buffers[0] = sgfx.makeBuffer(.{
            .usage = .{ .vertex_buffer = true, .immutable = true },
            .data = sgfx.asRange(&quad_verts),
        });
        self.bind.index_buffer = sgfx.makeBuffer(.{
            .usage = .{ .index_buffer = true, .immutable = true },
            .data = sgfx.asRange(&quad_idxs),
        });

        // shader pipeline
        const backend = sgfx.queryBackend();
        const shader = sgfx.makeShader(shd_solid.solidShaderDesc(backend));
        var vert_layout = sgfx.VertexLayoutState{};
        vert_layout.attrs[shd_solid.ATTR_solid_position_in].format = .FLOAT2;
        self.pipe = sgfx.makePipeline(.{
            .shader = shader,
            .layout = vert_layout,
            .index_type = .UINT16,
            .depth = .{
                .compare = .LESS_EQUAL,
                .write_enabled = true,
            },
            .cull_mode = .NONE,
        });
    }

    fn draw_quad(
        self: ColorQuadPipeline,
        entity: Entity,
        camera: Camera,
    ) void {
        // prepare uniforms
        const vs_params = shd_solid.VsParams{
            .model = entity.modelTransform(),
            .view = camera.viewTransform(),
        };
        const fs_params = shd_solid.FsParams{
            .color = entity.color_quad.?.color.to(za.Vec4).toArray(),
        };

        // draw call
        sgfx.applyPipeline(self.pipe);
        sgfx.applyBindings(self.bind);
        sgfx.applyUniforms(shd_solid.UB_vs_params, sgfx.asRange(&vs_params));
        sgfx.applyUniforms(shd_solid.UB_fs_params, sgfx.asRange(&fs_params));
        sgfx.draw(0, quad_idxs.len, 1);
    }
};

const DebugTextPipeline = struct {
    // font scale in pixels
    font_px: f32 = 16,

    const kc854 = 0;
    const c64 = 1;
    const oric = 2;

    pub fn init() void {
        sdtx.setup(.{
            .fonts = blk: {
                var f: [8]sdtx.FontDesc = @splat(.{});
                f[kc854] = sdtx.fontKc854();
                f[c64] = sdtx.fontC64();
                f[oric] = sdtx.fontOric();
                break :blk f;
            },
            .logger = .{ .func = slog.func },
        });
    }

    pub fn hello_world() void {
        const font_scale: f32 = 8.0 / 16.0;
        const w = sapp.widthf() * font_scale;
        const h = sapp.heightf() * font_scale;
        sdtx.canvas(w, h);
        sdtx.origin(0, 0);

        sdtx.font(c64);
        sdtx.color3b(200, 100, 200);

        for (0..256) |i| {
            const y: f32 = ncast(f32, i);
            sdtx.pos(3, y);
            sdtx.print("{d}", .{i});
        }

        // sdtx.print("Hello World!", .{});
    }

    pub fn resetCanvas(self: DebugTextPipeline) void {
        // sdtx.canvas(1, 1);
        const font_scale = 8 / self.font_px;
        const canvas_w = sapp.widthf() * font_scale;
        const canvas_h = sapp.heightf() * font_scale;
        sdtx.canvas(canvas_w, canvas_h);
        sdtx.origin(0, 0);
    }

    pub fn print(self: DebugTextPipeline, entity: Entity, camera: Camera) void {
        const dtext = entity.debug_text orelse return;
        sdtx.font(dtext.font_idx);
        sdtx.color3f(
            dtext.color.r,
            dtext.color.g,
            dtext.color.b,
        );

        const text_xform = entity.debugTextTransform();
        const view_xform = camera.viewTransform();
        const clip_xform = za.orthographic(-3, 1, 3, -1, -1, 1);
        var pos = za.Vec4.new(0, 0, 0, 1);
        pos = text_xform.mulByVec4(pos);
        pos = view_xform.mulByVec4(pos);
        pos = clip_xform.mulByVec4(pos);

        const font_scale = 8 / self.font_px;
        const canvas_w = sapp.widthf() * font_scale;
        const canvas_h = sapp.heightf() * font_scale;
        pos.data[0] *= canvas_w / 8;
        pos.data[1] *= canvas_h / 8;

        sdtx.pos(
            // convert from grid coords to px coords
            pos.x(),
            pos.y(),
        );
        sdtx.print("{s}", .{dtext.text});
    }
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
