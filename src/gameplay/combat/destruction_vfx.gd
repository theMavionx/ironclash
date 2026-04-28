class_name DestructionVFX
extends RefCounted

## Static helpers that turn a healthy vehicle node into a smoking wreck.
## Used by Tank/Heli/Drone controllers in their _on_destroyed handlers.
##
## Two stages:
##   1. apply_charred(vehicle): walks all MeshInstance3D descendants and sets
##      material_overlay to a charred ShaderMaterial (preserves silhouette).
##   2. spawn_smoke_fire(vehicle): instantiates a Node3D under the vehicle
##      with looping smoke. The legacy name is kept for controller callers.
##
## Both stages can be undone (clear_charred / clear_vfx) for the drone respawn flow.

const _CHARRED_SHADER_PATH: String = "res://src/vfx/charred_overlay.gdshader"
const _SOOT_NOISE_PATH: String = "res://assets/textures/3d_noise.png"
const _FLICKER_SCRIPT_PATH: String = "res://src/vfx/fire_flicker.gd"
const _SMOKE_SHADER_PATH: String = "res://src/vfx/spatial_particles_smoke.gdshader"
const _FIRE_SHADER_PATH: String = "res://src/vfx/spatial_particles_fire.gdshader"
const _SMOKE_WEB_SHADER_PATH: String = "res://src/vfx/spatial_particles_smoke_web.gdshader"
const _FIRE_WEB_SHADER_PATH: String = "res://src/vfx/spatial_particles_fire_web.gdshader"
const _WEB_SHADER_BILLBOARD_VFX_SCRIPT: Script = preload("res://src/vfx/web_shader_billboard_vfx.gd")
const _SMOKE_TEXTURE_PATH: String = "res://assets/textures/smoke_vfx/T_smoke_b7.png"
const _SMOKE_NOISE_TEXTURE_PATH: String = "res://assets/textures/smoke_vfx/T_Noise_001R.png"
const _SMOKE_CIRCLE_MASK_PATH: String = "res://assets/textures/smoke_vfx/T_VFX_circle_1.png"
const _FIRE_TEARDROP_PATH: String = "res://assets/textures/fire_vfx/T_fire_diff.png"
const _VFX_NODE_NAME: String = "_DestructionVFX"

# Shared textures — loaded once on first material build, reused by every
# subsequent smoke/spark instance.
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
static var _shared_web_fire_mask: Texture2D = null
static var _shared_web_spark_mask: Texture2D = null
static var _logged_smoke_shader_path: bool = false
static var _logged_fire_shader_path: bool = false
static var _logged_spark_shader_path: bool = false


## WebGL2/Compatibility can accept our authored particle shaders but still draw
## blank when GPUParticles3D feeds the custom vertex path on some browser
## drivers. Web keeps the same shader files/material parameters, but renders
## long-lived effects through CPUParticles3D billboards instead of GPU particles.
const _USE_GPU_PARTICLE_SHADERS_ON_WEB: bool = false


static func _is_web_build() -> bool:
	return OS.has_feature("web")


## True when GPUParticles3D emitters are allowed on Web. ShaderMaterial itself
## is still allowed on Web; this only controls the particle emitter backend.
static func _should_use_gpu_particle_emitters() -> bool:
	return not _is_web_build() or _USE_GPU_PARTICLE_SHADERS_ON_WEB


## Material factories should still use the authored shader files on Web. The
## browser fallback only swaps the emitter type, not the material.
static func _should_use_authored_shaders() -> bool:
	return true


## Apply the charred overlay to every MeshInstance3D under [param vehicle].
## Idempotent — re-applying replaces the previous overlay with a fresh instance.
static func apply_charred(vehicle: Node, skip_alpha_cutouts: bool = true) -> void:
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
		if skip_alpha_cutouts and _mesh_uses_alpha_cutout(m):
			return
		m.material_overlay = mat
	)


## Remove the charred overlay from all meshes under [param vehicle].
static func clear_charred(vehicle: Node) -> void:
	_walk_meshes(vehicle, func(m: MeshInstance3D) -> void:
		m.material_overlay = null
	)


