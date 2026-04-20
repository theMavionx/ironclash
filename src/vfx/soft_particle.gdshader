// Soft billboard particle shader. Uses a radial UV falloff to turn the
// QuadMesh into a soft puff/flame instead of a hard square. Per-particle
// COLOR (set by ParticleProcessMaterial color_ramp) modulates albedo and
// alpha. Optional emission_strength pushes fire above the HDR threshold so
// the world's glow bloom picks it up.
//
// Includes the Godot-standard billboard vertex pattern so the quad always
// faces the camera regardless of GPUParticles3D transform_align setting.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;

// 0 = hard edge, 1 = fully soft / fades from centre.
uniform float softness : hint_range(0.0, 1.0) = 0.55;
// 0 = pure smoke. 4+ = fire (boosts past glow_hdr_threshold = 0.9).
uniform float emission_strength : hint_range(0.0, 10.0) = 0.0;

void vertex() {
	// Billboard: replace the model basis with the camera's basis so the quad
	// always faces the camera. Preserve per-particle scale by reading the
	// length of each model basis column.
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
	// Distance from quad centre, normalised so corners = 1.0.
	vec2 centered = UV - vec2(0.5);
	float dist = length(centered) * 2.0;
	// Soft radial falloff. softness controls where the fade starts.
	float soft = 1.0 - smoothstep(softness, 1.0, dist);
	ALBEDO = COLOR.rgb;
	EMISSION = COLOR.rgb * emission_strength;
	ALPHA = COLOR.a * soft;
}
