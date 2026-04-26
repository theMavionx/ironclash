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
const _SMOKE_SHADER_PATH: String = "res://src/vfx/spatial_particles_smoke.gdshader"
const _FIRE_SHADER_PATH: String = "res://src/vfx/spatial_particles_fire.gdshader"
const _SMOKE_NOISE_TEXTURE_PATH: String = "res://assets/textures/smoke_vfx/T_Noise_001R.png"
const _SMOKE_CIRCLE_MASK_PATH: String = "res://assets/textures/smoke_vfx/T_VFX_circle_1.png"
const _FIRE_TEARDROP_PATH: String = "res://assets/textures/fire_vfx/T_fire_diff.png"
const _VFX_NODE_NAME: String = "_DestructionVFX"

# Shared textures — loaded once on first material build, reused by every
# subsequent smoke/fire/spark instance.
#  • smoke_noise — distortion / LOD noise. Smoke shader samples via textureLod
#    (mipmaps required), fire shader uses plain texture (filter_linear).
#  • circle_mask — radial alpha mask. Used by smoke (kills square corners) AND
#    by sparks (round bright dots).
#  • fire_teardrop — procedurally-painted 3-layer fire shape from
#    tools/vfx/generate_fire_texture.gd. Used by flame columns; sparks use
#    the circle_mask instead since their tiny quads can't show teardrop detail.
static var _shared_smoke_noise: Texture2D = null
static var _shared_circle_mask: Texture2D = null
static var _shared_fire_teardrop: Texture2D = null


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


