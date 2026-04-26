@tool
extends Node3D

## Le Lu "Stylized Fire shader for beginners" setup, faithful to the video:
##   • FireA: ONE quad, amount=1, gravity=0, lifetime≈infinite. The shader's
##     UV distortion is what makes the flame dance — there's no particle
##     spawn/die cycle on the fire itself.
##   • Smoke: separate GPUParticles3D with 15 particles, sphere emission,
##     spinning + damped, scale curve big→small, alpha 0→1→0.
##   • Embers: same recipe as smoke but smaller particles, brighter HDR color.
##
## Rebuilt in code because the editor's autosave keeps stripping shader_param
## lines from inline ShaderMaterial sub-resources.

const SHADER_PATH: String = "res://src/vfx/spatial_particles_fire.gdshader"
const FIRE_TEX_PATH: String = "res://assets/textures/fire_vfx/T_fire_diff.png"
const NOISE_PATH: String = "res://assets/textures/smoke_vfx/T_Noise_001R.png"
const SMOKE_SHADER_PATH: String = "res://src/vfx/spatial_particles_smoke.gdshader"
const SMOKE_TEX_PATH: String = "res://assets/textures/smoke_vfx/T_smoke_b7.png"
const CIRCLE_MASK_PATH: String = "res://assets/textures/smoke_vfx/T_VFX_circle_1.png"

const FIRE_COLOR: Color = Color(4.0, 0.8, 0.0, 1.0)


func _ready() -> void:
	var shader: Shader = load(SHADER_PATH) as Shader
	var fire_tex: Texture2D = load(FIRE_TEX_PATH) as Texture2D
	var noise: Texture2D = load(NOISE_PATH) as Texture2D
	if shader == null or fire_tex == null or noise == null:
		push_warning("FireTest: missing shader/fire_tex/noise")
		return

	_apply_fire("FireA", shader, fire_tex, noise)
	_ensure_smoke_layer()
	_ensure_ember_layer(noise)


# ---------------------------------------------------------------------------
# Fire — ONE static particle. Shader does all the visual work.
# ---------------------------------------------------------------------------
func _apply_fire(node_name: String, shader: Shader, fire_tex: Texture2D, noise: Texture2D) -> void:
	var p: GPUParticles3D = get_node_or_null(node_name) as GPUParticles3D
	if p == null:
		return

	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("fire_texture", fire_tex)
	mat.set_shader_parameter("distortion_texture", noise)
	mat.set_shader_parameter("fire_color", FIRE_COLOR)
	mat.set_shader_parameter("distortion_speed", Vector2(0.0, -1.4))  # faster pan = more dance
	mat.set_shader_parameter("distortion_amount", 0.28)  # slightly above Le Lu's "/4" for visible flicker
	mat.set_shader_parameter("anchor_power", 1.2)  # less aggressive anchor → top wobbles more

	var quad: QuadMesh = QuadMesh.new()
	# Bulbous aspect — close to 1:1 like Le Lu's reference, not a tall arrow.
	quad.size = Vector2(1.1, 1.3)
	quad.material = mat
	p.draw_passes = 1
	p.draw_pass_1 = quad

	# Le Lu's exact recipe: one persistent particle, no gravity, no spread.
	p.amount = 1
	p.lifetime = 100.0  # effectively infinite — the single particle never dies
	p.preprocess = 0.0
	p.randomness = 0.0

	# Render fire on top of smoke (sorting_offset=2 in Le Lu's tutorial).
	p.sorting_offset = 2.0

	# Strip any process-material complexity from the .tscn — fire is static.
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.gravity = Vector3.ZERO
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 0.0
	pm.initial_velocity_min = 0.0
	pm.initial_velocity_max = 0.0
	pm.scale_min = 1.0
	pm.scale_max = 1.0
	# Static color — particle COLOR.a stays at 1, shader's texture alpha
	# handles the flame outline.
	p.process_material = pm


