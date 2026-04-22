// Bullet tracer shader — billboard QuadMesh that reads as a thin round
// streak from any camera angle. Shader-specialist recommended approach:
//   - Cylindrical billboard vertex stage (Y locked to travel direction,
//     X/Z face the camera)
//   - Radial UV falloff on X axis for the "round" look
//   - Lengthwise end-fade for smooth streak tapers (no hard ends)
//   - blend_add + high emission so overlapping shots add brightness and
//     bloom past WorldEnvironment glow_hdr_threshold (0.9) with ACES tonemap
//
// Pair with a QuadMesh whose orientation = FACE_Z so local Y runs along
// the travel direction (set by look_at from muzzle to hit point).
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded;

uniform vec4 core_color : source_color = vec4(1.0, 0.95, 0.63, 1.0);
uniform vec4 glow_color : source_color = vec4(1.0, 0.55, 0.10, 1.0);
uniform float emission_strength : hint_range(1.0, 30.0) = 12.0;
uniform float fade_edge : hint_range(0.0, 0.5) = 0.25;


void vertex() {
	// Cylindrical billboard: keep local Y aligned to the streak length
	// (set by look_at), rotate X/Z around Y so the quad face turns toward
	// the camera. Falls back to the original MODELVIEW when Y is degenerate.
	vec3 streak_y_world = normalize((MODEL_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	vec3 cam_fwd_world = normalize(vec3(INV_VIEW_MATRIX[2][0], INV_VIEW_MATRIX[2][1], INV_VIEW_MATRIX[2][2]));
	vec3 right_world = cross(streak_y_world, cam_fwd_world);
	float right_len = length(right_world);
	if (right_len > 0.001) {
		right_world = right_world / right_len;
		vec3 forward_world = cross(right_world, streak_y_world);
		// Preserve the mesh's world translation.
		vec3 origin_world = MODEL_MATRIX[3].xyz;
		// Preserve per-axis scale so QuadMesh.size still drives length/width.
		float scale_x = length(MODEL_MATRIX[0].xyz);
		float scale_y = length(MODEL_MATRIX[1].xyz);
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			vec4(right_world * scale_x, 0.0),
			vec4(streak_y_world * scale_y, 0.0),
			vec4(forward_world, 0.0),
			vec4(origin_world, 1.0)
		);
	}
}

void fragment() {
	// UV.x in [0..1] across width, UV.y in [0..1] along length.
	float cx = (UV.x - 0.5) * 2.0;  // [-1, 1] width
	float cy = (UV.y - 0.5) * 2.0;  // [-1, 1] length

	// Radial falloff across the width axis — creates the "round" look.
	float radial = 1.0 - smoothstep(0.0, 1.0, abs(cx));

	// Length end-fade: smoothly taper at both tips.
	float end_start = 1.0 - fade_edge;
	float length_fade = 1.0 - smoothstep(end_start, 1.0, abs(cy));

	float a = radial * length_fade;
	if (a < 0.005) {
		discard;
	}

	// Core → glow gradient based on distance from streak axis.
	float t = smoothstep(0.0, 0.85, abs(cx));
	vec3 col = mix(core_color.rgb, glow_color.rgb, t);

	ALBEDO = vec3(0.0);
	EMISSION = col * a * emission_strength;
	ALPHA = a;
}