## Spawn a free-flying RigidBody3D turret wreck. The ENTIRE Model subtree
## (with Skeleton3D + skinned meshes) is duplicated and parented to the
## RigidBody3D, then all non-turret meshes are hidden. This is the only
## approach that renders correctly in Godot 4.3 — skinned vertex format
## requires a live Skeleton3D to provide the matrix palette; setting
## skin=null on a fresh MeshInstance3D leaves the vertices undrawn.
##
## [param world_root] is where the debris is parented.
## [param model_node] is the vehicle's Model subscene that contains the Armature.
## [param turret_bone] / [param barrel_bone] are bone indices in the skeleton.
## [param turret_pose] / [param barrel_pose] are the CURRENT bone rotations to
## freeze on the duplicated skeleton so the debris matches the aim at death.
## [param turret_world] is the bone's world pose — used as the debris spawn
## transform.
## [param spawn_world] is the debris RigidBody's world transform — pass the
## VEHICLE'S SKELETON world transform (not the turret bone's world). Placing
## the rigidbody at the skeleton root means the duplicated Model subtree
## renders with its bones at their normal skeleton-relative offsets.
## [param keep_mesh_names] is the list of MeshInstance3D names to keep visible
## on the debris (e.g. ["TankBody_001", "TankBody_002"]). Every other mesh in
## the duplicated subtree is hidden — hides hull/wheels/treads.
## [param turret_bone_local] is the turret bone's pose in skeleton-local
## space (from [code]skeleton.get_bone_global_pose(turret_bone)[/code]).
## Used to offset the cloned skeleton so the turret BONE sits at the
## RigidBody origin — gives a rotation pivot at the visible turret centre.
static func spawn_turret_debris(
	world_root: Node,
	model_node: Node3D,
	turret_bone: int,
	barrel_bone: int,
	turret_pose: Quaternion,
	barrel_pose: Quaternion,
	spawn_world: Transform3D,
	turret_bone_local: Transform3D,
	keep_mesh_names: PackedStringArray,
	mass: float = 500.0,
	upward_velocity: float = 12.0,
	horizontal_drift_max: float = 1.5,
	tumble_velocity_max: float = 6.0,
	self_destruct_after: float = 30.0
) -> RigidBody3D:
	if model_node == null:
		push_warning("DestructionVFX: model_node null, skipping cook-off")
		return null

	# Build the rigid body programmatically.
	var debris: RigidBody3D = RigidBody3D.new()
	debris.mass = mass
	debris.gravity_scale = 1.0
	debris.can_sleep = true
	# Isolated "debris" layer: bit 2 (layer 3). Projectile masks are 0b11
	# (layers 1+2), so shells pass through the flying turret instead of
	# triggering impact VFX on it.
	debris.collision_layer = 0b100
	# Start with NO collision — physics can't penetrate-resolve against the
	# tank hull on frame 0. Re-enable mask=0b001 (world/ground) after 0.3s
	# via a deferred timer, once the debris has flown clear of the hull.
	debris.collision_mask = 0
	debris.linear_damp = 0.05
	debris.angular_damp = 0.3
	var phys_mat: PhysicsMaterial = PhysicsMaterial.new()
	phys_mat.bounce = 0.2
	phys_mat.friction = 0.8
	phys_mat.rough = true
	debris.physics_material_override = phys_mat

	# Collision shape: rough bounds of turret + barrel.
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(1.5, 0.6, 2.0)
	shape.shape = box
	debris.add_child(shape)

	# Duplicate the WHOLE Model subtree. Default flags — USE_INSTANTIATION
	# broke the clone on this GLB (index-out-of-bounds in children_cache).
	# The "Child node disappeared" warnings are non-fatal Godot quirks.
	var model_copy: Node3D = model_node.duplicate() as Node3D
	debris.add_child(model_copy)
	# Find the cloned Skeleton3D and freeze it at the destruction-frame pose.
	var skel_copy: Skeleton3D = _find_skeleton(model_copy)
	if skel_copy != null:
		# Reset all bones to rest pose first, then re-apply just turret + barrel
		# so the wreck visually matches the aim at the moment of death.
		skel_copy.reset_bone_poses()
		if turret_bone != -1:
			skel_copy.set_bone_pose_rotation(turret_bone, turret_pose)
		if barrel_bone != -1:
			skel_copy.set_bone_pose_rotation(barrel_bone, barrel_pose)
	# Hide every MeshInstance3D whose name ISN'T in keep_mesh_names.
	_hide_meshes_except(model_copy, keep_mesh_names)

	# Parent to world root BEFORE setting global_transform.
	world_root.add_child(debris)
	debris.global_transform = spawn_world
	# Exclude collision with any PhysicsBody3D at the spawn point.
	if model_node != null:
		var donor: Node = model_node.get_parent()
		if donor is PhysicsBody3D:
			debris.add_collision_exception_with(donor as PhysicsBody3D)
	# Offset the cloned skeleton so the TURRET BONE lands at the debris origin.
	# Without this, the skeleton sits at debris origin and bones are offset
	# upward, making the rigidbody's rotation pivot below the visible turret
	# — the turret would dip below ground during tumble.
	# Math: skeleton.global * turret_bone_local = debris.global (desired)
	#     → skeleton.global = debris.global * turret_bone_local.inverse()
	if skel_copy != null:
		skel_copy.global_transform = spawn_world * turret_bone_local.affine_inverse()

	# Set velocities DIRECTLY (m/s and rad/s) instead of impulses. Bypasses
	# any mass-synchronization issues with the physics server on spawn.
	# Caller passes desired velocities (not impulses) via the _velocity params.
	debris.sleeping = false
	var drift_x: float = randf_range(-horizontal_drift_max, horizontal_drift_max)
	var drift_z: float = randf_range(-horizontal_drift_max, horizontal_drift_max)
	debris.linear_velocity = Vector3(drift_x, upward_velocity, drift_z)
	var tumble_axis: Vector3 = Vector3(
		randf_range(-1.0, 1.0),
		randf_range(-0.3, 0.3),
		randf_range(-1.0, 1.0)
	).normalized()
	debris.angular_velocity = tumble_axis * tumble_velocity_max

	# Note: hiding of the original turret/barrel meshes is the caller's
	# responsibility (TankController._spawn_cook_off_debris) — it has direct
	# refs and knows the donor vehicle's mesh hierarchy.

	# Enable ground collision after 0.3s — debris is well clear of hull by then.
	var enable_col_timer: SceneTreeTimer = world_root.get_tree().create_timer(0.3)
	enable_col_timer.timeout.connect(func() -> void:
		if is_instance_valid(debris):
			debris.collision_mask = 0b001
	)

	# self_destruct_after <= 0 → debris stays forever (wreck persists).
	# Positive value schedules a queue_free after that many seconds.
	if self_destruct_after > 0.0:
		var timer: SceneTreeTimer = world_root.get_tree().create_timer(self_destruct_after)
		timer.timeout.connect(debris.queue_free)

	return debris


