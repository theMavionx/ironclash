class_name PlayerFireVFX
extends RefCounted

## Static helpers for rifle-fire visual feedback:
##   - 4-frame sprite muzzle flash at the muzzle world position
##   - Yellow stretched-quad tracer from muzzle to hit point
##   - Hitscan raycast that damages any HealthComponent in the line of sight
##
## Called by WeaponController on each AR fire. Tracer life and emission are
## tuned for a classic arcade "laser-bullet" look — visible long yellow streak
## that fades in ~80ms.

const _FLASH_TEXTURE_PATH: String = "res://Model/Player/FootageCrate-Four_Point_Muuzzle_Flash_With_Shell_Front/FootageCrate-Four_Point_Muuzzle_Flash_With_Shell_Front-00001.png"

static var _flash_texture: Texture2D = null
## Shared resources — one CylinderMesh + one StandardMaterial3D reused across
## every tracer, saves 10+ heap allocations per second at sustained AR fire.
## Assignment to material_override shares by reference (Godot does not copy
## resources on set), so the material is effectively const-shared.
static var _tracer_mesh: CylinderMesh = null
static var _tracer_material: StandardMaterial3D = null


static func _ensure_textures_loaded() -> void:
	if _flash_texture == null:
		_flash_texture = load(_FLASH_TEXTURE_PATH) as Texture2D
	if _tracer_mesh == null:
		var cyl: CylinderMesh = CylinderMesh.new()
		cyl.top_radius = 0.025
		cyl.bottom_radius = 0.025
		cyl.height = 0.8
		cyl.radial_segments = 8
		cyl.rings = 1
		_tracer_mesh = cyl
	if _tracer_material == null:
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.95, 0.5)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.75, 0.2)
		mat.emission_energy_multiplier = 14.0
		_tracer_material = mat


## Prewarm: call from Player._ready() so the first shot doesn't stall on
## shader pipeline compilation + resource loading.
static func prewarm(world_root: Node) -> void:
	_ensure_textures_loaded()
	if _tracer_material == null or world_root == null:
		return
	# Spawn one invisible dummy mesh with the tracer material so Godot compiles
	# the emissive-unshaded pipeline variant during scene load.
	var dummy: MeshInstance3D = MeshInstance3D.new()
	dummy.mesh = _tracer_mesh
	dummy.material_override = _tracer_material
	dummy.visible = false
	world_root.add_child(dummy)
	dummy.get_tree().create_timer(0.1).timeout.connect(dummy.queue_free)