## Spawn a self-contained VFX node (smoke column only).
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
	var smoke_origin: Vector3 = _estimate_visual_smoke_origin(vehicle, y_offset)
	var root: Node3D = Node3D.new()
	root.name = _VFX_NODE_NAME
	if attach_to_vehicle:
		vehicle.add_child(root)
		root.position = smoke_origin
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
				vehicle.global_transform * smoke_origin
			)
		else:
			vehicle.add_child(root)
			root.position = smoke_origin

	var smoke_footprint: Vector2 = _estimate_smoke_footprint(vehicle)

	# Smoke starts from the lower visible body mesh, then spreads across the
	# vehicle footprint so wreck smoke rises out of the hull/ground contact.
	var source_pos: Vector3 = Vector3.ZERO
	if not _should_use_gpu_particle_emitters():
		_build_web_smoke(root, smoke_footprint, source_pos)
	else:
		var smoke: GPUParticles3D = _build_smoke(smoke_footprint)
		smoke.position = source_pos
		root.add_child(smoke)

	if auto_free_after > 0.0 and root.is_inside_tree():
		root.get_tree().create_timer(auto_free_after).timeout.connect(root.queue_free)
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

	# Manually rebuild a Skeleton3D + the two skinned meshes instead of
	# duplicate()ing the whole GLB subtree. Godot 4.3 (web build) trips an
	# "Index p_index = 3 is out of bounds" inside Node._duplicate_properties on
	# this Soldier/Tank GLB — children_cache reshuffles mid-clone so a deep
	# duplicate is unsafe. Building from scratch sidesteps the recursion.
	var src_skel: Skeleton3D = _find_skeleton(model_node)
	if src_skel == null:
		push_warning("DestructionVFX: no Skeleton3D under model_node, skipping cook-off")
		debris.queue_free()
		return null
	var skel_copy: Skeleton3D = _clone_skeleton_bones(src_skel)
	debris.add_child(skel_copy)
	# Freeze the new skeleton at the destruction-frame pose: rest by default,
	# turret + barrel set to the captured aim.
	skel_copy.reset_bone_poses()
	if turret_bone != -1:
		skel_copy.set_bone_pose_rotation(turret_bone, turret_pose)
	if barrel_bone != -1:
		skel_copy.set_bone_pose_rotation(barrel_bone, barrel_pose)
	# Copy only the turret + barrel skinned meshes — they default-resolve their
	# `skeleton` NodePath (^"..") to the parent skeleton, identical to the GLB
	# import layout.
	var copied: int = _copy_skinned_meshes_by_name(model_node, skel_copy, keep_mesh_names)
	if copied == 0:
		push_warning("DestructionVFX: no meshes matched keep_mesh_names %s — wreck will be invisible" % str(keep_mesh_names))
	else:
		# The live tank is charred before cook-off, but this debris is rebuilt
		# from fresh MeshInstance3D nodes. Apply the overlay directly so the
		# airborne turret/barrel read as burned too.
		apply_charred(skel_copy)

	# Parent to world root BEFORE setting global_transform.
	world_root.add_child(debris)
	debris.global_transform = spawn_world
	# Exclude collision with any PhysicsBody3D at the spawn point.
	if model_node != null:
		var donor: Node = model_node.get_parent()
		if donor is PhysicsBody3D:
			debris.add_collision_exception_with(donor as PhysicsBody3D)
	# Offset the new skeleton so the TURRET BONE lands at the debris origin.
	# Without this, the skeleton sits at debris origin and bones are offset
	# upward, making the rigidbody's rotation pivot below the visible turret
	# — the turret would dip below ground during tumble.
	# Math: skeleton.global * turret_bone_local = debris.global (desired)
	#     → skeleton.global = debris.global * turret_bone_local.affine_inverse()
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
	enable_col_timer.timeout.connect(debris.set.bind("collision_mask", 0b001))

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


## Build a fresh Skeleton3D with the same bone topology and current pose as
## [param src]. Used by spawn_turret_debris to avoid duplicate()ing the GLB
## subtree (which crashes Godot 4.3 web on this asset). Bone count, names,
## parents, rests, and pose (translation/rotation/scale) are copied directly;
## attachments and modifications are intentionally left out — debris only needs
## a frozen pose, not animation tracks or IK.
static func _clone_skeleton_bones(src: Skeleton3D) -> Skeleton3D:
	var dst: Skeleton3D = Skeleton3D.new()
	dst.name = src.name
	dst.motion_scale = src.motion_scale
	var n: int = src.get_bone_count()
	# First pass: add bones (parent indices reference earlier bones, so the
	# add order matches the source's index order).
	for i: int in n:
		dst.add_bone(src.get_bone_name(i))
	# Second pass: set parents + transforms now that all bones exist.
	for i: int in n:
		dst.set_bone_parent(i, src.get_bone_parent(i))
		dst.set_bone_rest(i, src.get_bone_rest(i))
		dst.set_bone_pose_position(i, src.get_bone_pose_position(i))
		dst.set_bone_pose_rotation(i, src.get_bone_pose_rotation(i))
		dst.set_bone_pose_scale(i, src.get_bone_pose_scale(i))
	return dst


## Find every MeshInstance3D under [param source_root] whose `name` is in
## [param names], and create a fresh copy as a child of [param target_skel].
## Mesh + Skin + material_override/material_overlay resources are shared by
## reference (no GPU copy). Local transform is copied so the skinned-vertex
## offset relative to the skeleton root matches the original. Returns the
## count of meshes copied.
##
## The default `MeshInstance3D.skeleton` NodePath is `^".."`, so parenting
## under the skeleton makes skinning resolve automatically — same layout the
## GLB importer produces.
static func _copy_skinned_meshes_by_name(
	source_root: Node,
	target_skel: Skeleton3D,
	names: PackedStringArray
) -> int:
	var count: int = 0
	if source_root is MeshInstance3D:
		var src_mi: MeshInstance3D = source_root as MeshInstance3D
		if String(src_mi.name) in names and src_mi.mesh != null:
			var copy: MeshInstance3D = MeshInstance3D.new()
			copy.name = src_mi.name
			copy.mesh = src_mi.mesh
			copy.skin = src_mi.skin
			copy.material_override = src_mi.material_override
			copy.material_overlay = src_mi.material_overlay
			target_skel.add_child(copy)
			copy.transform = src_mi.transform
			count += 1
	for child: Node in source_root.get_children():
		count += _copy_skinned_meshes_by_name(child, target_skel, names)
	return count


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


static func _estimate_visual_smoke_origin(vehicle: Node3D, fallback_y: float) -> Vector3:
	var bounds: Dictionary = {
		"found": false,
		"best_score": -1.0,
		"best_bottom_y": fallback_y,
	}
	_accumulate_burn_surface(vehicle, vehicle.global_transform.affine_inverse(), bounds)
	if not bool(bounds["found"]):
		return Vector3(0.0, fallback_y, 0.0)
	# Use the largest visible body mesh, but start the plume at its bottom so
	# smoke appears to leak from the wreck instead of sitting on top of it.
	var estimated_y: float = float(bounds["best_bottom_y"]) + 0.04
	return Vector3(0.0, estimated_y, 0.0)


