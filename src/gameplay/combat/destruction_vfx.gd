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
const _SMOKE_TEXTURE_PATH: String = "res://assets/textures/smoke_vfx/T_smoke_b7.png"
const _SMOKE_NOISE_TEXTURE_PATH: String = "res://assets/textures/smoke_vfx/T_Noise_001R.png"
const _SMOKE_CIRCLE_MASK_PATH: String = "res://assets/textures/smoke_vfx/T_VFX_circle_1.png"
const _FIRE_TEARDROP_PATH: String = "res://assets/textures/fire_vfx/T_fire_diff.png"
const _VFX_NODE_NAME: String = "_DestructionVFX"

# Shared textures — loaded once on first material build, reused by every
# subsequent smoke/fire/spark instance.
#  • smoke_texture — authored wispy smoke alpha. This is what prevents the
#    wreck plume from reading as round billboard bubbles.
#  • smoke_noise — subtle UV distortion for smoke / fire.
#  • circle_mask — radial alpha mask used by sparks (round bright dots).
#  • fire_teardrop — procedurally-painted 3-layer fire shape from
#    tools/vfx/generate_fire_texture.gd. Used by flame columns; sparks use
#    the circle_mask instead since their tiny quads can't show teardrop detail.
static var _shared_smoke_texture: Texture2D = null
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


## Spawn a self-contained VFX node (smoke column + fire + flicker light).
## By default it is attached to [param vehicle]; pass attach_to_vehicle=false
## for short-lived wrecks that respawn or teleport soon after destruction.
static func spawn_smoke_fire(
	vehicle: Node3D,
	y_offset: float = 1.0,
	attach_to_vehicle: bool = true,
	auto_free_after: float = 0.0
) -> Node3D:
	# Replace any existing attached VFX node so respawn doesn't stack effects.
	clear_vfx(vehicle)
	var root: Node3D = Node3D.new()
	root.name = _VFX_NODE_NAME
	if attach_to_vehicle:
		vehicle.add_child(root)
		root.position = Vector3(0.0, y_offset, 0.0)
	else:
		var parent: Node = null
		if vehicle.is_inside_tree():
			parent = vehicle.get_tree().current_scene
		if parent == null:
			parent = vehicle.get_parent()
		if parent != null:
			parent.add_child(root)
			root.global_transform = Transform3D(
				Basis.IDENTITY,
				vehicle.global_position + Vector3(0.0, y_offset, 0.0)
			)
		else:
			vehicle.add_child(root)
			root.position = Vector3(0.0, y_offset, 0.0)

	var smoke_footprint: Vector2 = _estimate_smoke_footprint(vehicle)

	# All combustion layers start from one shared point. The smoke emitter uses
	# the vehicle footprint for its horizontal spawn area, so tank wreck smoke
	# spreads over the hull instead of rising as a thin chimney.
	var source_pos: Vector3 = Vector3.ZERO
	var smoke: GPUParticles3D = _build_smoke(smoke_footprint)
	smoke.position = source_pos
	root.add_child(smoke)

	var fire: GPUParticles3D = _build_fire()
	fire.position = source_pos
	root.add_child(fire)
	var flame_licks: GPUParticles3D = _build_flame_licks()
	flame_licks.position = source_pos
	root.add_child(flame_licks)
	var embers: GPUParticles3D = _build_embers()
	embers.position = source_pos + Vector3(0.0, 0.25, 0.0)
	root.add_child(embers)

	root.add_child(_build_light())
	if auto_free_after > 0.0 and root.is_inside_tree():
		root.get_tree().create_timer(auto_free_after).timeout.connect(func() -> void:
			if is_instance_valid(root):
				root.queue_free()
		)
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


