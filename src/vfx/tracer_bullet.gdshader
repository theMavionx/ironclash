// CS:GO-style bullet tracer — screen-aligned beam billboard on QuadMesh.
//
// Rendering approach:
//   - QuadMesh vertices: VERTEX.y = position along streak, VERTEX.x = width
//     offset (overridden by the shader, size.x has no visual effect)
//   - Vertex stage projects the streak axis into VIEW space, then offsets
//     each vertex perpendicular to the streak IN THE SCREEN PLANE (XY of
//     view space). This gives a true screen-facing beam that is visible
//     from EVERY camera angle, including streaks flying directly at or
//     away from the camera (they shrink to a dot — correct perspective).
//   - Fragment stage: dual gaussian kernel composition — tight white core +
//     wide orange halo — producing a bright near-white center that fades
//     through warm orange at the edges, plus end taper for soft tips.
//     See fragment() comments for exact math and CS:GO color rationale.
//
// Why NOT a cylindrical-billboard quad:
//   cross(streak, camera_forward) = 0 when the streak is parallel to the
//   view direction, leaving the quad edge-on and invisible. A prior
//   attempt used that approach and broke visibility entirely in
//   third-person view.
//
// Why NOT a solid cylinder:
//   Real 3D geometry reads as a "rod", not a beam of light. CS:GO tracers
//   are sub-pixel-thin streaks with a bloom halo — this requires a
//   screen-space rendering, not world-space volume.
//
// Iteration history:
//   v1-v3: pow() falloff — center was orange/yellow because glow_color
//          bled additively into the sum. core_color=(1,0.98,0.90) looked
//          near-white in isolation but after adding orange glow the pixel
//          composite shifted to yellow ("yellow stick" complaint).
//   v4: Gaussian dual-layer with core_strength >> halo_strength. The tight
//       gaussian (k_core~55) concentrates white energy at cx=0 where halo
//       gaussian is still 1.0 but weighted down by halo_strength=0.6,
//       so the white core wins the additive sum by ~5:1 at the center.
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded;

// Core beam color — MUST be pure white (1,1,1). Prior near-white (1,0.98,0.90)
// looked slightly warm in isolation, but after the additive halo sum the center
// pixel composite shifted to yellow. Pure white + strong core_strength ensures
// the center saturates to white even with halo color present.
uniform vec4 core_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
// Halo (outer glow) color — warm orange. Only visually dominant where the tight
// core gaussian has decayed to near-zero (cx > ~0.2).
uniform vec4 halo_color : source_color = vec4(1.0, 0.55, 0.18, 1.0);
uniform float emission_strength : hint_range(1.0, 100.0) = 45.0;
uniform float fade_edge : hint_range(0.0, 0.5) = 0.18;
// beam_width in world metres — 36mm after the AK readability pass. Bloom from
// the HDR emission creates the perceived thickness, so the geometry still
// reads as a tracer instead of a flat orange band.
uniform float beam_width : hint_range(0.001, 0.2) = 0.036;

// Gaussian kernel parameters — exposed as uniforms so they are tunable in the
// Inspector without recompiling. k_core / k_halo are the exponent coefficients
// in exp(-cx^2 * k). Larger k = narrower bell curve.
group_uniforms gaussian;
// core_tightness (k_core): high value = very narrow bright white core.
// At k=55, half-power radius is cx = sqrt(ln2/55) ≈ 0.112 (11% of beam width).
uniform float core_tightness : hint_range(20.0, 100.0) = 55.0;
// halo_tightness (k_halo): low value = wide soft orange halo.
// At k=5, half-power radius is cx = sqrt(ln2/5) ≈ 0.372 (37% of beam width).
uniform float halo_tightness : hint_range(1.0, 15.0) = 5.0;
// core_strength >> halo_strength: ensures cx=0 composite is white-dominant.
// Center math (cx=0, both gaussians = 1.0):
//   col = halo_color * halo_strength * 1 + core_color * core_strength * 1
//       = (1,0.55,0.18)*0.6 + (1,1,1)*3.2
//       = (0.6,0.33,0.108) + (3.2,3.2,3.2)
//       = (3.8, 3.53, 3.308)
//   Normalised: ~(1.0, 0.929, 0.871) — warm white, not yellow. Correct.
uniform float core_strength : hint_range(0.5, 5.0) = 3.2;
uniform float halo_strength : hint_range(0.0, 2.0) = 0.6;
group_uniforms;