## Recursive depth-first search for a Skeleton3D descendant.
static func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root as Skeleton3D
	for child: Node in root.get_children():
		var found: Skeleton3D = _find_skeleton(child)
		if found != null:
			return found
	return null


## Hide every MeshInstance3D whose name is NOT in [param keep_names].
## Used by spawn_turret_debris to hide the hull/wheels/treads while keeping
## only the turret and barrel meshes visible on the flying wreck.
static func _hide_meshes_except(root: Node, keep_names: PackedStringArray) -> void:
	for child: Node in root.get_children():
		if child is MeshInstance3D and not (child.name in keep_names):
			(child as MeshInstance3D).visible = false
		_hide_meshes_except(child, keep_names)


## Collect all MeshInstance3D names under [param root] into [param out].
static func _collect_mesh_names(root: Node, out: Array[String]) -> void:
	if root is MeshInstance3D:
		out.append(String(root.name))
	for child: Node in root.get_children():
		_collect_mesh_names(child, out)


## Collect names of VISIBLE MeshInstance3D nodes. Uses local position only
## because this is called BEFORE add_child to world_root — global_position
## is undefined on nodes not in the scene tree.
static func _collect_visible_mesh_info(root: Node, out: Array[String]) -> void:
	if root is MeshInstance3D and (root as MeshInstance3D).visible:
		var mi: MeshInstance3D = root as MeshInstance3D
		out.append("%s (local=%v)" % [mi.name, mi.position])
	for child: Node in root.get_children():
		_collect_visible_mesh_info(child, out)


# ---------------------------------------------------------------------------
# Internal builders
# ---------------------------------------------------------------------------

static func _build_smoke() -> GPUParticles3D:
	# Mirrors smoke_volume.gd's particle settings (which the user calibrated
	# against a Unity reference image of a dense mushroom plume) so wreck
	# columns read as solid mass, not as scattered puffs.
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "Smoke"
	p.amount = 60
	p.lifetime = 3.0
	p.preprocess = 1.0
	p.explosiveness = 0.0
	p.randomness = 0.4

	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.3
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 10.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 1.1
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.7
	pm.scale_max = 1.5
	var scale_curve: Curve = Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.7))
	scale_curve.add_point(Vector2(1.0, 1.3))
	var scale_tex: CurveTexture = CurveTexture.new()
	scale_tex.curve = scale_curve
	pm.scale_curve = scale_tex
	# COLOR ramp drives the LOD-trick smoke shader:
	#   • RED 0 → 1 over lifetime → LOD 0 → max_lod (sharp → fully blurred).
	#   • ALPHA 0 → 0.7 → 0 → fade-in / fade-out, peak 0.7 lets sky show through.
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(0.0, 0.0, 0.0, 0.0))
	grad.set_offset(0, 0.0)
	grad.add_point(0.2, Color(0.15, 0.0, 0.0, 0.7))
	grad.add_point(0.7, Color(0.6, 0.0, 0.0, 0.55))
	grad.add_point(1.0, Color(1.0, 0.0, 0.0, 0.0))
	var grad_tex: GradientTexture1D = GradientTexture1D.new()
	grad_tex.gradient = grad
	pm.color_ramp = grad_tex
	p.process_material = pm

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(1.5, 1.5)
	# Medium-light grey tint — atmospheric without the blinding white from the
	# previous tuning iteration. max_lod=4 keeps noise detail visible.
	quad.material = _make_smoke_material(Color(0.65, 0.65, 0.68, 1.0), 4.0)
	p.draw_pass_1 = quad

	return p