## Fires one AR round: hitscan, muzzle flash (parented to muzzle node so it
## never lags when the player spins), and a travelling tracer.
##
## [param aim_origin] / [param aim_dir] come from the PLAYER'S CAMERA —
## raycast is camera-space so crosshair accuracy matches what the player sees.
## [param muzzle_node] is the AK muzzle Node3D. Flash is parented to it so it
## inherits the rifle's transform each frame (no lag on quick turns). Tracer
## reads its world position at spawn then flies world-space from there.
static func spawn_ar_shot(
	world_root: Node,
	muzzle_node: Node3D,
	aim_origin: Vector3,
	aim_dir: Vector3,
	shooter: CollisionObject3D = null,
	damage: int = 10,
	max_range: float = 500.0
) -> void:
	_ensure_textures_loaded()

	# 1. Hitscan from camera.
	var space: PhysicsDirectSpaceState3D = world_root.get_world_3d().direct_space_state
	var to_point: Vector3 = aim_origin + aim_dir.normalized() * max_range
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(aim_origin, to_point)
	if shooter != null:
		query.exclude = [shooter.get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	var hit_point: Vector3 = to_point
	if not hit.is_empty():
		hit_point = hit.get("position", to_point)
		var col: Object = hit.get("collider")
		if col != null and col is Node:
			var hc: HealthComponent = (col as Node).get_node_or_null("HealthComponent") as HealthComponent
			if hc != null:
				hc.take_damage(damage, DamageTypes.Source.PLAYER_RIFLE)

	if muzzle_node != null and is_instance_valid(muzzle_node):
		_spawn_muzzle_flash(muzzle_node)
		# CROSSHAIR CONVERGENCE (same pattern as tank/heli fix):
		# Tracer orientation must be MUZZLE→HIT, not camera aim_dir. The muzzle
		# sits offset from the camera (over-shoulder view), so firing parallel
		# to the camera direction makes the tracer miss the crosshair point
		# by the muzzle-camera gap (~1m). Using muzzle→hit direction makes
		# the tracer visibly converge on where the player aimed.
		var muzzle_world_pos: Vector3 = muzzle_node.global_transform.origin
		var convergence_dir: Vector3 = hit_point - muzzle_world_pos
		if convergence_dir.length_squared() < 0.001:
			convergence_dir = aim_dir  # fallback: point-blank shot
		else:
			convergence_dir = convergence_dir.normalized()
		_spawn_tracer(world_root, muzzle_node, hit_point, convergence_dir)


## Spawn flash as a CHILD of the muzzle node so it inherits rifle pose every
## frame. Previously parented to world_root, the flash lagged a frame behind
## when the player rotated rapidly.
static func _spawn_muzzle_flash(parent: Node3D) -> void:
	if _flash_texture == null or parent == null:
		return
	var sprite: Sprite3D = Sprite3D.new()
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.shaded = false
	sprite.pixel_size = 0.00028
	sprite.texture = _flash_texture
	# Random roll on Z so successive flashes don't look identical.
	sprite.rotation.z = randf() * TAU
	parent.add_child(sprite)
	sprite.position = Vector3.ZERO  # local to muzzle node
	# Hold the single frame briefly, then free.
	var done_t: SceneTreeTimer = parent.get_tree().create_timer(0.05)
	done_t.timeout.connect(func() -> void:
		if is_instance_valid(sprite):
			sprite.queue_free()
	)


## Spawn a thin round glowing tracer that travels from muzzle to hit point.
## Cylinder center is placed AT the muzzle. Front half (0.4m) extends out of
## the barrel — visible streak. Rear half is inside the rifle mesh — hidden
## by the gun geometry, so the player sees the tracer appear to exit the muzzle.
static func _spawn_tracer(world_root: Node, muzzle_node: Node3D, to_pos: Vector3, aim_dir: Vector3) -> void:
	# 80 m/s is arcade-readable — real bullet at 700+ m/s would be invisible
	# on a 60fps screen for any gameplay-range shot. Travel time caps at
	# ~0.35s so long shots still arrive quickly.
	const BULLET_SPEED: float = 80.0
	if muzzle_node == null or not is_instance_valid(muzzle_node):
		return
	var muzzle_world: Vector3 = muzzle_node.global_transform.origin
	var forward: Vector3 = aim_dir.normalized()
	var mesh: MeshInstance3D = MeshInstance3D.new()
	mesh.mesh = _tracer_mesh
	mesh.material_override = _tracer_material
	world_root.add_child(mesh)
	mesh.global_position = muzzle_world
	# Orient along aim direction. CylinderMesh length is local +Y.
	var up_ref: Vector3 = Vector3.UP
	if absf(forward.dot(Vector3.UP)) > 0.99:
		up_ref = Vector3.FORWARD
	mesh.look_at(to_pos, up_ref)
	mesh.rotate_object_local(Vector3.RIGHT, -PI / 2.0)
	var distance: float = muzzle_world.distance_to(to_pos)
	if distance < 0.2:
		mesh.queue_free()
		return
	var travel_time: float = clampf(distance / BULLET_SPEED, 0.02, 0.35)
	var tween: Tween = mesh.create_tween()
	# .from(muzzle_world) pins the start value — without it Godot 4.3 does a
	# lazy re-sample of global_position on the tween's first active frame,
	# which can read a stale/flushed value and make the tracer appear to
	# teleport to near-target before animating.
	tween.tween_property(mesh, "global_position", to_pos, travel_time) \
		.from(muzzle_world) \
		.set_trans(Tween.TRANS_LINEAR)
	tween.tween_callback(mesh.queue_free)
