// Web-safe fire shader for CPUParticles3D.
//
// Keeps the same fragment-side fire look as spatial_particles_fire.gdshader
// (noise distortion + procedural flame shape + orange/yellow palette), but
// deliberately does not write POSITION in vertex(). In Godot's WebGL2 path,
// overriding POSITION on particle geometry can bypass the particle instance
// transform and render the whole effect blank.
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded, fog_disabled;

uniform sampler2D fire_texture : filter_linear;
uniform sampler2D distortion_texture : filter_linear, repeat_enable;
uniform vec4 fire_color : source_color = vec4(2.6, 1.1, 0.28, 0.9);
uniform vec4 outer_color : source_color = vec4(0.95, 0.12, 0.02, 1.0);
uniform vec4 mid_color : source_color = vec4(1.0, 0.52, 0.04, 1.0);
uniform vec4 core_color : source_color = vec4(1.0, 0.92, 0.35, 1.0);
uniform vec2 distortion_speed = vec2(0.0, -1.0);
uniform float distortion_amount : hint_range(0.0, 0.5) = 0.25;
uniform float anchor_power : hint_range(0.5, 4.0) = 1.5;
uniform float edge_softness : hint_range(0.01, 0.4) = 0.16;
uniform float base_glow : hint_range(0.0, 1.0) = 0.35;
uniform float flame_width_scale : hint_range(0.5, 3.0) = 1.0;
uniform float procedural_flame : hint_range(0.0, 1.0) = 1.0;
uniform float time_offset = 0.0;
uniform float alpha_multiplier : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float particle_life_override : hint_range(-1.0, 1.0, 0.01) = -1.0;


void fragment() {
	float t = TIME + time_offset;
	float dist_a = texture(distortion_texture, UV * vec2(1.1, 1.35) + distortion_speed * t).r;
	float dist_b = texture(distortion_texture, UV * vec2(2.3, 1.8) + vec2(0.7, -0.35) * t).r;
	float dist = (dist_a - 0.5) + (dist_b - 0.5) * 0.45;

	float height_t = 1.0 - UV.y;
	float anchor_mask = pow(height_t, anchor_power);

	vec2 fire_uv = UV;
	fire_uv.x += dist * distortion_amount * 0.22 * anchor_mask;
	fire_uv.y += dist * distortion_amount * 0.34 * anchor_mask;
	fire_uv = clamp(fire_uv, vec2(0.0), vec2(1.0));

	float mask = texture(fire_texture, fire_uv).r;
	float flame_height = 1.0 - fire_uv.y;
	if (procedural_flame > 0.5) {
		float side_noise = texture(distortion_texture, fire_uv * vec2(1.7, 2.4) + vec2(0.1, -1.15) * t).r;
		float center_noise = texture(distortion_texture, fire_uv * vec2(0.85, 1.55) + vec2(-0.18, -0.72) * t).r;
		float center_shift = (center_noise - 0.5) * 0.20 * pow(flame_height, 0.65);
		float x = abs(fire_uv.x - 0.5 - center_shift);

		float width = mix(0.32, 0.042, pow(flame_height, 1.2)) * flame_width_scale;
		width += (side_noise - 0.5) * 0.08 * smoothstep(0.16, 0.92, flame_height);
		width = clamp(width, 0.035, 0.48);

		float side = 1.0 - smoothstep(width, width + edge_softness, x);
		float bottom = smoothstep(-0.06, 0.10, flame_height);
		float top = 1.0 - smoothstep(0.92, 1.04, flame_height);
		mask = side * bottom * top;
		mask = pow(clamp(mask, 0.0, 1.0), 0.72);
	} else {
		mask = pow(mask, 0.68);
	}

	float particle_alpha = max(COLOR.a, 0.001);
	float alpha = smoothstep(0.03, edge_softness, mask) * fire_color.a * particle_alpha * alpha_multiplier;
	if (alpha < 0.01) {
		discard;
	}

	float mid_t = smoothstep(0.24, 0.74, mask);
	float core_t = smoothstep(0.62, 0.96, mask);
	vec3 col = mix(outer_color.rgb, mid_color.rgb, mid_t);
	col = mix(col, core_color.rgb, core_t);

	float center = 1.0 - smoothstep(0.0, 0.45, abs(fire_uv.x - 0.5));
	float base = smoothstep(0.56, 1.0, fire_uv.y);
	float hot_base = center * base * base_glow * mask;
	col += core_color.rgb * hot_base;

	float brightness = 0.85 + mid_t * 0.55 + core_t * 0.75 + hot_base * 0.6;
	ALBEDO = col * fire_color.rgb * brightness;
	ALPHA = clamp(alpha, 0.0, 1.0);
}