static func _build_fire() -> GPUParticles3D:
	# Wreck flame — multiple short-lived flame licks dancing at the wreck base.
	# Le Lu uses a single persistent particle for a torch flame, but a wreck
	# needs the chaotic multi-lick look so we keep amount=12 with random spread.
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "Fire"
	p.amount = 16
	p.lifetime = 1.4
	p.preprocess = 0.4
	p.explosiveness = 0.0
	p.randomness = 0.5
	# Render fire ON TOP of smoke (Le Lu's sorting_offset=2 trick) — without
	# this, the smoke quad covers the flame from camera-facing angles.
	p.sorting_offset = 2.0

	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.5, 0.1, 0.5)
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 12.0
	pm.initial_velocity_min = 0.2
	pm.initial_velocity_max = 0.6
	pm.gravity = Vector3(0.0, 0.6, 0.0)  # buoyant — flames rise slowly
	# Bigger flames — peak ~1m tall to read clearly against the smoke column.
	pm.scale_min = 0.7
	pm.scale_max = 1.3
	# Grow then collapse — flickery feel.
	var scale_curve: Curve = Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.6))
	scale_curve.add_point(Vector2(0.5, 1.0))
	scale_curve.add_point(Vector2(1.0, 0.4))
	var scale_tex: CurveTexture = CurveTexture.new()
	scale_tex.curve = scale_curve
	pm.scale_curve = scale_tex
	# COLOR.a drives the shader's ALPHA fade — alpha 0 → 1 → 0 over lifetime.
	# RGB values are ignored by the Le Lu shader (it uses fire_color uniform),
	# so the gradient is effectively pure alpha animation.
	var grad: Gradient = Gradient.new()
	grad.add_point(0.0, Color(1.0, 1.0, 1.0, 0.0))
	grad.add_point(0.15, Color(1.0, 1.0, 1.0, 1.0))
	grad.add_point(0.7, Color(1.0, 1.0, 1.0, 0.85))
	grad.add_point(1.0, Color(1.0, 1.0, 1.0, 0.0))
	var grad_tex: GradientTexture1D = GradientTexture1D.new()
	grad_tex.gradient = grad
	pm.color_ramp = grad_tex
	p.process_material = pm

	var quad: QuadMesh = QuadMesh.new()
	# Bulbous aspect (~1:1.2) to match Le Lu's painted teardrop shape.
	# 1.1 × 1.4 with scale_curve max 1.0 → peak ~1.1×1.4m at mid-life, plenty
	# big to read clearly through the smoke column.
	quad.size = Vector2(1.1, 1.4)
	# Le Lu HDR (4, 0.8, 0) — bright orange core blooms past glow_hdr_threshold.
	var fire_mat: ShaderMaterial = _make_fire_material(Color(4.0, 0.8, 0.0, 1.0), 0.28, 1.2)
	if fire_mat == null:
		push_warning("DestructionVFX._build_fire: fire material build returned null — "
				+ "check that T_fire_diff.png exists and the fire shader compiles")
	quad.material = fire_mat
	p.draw_pass_1 = quad

	return p


## Lazily load the 2D noise texture used by the LOD-trick smoke shader.
## MUST be imported with mipmaps/generate=true so textureLod can sample down
## to a uniform gray as the LOD parameter increases over particle lifetime.
static func _get_shared_smoke_noise() -> Texture2D:
	if _shared_smoke_noise != null:
		return _shared_smoke_noise
	_shared_smoke_noise = load(_SMOKE_NOISE_TEXTURE_PATH) as Texture2D
	if _shared_smoke_noise == null:
		push_warning("DestructionVFX: smoke noise missing at %s" % _SMOKE_NOISE_TEXTURE_PATH)
	return _shared_smoke_noise


## Lazily load the radial alpha mask used to kill the square corners of the
## noise quad. Same circle_mask used by the impact-smoke volume.
static func _get_shared_circle_mask() -> Texture2D:
	if _shared_circle_mask != null:
		return _shared_circle_mask
	_shared_circle_mask = load(_SMOKE_CIRCLE_MASK_PATH) as Texture2D
	if _shared_circle_mask == null:
		push_warning("DestructionVFX: circle mask missing at %s" % _SMOKE_CIRCLE_MASK_PATH)
	return _shared_circle_mask


## Lazily load the procedural fire teardrop texture (3-layer brightness
## gradient with eraser-style holes — outer 50%, middle 75%, white core).
## Generated by tools/vfx/generate_fire_texture.gd. Bound as fire_texture
## uniform on the wreck-flame ShaderMaterial.
static func _get_shared_fire_teardrop() -> Texture2D:
	if _shared_fire_teardrop != null:
		return _shared_fire_teardrop
	_shared_fire_teardrop = load(_FIRE_TEARDROP_PATH) as Texture2D
	if _shared_fire_teardrop == null:
		push_warning("DestructionVFX: fire teardrop missing at %s — run the generator at tools/vfx/generate_fire_texture.gd" % _FIRE_TEARDROP_PATH)
	return _shared_fire_teardrop


