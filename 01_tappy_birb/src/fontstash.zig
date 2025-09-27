const c = @cImport({
    @cInclude("fontstash.h");
    @cInclude("sokol/sokol_gfx.h");
    @cInclude("sokol_fontstash.h");
});

const max_states = c.FONS_MAX_STATES;
const vertex_count = c.FONS_VERTEX_COUNT;

const Context = extern struct {
    params: Params = .{},
    itw: f32 = 0,
    ith: f32 = 0,
    tex_data: [*c]const u8 = null,
    dirty_rect: [4]i32 = @splat(0),
    fonts: [*c]*Font = null,
    atlas: [*c]Atlas = null,
    cfonts: i32 = 0,
    nfonts: i32 = 0,
    verts: [vertex_count * 2]f32 = @splat(0),
    tcoords: [vertex_count * 2]f32 = @splat(0),
    colors: [vertex_count]u32 = @splat(0),
    nverts: i32 = 0,
    scratch: [*c]u8 = null,
    nscratch: i32 = 0,
    states: [max_states]State = @splat(.{}),
    nstates: i32 = 0,
    handle_error: ?*const fn (*anyopaque, i32, i32) void = null,
    error_uptr: *anyopaque = null,
};

// TODO
const Params = extern struct {};
const Font = extern struct {};
const Atlas = extern struct {};
const State = extern struct {};
