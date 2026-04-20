// Toon-posterized billboard fire particle — ADDITIVE variant of the smoke shader.
// Identical noise/posterization logic but blend_add composites the hot core
// as glow accumulation, and EMISSION pushes fragments above the world's
// glow_hdr_threshold = 0.9 so the bloom pass picks them up.
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded;

uniform float softness : hint_range(0.0, 1.0) = 0.4;
uniform float silhouette_break : hint_range(0.0, 0.5) = 0.15;

uniform sampler2D noise_texture : hint_default_white, filter_linear_mipmap;
uniform float noise_scale : hint_range(0.5, 8.0) = 4.0;
uniform vec2 noise_scroll_speed = vec2(0.0, 0.35);

uniform float toon_steps : hint_range(1.0, 8.0, 1.0) = 3.0;
uniform float toon_strength : hint_range(0.0, 1.0) = 0.8;

uniform float emission_strength : hint_range(0.0, 10.0) = 4.0;

void vertex() {
	mat4 mv = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0],
		INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]
	);
	mv = mv * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0)
	);
	MODELVIEW_MATRIX = mv;
	MODELVIEW_NORMAL_MATRIX = mat3(mv);
}

void fragment() {
	float id = float(INSTANCE_ID);
	vec2 id_offset = vec2(id * 0.137, id * 0.731);

	vec2 scrolled_uv = UV * noise_scale + TIME * noise_scroll_speed + id_offset;
	float n = texture(noise_texture, scrolled_uv).r;

	n = n - 0.5;
	float d_from_center = distance(UV, vec2(0.5));
	n = n - smoothstep(0.3, 0.7, d_from_center);
	n = n + 0.5;

	float n_steps = max(toon_steps, 1.0);
	float n_posterized = floor(clamp(n, 0.0, 1.0) * n_steps) / n_steps;
	n = mix(n, n_posterized, toon_strength);

	vec2 centered = UV - vec2(0.5);
	float dist = length(centered) * 2.0;
	float radial = 1.0 - smoothstep(softness, 1.0, dist);

	float combined = radial * (n + silhouette_break * (n - 0.5));
	float final_alpha = COLOR.a * clamp(combined, 0.0, 1.0);

	if (final_alpha < 0.005) {
		discard;
	}

	ALBEDO = COLOR.rgb;
	EMISSION = COLOR.rgb * emission_strength * final_alpha;
	ALPHA = final_alpha;
}