static func _accumulate_burn_surface(root: Node, vehicle_inverse: Transform3D, bounds: Dictionary) -> void:
	if root is MeshInstance3D:
		var mi: MeshInstance3D = root as MeshInstance3D
		if mi.mesh != null and mi.is_visible_in_tree():
			var aabb: AABB = mi.mesh.get_aabb()
			var min_x: float = 999999.0
			var max_x: float = -999999.0
			var min_y: float = 999999.0
			var max_y: float = -999999.0
			var min_z: float = 999999.0
			var max_z: float = -999999.0
			for ix: int in range(2):
				for iy: int in range(2):
					for iz: int in range(2):
						var local_corner: Vector3 = aabb.position + Vector3(
							aabb.size.x * float(ix),
							aabb.size.y * float(iy),
							aabb.size.z * float(iz)
						)
						var vehicle_pos: Vector3 = vehicle_inverse * (mi.global_transform * local_corner)
						min_x = minf(min_x, vehicle_pos.x)
						max_x = maxf(max_x, vehicle_pos.x)
						min_y = minf(min_y, vehicle_pos.y)
						max_y = maxf(max_y, vehicle_pos.y)
						min_z = minf(min_z, vehicle_pos.z)
						max_z = maxf(max_z, vehicle_pos.z)
			var size_x: float = max_x - min_x
			var size_y: float = max_y - min_y
			var size_z: float = max_z - min_z
			var score: float = maxf(size_x, 0.01) * maxf(size_y, 0.01) * maxf(size_z, 0.01)
			if score > float(bounds["best_score"]):
				bounds["found"] = true
				bounds["best_score"] = score
				bounds["best_bottom_y"] = min_y
	for child: Node in root.get_children():
		_accumulate_burn_surface(child, vehicle_inverse, bounds)


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
	var web_build: bool = _is_web_build()
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "Smoke"
	p.amount = int(roundf((34.0 if web_build else 72.0) * footprint_scale))
	p.lifetime = 3.8 if web_build else 4.4
	p.preprocess = 0.65 if web_build else 1.1
	p.explosiveness = 0.0
	p.randomness = 0.62
	p.fixed_fps = 24 if web_build else 30
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
	pm.spread = 20.0 if web_build else 24.0
	pm.initial_velocity_min = 0.34 if web_build else 0.42
	pm.initial_velocity_max = 0.82 if web_build else 0.98
	pm.gravity = Vector3(0.0, 0.10, 0.0)
	pm.linear_accel_min = -0.20
	pm.linear_accel_max = 0.05
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -18.0
	pm.angular_velocity_max = 18.0
	pm.scale_min = 0.42 if web_build else 0.52
	pm.scale_max = 0.82 if web_build else 1.02
	var scale_curve: Curve = Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.42))
	scale_curve.add_point(Vector2(0.28, 0.92))
	scale_curve.add_point(Vector2(0.76, 1.28))
	scale_curve.add_point(Vector2(1.0, 1.48))
	var scale_tex: CurveTexture = CurveTexture.new()
	scale_tex.curve = scale_curve
	pm.scale_curve = scale_tex
	# Gradient encoding depends on which material path runs:
	#   shader path (desktop):  RED channel = lifetime (drives shader v_life),
	#                           ALPHA = opacity fade.
	#   billboard path (web):   white RGB so the billboard's vertex_color_use_as_albedo
	#                           doesn't tint the smoke red, ALPHA still drives fade.
	# _should_use_authored_shaders() is the single source of truth — flip it
	# (via _USE_GPU_PARTICLE_SHADERS_ON_WEB) and both this gradient and the
	# material factory move together.
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(0.0, 0.0, 0.0, 0.0))
	grad.set_offset(0, 0.0)
	if _should_use_authored_shaders():
		grad.add_point(0.14, Color(0.18, 0.0, 0.0, 0.58))
		grad.add_point(0.68, Color(0.64, 0.0, 0.0, 0.40))
	else:
		grad.add_point(0.14, Color(1.0, 1.0, 1.0, 0.42))
		grad.add_point(0.68, Color(1.0, 1.0, 1.0, 0.30))
	grad.add_point(1.0, Color(1.0, 0.0, 0.0, 0.0))
	var grad_tex: GradientTexture1D = GradientTexture1D.new()
	grad_tex.gradient = grad
	pm.color_ramp = grad_tex
	p.process_material = pm

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(1.18, 1.04) if web_build else Vector2(1.55, 1.32)
	var smoke_mat: Material = _make_smoke_material(
		Color(0.28, 0.29, 0.32, 0.62) if web_build else Color(0.26, 0.27, 0.30, 0.86),
		3.0 if web_build else 4.0
	)
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
	quad.size = Vector2(0.40, 0.54)
	var fire_mat: Material = _make_fire_material(Color(2.0, 0.82, 0.16, 0.58), 0.22, 1.0, 0.09, 0.10)
	if fire_mat == null:
		push_warning("DestructionVFX._build_fire: fire material build returned null — "
				+ "check that T_fire_diff.png exists and the fire shader compiles")
	if fire_mat == null:
		fire_mat = _make_billboard_material(null, Color(1.0, 0.42, 0.08, 0.55), 20, true)
	quad.material = fire_mat
	p.draw_passes = 1
	p.draw_pass_1 = quad

	return p


