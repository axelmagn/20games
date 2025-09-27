// draw a solid 2D shape
@header const za = @import("zalgebra")
@ctype mat4 za.Mat4
// @header const m = @import("../math.zig")
// @ctype mat4 m.Mat4

@vs vs
layout(binding = 0) uniform vs_params {
	mat4 model;
	mat4 view;
};

in vec2 position_in;

void main() {
	gl_Position = view * model * vec4(position_in, 0.0, 1.0);
	// gl_Position = vec4(position_in, 0.0, 1.0);
}
@end

@fs fs
layout(binding = 1) uniform fs_params {
	vec4 color;
};
out vec4 frag_color;

void main() {
	frag_color = color;
}
@end

@program solid vs fs
