extends GPUParticles3D

## Web-compatible smoke "volume". Replaces the prior FogVolume implementation
## which required Forward+ rendering (unavailable in HTML5 / gl_compatibility
## builds). Renders a column of LOD-trick stylized billboard particles using
## [code]src/vfx/spatial_particles_smoke.gdshader[/code] — a single noise texture
## sampled via textureLod, with the LOD level driven per-particle by COLOR.r.
## Each particle's noise progressively "blurs out" over its lifetime, reading
## visually as the wisp dispersing. Technique adapted from Lelu's "Smoke VFX"
## YouTube tutorial (the third / LOD-trick method).
##
## Lifecycle (driven by a single Tween):
##   amount_ratio: 0 → 1 over [member spawn_time]
##   hold for [member sustain_time]
##   amount_ratio: 1 → 0 over [member fade_time] (ease-in)
##   stop emitting, wait [member lifetime] more seconds for in-flight particles
##   to finish, then queue_free.
##
## Process material + draw mesh are built in [method _ready] from exports so
## designers can tune per-instance look without editing a sub-resource graph.
##
## Implements: design/gdd/projectile-system.md (smoke volume section)

const _SHADER_PATH: String = "res://src/vfx/spatial_particles_smoke.gdshader"
const _WEB_SHADER_PATH: String = "res://src/vfx/spatial_particles_smoke_web.gdshader"
const _WEB_SHADER_BILLBOARD_VFX_SCRIPT: Script = preload("res://src/vfx/web_shader_billboard_vfx.gd")
const _SMOKE_TEXTURE_PATH: String = "res://assets/textures/smoke_vfx/T_smoke_b7.png"
const _NOISE_TEXTURE_PATH: String = "res://assets/textures/smoke_vfx/T_Noise_001R.png"
const _CIRCLE_MASK_PATH: String = "res://assets/textures/smoke_vfx/T_VFX_circle_1.png"

@export_group("Animation")
## Time to ramp emission from 0 to full (seconds).
@export var spawn_time: float = 0.3
## Hold time at full emission (seconds).
@export var sustain_time: float = 2.0
## Time to ramp emission from full to 0 (seconds, ease-in).
@export var fade_time: float = 1.5

@export_group("Look")
## Sphere radius (m) where particles are seeded around the node origin.
@export var emission_radius: float = 0.3
## Per-particle peak scale multiplier (smaller = denser cloud, larger = wispier).
@export var particle_scale: float = 1.5
## Tint sent to the shader as smoke_color uniform. Particle COLOR.rgb is
## hijacked to drive LOD, so all per-particle tinting comes from this export.
@export var smoke_color: Color = Color(0.65, 0.65, 0.68, 1.0)
## Highest mip level the LOD trick reaches at end-of-life. 4 keeps texture
## detail visible through most of the lifetime — the original 8 blurred too
## aggressively for a column-shaped plume.
@export var max_lod: float = 4.0

# ---------------------------------------------------------------------------
# Shared resources — generated/loaded once on first instance, reused by all
# subsequent instances to avoid per-spawn file IO and texture allocation.
# ---------------------------------------------------------------------------
static var _shared_shader: Shader = null
static var _shared_smoke_texture: Texture2D = null
static var _shared_noise: Texture2D = null
static var _shared_mask: Texture2D = null


func _ready() -> void:
	var web_build: bool = OS.has_feature("web")
	# Web uses the same smoke shader on CPUParticles3D billboards. That keeps
	# the authored look and particle motion while avoiding the unstable
	# GPUParticles3D custom vertex path in WebGL2.
	if _shared_shader == null:
		_shared_shader = load(_SHADER_PATH) as Shader
		if _shared_shader == null:
			push_warning("SmokeVolume: shader missing at %s" % _SHADER_PATH)
	if _shared_smoke_texture == null:
		_shared_smoke_texture = load(_SMOKE_TEXTURE_PATH) as Texture2D
		if _shared_smoke_texture == null:
			push_warning("SmokeVolume: smoke texture missing at %s" % _SMOKE_TEXTURE_PATH)
	if _shared_noise == null:
		_shared_noise = load(_NOISE_TEXTURE_PATH) as Texture2D
		if _shared_noise == null:
			push_warning("SmokeVolume: noise texture missing at %s" % _NOISE_TEXTURE_PATH)
	if _shared_mask == null:
		_shared_mask = load(_CIRCLE_MASK_PATH) as Texture2D
		if _shared_mask == null:
			push_warning("SmokeVolume: circle mask missing at %s" % _CIRCLE_MASK_PATH)

	if web_build:
		emitting = false
		_build_web_smoke_particles()
		return

	process_material = _build_process_material()
	draw_pass_1 = _build_quad()
	# Generous AABB — particles drift up to ~3 m vertically and ~1 m laterally
	# over their lifetime. Without an explicit AABB, GPUParticles3D defaults to
	# a tiny box and frustum-culls the column the moment its origin leaves view.
	visibility_aabb = AABB(Vector3(-2.0, -1.0, -2.0), Vector3(4.0, 8.0, 4.0))
	amount_ratio = 0.0
	emitting = true

	var tween: Tween = create_tween()
	tween.tween_property(self, "amount_ratio", 1.0, spawn_time)
	tween.tween_interval(sustain_time)
	tween.tween_property(self, "amount_ratio", 0.0, fade_time).set_ease(Tween.EASE_IN)
	# After fade, stop new emission and wait one full particle lifetime so
	# the last in-flight particles finish their fade-out gradient before the
	# node is freed (otherwise the cloud pops out instantly).
	tween.tween_callback(_stop_emitting)
	tween.tween_interval(lifetime)
	tween.tween_callback(queue_free)