static func _build_flame_licks() -> GPUParticles3D:
	var web_build: bool = _is_web_build()
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "FlameLicks"
	p.amount = 3 if web_build else 5
	p.lifetime = 0.9
	p.preprocess = 0.5
	p.explosiveness = 0.0
	p.randomness = 0.55
	p.fixed_fps = 30 if web_build else 60
	p.emitting = true
	p.local_coords = true
	p.sorting_offset = 3.0
	p.visibility_aabb = AABB(Vector3(-2.0, -0.5, -2.0), Vector3(4.0, 4.0, 4.0))

	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.09
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 12.0
	pm.initial_velocity_min = 0.16
	pm.initial_velocity_max = 0.42
	pm.gravity = Vector3(0.0, 0.62, 0.0)
	pm.scale_min = 0.12
	pm.scale_max = 0.26
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
	quad.size = Vector2(0.22, 0.32)
	quad.material = _make_fire_material(Color(2.0, 0.72, 0.1, 0.52), 0.26, 0.75, 0.12, 0.02)
	p.draw_pass_1 = quad

	return p


static func _build_embers() -> GPUParticles3D:
	var web_build: bool = _is_web_build()
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "Embers"
	p.amount = 12 if web_build else 18
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


static func _build_web_smoke(root: Node3D, footprint: Vector2, source_pos: Vector3) -> void:
	var vfx = _WEB_SHADER_BILLBOARD_VFX_SCRIPT.new()
	vfx.name = "WebShaderSmoke"
	root.add_child(vfx)
	vfx.position = source_pos
	_populate_web_shader_smoke(vfx, footprint)


static func _populate_web_shader_smoke(vfx, footprint: Vector2) -> void:
	var footprint_x: float = clampf(footprint.x, 0.5, 3.6)
	var footprint_z: float = clampf(footprint.y, 0.5, 4.8)
	var footprint_scale: float = clampf(maxf(footprint_x, footprint_z) / 2.8, 0.75, 1.35)

	var smoke_count: int = int(roundf(32.0 * footprint_scale))
	for i: int in range(smoke_count):
		vfx.add_card(
			"Smoke%02d" % i,
			_make_web_smoke_material(Color(0.24, 0.25, 0.27, 0.86), randf() * 20.0),
			Vector2(1.34, 1.18),
			Vector3(0.0, 0.04, 0.0),
			Vector3(footprint_x * 0.30, 0.03, footprint_z * 0.26),
			Vector3(-0.12, 0.28, -0.12),
			Vector3(0.12, 0.74, 0.12),
			0.54,
			1.46,
			4.6,
			true,
			0.78,
			0.12,
			0.42,
			0.20,
			randf() * 4.6
		)


static func _add_web_fire_layer(
	vfx,
	fire_tex: Texture2D,
	name: String,
	origin: Vector3,
	size: Vector2,
	color: Color,
	scale_amount: float,
	base_glow: float,
	priority: int,
	flame_width_scale: float = 1.0
) -> void:
	vfx.add_card(
		name,
		_make_web_fire_material(fire_tex, color, true, randf() * 20.0, 0.20, 1.05, 0.10, base_glow, priority, flame_width_scale),
		size,
		origin,
		Vector3.ZERO,
		Vector3.ZERO,
		Vector3.ZERO,
		scale_amount,
		scale_amount,
		100.0,
		true,
		0.96,
		0.01,
		0.01,
		0.02,
		randf() * 100.0,
		true
	)


static func _build_web_smoke_particles(footprint: Vector2) -> CPUParticles3D:
	var footprint_x: float = clampf(footprint.x, 0.5, 3.6)
	var footprint_z: float = clampf(footprint.y, 0.5, 4.8)
	var footprint_scale: float = clampf(maxf(footprint_x, footprint_z) / 2.8, 0.75, 1.35)
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = "Smoke"
	p.amount = int(roundf(38.0 * footprint_scale))
	p.lifetime = 4.1
	p.preprocess = 1.2
	p.explosiveness = 0.0
	p.randomness = 0.58
	p.fixed_fps = 24
	p.emitting = true
	p.local_coords = true
	p.draw_order = CPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.visibility_aabb = AABB(
		Vector3(-footprint_x, -0.75, -footprint_z),
		Vector3(footprint_x * 2.0, 7.25, footprint_z * 2.0)
	)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(footprint_x * 0.26, 0.04, footprint_z * 0.22)
	p.direction = Vector3(0.0, 1.0, 0.0)
	p.spread = 22.0
	p.initial_velocity_min = 0.36
	p.initial_velocity_max = 0.92
	p.gravity = Vector3(0.0, 0.12, 0.0)
	p.linear_accel_min = -0.22
	p.linear_accel_max = 0.03
	p.angle_min = -180.0
	p.angle_max = 180.0
	p.angular_velocity_min = -18.0
	p.angular_velocity_max = 18.0
	p.scale_amount_min = 0.50
	p.scale_amount_max = 0.92
	var scale_curve: Curve = Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.42))
	scale_curve.add_point(Vector2(0.30, 0.92))
	scale_curve.add_point(Vector2(0.78, 1.28))
	scale_curve.add_point(Vector2(1.0, 1.46))
	p.scale_amount_curve = scale_curve
	p.color_ramp = _make_smoke_lifetime_gradient(0.66, 0.46)

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(1.25, 1.10)
	quad.material = _make_web_smoke_material(Color(0.26, 0.27, 0.30, 0.84), randf() * 20.0)
	p.mesh = quad
	return p


static func _build_web_fire_particles() -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = "Fire"
	p.amount = 1
	p.lifetime = 100.0
	p.preprocess = 0.0
	p.explosiveness = 0.0
	p.randomness = 0.0
	p.fixed_fps = 60
	p.emitting = true
	p.local_coords = true
	p.draw_order = CPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.visibility_aabb = AABB(Vector3(-2.0, -0.75, -2.0), Vector3(4.0, 4.5, 4.0))
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_POINT
	p.direction = Vector3(0.0, 1.0, 0.0)
	p.spread = 0.0
	p.initial_velocity_min = 0.0
	p.initial_velocity_max = 0.0
	p.gravity = Vector3.ZERO
	p.scale_amount_min = 1.0
	p.scale_amount_max = 1.0

	var fire_tex: Texture2D = _get_shared_fire_teardrop()
	if fire_tex == null:
		fire_tex = _get_web_fire_mask()
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.32, 0.44)
	quad.material = _make_web_fire_material(
		fire_tex,
		Color(2.0, 0.82, 0.16, 0.48),
		true,
		randf() * 20.0,
		0.24,
		1.05,
		0.10,
		0.08,
		20
	)
	p.mesh = quad
	return p


