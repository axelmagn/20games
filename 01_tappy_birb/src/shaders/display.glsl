@vs vs_display
layout(binding=0) uniform vs_params {
	vec2 scale;
	vec2 offset;
};

in vec2 position;
out vec2 uv;

void main() {
	// TODO: screen math
	gl_Position = vec4(position * scale + offset, 0.0, 1.0);
	uv = (position + 1) / 2;
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
