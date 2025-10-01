//------------------------------------------------------------------------------
//  Tappy Birb
//
//  A small demake of Flappy Bird
//------------------------------------------------------------------------------
const std = @import("std");
const builtin = @import("builtin");
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

pub fn main() void {
    sapp.run(.{
        .init_cb = sInit,
        .frame_cb = sFrame,
        .event_cb = sEvent,
        .cleanup_cb = sCleanup,
        .width = main_app_config.windowWidth(),
        .height = main_app_config.windowHeight(),
        .sample_count = 4,
        .icon = .{ .sokol_default = true },
        .window_title = "cube.zig",
        .logger = .{ .func = slog.func },
    });
}

const Error = error{} || mem.Allocator.Error;

export fn sInit() void {
    var allocator = switch (builtin.target.cpu.arch) {
        .wasm32, .wasm64 => heap.c_allocator,
        else => blk: {
            var gpa = heap.GeneralPurposeAllocator(.{}){};
            break :blk gpa.allocator();
        },
    };
    main_app = allocator.create(App) catch |err| {
        const trace = @errorReturnTrace().?.*;
        debug.dumpStackTrace(trace);
        debug.panic("initialization error: {any}", .{err});
    };
    main_app.* = .{};
    main_app.init(allocator, main_app_config);
}

export fn sFrame() void {
    main_app.frame();
}

export fn sEvent(sev: [*c]const sapp.Event) void {
    const ev = InputEvent.from(sev[0]);
    main_app.event(ev);
}

export fn sCleanup() void {
    main_app.cleanup();
}

pub const App = struct {
    /// general purpose allocator
    gpa: mem.Allocator = undefined,
    arena: mem.Allocator = undefined,

    config: AppConfig = .{},

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
        self.config = app_config;

        // TODO: arena allocator

        self.win.width = app_config.windowWidth();
        self.win.height = app_config.windowHeight();

        stime.setup();
        self.game.init(app_config);
        self.renderer.init();
    }

    pub fn frame(self: *App) void {
        self.game.tick();
        self.renderer.draw(self.game);
    }

    pub fn event(self: *App, ev: InputEvent) void {
        self.game.handleInputEvent(ev);
    }

    pub fn cleanup(_: *App) void {
        sgfx.shutdown();
    }
};

const AppConfig = struct {
    tile_size: i32 = 8,
    aspect_width: i32 = 10,
    aspect_height: i32 = 16,
    aspect_factor: i32 = 6,

    player: struct {
        size: f32 = 32,
        x0: f32 = 0.3,
        y0: f32 = 0.6,
        acc: f32 = -512,
        color: Color = Color.gray3,
        jump_vel: f32 = 256,
    } = .{},

    ground: struct {
        height: f32 = 64,
        color: Color = Color.gray2,
    } = .{},

    wall: struct {
        width: f32 = 64,
        speed: f32 = -256,
        color: Color = Color.gray1,
        // half-size of the hole in the pipes
        hole_hsize: f32 = 96,
        spawn_interval: f64 = 1.5,
        spawn_padding: f32 = 128,
    } = .{},

    fn windowWidth(self: AppConfig) i32 {
        return self.tile_size * self.aspect_width * self.aspect_factor;
    }

    fn windowWidthF(self: AppConfig) f32 {
        return ncast(f32, self.windowWidth());
    }

    fn windowHeight(self: AppConfig) i32 {
        return self.tile_size * self.aspect_height * self.aspect_factor;
    }

    fn windowHeightF(self: AppConfig) f32 {
        return ncast(f32, self.windowHeight());
    }
};

