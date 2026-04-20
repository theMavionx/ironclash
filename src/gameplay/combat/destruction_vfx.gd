class_name DestructionVFX
extends RefCounted

## Static helpers that turn a healthy vehicle node into a smoking wreck.
## Used by Tank/Heli/Drone controllers in their _on_destroyed handlers.
##
## Two stages:
##   1. apply_charred(vehicle): walks all MeshInstance3D descendants and sets
##      material_overlay to a charred ShaderMaterial (preserves silhouette).
##   2. spawn_smoke_fire(vehicle): instantiates a Node3D under the vehicle
##      with looping smoke + fire GPUParticles3D + a flickering OmniLight3D.
##
## Both stages can be undone (clear_charred / clear_vfx) for the drone respawn flow.

const _CHARRED_SHADER_PATH: String = "res://src/vfx/charred_overlay.gdshader"
const _SOOT_NOISE_PATH: String = "res://assets/textures/3d_noise.png"
const _FLICKER_SCRIPT_PATH: String = "res://src/vfx/fire_flicker.gd"
const _SOFT_PARTICLE_SHADER_PATH: String = "res://src/vfx/soft_particle.gdshader"
const _VFX_NODE_NAME: String = "_DestructionVFX"


## Apply the charred overlay to every MeshInstance3D under [param vehicle].
## Idempotent — re-applying replaces the previous overlay with a fresh instance.
static func apply_charred(vehicle: Node) -> void:
	var shader: Shader = load(_CHARRED_SHADER_PATH) as Shader
	if shader == null:
		push_warning("DestructionVFX: charred shader missing at %s" % _CHARRED_SHADER_PATH)
		return
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	var noise: Texture2D = load(_SOOT_NOISE_PATH) as Texture2D
	if noise != null:
		mat.set_shader_parameter("soot_noise", noise)
	_walk_meshes(vehicle, func(m: MeshInstance3D) -> void:
		m.material_overlay = mat
	)


## Remove the charred overlay from all meshes under [param vehicle].
static func clear_charred(vehicle: Node) -> void:
	_walk_meshes(vehicle, func(m: MeshInstance3D) -> void:
		m.material_overlay = null
	)


## Spawn a self-contained VFX node (smoke column + fire + flicker light) as
## a child of [param vehicle]. Pass [param y_offset] to lift the emitters
## above the model origin (vehicles often sit slightly under their visual centre).
static func spawn_smoke_fire(vehicle: Node3D, y_offset: float = 1.0) -> Node3D:
	# Replace any existing VFX node so respawn doesn't stack effects.
	clear_vfx(vehicle)
	var root: Node3D = Node3D.new()
	root.name = _VFX_NODE_NAME
	root.position = Vector3(0.0, y_offset, 0.0)
	vehicle.add_child(root)
	root.add_child(_build_smoke())
	root.add_child(_build_fire())
	root.add_child(_build_light())
	return root


## Remove the VFX node spawned by spawn_smoke_fire (safe if none exists).
static func clear_vfx(vehicle: Node) -> void:
	var existing: Node = vehicle.get_node_or_null(_VFX_NODE_NAME)
	if existing != null:
		existing.queue_free()


# ---------------------------------------------------------------------------
# Internal builders
# ---------------------------------------------------------------------------