static func _estimate_smoke_footprint(vehicle: Node3D) -> Vector2:
	var bounds: Dictionary = {
		"found": false,
		"min_x": 999999.0,
		"max_x": -999999.0,
		"min_z": 999999.0,
		"max_z": -999999.0,
	}
	_accumulate_mesh_footprint(vehicle, vehicle.global_transform.affine_inverse(), bounds)
	if not bool(bounds["found"]):
		return Vector2(0.8, 0.8)
	var size_x: float = float(bounds["max_x"]) - float(bounds["min_x"])
	var size_z: float = float(bounds["max_z"]) - float(bounds["min_z"])
	return Vector2(
		clampf(size_x, 0.8, 6.0),
		clampf(size_z, 0.8, 8.0)
	)


static func _accumulate_mesh_footprint(root: Node, vehicle_inverse: Transform3D, bounds: Dictionary) -> void:
	if root is MeshInstance3D:
		var mi: MeshInstance3D = root as MeshInstance3D
		if mi.mesh != null and mi.is_visible_in_tree():
			var aabb: AABB = mi.mesh.get_aabb()
			for ix: int in range(2):
				for iz: int in range(2):
					var local_corner: Vector3 = aabb.position + Vector3(
						aabb.size.x * float(ix),
						0.0,
						aabb.size.z * float(iz)
					)
					var vehicle_pos: Vector3 = vehicle_inverse * (mi.global_transform * local_corner)
					bounds["found"] = true
					bounds["min_x"] = minf(float(bounds["min_x"]), vehicle_pos.x)
					bounds["max_x"] = maxf(float(bounds["max_x"]), vehicle_pos.x)
					bounds["min_z"] = minf(float(bounds["min_z"]), vehicle_pos.z)
					bounds["max_z"] = maxf(float(bounds["max_z"]), vehicle_pos.z)
	for child: Node in root.get_children():
		_accumulate_mesh_footprint(child, vehicle_inverse, bounds)


# ---------------------------------------------------------------------------
# Internal builders
# ---------------------------------------------------------------------------

static func _build_smoke(footprint: Vector2 = Vector2(0.8, 0.8)) -> GPUParticles3D:
	# Wreck smoke plume. Uses authored smoke sprites instead of radial discs so
	# individual particles blend into a soft, torn smoke column rather than
	# visible circular bubbles.
	var footprint_x: float = clampf(footprint.x, 0.5, 3.6)
	var footprint_z: float = clampf(footprint.y, 0.5, 4.8)
	var footprint_scale: float = clampf(maxf(footprint_x, footprint_z) / 2.8, 0.75, 1.35)
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "Smoke"
	p.amount = int(roundf(72.0 * footprint_scale))
	p.lifetime = 4.4
	p.preprocess = 1.1
	p.explosiveness = 0.0
	p.randomness = 0.62
	p.fixed_fps = 30
	p.emitting = true
	p.local_coords = true
	p.visibility_aabb = AABB(
		Vector3(-footprint_x, -0.5, -footprint_z),
		Vector3(footprint_x * 2.0, 7.0, footprint_z * 2.0)
	)

	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(footprint_x * 0.26, 0.04, footprint_z * 0.22)
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 24.0
	pm.initial_velocity_min = 0.42
	pm.initial_velocity_max = 0.98
	pm.gravity = Vector3(0.0, 0.10, 0.0)
	pm.linear_accel_min = -0.20
	pm.linear_accel_max = 0.05
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -18.0
	pm.angular_velocity_max = 18.0
	pm.scale_min = 0.52
	pm.scale_max = 1.02
	var scale_curve: Curve = Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.42))
	scale_curve.add_point(Vector2(0.28, 0.92))
	scale_curve.add_point(Vector2(0.76, 1.28))
	scale_curve.add_point(Vector2(1.0, 1.48))
	var scale_tex: CurveTexture = CurveTexture.new()
	scale_tex.curve = scale_curve
	pm.scale_curve = scale_tex
	# RED carries lifetime to the shader; ALPHA now genuinely fades particles
	# out, avoiding the old "ghost circles" caused by a high alpha floor.
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(0.0, 0.0, 0.0, 0.0))
	grad.set_offset(0, 0.0)
	grad.add_point(0.14, Color(0.18, 0.0, 0.0, 0.42))
	grad.add_point(0.68, Color(0.64, 0.0, 0.0, 0.30))
	grad.add_point(1.0, Color(1.0, 0.0, 0.0, 0.0))
	var grad_tex: GradientTexture1D = GradientTexture1D.new()
	grad_tex.gradient = grad
	pm.color_ramp = grad_tex
	p.process_material = pm

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(1.55, 1.32)
	var smoke_mat: Material = _make_smoke_material(Color(0.42, 0.43, 0.46, 0.78), 4.0)
	if smoke_mat != null:
		quad.material = smoke_mat
	else:
		quad.material = _make_fallback_smoke_material()
	p.draw_pass_1 = quad

	return p