const Game = struct {
    camera: Camera = undefined,
    entities: [max_entities]?Entity = .{null} ** max_entities,
    events: RingBuf(Event, max_events) = .{},
    stage: GameStage = GameStage.splash,
    wall_spawn_timer: f64 = 0,
    score: u32 = 0,

    const max_entities = 256;
    const max_events = 256;

    fn init(self: *Game, app_config: AppConfig) void {
        const win_width = app_config.windowWidth();
        const win_height = app_config.windowHeight();
        const win_widthf = ncast(f32, win_width);
        const win_heightf = ncast(f32, win_height);

        // set up camera based on window size
        // TODO: decouple canvas from window
        self.camera.position = za.Vec2.new(0, 0);
        self.camera.size = za.Vec2.new(win_widthf, win_heightf);

        // set up wall spawn timer
        self.wall_spawn_timer = app_config.wall.spawn_interval;

        // create some test entities at the center of the screen
        self.entities[0] = Entity.createPlayer();
        self.entities[1] = Entity.createGround();
        self.entities[2] = Entity.createSplashText();
    }

    fn tick(self: *Game) void {
        const dt = sapp.frameDuration();
        self.stage.vtable.tick(self, dt);
    }

    fn handleInputEvent(self: *Game, ev: InputEvent) void {
        if (ev.isTap()) {
            // log.debug("action: tap", .{});
            self.events.push_back(.{ .action = .tap }) catch unreachable;
        }
        if (ev.isExit()) {
            sapp.requestQuit();
        }
    }

    fn createWallSet(self: *Game, x: f32, hole_y: f32) void {
        var i = self.findEntitySlot() orelse unreachable;
        const h = main_app.config.wall.hole_hsize;
        const wh = ncast(f32, main_app.config.windowHeight());
        self.entities[i] = Entity.createBottomWall(x, hole_y - h);
        i = self.findEntitySlot() orelse unreachable;
        self.entities[i] = Entity.createTopWall(x, wh - hole_y - h);
    }

    fn findEntitySlot(self: *Game) ?usize {
        for (0..self.entities.len) |i| {
            if (self.entities[i] == null) {
                return i;
            }
        }
        return null;
    }

    fn freeStaleWalls(self: *Game) void {
        for (0..self.entities.len) |i| {
            if (self.entities[i] == null) continue;
            const entity = self.entities[i].?;
            if (!self.entities[i].?.wall) continue;
            const r_edge = entity.position.x() + entity.size.x();
            if (r_edge < 0) self.entities[0] = null;
        }
    }

    fn countWallsBehindPlayers(self: *Game) u32 {
        var count: u32 = 0;
        for (0..self.entities.len) |i| {
            if (self.entities[i] == null) continue;
            if (!self.entities[i].?.player) continue;
            const ix = self.entities[i].?.position.x();
            for (0..self.entities.len) |j| {
                if (self.entities[j] == null) continue;
                if (!self.entities[j].?.wall) continue;
                const jx = self.entities[j].?.position.x();
                if (ix > jx) {
                    count += 1;
                }
            }
        }
        return count;
    }

    fn updateScoreText(self: *Game) void {
        for (0..self.entities.len) |i| {
            const entity_opt: *?Entity = &(self.entities[i]);
            if (self.entities[i] == null) continue;
            const entity: *Entity = &(entity_opt.?);
            if (!entity.score_text) continue;
            assert(entity.debug_text != null);
            // entity.debug_text.?.text
        }
    }
};

