// FPV Post-Process Shader
// Applies chromatic aberration, vignette, film grain, desaturation,
// and a warm colour tint to simulate an FPV drone camera feed.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;

// Pixel offset magnitude for RGB channel split (chromatic aberration).
uniform float aberration_strength : hint_range(0.0, 0.05, 0.001) = 0.004;
// Darkness at the screen edges (0 = no vignette, 1 = full black).
uniform float vignette_strength : hint_range(0.0, 1.0, 0.01) = 0.4;
// Intensity of per-frame film grain noise.
uniform float grain_strength : hint_range(0.0, 0.5, 0.01) = 0.12;
// How far to push toward greyscale (0 = full colour, 1 = monochrome).
uniform float desaturation : hint_range(0.0, 1.0, 0.01) = 0.35;
// Positive = warmer (more red, less blue). Negative = cooler.
uniform float warmth : hint_range(-0.3, 0.3, 0.01) = 0.08;

// Screen-space hash for grain — fast and stateless across frames when
// combined with TIME so it flickers like real sensor noise.
float hash(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 uv = SCREEN_UV;

	// Chromatic Aberration: shift R outward and B inward relative to centre.
	vec2 centre_offset = uv - 0.5;
	float r = texture(screen_tex, uv - centre_offset * aberration_strength).r;
	float g = texture(screen_tex, uv).g;
	float b = texture(screen_tex, uv + centre_offset * aberration_strength).b;
	vec3 col = vec3(r, g, b);

	// Desaturation.
	float luma = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, vec3(luma), desaturation);

	// Warm tint.
	col.r = clamp(col.r + warmth, 0.0, 1.0);
	col.b = clamp(col.b - warmth, 0.0, 1.0);

	// Vignette: smooth squared falloff from centre.
	float dist = length(centre_offset) * 2.0;
	float vignette = 1.0 - smoothstep(0.4, 1.4, dist) * vignette_strength;
	col *= vignette;

	// Film grain: noise changes every frame via TIME.
	vec2 grain_uv = FRAGCOORD.xy * 0.7 + vec2(TIME * 73.4, TIME * 41.7);
	float noise = hash(grain_uv) * 2.0 - 1.0;
	col += noise * grain_strength;

	COLOR = vec4(clamp(col, 0.0, 1.0), 1.0);
}