static func _build_fire() -> GPUParticles3D:
	# Wreck flame follows the Le Lu tutorial setup: one persistent billboard,
	# no particle scatter, with all motion coming from shader UV distortion.
	# Multiple particles looked like separate vertical layers on the wreck.
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "Fire"
	p.amount = 1
	p.lifetime = 100.0
	p.preprocess = 0.0
	p.explosiveness = 0.0
	p.randomness = 0.0
	p.fixed_fps = 60
	p.emitting = true
	p.local_coords = true
	p.sorting_offset = 2.0
	p.visibility_aabb = AABB(Vector3(-3.0, -1.0, -3.0), Vector3(6.0, 6.0, 6.0))

	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINT
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 0.0
	pm.initial_velocity_min = 0.0
	pm.initial_velocity_max = 0.0
	pm.gravity = Vector3.ZERO
	pm.scale_min = 1.0
	pm.scale_max = 1.0
	# Particle COLOR stays white/alpha=1 for the entire lifetime. Animation is
	# shader-driven, matching the tutorial instead of a particle birth/death loop.
	p.process_material = pm

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.72, 0.98)
	var fire_mat: Material = _make_fire_material(Color(2.0, 0.82, 0.16, 0.76), 0.25, 1.0, 0.09, 0.18)
	if fire_mat == null:
		push_warning("DestructionVFX._build_fire: fire material build returned null — "
				+ "check that T_fire_diff.png exists and the fire shader compiles")
	if fire_mat == null:
		fire_mat = _make_billboard_material(null, Color(1.0, 0.42, 0.08, 0.78), 20, true)
	quad.material = fire_mat
	p.draw_passes = 1
	p.draw_pass_1 = quad

	return p


static func _build_flame_licks() -> GPUParticles3D:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "FlameLicks"
	p.amount = 8
	p.lifetime = 0.9
	p.preprocess = 0.5
	p.explosiveness = 0.0
	p.randomness = 0.55
	p.fixed_fps = 60
	p.emitting = true
	p.local_coords = true
	p.sorting_offset = 3.0
	p.visibility_aabb = AABB(Vector3(-2.0, -0.5, -2.0), Vector3(4.0, 4.0, 4.0))

	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.09
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 12.0
	pm.initial_velocity_min = 0.24
	pm.initial_velocity_max = 0.64
	pm.gravity = Vector3(0.0, 0.9, 0.0)
	pm.scale_min = 0.22
	pm.scale_max = 0.44
	var scale_curve: Curve = Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.55))
	scale_curve.add_point(Vector2(0.45, 1.0))
	scale_curve.add_point(Vector2(1.0, 0.35))
	var scale_tex: CurveTexture = CurveTexture.new()
	scale_tex.curve = scale_curve
	pm.scale_curve = scale_tex
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(1.0, 1.0, 1.0, 0.0))
	grad.set_offset(0, 0.0)
	grad.add_point(0.18, Color(1.0, 1.0, 1.0, 0.85))
	grad.add_point(0.68, Color(1.0, 1.0, 1.0, 0.7))
	grad.add_point(1.0, Color(1.0, 1.0, 1.0, 0.0))
	var grad_tex: GradientTexture1D = GradientTexture1D.new()
	grad_tex.gradient = grad
	pm.color_ramp = grad_tex
	p.process_material = pm

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.40, 0.58)
	quad.material = _make_fire_material(Color(2.0, 0.72, 0.1, 0.72), 0.32, 0.75, 0.12, 0.03)
	p.draw_pass_1 = quad

	return p