/// VTable for stage-specific game logic
const GameStage = struct {
    vtable: VTable,

    const splash: GameStage = .{
        .vtable = .{
            .tick = Splash.tick,
        },
    };

    const playing: GameStage = .{
        .vtable = .{
            .tick = Playing.tick,
        },
    };

    const noop: GameStage = .{ .vtable = .{
        .tick = NoOp.tick,
    } };

    const VTable = struct {
        tick: *const fn (game: *Game, dt: f64) void,
    };

    const Splash = struct {
        fn tick(game: *Game, _: f64) void {
            // handle events
            while (game.events.pop_front()) |ev| {
                if (ev == .action and ev.action == .tap) {
                    game.stage = playing;
                    // push event back onto the queue so that player jumps
                    game.events.push_front(ev) catch unreachable;
                    // hide splash-only elements
                    // show playing-only elements
                    for (0..game.entities.len) |i| {
                        if (game.entities[i] == null) continue;
                        var entity: *Entity = &(game.entities[i].?);
                        if (entity.splash_only) entity.visible = false;
                        if (entity.playing_only) entity.visible = true;
                    }
                    return;
                }
            }
        }
    };

    const Playing = struct {
        fn tick(game: *Game, dt: f64) void {
            var jump = false;

            while (game.events.pop_front()) |ev| {
                if (ev == .action and ev.action == .tap) {
                    jump = true;
                }
            }

            const walls_passed_before = game.countWallsBehindPlayers();

            // tick entities
            for (0..game.entities.len) |i| {
                if (game.entities[i] == null) continue;
                var entity: *Entity = &(game.entities[i].?);
                // jump player
                if (jump and entity.player) entity.jump();
                // move entities
                entity.applyKinematics(dt);
            }

            const walls_passed_after = game.countWallsBehindPlayers();
            assert(walls_passed_before <= walls_passed_after);
            const score_delta = @divTrunc(walls_passed_after - walls_passed_before, 2);
            if (score_delta > 0) {
                game.score += score_delta;
                log.debug("score: {d}", .{game.score});
            }

            for (0..game.entities.len) |i| {
                if (game.entities[i] == null) continue;
                var entity: *Entity = &(game.entities[i].?);
                // clear stale walls
                if (entity.wall and entity.rightEdge() < 0) {
                    game.entities[i] = null;
                    continue; // entity now invalid
                }
            }

            // wall timer
            game.wall_spawn_timer -= dt;
            if (game.wall_spawn_timer < 0) {
                game.wall_spawn_timer += main_app.config.wall.spawn_interval;
                const x = ncast(f32, main_app.config.windowWidth());
                // TODO: random height
                const ymin = main_app.config.wall.spawn_padding + main_app.config.wall.hole_hsize;
                const ymax = ncast(f32, main_app.config.windowHeight()) - ymin;
                assert(ymax > ymin);
                var prng = std.Random.DefaultPrng.init(blk: {
                    var seed: u64 = undefined;
                    std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
                    break :blk seed;
                });
                const rand = prng.random();
                const y = ymin + rand.float(f32) * (ymax - ymin);
                game.createWallSet(x, y);
            }

            // check player collisions
            for (0..game.entities.len) |i| {
                if (game.entities[i] == null) continue;
                const player: *Entity = &(game.entities[i].?);
                if (!player.player) continue;
                for (0..game.entities.len) |j| {
                    if (game.entities[j] == null) continue;
                    const entity: *Entity = &(game.entities[j].?);
                    if (!entity.trigger_game_over) continue;
                    if (player.checkOverlap(entity.*)) {
                        game.stage = noop;
                        return;
                    }
                }
            }
        }
    };

    const NoOp = struct {
        fn tick(_: *Game, _: f64) void {}
    };
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

const Rect = struct {
    pos: za.Vec2,
    size: za.Vec2,

    fn top(self: Rect) f32 {
        return self.pos.y() + self.size.y();
    }

    fn bottom(self: Rect) f32 {
        return self.pos.y();
    }

    fn left(self: Rect) f32 {
        return self.pos.x();
    }

    fn right(self: Rect) f32 {
        return self.pos.x() + self.size.x();
    }

    fn checkOverlap(self: Rect, other: Rect) bool {
        return self.left() <= other.right() and self.right() >= other.left() and self.top() >= other.bottom() and self.bottom() <= other.top();
    }
};

const Event = union(enum) {
    /// player action
    action: InputAction,
    // todo: collision
};

const InputAction = enum {
    anykey,
    tap,
};

const InputEvent = struct {
    sevent: sapp.Event,

    fn from(ev: sapp.Event) InputEvent {
        return .{
            .sevent = ev,
        };
    }

    fn isAnyKey(self: InputEvent) bool {
        return self.sevent.type == .KEY_DOWN or self.sevent.type == .TOUCHES_BEGAN;
    }

    fn isTap(self: InputEvent) bool {
        // TODO: touch event
        return self.sevent.type == .KEY_DOWN and self.sevent.key_code == .SPACE;
    }

    fn isExit(self: InputEvent) bool {
        return self.sevent.type == .KEY_DOWN and self.sevent.key_code == .ESCAPE;
    }
};

fn RingBuf(T: type, size: usize) type {
    if (size == 0) {
        @compileError("size must be greater than zero");
    }

    return struct {
        buf: [size]T = undefined,
        start: usize = 0,
        count: usize = 0,

        fn push_back(self: *@This(), value: T) !void {
            if (self.count == self.buf.len) {
                return error.capacity_exceeded;
            }
            assert(self.count < self.buf.len);
            const i = @rem(self.start + self.count, self.buf.len);
            assert(i < self.buf.len);
            self.buf[i] = value;
            self.count += 1;
        }

        fn pop_back(self: *@This()) ?T {
            if (self.count == 0) return null;
            const i = @rem(self.start + self.count - 1, self.buf.len);
            defer self.count -= 1;
            return self.buf[i];
        }

        fn peek_back(self: @This()) ?T {
            if (self.count == 0) return null;
            const i = @rem(self.start + self.count - 1, self.buf.len);
            return self.buf[i];
        }

        fn push_front(self: *@This(), value: T) !void {
            if (self.count == self.buf.len) {
                return error.capacity_exceeded;
            }
            assert(self.count < self.buf.len);
            const i = @rem(self.buf.len + self.start - 1, self.buf.len);
            assert(i < self.buf.len);
            self.buf[i] = value;
            self.start = i;
            self.count += 1;
        }

        fn pop_front(self: *@This()) ?T {
            if (self.count == 0) return null;
            defer self.start = @rem(self.start + 1, self.buf.len);
            defer self.count -= 1;
            return self.buf[self.start];
        }

        fn peek_front(self: *@This()) ?T {
            if (self.count == 0) return null;
            return self.buf[self.start];
        }

        fn clear(self: *@This()) void {
            self.count = 0;
        }
    };
}

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

    visible: bool = true,

    player: bool = false,
    wall: bool = false,
    score_text: bool = false,
    trigger_game_over: bool = false,

    splash_only: bool = false,
    playing_only: bool = false,

    pub fn createPlayer() Entity {
        const app_config = main_app.config;
        const size = app_config.player.size;
        const hsize = app_config.player.size / 2;
        const x = app_config.player.x0;
        const y = app_config.player.y0;
        const w = ncast(f32, app_config.windowWidth());
        const h = ncast(f32, app_config.windowHeight());

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
            .player = true,
        };
    }

    /// create the ground obstacle
    pub fn createGround() Entity {
        const app_config = main_app.config;
        const w = ncast(f32, app_config.windowWidth());
        const h = app_config.ground.height;

        const x = 0;
        const y = 0;

        return Entity{
            .position = za.Vec2.new(x, y),
            .size = za.Vec2.new(w, h),
            .z_layer = 20,
            .trigger_game_over = true,
            .color_quad = .{
                .color = app_config.ground.color,
            },
        };
    }

    /// create a wall obstacle offscreen to the right, attached to the bottom of the screen
    pub fn createBottomWall(x: f32, height: f32) Entity {
        const app_config = main_app.config;
        return Entity{
            .position = za.Vec2.new(x, 0),
            .size = za.Vec2.new(app_config.wall.width, height),
            .velocity = za.Vec2.new(app_config.wall.speed, 0),
            .z_layer = 10,
            .color_quad = .{
                .color = app_config.wall.color,
            },
            .wall = true,
            .trigger_game_over = true,
        };
    }

    /// create a wall obstacle offscreen to the right, attached to the top of the screen
    pub fn createTopWall(x: f32, height: f32) Entity {
        const app_config = main_app.config;
        const y = ncast(f32, app_config.windowHeight()) - height;
        return Entity{
            .position = za.Vec2.new(x, y),
            .size = za.Vec2.new(app_config.wall.width, height),
            .velocity = za.Vec2.new(app_config.wall.speed, 0),
            .z_layer = 10,
            .color_quad = .{
                .color = app_config.wall.color,
            },
            .wall = true,
            .trigger_game_over = true,
        };
    }

    pub fn createSplashText() Entity {
        const cfg = main_app.config;
        const cx = cfg.windowWidthF() / 2 - 64;
        const cy = cfg.windowHeightF() / 2;
        return Entity{
            .position = za.Vec2.new(cx, cy),
            .debug_text = .{
                .text = "tap to start",
            },
            .splash_only = true,
        };
    }

    pub fn applyKinematics(self: *Entity, dt: f64) void {
        const dtf = ncast(f32, dt);
        const dtv = za.Vec2.set(dtf);
        const dx = self.velocity.mul(dtv);
        self.position = self.position.add(dx);
        const dv = self.acceleration.mul(dtv);
        self.velocity = self.velocity.add(dv);
    }

    pub fn modelTransform(self: Entity) za.Mat4 {
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
        var model_xform = za.Mat4.identity();
        model_xform = model_xform.translate(za.Vec3.new(
            self.position.x(),
            self.position.y(),
            ncast(f32, self.z_layer),
        ));
        return model_xform;
    }

    pub fn jump(self: *Entity) void {
        self.velocity.yMut().* = main_app_config.player.jump_vel;
    }

    fn rightEdge(self: Entity) f32 {
        return self.position.x() + self.size.x();
    }

    fn rect(self: Entity) Rect {
        return Rect{
            .pos = self.position,
            .size = self.size,
        };
    }

    fn checkOverlap(self: Entity, other: Entity) bool {
        return self.rect().checkOverlap(other.rect());
    }
};

/// a component for entities that correspond to a drawable quad
const ColorQuad = struct {
    color: Color,
};

const DebugText = struct {
    text: []const u8,
    font_idx: u8 = 0,
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
            if (!entity.visible) continue;
            if (entity.color_quad != null) {
                self.color_quad_pipe.draw_quad(entity, game.camera);
            }
            if (entity.debug_text != null) {
                self.debug_text_pipe.print(entity, game.camera);
            }
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
        assert(entity.color_quad != null);
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
        assert(entity.debug_text != null);
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

/// cast a compatible type to numeric
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

test "checkOverlap" {
    const t = std.testing;
    const r0 = Rect{
        .pos = za.Vec2.new(0, 0),
        .size = za.Vec2.new(2, 2),
    };
    const r1 = Rect{
        .pos = za.Vec2.new(1, 1),
        .size = za.Vec2.new(2, 2),
    };
    const r2 = Rect{
        .pos = za.Vec2.new(3, 3),
        .size = za.Vec2.new(2, 2),
    };

    try t.expect(r0.checkOverlap(r1));
    try t.expect(r1.checkOverlap(r2));
    try t.expect(!r0.checkOverlap(r2));
}
