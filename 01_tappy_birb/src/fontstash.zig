const c = @cImport({
    @cInclude("fontstash.h");
    @cInclude("sokol/sokol_gfx.h");
    @cInclude("sokol_fontstash.h");
});

pub const Error = error{
    Invalid,
};

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

    pub fn addFontMem(
        self: *Context,
        name: [:0]const u8,
        data: [:0]u8,
        data_size: usize,
        free_data: bool,
    ) Error!FontID {
        const res = c.fonsAddFontMem(
            self.fons_ctx,
            @ptrCast(name),
            @ptrCast(data),
            @intCast(data_size),
            @intFromBool(free_data),
        );
        if (res == c.FONS_INVALID) return .Invalid;
        return res;
    }

    pub fn setSize(self: *Context, size: f32) void {
        c.fonsSetSize(self.fons_ctx, @floatCast(size));
    }

    pub fn setColor(self: *Context, color: Color) void {
        c.fonsSetColor(self.fons_ctx, color);
    }

    pub fn setFont(self: *Context, font: FontID) void {
        c.fonsSetFont(self.fons_ctx, font);
    }
};

pub const FontID = c_int;
pub const Color = u32;

pub const rgba = c.sfons_rgba;