static func _build_embers() -> GPUParticles3D:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "Embers"
	p.amount = 18
	p.lifetime = 1.7
	p.preprocess = 0.8
	p.explosiveness = 0.0
	p.randomness = 0.35
	p.emitting = true
	p.local_coords = true
	p.visibility_aabb = AABB(Vector3(-2.0, -0.5, -2.0), Vector3(4.0, 5.0, 4.0))

	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.35
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 28.0
	pm.initial_velocity_min = 0.55
	pm.initial_velocity_max = 1.3
	pm.gravity = Vector3(0.0, 0.7, 0.0)
	pm.scale_min = 0.18
	pm.scale_max = 0.36
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(1.0, 0.78, 0.35, 0.0))
	grad.set_offset(0, 0.0)
	grad.add_point(0.18, Color(1.0, 0.36, 0.08, 0.9))
	grad.add_point(0.72, Color(0.8, 0.08, 0.02, 0.55))
	grad.add_point(1.0, Color(0.25, 0.0, 0.0, 0.0))
	var grad_tex: GradientTexture1D = GradientTexture1D.new()
	grad_tex.gradient = grad
	pm.color_ramp = grad_tex
	p.process_material = pm

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.12, 0.12)
	quad.material = _make_spark_material(Color(4.5, 1.2, 0.28, 0.95))
	p.draw_pass_1 = quad

	return p


## Lazily load the authored smoke sprite used by the wreck plume. This texture
## carries an irregular alpha silhouette, replacing the old radial puff mask.
static func _get_shared_smoke_texture() -> Texture2D:
	if _shared_smoke_texture != null:
		return _shared_smoke_texture
	_shared_smoke_texture = load(_SMOKE_TEXTURE_PATH) as Texture2D
	if _shared_smoke_texture == null:
		push_warning("DestructionVFX: smoke texture missing at %s" % _SMOKE_TEXTURE_PATH)
	return _shared_smoke_texture


## Lazily load the 2D noise texture used for subtle smoke/fire UV distortion.
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


## Build a ShaderMaterial bound to spatial_particles_smoke.gdshader.
## Web-compatible (no Forward+ features). [param tint] is the smoke_color
## uniform; particle alpha shapes the lifetime fade while the smoke texture
## supplies the non-circular silhouette.
static func _make_smoke_material(tint: Color = Color(0.55, 0.53, 0.50, 1.0), max_lod: float = 8.0) -> Material:
	var smoke_tex: Texture2D = _get_shared_smoke_texture()
	if smoke_tex == null:
		return null
	if OS.has_feature("web"):
		return _make_billboard_material(smoke_tex, tint, 10, false)
	var shader: Shader = load(_SMOKE_SHADER_PATH) as Shader
	if shader == null:
		push_warning("DestructionVFX: smoke shader missing at %s" % _SMOKE_SHADER_PATH)
		return null
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	# Transparent particles: smoke stays above the world, but fire uses an even
	# higher priority so the flame core remains visible at the plume base.
	mat.render_priority = 10
	mat.set_shader_parameter("smoke_texture", smoke_tex)
	mat.set_shader_parameter("distortion_texture", _get_shared_smoke_noise())
	mat.set_shader_parameter("smoke_color", tint)
	mat.set_shader_parameter("max_lod", max_lod)
	mat.set_shader_parameter("fade_intensity", 0.9)
	mat.set_shader_parameter("min_particle_alpha", 0.03)
	mat.set_shader_parameter("edge_start", 0.22)
	mat.set_shader_parameter("texture_power", 0.68)
	mat.set_shader_parameter("dissolve_strength", 0.16)
	return mat


static func _make_fallback_smoke_material() -> StandardMaterial3D:
	return _make_billboard_material(null, Color(0.48, 0.49, 0.52, 0.68), 3, false)


