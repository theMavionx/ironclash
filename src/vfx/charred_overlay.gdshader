// Charred overlay — applied via material_overlay slot on MeshInstance3D.
// Uses MUL blending so it darkens the underlying material rather than
// replacing it, which preserves the model's silhouette and shading detail.
// World-space XZ noise sampling adds soot variation so the wreck doesn't
// look like a uniform black blob.
shader_type spatial;
render_mode blend_mul, unshaded, cull_disabled;

uniform vec3 char_color : source_color = vec3(0.06, 0.05, 0.04);
uniform float soot_strength : hint_range(0.0, 1.0) = 0.25;
uniform sampler2D soot_noise : hint_default_white;
uniform float soot_scale : hint_range(0.05, 5.0) = 0.7;

varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Sample noise in world XZ so adjacent meshes look continuous, not tiled.
	vec2 nuv = v_world_pos.xz * soot_scale;
	float n = texture(soot_noise, nuv).r;
	// Bias toward darker — wreck reads as charred, not dusty.
	float soot = mix(1.0, n * 0.6 + 0.2, soot_strength);
	ALBEDO = char_color * soot;
}
