// draw a solid 2D shape
@header const za = @import("zalgebra")
@ctype mat4 za.Mat4

@vs vs_solid
layout(binding = 0) uniform vs_params {
    mat4 model;
    mat4 view;
};

in vec2 position_in;

void main() {
    gl_Position = view * model * vec4(position_in, 0.0, 1.0);
}
@end

@fs fs_solid
layout(binding = 1) uniform fs_params {
    vec4 color;
};
out vec4 frag_color;

void main() {
    frag_color = color;
}
@end

@program solid vs_solid fs_solid

@vs vs_display
layout(binding = 0) uniform vs_params_display {
	vec2 offscreen_size;
	vec2 display_size;
};
// layout(binding=0) uniform vec2 offscreen_size;
// layout(binding=1) uniform vec2 display_size;

in vec2 position;
out vec2 uv;

void main() {
	gl_Position = vec4(position, 0.0, 1.0);
	uv = position;
}
@end

@fs fs_display
layout(binding = 1) uniform texture2D tex;
layout(binding = 1) uniform sampler smp;

in vec2 uv;
out vec4 frag_color;

void main() {
	frag_color = texture(sampler2D(tex, smp), uv);
}
@end

@program display vs_display fs_display