## Build a ShaderMaterial bound to spatial_particles_smoke.gdshader — the
## LOD-trick stylized smoke shader from the Lelu tutorial (3rd method).
## Web-compatible (no Forward+ features). [param tint] is the smoke_color
## uniform; particle COLOR is hijacked to drive LOD so designer-visible color
## comes from this parameter.
static func _make_smoke_material(tint: Color = Color(0.55, 0.53, 0.50, 1.0), max_lod: float = 8.0) -> ShaderMaterial:
	var shader: Shader = load(_SMOKE_SHADER_PATH) as Shader
	if shader == null:
		push_warning("DestructionVFX: smoke shader missing at %s" % _SMOKE_SHADER_PATH)
		return null
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("noise_texture", _get_shared_smoke_noise())
	mat.set_shader_parameter("circle_mask", _get_shared_circle_mask())
	mat.set_shader_parameter("smoke_color", tint)
	mat.set_shader_parameter("max_lod", max_lod)
	mat.set_shader_parameter("fade_intensity", 1.0)
	return mat


## Build a ShaderMaterial bound to spatial_particles_fire.gdshader — the
## Le Lu stylized fire pipeline (pre-painted teardrop + panning distortion +
## HDR color mix). Web-compatible.
## [param fire_color] is the HDR tint multiplied into the texture; values >1
## (e.g. (4, 0.8, 0)) push the bright core past glow_hdr_threshold (0.9 in
## Main.tscn) so the bloom pass picks up the flame outline.
## [param distortion_amount] controls how violently the panning noise warps
## the silhouette — ~0.20 for stationary wreck flames, ~0.30 for embers.
static func _make_fire_material(
	fire_color: Color = Color(4.0, 0.8, 0.0, 1.0),
	distortion_amount: float = 0.20,
	anchor_power: float = 1.5
) -> ShaderMaterial:
	var shader: Shader = load(_FIRE_SHADER_PATH) as Shader
	if shader == null:
		push_warning("DestructionVFX: fire shader missing at %s" % _FIRE_SHADER_PATH)
		return null
	var fire_tex: Texture2D = _get_shared_fire_teardrop()
	var noise_tex: Texture2D = _get_shared_smoke_noise()
	if fire_tex == null:
		push_warning("DestructionVFX: fire teardrop texture failed to load — wreck fire will be invisible")
		return null
	if noise_tex == null:
		push_warning("DestructionVFX: distortion noise texture failed to load")
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("fire_texture", fire_tex)
	mat.set_shader_parameter("distortion_texture", noise_tex)
	mat.set_shader_parameter("fire_color", fire_color)
	mat.set_shader_parameter("distortion_speed", Vector2(0.0, -1.0))
	mat.set_shader_parameter("distortion_amount", distortion_amount)
	mat.set_shader_parameter("anchor_power", anchor_power)
	return mat


## Build a ShaderMaterial for explosion sparks — same fire shader but bound
## to a soft circle mask instead of the teardrop, with high HDR color so the
## tiny billboards bloom hard. Distortion is disabled because the spark quads
## are too small (~0.25 m) for noise warping to read.
static func _make_spark_material(
	fire_color: Color = Color(8.0, 3.0, 0.5, 1.0)
) -> ShaderMaterial:
	var shader: Shader = load(_FIRE_SHADER_PATH) as Shader
	if shader == null:
		push_warning("DestructionVFX: fire shader missing at %s" % _FIRE_SHADER_PATH)
		return null
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	# Circle mask (soft radial alpha) makes the spark a round glowing dot.
	mat.set_shader_parameter("fire_texture", _get_shared_circle_mask())
	mat.set_shader_parameter("distortion_texture", _get_shared_smoke_noise())
	mat.set_shader_parameter("fire_color", fire_color)
	mat.set_shader_parameter("distortion_speed", Vector2(0.0, 0.0))
	mat.set_shader_parameter("distortion_amount", 0.0)
	mat.set_shader_parameter("anchor_power", 1.0)
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


## Build a fresh MeshInstance3D that shares the source's Mesh resource but
## has NO skeleton/skin bindings — renders cleanly as a static mesh detached
## from any armature. Falls back to a BoxMesh if source has no .mesh.
static func _make_fresh_mesh_copy(source: MeshInstance3D, fallback_size: Vector3) -> MeshInstance3D:
	var copy: MeshInstance3D = MeshInstance3D.new()
	if source != null and source.mesh != null:
		copy.mesh = source.mesh
	else:
		var box: BoxMesh = BoxMesh.new()
		box.size = fallback_size
		copy.mesh = box
		push_warning("DestructionVFX: source mesh null — using BoxMesh fallback")
	copy.visible = true
	return copy