static func _build_web_flame_licks_particles() -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = "FlameLicks"
	p.amount = 3
	p.lifetime = 0.9
	p.preprocess = 0.45
	p.explosiveness = 0.0
	p.randomness = 0.48
	p.fixed_fps = 30
	p.emitting = true
	p.local_coords = true
	p.draw_order = CPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.visibility_aabb = AABB(Vector3(-1.5, -0.5, -1.5), Vector3(3.0, 3.25, 3.0))
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.08
	p.direction = Vector3(0.0, 1.0, 0.0)
	p.spread = 12.0
	p.initial_velocity_min = 0.14
	p.initial_velocity_max = 0.36
	p.gravity = Vector3(0.0, 0.54, 0.0)
	p.scale_amount_min = 0.10
	p.scale_amount_max = 0.22
	var scale_curve: Curve = Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.55))
	scale_curve.add_point(Vector2(0.45, 1.0))
	scale_curve.add_point(Vector2(1.0, 0.35))
	p.scale_amount_curve = scale_curve
	p.color_ramp = _make_fire_lifetime_gradient(0.48, 0.34)

	var fire_tex: Texture2D = _get_shared_fire_teardrop()
	if fire_tex == null:
		fire_tex = _get_web_fire_mask()
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.18, 0.26)
	quad.material = _make_web_fire_material(
		fire_tex,
		Color(2.0, 0.72, 0.10, 0.38),
		true,
		randf() * 20.0,
		0.30,
		0.85,
		0.12,
		0.02,
		22
	)
	p.mesh = quad
	return p


static func _build_web_embers_particles() -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = "Embers"
	p.amount = 10
	p.lifetime = 1.5
	p.preprocess = 0.65
	p.explosiveness = 0.0
	p.randomness = 0.35
	p.fixed_fps = 24
	p.emitting = true
	p.local_coords = true
	p.draw_order = CPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.visibility_aabb = AABB(Vector3(-1.8, -0.5, -1.8), Vector3(3.6, 4.2, 3.6))
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.28
	p.direction = Vector3(0.0, 1.0, 0.0)
	p.spread = 28.0
	p.initial_velocity_min = 0.45
	p.initial_velocity_max = 1.05
	p.gravity = Vector3(0.0, 0.55, 0.0)
	p.scale_amount_min = 0.08
	p.scale_amount_max = 0.18
	p.color_ramp = _make_ember_lifetime_gradient()

	var spark_tex: Texture2D = _get_shared_circle_mask()
	if spark_tex == null:
		spark_tex = _get_web_spark_mask()
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.08, 0.08)
	quad.material = _make_web_fire_material(
		spark_tex,
		Color(4.5, 1.2, 0.28, 0.72),
		false,
		randf() * 20.0,
		0.0,
		1.0,
		0.12,
		0.0,
		30
	)
	p.mesh = quad
	return p


static func _make_smoke_lifetime_gradient(peak_alpha: float, tail_alpha: float) -> Gradient:
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(0.0, 0.0, 0.0, 0.0))
	grad.set_offset(0, 0.0)
	grad.add_point(0.14, Color(0.18, 0.0, 0.0, peak_alpha))
	grad.add_point(0.68, Color(0.64, 0.0, 0.0, tail_alpha))
	grad.add_point(1.0, Color(1.0, 0.0, 0.0, 0.0))
	return grad


static func _make_fire_lifetime_gradient(peak_alpha: float, tail_alpha: float) -> Gradient:
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(1.0, 1.0, 1.0, 0.0))
	grad.set_offset(0, 0.0)
	grad.add_point(0.18, Color(1.0, 1.0, 1.0, peak_alpha))
	grad.add_point(0.68, Color(1.0, 1.0, 1.0, tail_alpha))
	grad.add_point(1.0, Color(1.0, 1.0, 1.0, 0.0))
	return grad


static func _make_ember_lifetime_gradient() -> Gradient:
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(1.0, 0.78, 0.35, 0.0))
	grad.set_offset(0, 0.0)
	grad.add_point(0.18, Color(1.0, 0.36, 0.08, 0.9))
	grad.add_point(0.72, Color(0.8, 0.08, 0.02, 0.50))
	grad.add_point(1.0, Color(0.25, 0.0, 0.0, 0.0))
	return grad


static func _make_web_smoke_material(tint: Color, time_offset: float, particle_life_override: float = -1.0) -> Material:
	var smoke_tex: Texture2D = _get_shared_smoke_texture()
	var shader: Shader = load(_SMOKE_WEB_SHADER_PATH) as Shader
	if smoke_tex == null or shader == null:
		return _make_billboard_material(smoke_tex, tint, 10, false)
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	mat.render_priority = 10
	mat.set_shader_parameter("smoke_texture", smoke_tex)
	mat.set_shader_parameter("distortion_texture", _get_shared_smoke_noise())
	mat.set_shader_parameter("smoke_color", tint)
	mat.set_shader_parameter("max_lod", 3.0)
	mat.set_shader_parameter("fade_intensity", 1.18)
	mat.set_shader_parameter("min_particle_alpha", 0.0)
	mat.set_shader_parameter("edge_start", 0.18)
	mat.set_shader_parameter("texture_power", 0.58)
	mat.set_shader_parameter("dissolve_strength", 0.12)
	mat.set_shader_parameter("time_offset", time_offset)
	mat.set_shader_parameter("particle_life_override", particle_life_override)
	return mat


