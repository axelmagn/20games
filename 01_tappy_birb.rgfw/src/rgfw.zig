pub const c = @cImport({
    @cDefine("RGFW_OPENGL", {});
    @cDefine("RGFW_USE_XDL", {});
    @cDefine("RGFW_ALLOC_DROPFILES", {});
    @cDefine("RGFW_PRINT_ERRORS", {});
    @cDefine("RGFW_DEBUG", {});
    @cDefine("RGFW_SILENCE_DEPRECATION", {});
    @cInclude("RGFW.h");
});

pub const Key = c.RGFW_key;

pub const GLHints = c.RGFW_glHints;

pub const Event = c.RGFW_event;

/// event codes
pub const EventType = enum(u8) {
    /// no event has been sent
    none = 0,
    key_pressed,
    key_released,
    mouse_button_pressed,
    mouse_button_released,
    mouse_pos_changed,
    window_moved,
    window_resized,
    focus_in,
    focus_out,
    mouse_enter,
    mouse_leave,
    window_refresh,
    quit,
    data_drop,
    data_drag,
    window_maximized,
    window_minimized,
    window_restored,
    scale_updated
};

pub const gl = struct {
    pub const getProcAddress = &c.RGFW_getProcAddress_OpenGL;

    pub fn getGlobalHints() *GLHints {
        return @ptrCast(&c.RGFW_getGlobalHints_OpenGL()[0]);
    }

    pub fn setGlobalHints(hints: *GLHints) void {
        c.RGFW_setGlobalHints_OpenGL(@ptrCast(hints));
    }

    pub fn makeCurrentContext(window: Window) void {
        c.RGFW_window_makeCurrentContext_OpenGL(window.ptr);
    }

    pub fn swapBuffers(window: Window) void {
        c.RGFW_window_swapBuffers_OpenGL(window.ptr);
    }
};

pub const Window = struct {
    ptr: *c.RGFW_window,

    const Flags = c.RGFW_windowFlags;

    pub fn create(
        name: [*c]const u8,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        flags: Flags,
    ) ?Window {
        const ptr = c.RGFW_createWindow(
            name,
            x,
            y,
            width,
            height,
            flags,
        ) orelse return null;
        return .{ .ptr = ptr };
    }

    pub fn setExitKey(self: Window, key: Key) void {
        c.RGFW_window_setExitKey(self.ptr, key);
    }

    pub fn shouldClose(self: Window) bool {
        return c.RGFW_window_shouldClose(self.ptr) == c.RGFW_TRUE;
    }

    /// returns true if an event was polled
    pub fn checkEvent(self: Window, event: *Event) bool {
        return c.RGFW_window_checkEvent(self.ptr, @ptrCast(event)) == c.RGFW_TRUE;
    }

    pub fn close(self: Window) void {
        c.RGFW_window_close(self.ptr);
    }
};