func _stop_emitting() -> void:
	emitting = false


# ---------------------------------------------------------------------------
# Resource builders
# ---------------------------------------------------------------------------

func _build_process_material() -> ParticleProcessMaterial:
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = emission_radius
	pm.direction = Vector3(0.0, 1.0, 0.0)
	# Tight spread keeps the column narrow.
	pm.spread = 10.0
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -18.0
	pm.angular_velocity_max = 18.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 1.1
	# No gravity — smoke drifts neutrally so the column stays vertical.
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.7
	pm.scale_max = particle_scale
	# Slight grow over lifetime — keeps the column roughly column-shaped
	# instead of fanning out into a wide mushroom cap.
	var scale_curve: Curve = Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.7))
	scale_curve.add_point(Vector2(1.0, 1.3))
	var scale_tex: CurveTexture = CurveTexture.new()
	scale_tex.curve = scale_curve
	pm.scale_curve = scale_tex
	# COLOR ramp drives the shader:
	#   • RED channel 0 → 1 over lifetime → controls LOD (0 = sharp, 1 = max blur).
	#   • ALPHA channel 0 → 0.7 → 0 → fade-in / fade-out for opacity.
	# Peak 0.7 lets background read through — full 0.95 produced an opaque wall.
	# RGB is hijacked, so visual color comes from the shader's smoke_color uniform.
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(0.0, 0.0, 0.0, 0.0))
	grad.set_offset(0, 0.0)
	grad.add_point(0.2, Color(0.15, 0.0, 0.0, 0.7))
	grad.add_point(0.7, Color(0.6, 0.0, 0.0, 0.55))
	grad.add_point(1.0, Color(1.0, 0.0, 0.0, 0.0))
	var grad_tex: GradientTexture1D = GradientTexture1D.new()
	grad_tex.gradient = grad
	pm.color_ramp = grad_tex
	return pm


func _build_quad() -> QuadMesh:
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(1.5, 1.5)
	if _shared_shader == null:
		quad.material = _build_web_billboard_material()
		return quad
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = _shared_shader
	mat.set_shader_parameter("smoke_texture", _shared_smoke_texture)
	mat.set_shader_parameter("distortion_texture", _shared_noise)
	mat.set_shader_parameter("smoke_color", smoke_color)
	mat.set_shader_parameter("max_lod", max_lod)
	mat.set_shader_parameter("fade_intensity", 1.0)
	mat.set_shader_parameter("min_particle_alpha", 0.0)
	mat.set_shader_parameter("edge_start", 0.22)
	mat.set_shader_parameter("texture_power", 0.72)
	mat.set_shader_parameter("dissolve_strength", 0.16)
	quad.material = mat
	return quad


func _build_web_billboard_material() -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.render_priority = 10
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = smoke_color
	if _shared_smoke_texture != null:
		mat.albedo_texture = _shared_smoke_texture
	return mat


func _build_web_smoke_particles() -> void:
	var tint: Color = smoke_color
	tint.a = 0.82
	var vfx = _WEB_SHADER_BILLBOARD_VFX_SCRIPT.new()
	vfx.name = "WebSmokeParticles"
	add_child(vfx)

	var smoke_count: int = mini(amount, 36)
	for i: int in range(smoke_count):
		vfx.add_card(
			"Smoke%02d" % i,
			_build_web_smoke_shader_material(tint, randf() * 20.0),
			Vector2(1.5, 1.5),
			Vector3.ZERO,
			Vector3(emission_radius, emission_radius * 0.35, emission_radius),
			Vector3(-0.10, 0.45, -0.10),
			Vector3(0.10, 1.05, 0.10),
			0.70,
			1.30,
			lifetime,
			true,
			0.82,
			0.20,
			0.30,
			0.5,
			randf() * lifetime
		)

	var stop_timer: SceneTreeTimer = get_tree().create_timer(spawn_time + sustain_time + fade_time)
	stop_timer.timeout.connect(vfx.stop_looping)
	var done_timer: SceneTreeTimer = get_tree().create_timer(spawn_time + sustain_time + fade_time + lifetime)
	done_timer.timeout.connect(queue_free)


func _build_smoke_lifetime_gradient() -> Gradient:
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(0.0, 0.0, 0.0, 0.0))
	grad.set_offset(0, 0.0)
	grad.add_point(0.2, Color(0.15, 0.0, 0.0, 0.70))
	grad.add_point(0.7, Color(0.6, 0.0, 0.0, 0.55))
	grad.add_point(1.0, Color(1.0, 0.0, 0.0, 0.0))
	return grad


func _build_web_smoke_shader_material(tint: Color, time_offset: float, particle_life_override: float = -1.0) -> Material:
	var web_shader: Shader = load(_WEB_SHADER_PATH) as Shader
	if web_shader == null or _shared_smoke_texture == null:
		var fallback: StandardMaterial3D = _build_web_billboard_material()
		fallback.albedo_color = tint
		fallback.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		return fallback
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = web_shader
	mat.render_priority = 10
	mat.set_shader_parameter("smoke_texture", _shared_smoke_texture)
	mat.set_shader_parameter("distortion_texture", _shared_noise)
	mat.set_shader_parameter("smoke_color", tint)
	mat.set_shader_parameter("max_lod", max_lod)
	mat.set_shader_parameter("fade_intensity", 1.0)
	mat.set_shader_parameter("min_particle_alpha", 0.0)
	mat.set_shader_parameter("edge_start", 0.22)
	mat.set_shader_parameter("texture_power", 0.72)
	mat.set_shader_parameter("dissolve_strength", 0.16)
	mat.set_shader_parameter("time_offset", time_offset)
	mat.set_shader_parameter("particle_life_override", particle_life_override)
	return mat
