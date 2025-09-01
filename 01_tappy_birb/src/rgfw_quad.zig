// const c = @cImport({
//     @cDefine("RGFW_OPENGL", {});
//     @cDefine("RGFW_USE_XDL", {});
//     @cDefine("RGFW_ALLOC_DROPFILES", {});
//     @cDefine("RGFW_PRINT_ERRORS", {});
//     @cDefine("RGFW_DEBUG", {});
//     @cDefine("RGFW_SILENCE_DEPRECATION", {});
//     @cInclude("RGFW.h");
//     // @cDefine("RGL_LOAD_IMPLEMENTATION", {});
//     // @cInclude("rglLoad.h");
// });
const print = @import("std").debug.print;
const gl = @import("gl");
const rgfw = @import("rgfw.zig");

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
    var hints = rgfw.gl.getGlobalHints();
    hints.major = 3;
    hints.minor = 3;
    rgfw.gl.setGlobalHints(hints);

    const window_opt = rgfw.Window.create(
        "rgfw",
        scr_width,
        scr_height,
        scr_width,
        scr_height,
        // TODO: RGFW ENUM
        rgfw.c.RGFW_windowAllowDND | rgfw.c.RGFW_windowCenter | rgfw.c.RGFW_windowScaleToMonitor | rgfw.c.RGFW_windowOpenGL,
    );
    if (window_opt == null) {
        print("Failed to create RGFW window\n", .{});
        return error.err_rgfw;
    }
    const window = window_opt.?;

    // TODO: RGFW ENUM
    window.setExitKey(rgfw.c.RGFW_escape);
    rgfw.gl.makeCurrentContext(window);

    var gl_procs: gl.ProcTable = undefined;
    if (!gl_procs.init(rgfw.gl.getProcAddress)) return error.err_gl;
    gl.makeProcTableCurrent(&gl_procs);
    errdefer gl.makeProcTableCurrent(null);

    // compile vertex shader
    const vertex_shader = gl.CreateShader(gl.VERTEX_SHADER);
    gl.ShaderSource(vertex_shader, 1, @ptrCast(&vertex_shader_src), null);
    gl.CompileShader(vertex_shader);
    var success: c_int = undefined;
    var info_log: [512]u8 = undefined;
    gl.GetShaderiv(vertex_shader, gl.COMPILE_STATUS, @ptrCast(&success));
    if (success == 0) {
        gl.GetShaderInfoLog(vertex_shader, 512, null, &info_log);
        print("ERROR::SHADER::VERTEX::COMPILATION_FAILED\n{s}\n", .{info_log});
    }

    // compile fragment shader
    const fragment_shader = gl.CreateShader(gl.FRAGMENT_SHADER);
    gl.ShaderSource(fragment_shader, 1, @ptrCast(&fragment_shader_src), null);
    gl.CompileShader(fragment_shader);
    gl.GetShaderiv(fragment_shader, gl.COMPILE_STATUS, @ptrCast(&success));
    if (success == 0) {
        gl.GetShaderInfoLog(fragment_shader, 512, null, &info_log);
        print("ERROR::SHADER::FRAGMENT::COMPILATION_FAILED\n{s}\n", .{info_log});
    }

    // link shaders
    const shader_program = gl.CreateProgram();
    gl.AttachShader(shader_program, vertex_shader);
    gl.AttachShader(shader_program, fragment_shader);
    gl.LinkProgram(shader_program);
    gl.GetProgramiv(shader_program, gl.LINK_STATUS, @ptrCast(&success));
    if (success == 0) {
        gl.GetProgramInfoLog(shader_program, 512, null, &info_log);
        print("ERROR::SHADER::PROGRAM::LINKING_FAILED\n{s}\n", .{info_log});
    }
    gl.DeleteShader(vertex_shader);
    gl.DeleteShader(fragment_shader);

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
    gl.GenVertexArrays(1, @ptrCast(&vao));
    gl.GenBuffers(1, @ptrCast(&vbo));
    gl.GenBuffers(1, @ptrCast(&ebo));

    // 1. bind vertex array object
    gl.BindVertexArray(vao);

    // 2. bind and set vertex buffer
    gl.BindBuffer(gl.ARRAY_BUFFER, vbo);
    gl.BufferData(
        gl.ARRAY_BUFFER,
        @sizeOf(@TypeOf(vertices)),
        &vertices,
        gl.STATIC_DRAW,
    );

    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo);
    gl.BufferData(
        gl.ELEMENT_ARRAY_BUFFER,
        @sizeOf(@TypeOf(indices)),
        &indices,
        gl.STATIC_DRAW,
    );

    // 3. configure vertex attributes
    gl.VertexAttribPointer(
        0,
        3,
        gl.FLOAT,
        gl.FALSE,
        3 * @sizeOf(f32),
        0,
    );
    gl.EnableVertexAttribArray(0);

    // 4. unbind
    gl.BindBuffer(gl.ARRAY_BUFFER, 0);
    gl.BindVertexArray(0);

    // render loop
    while (!window.shouldClose()) {
        var event: rgfw.Event = undefined;
        while (window.checkEvent(&event)) {
            // TODO: RGFW EVENTS IN ZIG
            if (event.type == rgfw.c.RGFW_quit) {
                break;
            }
        }

        // render
        gl.ClearColor(0.2, 0.3, 0.3, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT);

        // draw quad
        gl.UseProgram(shader_program);
        gl.BindVertexArray(vao);
        gl.DrawElements(gl.TRIANGLES, 6, gl.UNSIGNED_INT, 0);

        // swap buffers
        rgfw.gl.swapBuffers(window);
    }

    gl.DeleteVertexArrays(1, @ptrCast(&vao));
    gl.DeleteBuffers(1, @ptrCast(&vbo));
    gl.DeleteBuffers(1, @ptrCast(&ebo));
    gl.DeleteProgram(shader_program);

    window.close();
}
