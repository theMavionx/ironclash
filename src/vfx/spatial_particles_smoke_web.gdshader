// Web-safe smoke shader for CPUParticles3D.
//
// Same smoke alpha/noise/dissolve look as spatial_particles_smoke.gdshader,
// but no custom POSITION write in vertex(). Letting Godot keep the default
// particle transform is the stable path on WebGL2.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, fog_disabled;

uniform sampler2D smoke_texture : filter_linear;
uniform sampler2D distortion_texture : filter_linear, repeat_enable;
uniform vec4 smoke_color : source_color = vec4(0.58, 0.58, 0.60, 0.85);
uniform float max_lod : hint_range(0.0, 12.0, 0.1) = 8.0;
uniform float fade_intensity : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform float min_particle_alpha : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float edge_start : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float texture_power : hint_range(0.2, 2.0, 0.05) = 0.72;
uniform float dissolve_strength : hint_range(0.0, 0.7, 0.01) = 0.18;
uniform float time_offset = 0.0;
uniform float particle_life_override : hint_range(-1.0, 1.0, 0.01) = -1.0;
uniform float alpha_multiplier : hint_range(0.0, 1.0, 0.01) = 1.0;


float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}


float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));

	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}


float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	v += value_noise(p) * a;
	p = p * 2.03 + vec2(17.1, 9.2);
	a *= 0.5;
	v += value_noise(p) * a;
	p = p * 2.01 + vec2(3.7, 21.8);
	a *= 0.5;
	v += value_noise(p) * a;
	return v;
}


void fragment() {
	float t = TIME + time_offset;
	float life = particle_life_override >= 0.0 ? clamp(particle_life_override, 0.0, 1.0) : clamp(COLOR.r, 0.0, 1.0);
	float seed = hash12(vec2(time_offset, COLOR.r + COLOR.a * 3.7));
	vec2 drift = vec2(t * 0.018 + seed * 3.1, -t * 0.026 + seed * 5.3);
	float large_noise = fbm(UV * 2.4 + drift);
	float fine_noise = fbm(UV * 7.0 + vec2(seed * 11.0, seed * 17.0) - drift.yx);

	vec2 smoke_uv = UV;
	smoke_uv += vec2(large_noise - 0.5, fine_noise - 0.5) * 0.075 * (1.0 - life * 0.45);
	smoke_uv = clamp(smoke_uv, vec2(0.0), vec2(1.0));

	vec4 tex = texture(smoke_texture, smoke_uv);
	float luma = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
	float luma_mask = smoothstep(0.025, 0.42, luma);
	// Web exports can occasionally sample this PNG as opaque while preserving
	// its black RGB background. Intersect alpha with luminance so the black
	// card never becomes the smoke shape, while still honoring the authored
	// cutout when alpha is available.
	float texture_mask = min(clamp(tex.a, 0.0, 1.0), luma_mask);
	texture_mask = pow(clamp(texture_mask * 1.65, 0.0, 1.0), texture_power);
	float broken_edge = smoothstep(edge_start * 0.25, 1.0, texture_mask + (fine_noise - 0.5) * dissolve_strength);
	float quad_edge = smoothstep(0.0, 0.055, smoke_uv.x)
		* smoothstep(0.0, 0.055, smoke_uv.y)
		* smoothstep(0.0, 0.055, 1.0 - smoke_uv.x)
		* smoothstep(0.0, 0.055, 1.0 - smoke_uv.y);
	float cloud_edge = 1.0 - smoothstep(
		0.68,
		1.08,
		length((smoke_uv - vec2(0.5)) * vec2(1.04, 0.92))
	);
	float shape = texture_mask * broken_edge * quad_edge * cloud_edge;

	float middle_life = smoothstep(0.04, 0.18, life) * (1.0 - smoothstep(0.82, 1.0, life));
	float particle_alpha = max(COLOR.a, min_particle_alpha * middle_life);
	float alpha = shape * smoke_color.a * particle_alpha * fade_intensity * alpha_multiplier;
	if (alpha < 0.025) {
		discard;
	}

	float density_light = 0.78 + tex.r * 0.34 + large_noise * 0.08;
	ALBEDO = smoke_color.rgb * density_light;
	ALPHA = clamp(alpha, 0.0, 0.95);
}
