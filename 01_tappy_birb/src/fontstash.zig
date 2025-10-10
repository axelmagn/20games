const c = @cImport({
    @cInclude("fontstash.h");
    @cInclude("sokol/sokol_gfx.h");
    @cInclude("sokol_fontstash.h");
});

/// FONScontext
pub const Context = struct {
    fons_ctx: *c.FONScontext,

    pub fn create(desc: Descriptor) ?Context {
        const ctx = c.sfons_create(@ptrCast(&desc)) orelse return null;
        return .{ .fons_ctx = ctx };
    }

    pub fn destroy(self: *Context) void {
        c.sfons_destroy(self.fons_ctx);
    }

    pub fn flush(self: *Context) void {
        c.sfons_flush(self.fons_ctx);
    }
    // pub const destroy = c.sfons_destroy;
    // pub const flush = c.sfons_flush;

    pub fn addFontMem() void {
        c.fonsAddFontMem();
    }
};

pub const rgba = c.sfons_rgba;

pub const Descriptor = struct {
    /// atlas width
    width: i32,
    /// atlas height
    height: i32,
    /// optional: allocator
    allocator: Allocator = .{},
};

pub const Allocator = struct {
    alloc_fn: ?*const fn (usize, *anyopaque) *opaque {} = null,
    free_fn: ?*const fn (*anyopaque, *anyopaque) *opaque {} = null,
    user_data: ?*anyopaque = null,
};
