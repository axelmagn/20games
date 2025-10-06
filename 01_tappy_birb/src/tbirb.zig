//-----------------------------------------------------------------------------
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
const sshape = sokol.shape;
const sdtx = sokol.debugtext;
const za = @import("zalgebra");
const lm32 = @import("zlm").as(f32);
const shd_solid = @import("shaders/solid.glsl.zig");
const shd_display = @import("shaders/display.glsl.zig");
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
            var gpa = heap.GeneralPurposeAllocator(.{}).init;
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
    arena: std.heap.ArenaAllocator = undefined,
    arena_buf: []u8 = undefined,

    config: AppConfig = .{},

    /// game state
    game: Game = .{},

    // renderer: OldRenderer = .{},
    // test_renderer: TestOffscreenRenderer = .{},
    renderer: Renderer = undefined,

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

        self.arena_buf = gpa.alloc(u8, app_config.arena_size) catch |err| debug.panic("{any}", .{err});
        var fba = std.heap.FixedBufferAllocator.init(self.arena_buf);
        self.arena = std.heap.ArenaAllocator.init(fba.allocator());

        stime.setup();
        self.game.init(app_config);
        // self.renderer.init(.{ .offscreen = .{ .render_size = offscreen_size } });
        // self.test_renderer.setup();
        self.renderer = Renderer.init(.{
            // TODO: make part of app config
            .offscreen = .{
                .render_width = app_config.windowWidth(),
                .render_height = app_config.windowHeight(),
                .samples = 1,
                .clear_color = Color.gray0,
            },
            .display = .{
                .clear_color = Color.black,
            },
        }) catch |err| debug.panic("{any}", .{err});
    }

    pub fn frame(self: *App) void {
        self.game.tick();
        self.renderer.draw(self.game) catch |err| debug.panic("render error: {any}", .{err});
        // self.test_renderer.draw();
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
    arena_size: usize = 64 * 1024, // 64 KB

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
    score_text_buf: [16]u8 = undefined,

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
        self.entities[3] = Entity.createGameOverText();
        self.entities[4] = Entity.createScoreText();
    }

    fn restart(self: *Game) void {
        self.* = .{};
        self.init(main_app_config);
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
        if (ev.isRestart()) {
            self.events.push_back(.{ .action = .restart }) catch unreachable;
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
        .vtable = .{ .tick = Splash.tick },
    };

    const playing: GameStage = .{
        .vtable = .{ .tick = Playing.tick },
    };

    const game_over: GameStage = .{
        .vtable = .{ .tick = GameOver.tick },
    };

    const noop: GameStage = .{
        .vtable = .{ .tick = NoOp.tick },
    };

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
                        if (entity.playing_only) entity.visible = true;
                        if (entity.splash_only) entity.visible = false;
                        if (entity.game_over_only) entity.visible = false;
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
                        GameOver.enter(game_over, game);
                        return;
                    }
                }
            }

            // update score
            const score_text: []u8 = std.fmt.bufPrint(&game.score_text_buf, "{d}", .{game.score}) catch unreachable;
            // total hack - don't care
            const score_text_const: []const u8 = @constCast(score_text);
            for (0..game.entities.len) |i| {
                if (game.entities[i] == null) continue;
                const entity: *Entity = &(game.entities[i].?);
                if (entity.score_text) {
                    assert(entity.debug_text != null);
                    entity.debug_text.?.text = score_text_const;
                }
            }
        }
    };

    const GameOver = struct {
        fn enter(self: GameStage, game: *Game) void {
            for (0..game.entities.len) |i| {
                if (game.entities[i] == null) continue;
                const entity: *Entity = &(game.entities[i].?);
                if (entity.splash_only) entity.visible = false;
                if (entity.playing_only) entity.visible = false;
                if (entity.game_over_only) entity.visible = true;
            }
            game.stage = self;
        }
        fn tick(game: *Game, _: f64) void {
            while (game.events.pop_front()) |ev| {
                if (ev == .action and ev.action == .restart) {
                    game.restart();
                    return;
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
    restart,
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

    fn isRestart(self: InputEvent) bool {
        return self.sevent.type == .KEY_DOWN and self.sevent.key_code == .R;
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
    game_over_only: bool = false,

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
            // .debug_text = .{
            //     .text = "birb",
            // },
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
        const cx = cfg.windowWidthF() / 2 - 96;
        const cy = cfg.windowHeightF() / 2;
        return Entity{
            .position = za.Vec2.new(cx, cy),
            .debug_text = .{
                .text = "tap to start",
            },
            .splash_only = true,
        };
    }
    pub fn createGameOverText() Entity {
        const cfg = main_app.config;
        const cx = cfg.windowWidthF() / 2 - 192;
        const cy = cfg.windowHeightF() / 2;
        return Entity{
            .position = za.Vec2.new(cx, cy),
            .debug_text = .{
                .text = "game over (R to restart)",
            },
            .game_over_only = true,
            .visible = false,
        };
    }

    pub fn createScoreText() Entity {
        const cfg = main_app.config;
        const cx = cfg.windowWidthF() / 2 - 4;
        const cy = cfg.windowHeightF() * 7 / 8;
        return Entity{
            .position = za.Vec2.new(cx, cy),
            .debug_text = .{
                .text = "  0",
            },
            .playing_only = true,
            .visible = false,
            .score_text = true,
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

/// renders the game by managing sgfx primitives and draw calls
const OldRenderer = struct {
    initialized: bool = false,
    offscreen_pass: OffscreenPass = undefined,
    display_pass: DisplayPass = undefined,

    color_quad_pipe: ColorQuadPipeline = undefined,
    debug_text_pipe: DebugTextPipeline = .{},
    display_pipe: DisplayPipeline = undefined,

    const InitOptions = struct {
        offscreen: struct {
            render_size: za.Vec2_i32,
            clear_color: Color = Color.gray0,
        },
        display: struct {
            clear_color: Color = Color.black,
        } = .{},
    };

    fn init(self: *OldRenderer, opt: InitOptions) void {
        sgfx.setup(.{
            .environment = sglue.environment(),
            .logger = .{ .func = slog.func },
        });

        // set up passes
        self.offscreen_pass = OffscreenPass.create(
            opt.offscreen.render_size,
            opt.offscreen.clear_color,
        );
        self.display_pass = DisplayPass.create(
            opt.display.clear_color,
            sglue.swapchain(),
        );

        // set up pipelines
        DebugTextPipeline.setup();
        self.color_quad_pipe = ColorQuadPipeline.create();
        self.display_pipe = DisplayPipeline.create(self.offscreen_pass.color_tex);
    }

    fn makePassAction(clear_color: Color) sgfx.PassAction {
        var pass_action = sgfx.PassAction{};
        pass_action.colors[0] = .{
            .load_action = .CLEAR,
            .clear_value = clear_color.to(sgfx.Color),
        };
        return pass_action;
    }

    fn draw(self: OldRenderer, game: Game) void {
        // DebugTextPipeline.hello_world();
        self.debug_text_pipe.resetCanvas();

        // begin offscreen pass
        sgfx.beginPass(self.offscreen_pass.pass);

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

        sgfx.beginPass(self.offscreen_pass.pass);
        self.display_pipe.draw_display();
        sgfx.endPass();

        sgfx.commit();
    }
};

const TestOffscreenRenderer = struct {
    offscreen: struct {
        pass: sgfx.Pass = .{},
        pipe: sgfx.Pipeline = .{},
        bind: sgfx.Bindings = .{},
        color_img: sgfx.Image = .{},
    } = .{},

    display: struct {
        pass: sgfx.Pass = .{},
        pipe: sgfx.Pipeline = .{},
        bind: sgfx.Bindings = .{},
    } = .{},

    const Self = TestOffscreenRenderer;

    const quad_verts = [_]f32{
        -1, -1,
        -1, 1,
        1,  1,
        1,  -1,
    };
    const quad_idxs = [_]u16{
        0, 1, 2,
        2, 3, 0,
    };

    fn setup(self: *Self) void {
        self.* = .{};
        sgfx.setup(.{
            .environment = sglue.environment(),
            .logger = .{ .func = slog.func },
        });
        self.setupOffscreen();
        self.setupDisplay();
    }

    fn setupOffscreen(self: *Self) void {
        const offscreen_width = 256;
        const offscreen_height = 256;
        const offscreen_sample_count = 1;

        // make render targets
        const color_img = sgfx.makeImage(.{
            .usage = .{ .color_attachment = true },
            .width = offscreen_width,
            .height = offscreen_height,
            .sample_count = offscreen_sample_count,
            .pixel_format = .RGBA8,
        });
        self.offscreen.color_img = color_img;

        const depth_img = sgfx.makeImage(.{
            .usage = .{ .depth_stencil_attachment = true },
            .width = offscreen_width,
            .height = offscreen_height,
            .sample_count = offscreen_sample_count,
            .pixel_format = .DEPTH,
        });

        // set up pass
        self.offscreen.pass.action.colors[0] = .{
            .load_action = .CLEAR,
            .clear_value = .{ .r = 0.25, .g = 0.25, .b = 0.25, .a = 1.0 },
        };
        self.offscreen.pass.attachments.colors[0] = sgfx.makeView(.{
            .color_attachment = .{ .image = color_img },
        });
        self.offscreen.pass.attachments.depth_stencil = sgfx.makeView(.{
            .depth_stencil_attachment = .{ .image = depth_img },
        });

        // set up pipeline
        const shader_desc = shd_solid.solidShaderDesc(sgfx.queryBackend());
        self.offscreen.pipe = sgfx.makePipeline(.{
            .shader = sgfx.makeShader(shader_desc),
            .layout = init: {
                var l = sgfx.VertexLayoutState{};
                l.attrs[shd_solid.ATTR_solid_position_in].format = .FLOAT2;
                break :init l;
            },
            .index_type = .UINT16,
            .cull_mode = .BACK,
            .sample_count = offscreen_sample_count,
            .depth = .{
                .pixel_format = .DEPTH,
                .compare = .LESS_EQUAL,
                .write_enabled = true,
            },
            .colors = init: {
                var c: [sgfx.max_color_attachments]sgfx.ColorTargetState = @splat(.{});
                c[0].pixel_format = .RGBA8;
                break :init c;
            },
        });

        // set up bindings
        self.offscreen.bind.vertex_buffers[0] = sgfx.makeBuffer(.{
            .usage = .{ .vertex_buffer = true, .immutable = true },
            .data = sgfx.asRange(&quad_verts),
        });
        self.offscreen.bind.index_buffer = sgfx.makeBuffer(.{
            .usage = .{ .index_buffer = true, .immutable = true },
            .data = sgfx.asRange(&quad_idxs),
        });
    }

    fn setupDisplay(self: *Self) void {
        self.display.pass.action.colors[0] = .{
            .load_action = .CLEAR,
        };
        self.display.pass.swapchain = sglue.swapchain();

        const shader_desc = shd_display.displayShaderDesc(sgfx.queryBackend());
        self.display.pipe = sgfx.makePipeline(.{
            .shader = sgfx.makeShader(shader_desc),
            .layout = init: {
                var l = sgfx.VertexLayoutState{};
                l.attrs[shd_display.ATTR_display_position].format = .FLOAT2;
                break :init l;
            },
            .index_type = .UINT16,
            .cull_mode = .NONE,
            .depth = .{
                .compare = .LESS_EQUAL,
                .write_enabled = true,
            },
        });

        self.display.bind.views[shd_display.VIEW_tex] = sgfx.makeView(.{
            .texture = .{ .image = self.offscreen.color_img },
        });
        self.display.bind.vertex_buffers[0] = sgfx.makeBuffer(.{
            .usage = .{ .vertex_buffer = true, .immutable = true },
            .data = sgfx.asRange(&quad_verts),
        });
        self.display.bind.index_buffer = sgfx.makeBuffer(.{
            .usage = .{ .index_buffer = true, .immutable = true },
            .data = sgfx.asRange(&quad_idxs),
        });
        self.display.bind.samplers[shd_display.SMP_smp] = sgfx.makeSampler(.{
            .min_filter = .NEAREST,
            .mag_filter = .NEAREST,
            .wrap_u = .REPEAT,
            .wrap_v = .REPEAT,
        });
    }

    fn draw(self: *Self) void {
        // render to offscreen
        sgfx.beginPass(self.offscreen.pass);
        sgfx.applyPipeline(self.offscreen.pipe);
        sgfx.applyBindings(self.offscreen.bind);
        sgfx.applyUniforms(
            shd_solid.UB_vs_params,
            sgfx.asRange(&shd_solid.VsParams{
                .model = za.Mat4.identity().scale(za.Vec3.new(0.5, 0.5, 0.5)),
                .view = za.Mat4.identity(),
            }),
        );
        sgfx.applyUniforms(
            shd_solid.UB_fs_params,
            sgfx.asRange(&shd_solid.FsParams{
                .color = Color.new(0.2, 0.4, 0.6, 1.0).to(za.Vec4).toArray(),
            }),
        );
        sgfx.draw(0, quad_idxs.len, 1);
        sgfx.endPass();

        sgfx.beginPass(self.display.pass);
        sgfx.applyPipeline(self.display.pipe);
        sgfx.applyBindings(self.display.bind);
        sgfx.applyUniforms(
            shd_display.UB_vs_params,
            sgfx.asRange(&shd_display.VsParams{
                .scale = za.Vec2.new(0.5, 0.5).data,
                .offset = za.Vec2.zero().data,
            }),
        );
        sgfx.draw(0, quad_idxs.len, 1);
        sgfx.endPass();
        sgfx.commit();
    }
};

/// render the game in a viewport with locked size and aspect
const OffscreenPass = struct {
    color_img: sgfx.Image,
    depth_img: sgfx.Image,
    color_tex: sgfx.View,

    pass: sgfx.Pass,

    fn create(
        render_size: za.Vec2_i32,
        clear_color: Color,
    ) OffscreenPass {
        // sheer laziness after too many refactors
        var self: OffscreenPass = undefined;
        self.color_img = makeColorImage(render_size);
        self.depth_img = makeDepthImage(render_size);
        self.color_tex = sgfx.makeView(.{
            .texture = .{ .image = self.color_img },
        });
        self.pass = sgfx.Pass{
            .action = OldRenderer.makePassAction(clear_color),
            .attachments = .{
                .colors = makeColorAttachments(self.color_img),
                .depth_stencil = makeDepthAttachment(self.depth_img),
            },

            .label = "offscreen-pass",
        };
        return self;
    }

    fn makeColorImage(size: za.Vec2_i32) sgfx.Image {
        return sgfx.makeImage(.{
            .usage = .{ .color_attachment = true },
            .width = size.x(),
            .height = size.y(),
            .pixel_format = .RGBA8,
            .sample_count = 1,
            .label = "color-image",
        });
    }

    fn makeDepthImage(size: za.Vec2_i32) sgfx.Image {
        return sgfx.makeImage(.{
            .usage = .{ .depth_stencil_attachment = true },
            .width = size.x(),
            .height = size.y(),
            .pixel_format = .DEPTH,
            .sample_count = 1,
            .label = "depth-image",
        });
    }

    fn makeColorAttachments(color_img: sgfx.Image) [4]sgfx.View {
        var colors: [4]sgfx.View = [_]sgfx.View{.{}} ** 4;
        colors[0] = sgfx.makeView(.{
            .color_attachment = .{ .image = color_img },
            .label = "color-attachment",
        });
        return colors;
    }

    fn makeDepthAttachment(depth_img: sgfx.Image) sgfx.View {
        return sgfx.makeView(.{
            .depth_stencil_attachment = .{ .image = depth_img },
            .label = "depth-attachment",
        });
    }
};

/// blit the game viewport to the screen
const DisplayPass = struct {
    pass: sgfx.Pass = undefined,

    fn create(clear_color: Color, swapchain: sgfx.Swapchain) DisplayPass {
        return .{ .pass = .{
            .action = OldRenderer.makePassAction(clear_color),
            .swapchain = swapchain,
            .label = "display_pass",
        } };
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

    fn create() ColorQuadPipeline {
        var self = ColorQuadPipeline{};
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
        const pipe_desc: sgfx.PipelineDesc = .{
            .shader = shader,
            .layout = vert_layout,
            .index_type = .UINT16,
            .sample_count = 1,
            .depth = .{
                .pixel_format = .DEPTH,
                .compare = .LESS_EQUAL,
                .write_enabled = true,
            },

            .cull_mode = .NONE,
        };
        self.pipe = sgfx.makePipeline(pipe_desc);
        return self;
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

    pub fn setup() void {
        sdtx.setup(.{
            .fonts = blk: {
                var f: [8]sdtx.FontDesc = @splat(.{});
                f[kc854] = sdtx.fontKc854();
                f[c64] = sdtx.fontC64();
                f[oric] = sdtx.fontOric();
                break :blk f;
            },
            .logger = .{ .func = slog.func },
            .context = .{
                .color_format = .RGBA8,
                .depth_format = .DEPTH,
                .sample_count = 1,
            },
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

const DisplayPipeline = struct {
    pipe: sgfx.Pipeline = .{},
    bind: sgfx.Bindings = .{},

    const VB_quad = 0;

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

    fn create(color_tex: sgfx.View) DisplayPipeline {
        return .{
            .pipe = makePipeline(),
            .bind = makeBindings(color_tex),
        };
    }

    fn makeBindings(color_tex: sgfx.View) sgfx.Bindings {
        var bind = sgfx.Bindings{};
        bind.vertex_buffers[0] = sgfx.makeBuffer(.{
            .usage = .{ .vertex_buffer = true, .immutable = true },
            .data = sgfx.asRange(&quad_verts),
        });
        bind.index_buffer = sgfx.makeBuffer(.{
            .usage = .{ .index_buffer = true, .immutable = true },
            .data = sgfx.asRange(&quad_idxs),
        });
        const sampler = sgfx.makeSampler(.{
            .label = "color-sampler",
        });
        bind.views[shd_display.VIEW_tex] = color_tex;
        bind.samplers[shd_display.SMP_smp] = sampler;
        return bind;
    }

    fn makePipeline() sgfx.Pipeline {
        return sgfx.makePipeline(.{
            .shader = makeShader(),
            .layout = makeVertLayout(),
            .index_type = .UINT16,
            .depth = .{
                .compare = .LESS_EQUAL,
                .write_enabled = true,
            },
            .cull_mode = .NONE,
            .sample_count = 4,
        });
    }

    fn makeShader() sgfx.Shader {
        const backend = sgfx.queryBackend();
        const desc = shd_display.displayShaderDesc(backend);
        return sgfx.makeShader(desc);
    }

    fn makeVertLayout() sgfx.VertexLayoutState {
        var vert_layout = sgfx.VertexLayoutState{};
        vert_layout.attrs[shd_display.ATTR_display_position].format = .FLOAT2;
        return vert_layout;
    }

    fn draw_display(self: DisplayPipeline) void {
        const vs_params = shd_display.VsParams{
            .offset = za.Vec2.new(0.25, 0.0).data,
            .scale = za.Vec2.new(0.5, 1.0).data,
        };

        // draw call
        sgfx.applyPipeline(self.pipe);
        sgfx.applyBindings(self.bind);
        sgfx.applyUniforms(shd_display.UB_vs_params, sgfx.asRange(&vs_params));
        sgfx.draw(0, quad_idxs.len, 1);
    }
};

const Renderer = struct {
    offscreen_pass: RenderPass,
    display_pass: RenderPass,

    const Self = @This();

    const Config = struct {
        offscreen: Offscreen,
        display: Display,

        const Offscreen = struct {
            render_width: i32,
            render_height: i32,
            samples: i32,
            clear_color: Color,
        };

        const Display = struct {
            clear_color: Color,
        };
    };

    fn init(cfg: Config) !Self {
        sgfx.setup(.{
            .environment = sglue.environment(),
            .logger = .{ .func = slog.func },
        });
        return .{
            .offscreen_pass = try makeOffscreenPass(cfg.offscreen),
            .display_pass = try makeDisplayPass(cfg.display),
        };
    }

    fn draw(self: *Self, game: Game) !void {
        _ = game;
        // offscreen pass
        sgfx.beginPass(self.offscreen_pass.pass);
        // TODO: offscreen stages
        sgfx.endPass();

        // display pass
        sgfx.beginPass(self.display_pass.pass);
        // TODO: display stages
        sgfx.endPass();
    }

    fn makeOffscreenPass(cfg: Config.Offscreen) !RenderPass {
        const color_img = sgfx.makeImage(.{
            .usage = .{ .color_attachment = true },
            .width = cfg.render_width,
            .height = cfg.render_height,
            .pixel_format = .RGBA8,
            .sample_count = cfg.samples,
            .label = "color-image",
        });
        const depth_img = sgfx.makeImage(.{
            .usage = .{ .depth_stencil_attachment = true },
            .width = cfg.render_width,
            .height = cfg.render_height,
            .pixel_format = .DEPTH,
            .sample_count = cfg.samples,
            .label = "depth-image",
        });
        const pass = sgfx.Pass{
            .action = .{ .colors = init: {
                var c: [4]sgfx.ColorAttachmentAction = @splat(.{});
                c[0] = .{
                    .load_action = .CLEAR,
                    .clear_value = cfg.clear_color.to(sgfx.Color),
                };
                break :init c;
            } },
            .attachments = .{
                .colors = init: {
                    var c: [4]sgfx.View = @splat(.{});
                    c[0] = sgfx.makeView(.{
                        .color_attachment = .{ .image = color_img },
                    });
                    break :init c;
                },
                .depth_stencil = sgfx.makeView(.{
                    .depth_stencil_attachment = .{ .image = depth_img },
                }),
            },
        };

        return .{
            .pass = pass,
            .render_tgt = color_img,
        };
    }

    fn makeDisplayPass(cfg: Config.Display) !RenderPass {
        return .{
            .pass = .{
                .action = .{ .colors = init: {
                    var c: [4]sgfx.ColorAttachmentAction = @splat(.{});
                    c[0] = .{
                        .load_action = .CLEAR,
                        .clear_value = cfg.clear_color.to(sgfx.Color),
                    };
                    break :init c;
                } },
                .swapchain = sglue.swapchain(),
            },
        };
    }
};

const RenderPass = struct {
    pass: sgfx.Pass,
    render_tgt: ?sgfx.Image = null,

    const Self = @This();
};

const RenderStage = struct {
    pipe: sgfx.Pipeline,
    bind: sgfx.Bindings,

    ptr: *anyopaque,
    vtable: *const VTable,

    const Self = @This();

    const VTable = struct {
        draw: *const fn (*anyopaque, Game) RenderStage.Error!void,
    };

    const Error = struct {};

    fn draw(self: Self, game: *Game) RenderStage.Error!void {
        sgfx.applyPipeline(self.pipe);
        sgfx.applyBindings(self.bind);
        self.vtable.draw(self.ptr, game);
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

test "Rect.checkOverlap" {
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