# ---------------------------------------------------------------------------
# Explosion burst — one-shot spark/debris particles + bright flash light.
# Call at the moment of destruction, before spawn_smoke_fire.
# ---------------------------------------------------------------------------

## One-shot explosion at [param position_world]. Spawns sparks + a pulsing
## flash light under [param world_root]. CRITICAL: nodes are added to the tree
## BEFORE setting global_position / creating tweens — orphan nodes silently
## drop global_transform writes and create_tween() returns null.
static func spawn_explosion(world_root: Node, position_world: Vector3) -> void:
	# --- Flash light ---
	var flash_root: Node3D = Node3D.new()
	flash_root.name = "ExplosionFlash"
	var light: OmniLight3D = OmniLight3D.new()
	light.light_color = Color(1.0, 0.75, 0.35)
	light.light_energy = 18.0
	light.omni_range = 12.0
	light.shadow_enabled = false
	flash_root.add_child(light)
	world_root.add_child(flash_root)
	flash_root.global_position = position_world  # AFTER add_child — required
	# Tween REQUIRES the node to be in the tree — creating it on an orphan
	# returns null and the light would stay at energy=18 forever.
	var tween: Tween = flash_root.create_tween()
	tween.tween_property(light, "light_energy", 0.0, 0.25).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tween.tween_callback(flash_root.queue_free)

	# --- Spark burst ---
	var sparks: GPUParticles3D = _build_spark_burst()
	world_root.add_child(sparks)
	sparks.global_position = position_world
	sparks.emitting = true  # programmatic GPUParticles3D defaults to false in code


static func _build_spark_burst() -> GPUParticles3D:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "ExplosionSparks"
	p.amount = 50
	p.lifetime = 0.8
	p.one_shot = true
	p.explosiveness = 1.0
	p.randomness = 0.4

	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.3
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 180.0  # full sphere — omnidirectional burst
	pm.initial_velocity_min = 4.0
	pm.initial_velocity_max = 10.0
	pm.gravity = Vector3(0.0, -5.0, 0.0)
	pm.scale_min = 0.12
	pm.scale_max = 0.28
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(1.0, 0.95, 0.7, 1.0))
	grad.set_offset(0, 0.0)
	grad.add_point(0.4, Color(1.0, 0.5, 0.1, 0.9))
	grad.add_point(1.0, Color(0.5, 0.1, 0.0, 0.0))
	var grad_tex: GradientTexture1D = GradientTexture1D.new()
	grad_tex.gradient = grad
	pm.color_ramp = grad_tex
	p.process_material = pm

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.25, 0.25)
	# Spark material: circle-mask billboard with high HDR (8, 3, 0.5) so
	# sparks read as bright glowing dots and reliably trigger the bloom pass
	# even past ACES tonemap compression.
	quad.material = _make_spark_material(Color(8.0, 3.0, 0.5, 1.0))
	p.draw_pass_1 = quad

	p.finished.connect(p.queue_free)
	return p


# ---------------------------------------------------------------------------
# Mesh walker
# ---------------------------------------------------------------------------

static func _walk_meshes(root: Node, fn: Callable) -> void:
	if root is MeshInstance3D:
		fn.call(root as MeshInstance3D)
	for child: Node in root.get_children():
		_walk_meshes(child, fn)


# ---------------------------------------------------------------------------
# Helicopter multi-mesh debris — static-mesh and subtree variants.
# ---------------------------------------------------------------------------