static func _make_web_fire_material(
	fire_texture: Texture2D,
	fire_color: Color,
	procedural_flame: bool,
	time_offset: float,
	distortion_amount: float,
	anchor_power: float,
	edge_softness: float,
	base_glow: float,
	priority: int,
	flame_width_scale: float = 1.0
) -> Material:
	var shader: Shader = load(_FIRE_WEB_SHADER_PATH) as Shader
	if fire_texture == null or shader == null:
		return _make_billboard_material(fire_texture, fire_color, priority, true)
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	mat.render_priority = priority
	mat.set_shader_parameter("fire_texture", fire_texture)
	mat.set_shader_parameter("distortion_texture", _get_shared_smoke_noise())
	mat.set_shader_parameter("fire_color", fire_color)
	mat.set_shader_parameter("distortion_speed", Vector2(0.0, -1.4))
	mat.set_shader_parameter("distortion_amount", distortion_amount)
	mat.set_shader_parameter("anchor_power", anchor_power)
	mat.set_shader_parameter("edge_softness", edge_softness)
	mat.set_shader_parameter("base_glow", base_glow)
	mat.set_shader_parameter("flame_width_scale", flame_width_scale)
	mat.set_shader_parameter("procedural_flame", 1.0 if procedural_flame else 0.0)
	mat.set_shader_parameter("time_offset", time_offset)
	return mat


## Lazily load the authored smoke sprite used by the wreck plume. This texture
## carries an irregular alpha silhouette, replacing the old radial puff mask.
static func _get_shared_smoke_texture() -> Texture2D:
	if _shared_smoke_texture != null:
		return _shared_smoke_texture
	_shared_smoke_texture = load(_SMOKE_TEXTURE_PATH) as Texture2D
	if _shared_smoke_texture == null:
		push_warning("DestructionVFX: smoke texture missing at %s" % _SMOKE_TEXTURE_PATH)
	return _shared_smoke_texture


## Lazily load the 2D noise texture used for subtle smoke/spark UV distortion.
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
		print("[VFX/smoke] smoke_texture failed to load — material is null")
		return null
	var shader: Shader = load(_SMOKE_SHADER_PATH) as Shader
	if shader == null:
		print("[VFX/smoke] BILLBOARD path (shader load failed: %s)" % _SMOKE_SHADER_PATH)
		push_warning("DestructionVFX: smoke shader missing at %s — using billboard fallback" % _SMOKE_SHADER_PATH)
		return _make_billboard_material(smoke_tex, tint, 10, false)
	if not _logged_smoke_shader_path:
		_logged_smoke_shader_path = true
		print("[VFX/smoke] SHADER path (authored gdshader)")
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
	return _make_billboard_material(_get_shared_smoke_texture(), Color(0.48, 0.49, 0.52, 0.68), 3, false)


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
	mat.no_depth_test = false
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = tint
	if texture != null:
		mat.albedo_texture = texture
	if additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.emission_enabled = true
		mat.emission = Color(tint.r, tint.g, tint.b, tint.a)
		mat.emission_energy_multiplier = maxf(1.0, maxf(tint.r, maxf(tint.g, tint.b)))
	return mat


## Procedurally-generated teardrop alpha mask used as a FALLBACK when the
## authored fire teardrop texture or shader fails to load. Cached on first
## call. Synthesised at runtime via Image.set_pixel so it doesn't depend on
## a .png file in the .pck — guarantees the wreck flame is never invisible
## even if asset import broke or the GPU rejected the authored shader.
##
## The browser CPU-particle path uses this only if the imported fire texture is
## unavailable. Desktop uses it only if the authored shader/material cannot load.
static func _get_web_fire_mask() -> Texture2D:
	if _shared_web_fire_mask != null:
		return _shared_web_fire_mask
	const SIZE: int = 128
	var img: Image = Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y: int in range(SIZE):
		var t: float = 1.0 - float(y) / float(SIZE - 1)
		var width: float = lerpf(0.33, 0.045, pow(t, 1.22))
		var bottom: float = smoothstep(0.0, 0.12, t)
		var top: float = 1.0 - smoothstep(0.88, 1.0, t)
		for x: int in range(SIZE):
			var u: float = float(x) / float(SIZE - 1)
			var center_shift: float = sin(t * TAU * 1.35) * 0.035 * t
			var dist: float = absf(u - 0.5 - center_shift)
			var side: float = 1.0 - smoothstep(width, width + 0.10, dist)
			var mask: float = pow(clampf(side * bottom * top, 0.0, 1.0), 0.72)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, mask))
	_shared_web_fire_mask = ImageTexture.create_from_image(img)
	return _shared_web_fire_mask


## Procedurally-generated radial soft-circle mask used as a FALLBACK for the
## explosion spark material when the authored circle_mask texture or fire
## shader fails to load. Same role + lifecycle as [_get_web_fire_mask].
static func _get_web_spark_mask() -> Texture2D:
	if _shared_web_spark_mask != null:
		return _shared_web_spark_mask
	const SIZE: int = 64
	var img: Image = Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y: int in range(SIZE):
		var v: float = (float(y) / float(SIZE - 1)) * 2.0 - 1.0
		for x: int in range(SIZE):
			var u: float = (float(x) / float(SIZE - 1)) * 2.0 - 1.0
			var r: float = sqrt(u * u + v * v)
			var mask: float = 1.0 - smoothstep(0.42, 1.0, r)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, mask))
	_shared_web_spark_mask = ImageTexture.create_from_image(img)
	return _shared_web_spark_mask


