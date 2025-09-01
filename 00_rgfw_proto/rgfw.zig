const c = @cImport({
    @cDefine("RGFW_OPENGL", {});
    @cDefine("RGFW_USE_XDL", {});
    @cDefine("RGFW_ALLOC_DROPFILES", {});
    @cDefine("RGFW_PRINT_ERRORS", {});
    @cDefine("RGFW_DEBUG", {});
    @cDefine("RGFW_SILENCE_DEPRECATION", {});
    @cInclude("RGFW.h");
    @cDefine("RGL_LOAD_IMPLEMENTATION", {});
    @cInclude("rglLoad.h");
});
const print = @import("std").debug.print;

const scr_width = 800;
const scr_height = 800;

const vertex_shader_src =
    \\#version 330 core
    \\
    \\layout (location = 0) in vec3 aPos;
    \\void main()
    \\{
    \\    gl_Position = vec4(aPos.x, aPos.y, aPos.z, 1.0);
    \\}
;

const fragment_shader_src =
    \\#version 330 core
    \\
    \\out vec4 FragColor;
    \\void main()
    \\{
    \\    FragColor = vec4(1.0f, 0.5f, 0.2f, 1.0f);
    \\}
;

pub fn main() !void {
    var hints = c.RGFW_getGlobalHints_OpenGL();
    hints[0].major = 3;
    hints[0].minor = 3;
    c.RGFW_setGlobalHints_OpenGL(hints);

    const window_opt = c.RGFW_createWindow(
        "rgfw",
        scr_width,
        scr_height,
        scr_width,
        scr_height,
        c.RGFW_windowAllowDND | c.RGFW_windowCenter | c.RGFW_windowScaleToMonitor | c.RGFW_windowOpenGL,
    );
    if (window_opt == null) {
        print("Failed to create RGFW window\n", .{});
        return error.err_rgfw;
    }
    const window = window_opt.?;

    c.RGFW_window_setExitKey(window, c.RGFW_escape);
    c.RGFW_window_makeCurrentContext_OpenGL(window);
    const rgl_err = c.RGL_loadGL3(c.RGFW_getProcAddress_OpenGL);
    if (rgl_err > 0) {
        print("Failed to initialize GLAD\n", .{});
        return error.err_gl;
    }

    // compile vertex shader
    const vertex_shader = c.glCreateShader(c.GL_VERTEX_SHADER);
    c.glShaderSource(vertex_shader, 1, @ptrCast(&vertex_shader_src), null);
    c.glCompileShader(vertex_shader);
    var success: c_int = undefined;
    var info_log: [512]u8 = undefined;
    c.glGetShaderiv(vertex_shader, c.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        c.glGetShaderInfoLog(vertex_shader, 512, null, &info_log);
        print("ERROR::SHADER::VERTEX::COMPILATION_FAILED\n{s}\n", .{info_log});
    }

    // compile fragment shader
    const fragment_shader = c.glCreateShader(c.GL_FRAGMENT_SHADER);
    c.glShaderSource(fragment_shader, 1, @ptrCast(&fragment_shader_src), null);
    c.glCompileShader(fragment_shader);
    c.glGetShaderiv(fragment_shader, c.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        c.glGetShaderInfoLog(fragment_shader, 512, null, &info_log);
        print("ERROR::SHADER::FRAGMENT::COMPILATION_FAILED\n{s}\n", .{info_log});
    }

    // link shaders
    const shader_program = c.glCreateProgram();
    c.glAttachShader(shader_program, vertex_shader);
    c.glAttachShader(shader_program, fragment_shader);
    c.glLinkProgram(shader_program);
    c.glGetProgramiv(shader_program, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        c.glGetProgramInfoLog(shader_program, 512, null, &info_log);
        print("ERROR::SHADER::PROGRAM::LINKING_FAILED\n{s}\n", .{info_log});
    }
    c.glDeleteShader(vertex_shader);
    c.glDeleteShader(fragment_shader);

    // set up quad verts
    const vertices = [_]f32{
        0.5, 0.5, 0.0, // top right
        0.5, -0.5, 0.0, // bottom right
        -0.5, -0.5, 0.0, // bottom left
        -0.5, 0.5, 0.0, // top left
    };

    const indices = [_]c_uint{
        0, 1, 3,
        1, 2, 3,
    };

    // bind verts
    var vao: c_uint = undefined;
    var vbo: c_uint = undefined;
    var ebo: c_uint = undefined;
    c.glGenVertexArrays(1, @ptrCast(&vao));
    c.glGenBuffers(1, @ptrCast(&vbo));
    c.glGenBuffers(1, @ptrCast(&ebo));

    // 1. bind vertex array object
    c.glBindVertexArray(vao);

    // 2. bind and set vertex buffer
    c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
    c.glBufferData(
        c.GL_ARRAY_BUFFER,
        @sizeOf(@TypeOf(vertices)),
        &vertices,
        c.GL_STATIC_DRAW,
    );

    c.glBindBuffer(c.GL_ELEMENT_ARRAY_BUFFER, ebo);
    c.glBufferData(
        c.GL_ELEMENT_ARRAY_BUFFER,
        @sizeOf(@TypeOf(indices)),
        &indices,
        c.GL_STATIC_DRAW,
    );

    // 3. configure vertex attributes
    c.glVertexAttribPointer(
        0,
        3,
        c.GL_FLOAT,
        c.GL_FALSE,
        3 * @sizeOf(f32),
        null,
    );
    c.glEnableVertexAttribArray(0);

    // 4. unbind
    c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
    c.glBindVertexArray(0);

    // render loop
    while (c.RGFW_window_shouldClose(window) == c.RGFW_FALSE) {
        var event: c.RGFW_event = undefined;
        while (c.RGFW_window_checkEvent(window, &event) != 0) {
            if (event.type == c.RGFW_quit) {
                break;
            }
        }

        // render
        c.glClearColor(0.2, 0.3, 0.3, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        // draw quad
        c.glUseProgram(shader_program);
        c.glBindVertexArray(vao);
        c.glDrawElements(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_INT, null);

        // swap buffers
        c.RGFW_window_swapBuffers_OpenGL(window);
    }

    c.glDeleteVertexArrays(1, @ptrCast(&vao));
    c.glDeleteBuffers(1, @ptrCast(&vbo));
    c.glDeleteBuffers(1, @ptrCast(&ebo));
    c.glDeleteProgram(shader_program);

    c.RGFW_window_close(window);
}