## Spawn a single free-flying RigidBody3D carrying one freshly-created
## MeshInstance3D that shares [param source_mesh]'s Mesh resource.
## No skeleton/skin bindings — always renders cleanly as a static prop.
##
## [param world_root] is the scene node the debris is parented under.
## [param source_mesh] is the live MeshInstance3D whose mesh to reuse
## (e.g. a rotor blade still attached to the helicopter).
## [param spawn_world] is the world-space Transform3D for the new body.
## [param fallback_box_size] is used if [param source_mesh].mesh is null.
## [param mass], [param upward_vel], [param h_drift_max], [param tumble_max]
## control the launch impulse. [param lifetime] schedules queue_free
## (pass 0 to keep debris forever).
static func spawn_static_mesh_debris(
	world_root: Node,
	source_mesh: MeshInstance3D,
	spawn_world: Transform3D,
	fallback_box_size: Vector3 = Vector3(0.5, 0.1, 2.0),
	mass: float = 40.0,
	upward_vel: float = 6.0,
	h_drift_max: float = 4.0,
	tumble_max: float = 8.0,
	lifetime: float = 20.0
) -> RigidBody3D:
	# Body carries position + rotation only (no scale). The fresh mesh copy
	# is placed via global_transform so it matches the source's world pose
	# EXACTLY (including any scale inherited from GLB-import ancestors).
	# See spawn_subtree_debris for the full rationale — this mirrors that
	# approach for single-mesh callers.
	var body: RigidBody3D = _build_debris_body(mass)
	world_root.add_child(body)
	body.global_transform = Transform3D(
		spawn_world.basis.orthonormalized(),
		spawn_world.origin
	)
	var mesh_copy: MeshInstance3D = _make_fresh_mesh_copy(source_mesh, fallback_box_size)
	body.add_child(mesh_copy)
	# Set the mesh copy's global_transform to the source's world transform —
	# Godot computes the correct local relative to the unscaled body.
	if source_mesh != null:
		mesh_copy.global_transform = source_mesh.global_transform
	_launch_debris(body, upward_vel, h_drift_max, tumble_max)
	if lifetime > 0.0:
		world_root.get_tree().create_timer(lifetime).timeout.connect(func() -> void:
			if is_instance_valid(body):
				body.queue_free()
		)
	return body


## Spawn a free-flying RigidBody3D carrying a full duplicated subtree rooted
## at [param subtree_root] (e.g. the tail boom Node3D including its meshes
## and child nodes). Useful when a part has multiple meshes or nested nodes
## that must move as a unit.
##
## Duplicate flags default to 0 (shallow copy of resources) — same strategy
## used by spawn_turret_debris to avoid the USE_INSTANTIATION index crash.
## [param collision_exception] is an optional PhysicsBody3D to exclude from
## collision on spawn (typically the helicopter CharacterBody3D itself).
static func spawn_subtree_debris(
	world_root: Node,
	subtree_root: Node3D,
	spawn_world: Transform3D,
	collision_exception: PhysicsBody3D = null,
	mass: float = 80.0,
	upward_vel: float = 5.0,
	h_drift_max: float = 3.0,
	tumble_max: float = 7.0,
	lifetime: float = 20.0
) -> RigidBody3D:
	# DESIGN NOTE: we deliberately do NOT use duplicate() on the source subtree.
	# duplicate() preserves the source's local transforms, but those locals
	# were designed for the source's original parent chain. When the duplicate
	# is re-parented under a RigidBody3D that was positioned at the source's
	# world transform, any scale/translation baked into the source hierarchy
	# gets applied TWICE — resulting in oversized, mis-positioned debris
	# (confirmed empirically on the Apache GLB helicopter rotor).
	#
	# Instead, we walk the source and create FRESH MeshInstance3D nodes,
	# positioning each one via global_transform directly. Godot auto-computes
	# the correct local transform relative to the body. This sidesteps every
	# GLB import quirk (baked scales, skinned-mesh bind poses, intermediate
	# Node3D containers with scale) because we never read a local transform
	# from the source — only absolute world transforms.
	var body: RigidBody3D = _build_debris_body(mass)
	# Body carries position + rotation ONLY, no scale. Keeping the RigidBody
	# at identity scale avoids non-uniform-scale physics issues. Fresh mesh
	# copies carry their own world-space poses (which include any inherited
	# scale) as their local transforms under the unscaled body.
	world_root.add_child(body)
	body.global_transform = Transform3D(
		spawn_world.basis.orthonormalized(),
		spawn_world.origin
	)
	var mesh_count: int = _copy_subtree_meshes_fresh(subtree_root, body)
	if mesh_count == 0:
		push_warning("DestructionVFX.spawn_subtree_debris: no visible MeshInstance3D "
				+ "found under '%s' — debris body will be invisible" % subtree_root.name)
	if collision_exception != null:
		body.add_collision_exception_with(collision_exception)
	_launch_debris(body, upward_vel, h_drift_max, tumble_max)
	if lifetime > 0.0:
		world_root.get_tree().create_timer(lifetime).timeout.connect(func() -> void:
			if is_instance_valid(body):
				body.queue_free()
		)
	return body