static func _build_smoke() -> GPUParticles3D:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "Smoke"
	p.amount = 24
	p.lifetime = 4.0
	p.preprocess = 1.0
	p.explosiveness = 0.0
	p.randomness = 0.3

	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.6, 0.1, 0.6)
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 18.0
	pm.initial_velocity_min = 1.2
	pm.initial_velocity_max = 2.5
	pm.gravity = Vector3(0.0, -0.15, 0.0)
	pm.scale_min = 0.4
	pm.scale_max = 0.6
	# Grow over lifetime — column widens as it rises.
	var scale_curve: Curve = Curve.new()
	scale_curve.add_point(Vector2(0.0, 1.0))
	scale_curve.add_point(Vector2(1.0, 3.5))
	var scale_tex: CurveTexture = CurveTexture.new()
	scale_tex.curve = scale_curve
	pm.scale_curve = scale_tex
	# Color ramp: dark charcoal at base → warm grey → light ash fading to clear.
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(0.08, 0.07, 0.06, 1.0))
	grad.set_offset(0, 0.0)
	grad.add_point(0.4, Color(0.28, 0.26, 0.24, 0.9))
	grad.add_point(1.0, Color(0.55, 0.53, 0.50, 0.0))
	var grad_tex: GradientTexture1D = GradientTexture1D.new()
	grad_tex.gradient = grad
	pm.color_ramp = grad_tex
	p.process_material = pm

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = _make_soft_material(0.55, 0.0)
	p.draw_pass_1 = quad

	return p


static func _build_fire() -> GPUParticles3D:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "Fire"
	p.amount = 18
	p.lifetime = 0.35
	p.preprocess = 0.2
	p.explosiveness = 0.15
	p.randomness = 0.6

	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.5, 0.1, 0.5)
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 30.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 1.4
	pm.gravity = Vector3(0.0, 0.3, 0.0)  # flames lick upward
	pm.scale_min = 0.15
	pm.scale_max = 0.40
	# Grow then collapse — flickery feel.
	var scale_curve: Curve = Curve.new()
	scale_curve.add_point(Vector2(0.0, 1.0))
	scale_curve.add_point(Vector2(0.7, 1.6))
	scale_curve.add_point(Vector2(1.0, 0.0))
	var scale_tex: CurveTexture = CurveTexture.new()
	scale_tex.curve = scale_curve
	pm.scale_curve = scale_tex
	# Yellow-white core → orange → red ember → fade.
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(1.0, 0.85, 0.30, 1.0))
	grad.set_offset(0, 0.0)
	grad.add_point(0.35, Color(1.0, 0.45, 0.05, 0.9))
	grad.add_point(0.70, Color(0.6, 0.15, 0.02, 0.5))
	grad.add_point(1.0, Color(0.2, 0.05, 0.0, 0.0))
	var grad_tex: GradientTexture1D = GradientTexture1D.new()
	grad_tex.gradient = grad
	pm.color_ramp = grad_tex
	p.process_material = pm

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.3, 0.5)
	# softness 0.4 = tighter falloff (flames are denser than smoke);
	# emission_strength 4.0 pushes past WorldEnvironment glow_hdr_threshold (0.9).
	quad.material = _make_soft_material(0.4, 4.0)
	p.draw_pass_1 = quad

	return p


static func _make_soft_material(softness: float, emission_strength: float) -> ShaderMaterial:
	var shader: Shader = load(_SOFT_PARTICLE_SHADER_PATH) as Shader
	if shader == null:
		push_warning("DestructionVFX: soft particle shader missing at %s" % _SOFT_PARTICLE_SHADER_PATH)
		return null
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("softness", softness)
	mat.set_shader_parameter("emission_strength", emission_strength)
	return mat


static func _build_light() -> OmniLight3D:
	# Pulsing warm light — gives volumetric fog something to glow through.
	# No shadows (3 wrecks × cubemap shadow pass would be expensive).
	var light: OmniLight3D = OmniLight3D.new()
	light.name = "FireGlow"
	light.light_color = Color(1.0, 0.45, 0.10)
	light.light_energy = 2.0
	light.omni_range = 5.0
	light.shadow_enabled = false
	# fire_flicker.gd oscillates light_energy each _process frame.
	var flicker: Script = load(_FLICKER_SCRIPT_PATH) as Script
	if flicker != null:
		light.set_script(flicker)
	return light


# ---------------------------------------------------------------------------
# Mesh walker
# ---------------------------------------------------------------------------

static func _walk_meshes(root: Node, fn: Callable) -> void:
	if root is MeshInstance3D:
		fn.call(root as MeshInstance3D)
	for child: Node in root.get_children():
		_walk_meshes(child, fn)
