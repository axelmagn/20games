@header const za = @import("zalgebra")
@ctype mat4 za.Mat4

@vs vs_sprite
layout(binding = 0) uniform vs_view_params {
	mat4 model;
	mat4 view;
};
layout(binding = 1) uniform vs_tile_params {
	vec2 tile_uv;
	vec2 tile_uv_size;
};

in vec2 position_in;
in vec2 uv_in;

out vec2 uv;

void main() {
	gl_Position = view * model * vec4(position_in, 0.0, 1.0);
	uv = tile_uv + uv_in * tile_uv_size;
}

@end

@fs fs_sprite
layout(binding = 2) uniform texture2D tex;
layout(binding = 2) uniform sampler smp;
layout(binding = 3) uniform fs_params {
	vec4 tint;
};

in vec2 uv;

out vec4 frag_color;

void main() {
	frag_color = texture(sampler2D(tex, smp), uv) * tint;
}
@end

@program sprite vs_sprite fs_sprite