## Build a ShaderMaterial bound to spatial_particles_fire.gdshader for desktop:
## the Le Lu stylized fire pipeline (pre-painted teardrop + panning distortion
## + HDR color mix). Browser builds use the same shader on MeshInstance3D
## CPUParticles3D billboards by default because WebGL2 can silently draw custom
## GPUParticles3D vertex shaders blank.
##
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
	var shader_path: String = _FIRE_SHADER_PATH if _should_use_gpu_particle_emitters() else _FIRE_WEB_SHADER_PATH
	var shader: Shader = load(shader_path) as Shader
	if fire_tex == null or shader == null:
		print("[VFX/fire] BILLBOARD path (fire_tex=%s shader=%s)" % [fire_tex, shader])
		push_warning("DestructionVFX: fire shader/teardrop unavailable — using procedural billboard fallback")
		return _make_billboard_material(_get_web_fire_mask(), fire_color, 20, true)
	if not _logged_fire_shader_path:
		_logged_fire_shader_path = true
		print("[VFX/fire] SHADER path (authored gdshader)")
	if noise_tex == null:
		push_warning("DestructionVFX: distortion noise texture failed to load")
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
	mat.set_shader_parameter("procedural_flame", 1.0)
	return mat


## Build a ShaderMaterial for explosion sparks — same fire shader but bound
## to a soft circle mask instead of the teardrop, with high HDR color so the
## tiny billboards bloom hard. Distortion is disabled because the spark quads
## are too small (~0.25 m) for noise warping to read.
static func _make_spark_material(
	fire_color: Color = Color(8.0, 3.0, 0.5, 1.0)
) -> Material:
	var circle_tex: Texture2D = _get_shared_circle_mask()
	var shader_path: String = _FIRE_SHADER_PATH if _should_use_gpu_particle_emitters() else _FIRE_WEB_SHADER_PATH
	var shader: Shader = load(shader_path) as Shader
	if circle_tex == null or shader == null:
		print("[VFX/spark] BILLBOARD path (circle_tex=%s shader=%s path=%s)" % [circle_tex, shader, shader_path])
		push_warning("DestructionVFX: fire shader/circle mask unavailable — using procedural billboard fallback")
		return _make_billboard_material(_get_web_spark_mask(), fire_color, 30, true)
	if not _logged_spark_shader_path:
		_logged_spark_shader_path = true
		print("[VFX/spark] SHADER path (%s)" % shader_path)
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
	mat.set_shader_parameter("procedural_flame", 0.0)
	return mat


static func _build_light() -> OmniLight3D:
	# Pulsing warm light — gives volumetric fog something to glow through.
	# No shadows (3 wrecks × cubemap shadow pass would be expensive).
	var light: OmniLight3D = OmniLight3D.new()
	light.name = "FireGlow"
	light.light_color = Color(1.0, 0.45, 0.10)
	light.light_energy = 0.85
	light.omni_range = 3.2
	light.shadow_enabled = false
	# fire_flicker.gd oscillates light_energy each _process frame.
	var flicker: Script = load(_FLICKER_SCRIPT_PATH) as Script
	if flicker != null:
		light.set_script(flicker)
		light.set("min_energy", 0.45)
		light.set("max_energy", 1.15)
	return light


## Build a fresh MeshInstance3D that shares the source's Mesh resource but
## has NO skeleton/skin bindings — renders cleanly as a static mesh detached
## from any armature. Falls back to a BoxMesh if source has no .mesh.
static func _make_fresh_mesh_copy(source: MeshInstance3D, fallback_size: Vector3) -> MeshInstance3D:
	var copy: MeshInstance3D = MeshInstance3D.new()
	if source != null and source.mesh != null:
		copy.mesh = source.mesh
		copy.material_override = source.material_override
		copy.material_overlay = source.material_overlay
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

## One-shot explosion at [param position_world]. Spawns a short fireball,
## sparks, and a pulsing flash light under [param world_root]. CRITICAL: nodes are added to the tree
## BEFORE setting global_position / creating tweens — orphan nodes silently
## drop global_transform writes and create_tween() returns null.
static func spawn_explosion(world_root: Node, position_world: Vector3, include_fireball: bool = true) -> void:
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

	if include_fireball:
		_spawn_explosion_fireball(world_root, position_world)

	# --- Spark burst ---
	if _should_use_gpu_particle_emitters():
		var sparks: GPUParticles3D = _build_spark_burst()
		world_root.add_child(sparks)
		sparks.global_position = position_world
		sparks.emitting = true  # programmatic GPUParticles3D defaults to false in code
	else:
		# Browser spark billboards read as floating round dots over the wreck.
		# Keep the flash light and persistent smoke, but skip these balls.
		pass


static func _spawn_explosion_fireball(world_root: Node, position_world: Vector3) -> void:
	var burst: Node3D = _build_explosion_fireball()
	world_root.add_child(burst)
	burst.global_position = position_world
	world_root.get_tree().create_timer(0.9).timeout.connect(burst.queue_free)