# ---------------------------------------------------------------------------
# Smoke — Le Lu's exact GPU-particle recipe.
# ---------------------------------------------------------------------------
func _ensure_smoke_layer() -> void:
	if has_node("Smoke"):
		return
	var smoke: GPUParticles3D = GPUParticles3D.new()
	smoke.name = "Smoke"
	smoke.amount = 15           # Le Lu: 15
	smoke.lifetime = 1.6        # Le Lu: 1.6
	smoke.preprocess = 0.5
	smoke.randomness = 0.1      # Le Lu: 0.1
	smoke.fixed_fps = 60        # Le Lu: 60
	smoke.position = Vector3(0.0, 1.0, 0.0)
	smoke.visibility_aabb = AABB(Vector3(-1.5, -0.5, -1.5), Vector3(3.0, 5.0, 3.0))

	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.2     # Le Lu: 0.2
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 90.0                    # Le Lu: ±90°
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -180.0    # Le Lu: ±180°
	pm.angular_velocity_max = 180.0
	pm.gravity = Vector3(0.0, 5.0, 0.0)  # Le Lu: gravity Y = -5 → upward (Godot's -Y is down, so +Y for upward)
	pm.linear_accel_min = -2.2          # Le Lu: damping 1.5–2.2 (negative accel)
	pm.linear_accel_max = -1.5
	pm.scale_min = 0.5                  # Le Lu: 0.5
	pm.scale_max = 1.2                  # Le Lu: 1.2
	# Scale curve: start big, end small (Le Lu's curve).
	var sc: Curve = Curve.new()
	sc.add_point(Vector2(0.0, 1.0))
	sc.add_point(Vector2(1.0, 0.3))
	var sct: CurveTexture = CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	# Color ramp: alpha 0 → 1 → 0 (Le Lu's gradient).
	# RED also drives the LOD trick in our smoke shader (sharp → blurred).
	var grad: Gradient = Gradient.new()
	grad.add_point(0.0, Color(0.0, 0.0, 0.0, 0.0))
	grad.add_point(0.2, Color(0.2, 0.0, 0.0, 0.7))
	grad.add_point(0.7, Color(0.7, 0.0, 0.0, 0.4))
	grad.add_point(1.0, Color(1.0, 0.0, 0.0, 0.0))
	var grad_tex: GradientTexture1D = GradientTexture1D.new()
	grad_tex.gradient = grad
	pm.color_ramp = grad_tex
	smoke.process_material = pm

	var smoke_shader: Shader = load(SMOKE_SHADER_PATH) as Shader
	var smoke_noise: Texture2D = load(NOISE_PATH) as Texture2D
	var smoke_tex: Texture2D = load(SMOKE_TEX_PATH) as Texture2D
	if smoke_shader and smoke_noise and smoke_tex:
		var smat: ShaderMaterial = ShaderMaterial.new()
		smat.shader = smoke_shader
		smat.set_shader_parameter("smoke_texture", smoke_tex)
		smat.set_shader_parameter("distortion_texture", smoke_noise)
		smat.set_shader_parameter("smoke_color", Color(0.4, 0.36, 0.32, 1.0))
		smat.set_shader_parameter("max_lod", 5.0)
		smat.set_shader_parameter("fade_intensity", 0.7)
		smat.set_shader_parameter("min_particle_alpha", 0.0)
		smat.set_shader_parameter("edge_start", 0.22)
		smat.set_shader_parameter("texture_power", 0.72)
		smat.set_shader_parameter("dissolve_strength", 0.16)
		var quad: QuadMesh = QuadMesh.new()
		quad.size = Vector2(1.0, 1.0)
		quad.material = smat
		smoke.draw_pass_1 = quad

	add_child(smoke)


# ---------------------------------------------------------------------------
# Embers — Le Lu: "same as smoke but smaller particle texture and smaller size".
# ---------------------------------------------------------------------------
func _ensure_ember_layer(noise: Texture2D) -> void:
	if has_node("Embers"):
		return
	var embers: GPUParticles3D = GPUParticles3D.new()
	embers.name = "Embers"
	embers.amount = 25
	embers.lifetime = 2.0
	embers.preprocess = 0.5
	embers.randomness = 0.4
	embers.fixed_fps = 60
	embers.position = Vector3(0.0, 0.5, 0.0)
	embers.visibility_aabb = AABB(Vector3(-2.0, -0.5, -2.0), Vector3(4.0, 6.0, 4.0))

	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.15
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 25.0
	pm.gravity = Vector3(0.0, 1.5, 0.0)
	pm.initial_velocity_min = 0.6
	pm.initial_velocity_max = 1.5
	pm.scale_min = 0.04
	pm.scale_max = 0.10
	var sc: Curve = Curve.new()
	sc.add_point(Vector2(0.0, 1.0))
	sc.add_point(Vector2(1.0, 0.0))
	var sct: CurveTexture = CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var grad: Gradient = Gradient.new()
	grad.add_point(0.0, Color(1.0, 0.9, 0.5, 0.0))
	grad.add_point(0.15, Color(1.0, 0.7, 0.2, 1.0))
	grad.add_point(1.0, Color(0.6, 0.1, 0.0, 0.0))
	var grad_tex: GradientTexture1D = GradientTexture1D.new()
	grad_tex.gradient = grad
	pm.color_ramp = grad_tex
	embers.process_material = pm

	var mask: Texture2D = load(CIRCLE_MASK_PATH) as Texture2D
	var shader: Shader = load(SHADER_PATH) as Shader
	if mask and shader and noise:
		var emat: ShaderMaterial = ShaderMaterial.new()
		emat.shader = shader
		emat.set_shader_parameter("fire_texture", mask)
		emat.set_shader_parameter("distortion_texture", noise)
		emat.set_shader_parameter("fire_color", Color(8.0, 3.0, 0.5, 1.0))
		emat.set_shader_parameter("distortion_speed", Vector2(0.0, 0.0))
		emat.set_shader_parameter("distortion_amount", 0.0)
		emat.set_shader_parameter("anchor_power", 1.0)
		var equad: QuadMesh = QuadMesh.new()
		equad.size = Vector2(0.18, 0.18)
		equad.material = emat
		embers.draw_pass_1 = equad

	add_child(embers)
