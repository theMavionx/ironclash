extends RefCounted
class_name FireTextureGenerator

## Procedural fire teardrop texture generator. Soft anti-aliased boundaries
## + smooth 3-stop brightness gradient (outer 50% → middle 75% → core 100%).
## Replicates Le Lu's hand-painted look without Photoshop.
##
## Usage:
##   preload("res://tools/vfx/generate_fire_texture.gd").generate()

const TEX_SIZE: int = 512
const OUTPUT_PATH: String = "res://assets/textures/fire_vfx/T_fire_diff.png"

# Three nested teardrop layers. Each contributes ADDITIVELY to brightness with
# soft anti-aliased boundaries — produces smooth 0.0 → 0.5 → 0.75 → 1.0 gradient.
# Bulbous proportions: base_width values pushed up so the silhouette reads as
# Le Lu's hand-painted blob shape rather than a sharply-tapered arrow. Each
# layer noticeably wider than the prior tuning iteration.
const LAYER_OUTER := { "base_width": 0.48, "contribution": 0.55, "spike": 0.22, "soft": 0.06 }
const LAYER_MIDDLE := { "base_width": 0.36, "contribution": 0.27, "spike": 0.14, "soft": 0.05 }
const LAYER_CORE := { "base_width": 0.22, "contribution": 0.20, "spike": 0.10, "soft": 0.04 }


static func generate() -> int:
	var img: Image = Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 1.0))

	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 0.014
	noise.seed = 42

	var fine: FastNoiseLite = FastNoiseLite.new()
	fine.noise_type = FastNoiseLite.TYPE_PERLIN
	fine.frequency = 0.045
	fine.seed = 7

	# Walk every pixel once, summing contributions from all three layers.
	# Boolean-painting per layer (the prior approach) produced visible quantization
	# bands; sampling all three at once and adding their soft falloffs gives a
	# continuous gradient with proper sub-pixel anti-aliasing on the silhouette.
	var sz: Vector2i = img.get_size()
	var center_x: float = float(sz.x) * 0.5

	for y in sz.y:
		# v_norm: 0 at image top (flame tip), 1 at image bottom (flame base).
		var v_norm: float = float(y) / float(sz.y - 1)
		# Bulbous taper — stays near full width through the middle 60% then
		# narrows fast at the tip. Le Lu's painted teardrop is rounder than
		# a clean smoothstep; this two-segment curve mimics that:
		#   v_norm < 0.4   → quick ramp 0 → 0.7  (sharp tip)
		#   v_norm 0.4-0.7 → 0.7 → 1.0          (bulb body)
		#   v_norm > 0.7   → plateau at 1.0     (wide round base)
		var flame_t: float
		if v_norm < 0.4:
			flame_t = (v_norm / 0.4) * 0.7
		elif v_norm < 0.7:
			flame_t = 0.7 + ((v_norm - 0.4) / 0.3) * 0.3
		else:
			flame_t = 1.0
		# spike_t: 1 at tip → 0 at base. Tip wobbles, base is anchored.
		var spike_t: float = 1.0 - smoothstep(0.35, 0.95, v_norm)

		for x in sz.x:
			var u: float = (float(x) - center_x) / center_x

			# Per-pixel noise — coords stretched vertically so spikes are
			# vertical streaks rather than circular blobs.
			var nx: float = float(x) * 0.4
			var ny: float = float(y) * 1.8
			var n_coarse: float = noise.get_noise_2d(nx, ny) * 0.5 + 0.5
			var n_fine: float = fine.get_noise_2d(nx, ny * 1.7) * 0.5 + 0.5
			var perturb: float = (n_coarse - 0.5) * spike_t

			# Sum soft contribution from each layer.
			var brightness: float = 0.0
			brightness += _layer_contribution(u, flame_t, perturb, LAYER_OUTER)
			brightness += _layer_contribution(u, flame_t, perturb, LAYER_MIDDLE)
			brightness += _layer_contribution(u, flame_t, perturb, LAYER_CORE)

			# Erosion noise on the inner core for "spikes and holes" Le Lu paints.
			# Only carves the brightest area, so the outer rim stays continuous.
			if brightness > 0.85:
				var hole_n: float = fine.get_noise_2d(float(x) * 1.7, float(y) * 1.3) * 0.5 + 0.5
				if hole_n > 0.62:
					brightness *= 0.6  # carve, but don't fully erase

			brightness = clampf(brightness, 0.0, 1.0)
			img.set_pixel(x, y, Color(brightness, brightness, brightness, 1.0))

	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(OUTPUT_PATH).get_base_dir()):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_PATH).get_base_dir())
	var err: int = img.save_png(OUTPUT_PATH)
	if err == OK:
		print("FireTextureGenerator: saved %s (%dx%d, soft AA)" % [OUTPUT_PATH, TEX_SIZE, TEX_SIZE])
	return err


# Returns this layer's contribution to brightness at (u, flame_t), with a
# soft anti-aliased boundary. The `soft` field controls the AA band width —
# pixels within that band of the boundary get a smooth falloff from full
# contribution to zero.
static func _layer_contribution(u: float, flame_t: float, perturb: float, layer: Dictionary) -> float:
	var base_width: float = layer["base_width"]
	var contribution: float = layer["contribution"]
	var spike_amount: float = layer["spike"]
	var soft: float = layer["soft"]

	var radius: float = base_width * flame_t + perturb * spike_amount
	if radius <= 0.0:
		return 0.0
	var au: float = absf(u)
	# Smooth boundary: full contribution inside radius - soft, zero outside radius,
	# linear fade across the soft band. This is what kills the rectangular look.
	var t: float = smoothstep(radius, radius - soft, au)
	return contribution * t
