// Stylized fire shader — Le Lu pipeline. Web-compatible (gl_compatibility).
//   1. Sample a panning distortion noise.
//   2. Use a vertical anchor mask so the bottom of the flame doesn't wobble.
//   3. Distort the fire UV by the masked noise.
//   4. Sample the pre-painted fire teardrop.
//   5. Multiply by HDR fire_color → bright core triggers bloom.
//
// Sparks (explosion burst) bind a separate material with a different
// fire_texture (white radial circle) — same shader, no special-case logic.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;

uniform sampler2D fire_texture : filter_linear;
uniform sampler2D distortion_texture : filter_linear, repeat_enable;
uniform vec4 fire_color = vec4(4.0, 0.8, 0.0, 1.0);
uniform vec2 distortion_speed = vec2(0.0, -1.0);
uniform float distortion_amount : hint_range(0.0, 0.5) = 0.25;
uniform float anchor_power : hint_range(0.5, 4.0) = 1.5;


void vertex() {
	vec3 cam_world = INV_VIEW_MATRIX[3].xyz;
	vec3 to_cam = cam_world - MODEL_MATRIX[3].xyz;
	to_cam.y = 0.0;
	to_cam = normalize(to_cam);
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 right = normalize(cross(up, to_cam));

	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);

	mat4 billboard = mat4(
		vec4(right * sx, 0.0),
		vec4(up * sy, 0.0),
		vec4(to_cam, 0.0),
		MODEL_MATRIX[3]
	);
	MODELVIEW_MATRIX = VIEW_MATRIX * billboard;
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}


void fragment() {
	// Panning distortion noise.
	vec2 dist_uv = UV + distortion_speed * TIME;
	float dist_n = texture(distortion_texture, dist_uv).r;

	// Anchor mask: 0 at flame base (UV.y=1), 1 at tip (UV.y=0).
	float anchor_t = 1.0 - UV.y;
	float anchor_mask = pow(anchor_t, anchor_power);

	// Distort fire UV — only Y, so the flame licks vertically not sideways.
	vec2 fire_uv = UV;
	fire_uv.y -= (dist_n - 0.5) * distortion_amount * anchor_mask;

	// Sample the painted teardrop.
	vec4 fire_sample = texture(fire_texture, fire_uv);

	// Discard the black background.
	if (fire_sample.r < 0.01) {
		discard;
	}

	vec3 col = fire_sample.rgb * fire_color.rgb;
	ALBEDO = col;
	EMISSION = col;
	ALPHA = fire_sample.r * COLOR.a * fire_color.a;
}