void vertex() {
	// Streak axis origin point (on the beam center line) for this vertex.
	// VERTEX.y determines which point along the streak this vertex sits at;
	// VERTEX.x will be discarded for position — replaced by a perpendicular
	// offset in view space below.
	vec3 axis_pos_local = vec3(0.0, VERTEX.y, 0.0);
	vec4 axis_pos_view = MODELVIEW_MATRIX * vec4(axis_pos_local, 1.0);

	// Streak direction in VIEW space — local +Y (the quad's length axis)
	// transformed into view space by the modelview matrix. The .w = 0.0
	// skips the translation, giving us a direction vector.
	vec3 streak_dir_view = (MODELVIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;

	// Project streak direction onto the screen plane (view-space XY) and
	// pick a perpendicular. When the streak is nearly parallel to the view
	// direction (XY projection length ~ 0) the beam SHOULD appear as a dot
	// in screen space — we still need a valid perpendicular to avoid NaN,
	// so we fall back to a canonical horizontal direction.
	vec2 streak_screen = streak_dir_view.xy;
	float screen_len = length(streak_screen);
	vec2 perp_screen;
	if (screen_len < 0.001) {
		perp_screen = vec2(1.0, 0.0);
	} else {
		vec2 dir_norm = streak_screen / screen_len;
		perp_screen = vec2(-dir_norm.y, dir_norm.x);
	}

	// Apply the perpendicular offset in view space. VERTEX.x for a stock
	// QuadMesh with size = (1.0, L) ranges in [-0.5, 0.5], so multiplying
	// by 2 * beam_width gives a total quad width of 2 * beam_width in
	// view-space meters. PROJECTION_MATRIX then foreshortens it properly.
	vec3 offset_view = vec3(perp_screen * VERTEX.x * 2.0 * beam_width, 0.0);
	vec3 final_view = axis_pos_view.xyz + offset_view;

	POSITION = PROJECTION_MATRIX * vec4(final_view, 1.0);
}


void fragment() {
	// UV conventions from QuadMesh (FACE_Z, size=(1, L)):
	//   UV.x in [0, 1] across the width (width direction set by vertex stage)
	//   UV.y in [0, 1] along the length (streak direction)
	float cx = (UV.x - 0.5) * 2.0;  // [-1, 1] centre-relative width coordinate
	float cy = (UV.y - 0.5) * 2.0;  // [-1, 1] centre-relative length coordinate

	// --- Length-wise end taper ---
	// Smooth the beam tips so they don't have hard square cuts. The discard
	// eliminates fully-transparent fragments before the gaussian math runs,
	// saving fragment ALU on the tips.
	float end_start = 1.0 - fade_edge;
	float length_fade = 1.0 - smoothstep(end_start, 1.0, abs(cy));
	if (length_fade < 0.003) {
		discard;
	}

	// --- Dual gaussian kernels across beam width ---
	//
	// Gaussian bell: exp(-cx^2 * k)
	//   k_core (core_tightness) is high  → narrow, peaky hot center
	//   k_halo (halo_tightness) is low   → wide, soft outer glow
	//
	// Using gaussians instead of pow(1-|cx|, n):
	//   - Gaussian is symmetric and smooth through zero by construction.
	//   - At cx=0 both equal 1.0, so the strength coefficients decide the
	//     composite color directly — easy to reason about.
	//   - Gaussian tails reach true zero asymptotically; pow() leaves a
	//     visible discontinuity at cx=±1 boundary, causing edge banding.
	float cx2 = cx * cx;
	float core_gauss = exp(-cx2 * core_tightness);  // tight white center
	float halo_gauss = exp(-cx2 * halo_tightness);  // wide orange halo

	// --- Color composition (additive, strength-weighted) ---
	//
	// CRITICAL: do NOT use mix() here — mix() would lerp colors and cap at
	// component-1.0, destroying the HDR overbright needed for bloom. We want
	// additive sum in HDR space. core_strength >> halo_strength keeps the
	// cx=0 pixel white-dominant (see uniform comments for worked values).
	//
	// Halo-only region (cx ≈ 0.3):
	//   core_gauss ≈ exp(-0.09*55) ≈ 0.007  (white contribution ~negligible)
	//   halo_gauss ≈ exp(-0.09*5)  ≈ 0.638  (orange dominates)
	//   → reads as warm orange. Correct.
	vec3 col = halo_color.rgb * halo_gauss * halo_strength
	         + core_color.rgb * core_gauss * core_strength;

	// Intensity scalar for length fade. The maximum of the two weighted
	// gaussians drives alpha — core peak (3.2) is used so the halo doesn't
	// add phantom width to the alpha mask.
	float intensity = length_fade * max(halo_gauss * halo_strength + core_gauss * core_strength, 0.0);

	// --- HDR emission ---
	// Multiply by emission_strength before writing. With emission_strength=45
	// the cx=0 peak RGB is ~(171, 159, 149) — far past the glow_hdr_threshold
	// of 0.9 set in WorldEnvironment. Bloom then expands the apparent beam
	// width to a CS:GO-like radius without requiring wide geometry.
	//
	// GODOT 4 UNSHADED GOTCHA: render_mode unshaded means the pipeline writes
	// only ALBEDO to FRAG_COLOR. EMISSION is NOT automatically written to the
	// colour output in unshaded mode — it would be consumed by the lighting
	// pass which is skipped. We write to BOTH so the shader works correctly
	// whether used in an unshaded or (future) lit context, and so Godot's
	// glow pre-pass (which samples EMISSION separately) still fires.
	vec3 bright = col * intensity * emission_strength;
	ALBEDO = bright;
	EMISSION = bright;
	ALPHA = clamp(intensity, 0.0, 1.0);
}