static func _build_explosion_fireball() -> Node3D:
	var vfx = _WEB_SHADER_BILLBOARD_VFX_SCRIPT.new()
	vfx.name = "ExplosionFireball"
	var fire_tex: Texture2D = _get_shared_fire_teardrop()
	if fire_tex == null:
		fire_tex = _get_web_fire_mask()
	var core_mat: Material = _make_web_fire_material(
		fire_tex,
		Color(3.5, 1.15, 0.18, 0.78),
		true,
		randf() * 20.0,
		0.32,
		0.82,
		0.11,
		0.18,
		28,
		1.18
	)
	vfx.add_card(
		"BlastCore",
		core_mat,
		Vector2(1.18, 0.92),
		Vector3(0.0, 0.05, 0.0),
		Vector3(0.18, 0.04, 0.18),
		Vector3(-0.55, 0.35, -0.55),
		Vector3(0.55, 1.05, 0.55),
		0.30,
		1.55,
		0.46,
		false,
		1.0,
		0.06,
		0.62,
		0.45,
		0.0
	)
	var lick_mat: Material = _make_web_fire_material(
		fire_tex,
		Color(2.4, 0.68, 0.08, 0.56),
		true,
		randf() * 20.0,
		0.38,
		0.78,
		0.13,
		0.05,
		27,
		0.92
	)
	for i: int in range(3):
		vfx.add_card(
			"BlastLick%02d" % i,
			lick_mat,
			Vector2(0.62, 0.78),
			Vector3(0.0, 0.02, 0.0),
			Vector3(0.30, 0.06, 0.30),
			Vector3(-0.75, 0.45, -0.75),
			Vector3(0.75, 1.30, 0.75),
			0.18,
			0.92,
			0.38,
			false,
			0.82,
			0.04,
			0.70,
			1.2,
			randf() * 0.12
		)
	var smoke_mat: Material = _make_web_smoke_material(Color(0.18, 0.18, 0.19, 0.72), randf() * 20.0)
	vfx.add_card(
		"BlastSoot",
		smoke_mat,
		Vector2(1.55, 1.25),
		Vector3(0.0, 0.10, 0.0),
		Vector3(0.28, 0.05, 0.28),
		Vector3(-0.32, 0.28, -0.32),
		Vector3(0.32, 0.88, 0.32),
		0.36,
		1.55,
		0.82,
		false,
		0.68,
		0.08,
		0.72,
		0.65,
		0.0
	)
	return vfx


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


static func _build_web_spark_burst() -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = "ExplosionSparks"
	p.amount = 50
	p.lifetime = 0.8
	p.one_shot = true
	p.explosiveness = 1.0
	p.randomness = 0.4
	p.fixed_fps = 30
	p.local_coords = true
	p.draw_order = CPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.visibility_aabb = AABB(Vector3(-5.0, -5.0, -5.0), Vector3(10.0, 10.0, 10.0))
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.3
	p.direction = Vector3(0.0, 1.0, 0.0)
	p.spread = 180.0
	p.initial_velocity_min = 4.0
	p.initial_velocity_max = 10.0
	p.gravity = Vector3(0.0, -5.0, 0.0)
	p.scale_amount_min = 0.12
	p.scale_amount_max = 0.28
	p.color_ramp = _make_ember_lifetime_gradient()

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.25, 0.25)
	quad.material = _make_spark_material(Color(8.0, 3.0, 0.5, 1.0))
	p.mesh = quad
	return p


static func _build_web_shader_spark_burst() -> Node3D:
	var vfx = _WEB_SHADER_BILLBOARD_VFX_SCRIPT.new()
	vfx.name = "ExplosionSparks"
	var spark_mat: Material = _make_spark_material(Color(8.0, 3.0, 0.5, 1.0))
	for i: int in range(50):
		var dir: Vector3 = Vector3(
			randf_range(-1.0, 1.0),
			randf_range(-0.35, 1.0),
			randf_range(-1.0, 1.0)
		)
		if dir.length_squared() < 0.001:
			dir = Vector3.UP
		dir = dir.normalized()
		var speed: float = randf_range(4.0, 10.0)
		vfx.add_card_with_velocity(
			"Spark%02d" % i,
			spark_mat,
			Vector2(0.25, 0.25),
			Vector3.ZERO,
			dir * speed + Vector3(0.0, -2.5, 0.0),
			0.45,
			0.05,
			0.8,
			false,
			0.95,
			0.04,
			0.45,
			3.5,
			0.0
		)
	return vfx


# ---------------------------------------------------------------------------
# Mesh walker
# ---------------------------------------------------------------------------

static func _walk_meshes(root: Node, fn: Callable) -> void:
	if root is MeshInstance3D:
		fn.call(root as MeshInstance3D)
	for child: Node in root.get_children():
		_walk_meshes(child, fn)


static func _mesh_uses_alpha_cutout(mesh_instance: MeshInstance3D) -> bool:
	if mesh_instance == null or mesh_instance.mesh == null:
		return false
	if mesh_instance.transparency > 0.001:
		return true
	if _material_uses_alpha_cutout(mesh_instance.material_override):
		return true
	for surface: int in range(mesh_instance.mesh.get_surface_count()):
		if _material_uses_alpha_cutout(mesh_instance.get_active_material(surface)):
			return true
	return false


static func _material_uses_alpha_cutout(material: Material) -> bool:
	if material == null:
		return false
	if material is BaseMaterial3D:
		var base: BaseMaterial3D = material as BaseMaterial3D
		if base.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return true
		if base.albedo_color.a < 0.995:
			return true
		if _texture_has_alpha(base.albedo_texture):
			return true
	return false


static func _texture_has_alpha(texture: Texture2D) -> bool:
	if texture == null:
		return false
	var image: Image = texture.get_image()
	if image == null:
		return false
	return image.detect_alpha() != Image.ALPHA_NONE


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
		world_root.get_tree().create_timer(lifetime).timeout.connect(body.queue_free)
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
		world_root.get_tree().create_timer(lifetime).timeout.connect(body.queue_free)
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
## Fresh MeshInstance3Ds share the source's Mesh + material_override/material_overlay
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
			copy.material_overlay = src_mi.material_overlay
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
	tree.create_timer(0.3).timeout.connect(body.set.bind("collision_mask", 0b001))
