// LOD-trick stylized smoke. Single noise texture sampled via textureLod —
// the mip level is driven per-particle by COLOR.r so the same noise texture
// progressively "blurs out" over each particle's lifetime. The lower mip
// levels of a 256² seamless Perlin texture converge on a uniform gray, which
// after the circle-mask multiply reads visually as the smoke wisp dispersing.
//
// Adapted from Lelu's "Smoke VFX" tutorial (3rd method) for Godot 4.
//
// Usage:
//   • noise_texture  : seamless tileable noise (e.g. T_Noise_001R), MUST be
//                      imported with mipmaps/generate=true, filter=linear_mipmap.
//   • circle_mask    : radial alpha mask (e.g. T_VFX_circle_1) to kill the
//                      square corners of the noise quad.
//   • smoke_color    : uniform tint, since particle COLOR is hijacked for LOD.
//   • max_lod        : highest mip the trick reaches at end-of-life. 8 ≈ 1×1
//                      for a 256² source, giving a fully diffuse blob.
//
// The driving ParticleProcessMaterial must have a color_ramp whose ALPHA
// goes 0 → ~1 → 0 (visual fade) and whose RED channel goes 0 → 1 (LOD ramp).
// The shader treats COLOR.r as the LOD parameter and COLOR.a as the fade.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;

// ---------------------------------------------------------------------------
// Uniforms
// ---------------------------------------------------------------------------

uniform sampler2D noise_texture : filter_linear_mipmap, repeat_enable;
uniform sampler2D circle_mask : filter_linear, hint_default_white;
uniform vec4 smoke_color : source_color = vec4(0.55, 0.53, 0.50, 1.0);
// Highest mip the trick reaches at end-of-life. Higher = more pronounced
// "fade through blur". 8 maps the 256² source down to 1×1 (uniform gray).
uniform float max_lod : hint_range(0.0, 12.0, 0.1) = 8.0;
// Final opacity multiplier — lets designers dial the smoke down without
// touching the gradient. Multiplied on top of COLOR.a × mask × noise.
uniform float fade_intensity : hint_range(0.0, 2.0, 0.05) = 1.0;


// ---------------------------------------------------------------------------
// Vertex — standard GPUParticles3D billboard. Replaces the model basis with
// the camera basis while preserving per-particle scale (read from the length
// of each MODEL_MATRIX column). Same pattern Godot's StandardMaterial3D uses
// when "Particle Billboard" is selected.
// ---------------------------------------------------------------------------
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


// ---------------------------------------------------------------------------
// Fragment — sample noise at LOD driven by COLOR.r, multiply by circle mask
// to remove square corners, multiply by COLOR.a for opacity fade.
// ---------------------------------------------------------------------------
void fragment() {
	// COLOR.r ∈ [0, 1] from particle color ramp → LOD ∈ [0, max_lod].
	// LOD 0 = full-resolution noise (sharp wisps); LOD max_lod = blurred to
	// nearly uniform gray. The progression is what produces the "smoke
	// dispersing" look without any actual frame animation.
	float lod_level = COLOR.r * max_lod;
	float noise = textureLod(noise_texture, UV, lod_level).r;

	// Circle mask kills the texture's square edges so the silhouette stays round.
	float mask = texture(circle_mask, UV).r;

	float alpha = noise * mask * COLOR.a * fade_intensity;
	if (alpha < 0.005) {
		discard;
	}

	ALBEDO = smoke_color.rgb;
	ALPHA = alpha;
}