static func _make_billboard_material(
	texture: Texture2D,
	tint: Color,
	priority: int,
	additive: bool = false
) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.render_priority = priority
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = tint
	if texture != null:
		mat.albedo_texture = texture
	if additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.emission_enabled = true
		mat.emission = Color(tint.r, tint.g, tint.b, tint.a)
		mat.emission_energy_multiplier = maxf(1.0, maxf(tint.r, maxf(tint.g, tint.b)))
	return mat


## Build a ShaderMaterial bound to spatial_particles_fire.gdshader — the
## Le Lu stylized fire pipeline (pre-painted teardrop + panning distortion +
## HDR color mix). Web-compatible.
## [param fire_color] is the HDR tint multiplied into the texture; values >1
## (e.g. (4, 0.8, 0)) push the bright core past glow_hdr_threshold (0.9 in
## Main.tscn) so the bloom pass picks up the flame outline.
## [param distortion_amount] controls how violently the panning noise warps
## the silhouette — ~0.20 for stationary wreck flames, ~0.30 for embers.
##
## Fire renders after smoke so the flame remains readable at the plume base.
static func _make_fire_material(
	fire_color: Color = Color(4.0, 0.8, 0.0, 1.0),
	distortion_amount: float = 0.20,
	anchor_power: float = 1.5,
	edge_softness: float = 0.16,
	base_glow: float = 0.42
) -> Material:
	var fire_tex: Texture2D = _get_shared_fire_teardrop()
	var noise_tex: Texture2D = _get_shared_smoke_noise()
	if fire_tex == null:
		push_warning("DestructionVFX: fire teardrop texture failed to load — wreck fire will be invisible")
		return null
	if OS.has_feature("web"):
		return _make_billboard_material(fire_tex, fire_color, 20, true)
	if noise_tex == null:
		push_warning("DestructionVFX: distortion noise texture failed to load")
	var shader: Shader = load(_FIRE_SHADER_PATH) as Shader
	if shader == null:
		push_warning("DestructionVFX: fire shader missing at %s" % _FIRE_SHADER_PATH)
		return null
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	mat.render_priority = 20
	mat.set_shader_parameter("fire_texture", fire_tex)
	mat.set_shader_parameter("distortion_texture", noise_tex)
	mat.set_shader_parameter("fire_color", fire_color)
	mat.set_shader_parameter("distortion_speed", Vector2(0.0, -1.4))
	mat.set_shader_parameter("distortion_amount", distortion_amount)
	mat.set_shader_parameter("anchor_power", anchor_power)
	mat.set_shader_parameter("edge_softness", edge_softness)
	mat.set_shader_parameter("base_glow", base_glow)
	mat.set_shader_parameter("procedural_flame", true)
	return mat


## Build a ShaderMaterial for explosion sparks — same fire shader but bound
## to a soft circle mask instead of the teardrop, with high HDR color so the
## tiny billboards bloom hard. Distortion is disabled because the spark quads
## are too small (~0.25 m) for noise warping to read.
static func _make_spark_material(
	fire_color: Color = Color(8.0, 3.0, 0.5, 1.0)
) -> Material:
	var circle_tex: Texture2D = _get_shared_circle_mask()
	if OS.has_feature("web"):
		return _make_billboard_material(circle_tex, fire_color, 30, true)
	var shader: Shader = load(_FIRE_SHADER_PATH) as Shader
	if shader == null:
		push_warning("DestructionVFX: fire shader missing at %s" % _FIRE_SHADER_PATH)
		return null
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	# Circle mask (soft radial alpha) makes the spark a round glowing dot.
	mat.set_shader_parameter("fire_texture", circle_tex)
	mat.set_shader_parameter("distortion_texture", _get_shared_smoke_noise())
	mat.set_shader_parameter("fire_color", fire_color)
	mat.set_shader_parameter("distortion_speed", Vector2(0.0, 0.0))
	mat.set_shader_parameter("distortion_amount", 0.0)
	mat.set_shader_parameter("anchor_power", 1.0)
	mat.set_shader_parameter("edge_softness", 0.12)
	mat.set_shader_parameter("base_glow", 0.0)
	mat.set_shader_parameter("procedural_flame", false)
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