## Recursively set visible = false on every MeshInstance3D descendant of
## [param root]. Belt-and-braces alternative to `root.visible = false` —
## Godot 4.3's is_visible_in_tree() SHOULD cascade through Node3D ancestors,
## but some GLB-imported hierarchies have edge cases where a MeshInstance3D
## is parented outside the expected subtree, or where an intermediate node
## lifts visibility. This helper hides each mesh directly so callers can
## guarantee the original visual vanishes once debris has spawned.
static func hide_visible_meshes(root: Node) -> void:
	if root is MeshInstance3D:
		(root as MeshInstance3D).visible = false
	for child: Node in root.get_children():
		hide_visible_meshes(child)


## Walk [param source_root] recursively. For every MeshInstance3D descendant
## that is visible_in_tree and has a non-null mesh, create a fresh
## MeshInstance3D under [param target_parent] and position it via
## global_transform to match the source's world pose. Returns the number of
## meshes copied so the caller can warn on empty subtrees.
##
## Fresh MeshInstance3Ds share the source's Mesh + material_override
## resources — zero GPU copies, just a new scene node. Because we never
## read or copy a local transform, we bypass all GLB-import inheritance
## quirks.
static func _copy_subtree_meshes_fresh(source_root: Node, target_parent: Node3D) -> int:
	var count: int = 0
	if source_root is MeshInstance3D:
		var src_mi: MeshInstance3D = source_root as MeshInstance3D
		if src_mi.mesh != null and src_mi.is_visible_in_tree():
			var copy: MeshInstance3D = MeshInstance3D.new()
			copy.mesh = src_mi.mesh
			copy.material_override = src_mi.material_override
			# Parent BEFORE setting global_transform — Godot requires the node
			# to be in the tree to compute local from a global assignment.
			target_parent.add_child(copy)
			copy.global_transform = src_mi.global_transform
			count += 1
	for child: Node in source_root.get_children():
		count += _copy_subtree_meshes_fresh(child, target_parent)
	return count


## Build a bare RigidBody3D configured for short-lived visual debris.
## Collision layer 4 (bit 2) keeps it isolated from projectile masks (0b11).
## Collision mask starts at 0 — callers or _launch_debris re-enable ground
## collision after 0.3 s so the body flies clear of its spawn hull first.
static func _build_debris_body(mass: float) -> RigidBody3D:
	var body: RigidBody3D = RigidBody3D.new()
	body.mass = mass
	body.gravity_scale = 1.0
	body.can_sleep = true
	body.collision_layer = 0b100
	body.collision_mask = 0
	body.linear_damp = 0.05
	body.angular_damp = 0.4

	var phys_mat: PhysicsMaterial = PhysicsMaterial.new()
	phys_mat.bounce = 0.15
	phys_mat.friction = 0.7
	phys_mat.rough = true
	body.physics_material_override = phys_mat

	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(1.0, 0.3, 1.0)
	shape.shape = box
	body.add_child(shape)

	return body


## Apply a randomised launch velocity and angular velocity to [param body],
## then re-enable ground collision (mask bit 0) after 0.3 s.
static func _launch_debris(
	body: RigidBody3D,
	upward_vel: float,
	h_drift_max: float,
	tumble_max: float
) -> void:
	body.sleeping = false
	body.linear_velocity = Vector3(
		randf_range(-h_drift_max, h_drift_max),
		upward_vel,
		randf_range(-h_drift_max, h_drift_max)
	)
	var axis: Vector3 = Vector3(
		randf_range(-1.0, 1.0),
		randf_range(-0.2, 0.2),
		randf_range(-1.0, 1.0)
	).normalized()
	body.angular_velocity = axis * tumble_max
	# Defer ground-collision enable so the body escapes the spawn hull first.
	# is_instance_valid guard: body may already be freed if the scene is torn
	# down during the 0.3 s window (e.g. scene reload mid-game).
	var tree: SceneTree = body.get_tree()
	tree.create_timer(0.3).timeout.connect(func() -> void:
		if is_instance_valid(body):
			body.collision_mask = 0b001
	)
