shader_type spatial;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform float uv_offset = 0.0;
uniform vec2 uv_direction = vec2(0.0, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.85;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 scrolled_uv = UV + uv_direction * uv_offset;
	ALBEDO = texture(albedo_texture, scrolled_uv).rgb;
	ROUGHNESS = roughness;
	METALLIC = metallic;
}
