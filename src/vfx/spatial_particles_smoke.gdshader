// Smoke billboard shader for GPUParticles3D.
//
// Uses the authored smoke alpha texture for the silhouette, then adds a tiny
// procedural distortion/dissolve pass. The important part: the base mask is no
// longer radial, so wreck smoke reads as wispy smoke instead of circular puffs.
shader_type spatial;
render_mode blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, unshaded;

uniform sampler2D smoke_texture : filter_linear;
uniform sampler2D distortion_texture : filter_linear, repeat_enable;
uniform vec4 smoke_color : source_color = vec4(0.58, 0.58, 0.60, 0.85);
// Kept for existing scripts/materials that still set this parameter.
uniform float max_lod : hint_range(0.0, 12.0, 0.1) = 8.0;
uniform float fade_intensity : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform float min_particle_alpha : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float edge_start : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float texture_power : hint_range(0.2, 2.0, 0.05) = 0.72;
uniform float dissolve_strength : hint_range(0.0, 0.7, 0.01) = 0.18;

varying float v_life;
varying float v_seed;


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


void vertex() {
	vec3 cam_world = INV_VIEW_MATRIX[3].xyz;
	vec3 to_cam = cam_world - MODEL_MATRIX[3].xyz;
	to_cam.y = 0.0;
	if (dot(to_cam, to_cam) < 0.0001) {
		to_cam = vec3(0.0, 0.0, 1.0);
	}
	to_cam = normalize(to_cam);
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 right = normalize(cross(up, to_cam));

	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);

	// Preserve whatever per-particle roll Godot baked into MODEL_MATRIX. This
	// keeps smoke cards from all lining up identically.
	vec3 source_x = MODEL_MATRIX[0].xyz;
	vec2 roll_vec = vec2(dot(source_x, right), dot(source_x, up));
	if (dot(roll_vec, roll_vec) < 0.0001) {
		roll_vec = vec2(1.0, 0.0);
	} else {
		roll_vec = normalize(roll_vec);
	}
	vec3 rolled_right = right * roll_vec.x + up * roll_vec.y;
	vec3 rolled_up = up * roll_vec.x - right * roll_vec.y;
	v_life = clamp(COLOR.r, 0.0, 1.0);
	v_seed = hash12(MODEL_MATRIX[3].xz + vec2(MODEL_MATRIX[3].y, sx + sy));

	mat4 billboard = mat4(
		vec4(rolled_right * sx, 0.0),
		vec4(rolled_up * sy, 0.0),
		vec4(to_cam, 0.0),
		MODEL_MATRIX[3]
	);
	MODELVIEW_MATRIX = VIEW_MATRIX * billboard;
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}


void fragment() {
	float seed = v_seed;
	vec2 drift = vec2(TIME * 0.018 + seed * 3.1, -TIME * 0.026 + seed * 5.3);
	float large_noise = fbm(UV * 2.4 + drift);
	float fine_noise = fbm(UV * 7.0 + vec2(seed * 11.0, seed * 17.0) - drift.yx);

	vec2 smoke_uv = UV;
	smoke_uv += vec2(large_noise - 0.5, fine_noise - 0.5) * 0.075 * (1.0 - v_life * 0.45);
	smoke_uv = clamp(smoke_uv, vec2(0.0), vec2(1.0));

	vec4 tex = texture(smoke_texture, smoke_uv);
	float texture_mask = pow(clamp(tex.a, 0.0, 1.0), texture_power);

	// Tiny dissolve only at the edges. This keeps the texture's natural wisps
	// but prevents the same card outline from being visible on every particle.
	float broken_edge = smoothstep(edge_start * 0.25, 1.0, texture_mask + (fine_noise - 0.5) * dissolve_strength);
	float quad_edge = smoothstep(0.0, 0.055, smoke_uv.x)
		* smoothstep(0.0, 0.055, smoke_uv.y)
		* smoothstep(0.0, 0.055, 1.0 - smoke_uv.x)
		* smoothstep(0.0, 0.055, 1.0 - smoke_uv.y);
	float shape = texture_mask * broken_edge * quad_edge;

	float middle_life = smoothstep(0.04, 0.18, v_life) * (1.0 - smoothstep(0.82, 1.0, v_life));
	float particle_alpha = max(COLOR.a, min_particle_alpha * middle_life);
	float alpha = shape * smoke_color.a * particle_alpha * fade_intensity;

	if (alpha < 0.01) {
		discard;
	}

	float density_light = 0.78 + tex.r * 0.34 + large_noise * 0.08;
	ALBEDO = smoke_color.rgb * density_light;
	ALPHA = clamp(alpha, 0.0, 0.85);
}
