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
##
## POOL WIRING:
##   Call PlayerFireVFX.set_pools(tracer_pool, flash_pool) once from
##   WeaponController._ready() AFTER prewarm() so the shared mesh/material
##   statics are populated before the pool receives them.
##   If pools are null or unset the system falls back to the old allocating
##   path with a push_warning — the game never silently breaks.

const _FLASH_TEXTURE_PATH: String = "res://assets/textures/muzzle_flash/ak_muzzle_flash.png"
const _TRACER_SHADER_PATH: String = "res://src/vfx/tracer_bullet.gdshader"

static var _flash_texture: Texture2D = null

## Shared resources — one CylinderMesh + one material reused across every
## tracer, saves 10+ heap allocations per second at sustained AR fire.
## Assignment to material_override shares by reference (Godot does not copy
## resources on set), so the material is effectively const-shared.
##
## Two fully independent tracer pipelines coexist so spawn CANNOT produce
## invisible geometry, regardless of shader availability:
##
##   1. Shader path (preferred, CS:GO-style beam): QuadMesh + ShaderMaterial
##      using tracer_bullet.gdshader. The shader screen-aligns the quad in
##      VIEW space: it projects the streak direction onto the screen plane
##      and places the quad perpendicular to that projection, so the beam
##      is visible from every camera angle (including streaks flying along
##      the camera forward axis — they correctly shrink to a dot).
##      Fragment stage draws a hot near-white core with a warm orange glow
##      halo via pow() falloff across the quad width.
##   2. Fallback: CylinderMesh + StandardMaterial3D (identical to the
##      pre-shader behaviour). Used if the shader file is missing or fails
##      to load. Worst case is the plain yellow emissive cylinder — bullets
##      always visible.
##
## Prior tracer attempts broke because:
##   - A solid cylinder + fresnel shader reads as a "rod", not a beam.
##   - A cylindrical-billboard quad (rotate around streak axis to face
##     camera) degenerates when streak ≈ camera_forward in third-person,
##     leaving the quad edge-on and invisible.
## The screen-aligned beam approach here solves both issues.
static var _tracer_mesh: CylinderMesh = null
static var _tracer_material: StandardMaterial3D = null
static var _tracer_quad_mesh: QuadMesh = null
static var _tracer_shader_material: ShaderMaterial = null
static var _tracer_shader_ready: bool = false

## Injected pool references. Set once via set_pools(). Null = fall back to
## the old allocating path.
static var _tracer_pool: TracerPool = null
static var _flash_pool: MuzzleFlashPool = null

## Cached PhysicsRayQueryParameters3D instance — reused every shot.
## Godot 4.3's intersect_ray() does NOT mutate the query object so this is safe.
static var _ray_query: PhysicsRayQueryParameters3D = null

## Reusable 1-element exclude array. Updating [0] per shot avoids rebuilding
## an Array[RID] allocation on every call.
static var _exclude_rids: Array[RID] = []
## Empty exclude array — cached so the no-shooter path doesn't allocate [] each shot.
static var _empty_rids: Array[RID] = []

## One-shot warning guards — emit once, then stay silent, to avoid log spam.
static var _warned_no_tracer_pool: bool = false
static var _warned_no_flash_pool: bool = false
static var _warned_no_ray_query: bool = false


static func _ensure_textures_loaded() -> void:
	if _flash_texture == null:
		_flash_texture = load(_FLASH_TEXTURE_PATH) as Texture2D
	if _tracer_mesh == null:
		var cyl: CylinderMesh = CylinderMesh.new()
		# 4.5cm radius — AK tracer readability pass, 3x the older thin streak.
		# Additive shader + emission
		# make it read brighter/thicker than the raw geometry, so the mesh
		# itself stays small. Prior radius 0.025 looked fat once the fresnel
		# rim and bloom kicked in.
		cyl.top_radius = 0.045
		cyl.bottom_radius = 0.045
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
	_ensure_shader_pipeline()


## Try once to build the shader material + QuadMesh pair. On any failure
## the fallback CylinderMesh + StandardMaterial3D path remains and tracers
## still render. The CS:GO-style screen-aligned beam is written for
## gl_compatibility (uses INV_VIEW_MATRIX, no Forward+ features), so the
## previous web skip-gate is gone — if the shader ever does fail to load on a
## particular renderer, the null-check below still kicks the fallback in.
static func _ensure_shader_pipeline() -> void:
	if _tracer_shader_ready:
		return
	if _tracer_shader_material != null or _tracer_quad_mesh != null:
		return  # already attempted; don't retry every shot
	if not ResourceLoader.exists(_TRACER_SHADER_PATH):
		push_warning("PlayerFireVFX: tracer shader missing at %s — using fallback material" % _TRACER_SHADER_PATH)
		return
	var shader: Shader = load(_TRACER_SHADER_PATH) as Shader
	if shader == null:
		push_warning("PlayerFireVFX: tracer shader failed to load — using fallback material")
		return
	# QuadMesh: default orientation is already FACE_Z (quad normal = +Z,
	# width +X, length +Y) — that's exactly what the shader expects, so
	# no explicit orientation assignment needed. size.y controls the streak
	# length in world units (0.8m, matching the fallback cylinder). size.x
	# is consumed by the shader as a normalized width coordinate in
	# VERTEX.x; the visual beam thickness is driven entirely by the
	# beam_width uniform, not by size.x.
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(1.0, 0.8)
	var shader_mat: ShaderMaterial = ShaderMaterial.new()
	shader_mat.shader = shader
	# CS:GO tuning (v4 — gaussian dual-layer):
	#   core_color:  pure white (1,1,1). Previous (1,0.98,0.90) looked off-white
	#                in isolation but yellow after the additive halo sum — fixed.
	#   halo_color:  warm orange, only visible where the tight core gaussian has
	#                decayed (cx > ~0.2). Replaces the old "glow_color" uniform.
	#   beam_width:  36mm world-space. Bloom from HDR emission (~45x) creates the
	#                perceived width; tuned 3x larger for AK bullet readability.
	#   emission:    45.0 — pushes cx=0 RGB to ~170, far past glow_hdr_threshold
	#                (0.9) so WorldEnvironment bloom fires on every frame.
	#   gaussian params: core_tightness=55 (narrow white peak), halo_tightness=5
	#                (wide orange skirt), core_strength=3.2 >> halo_strength=0.6
	#                so the center composite is white-dominant (~5:1 ratio).
	shader_mat.set_shader_parameter("core_color", Color(1.0, 1.0, 1.0, 1.0))
	shader_mat.set_shader_parameter("halo_color", Color(1.0, 0.55, 0.18, 1.0))
	shader_mat.set_shader_parameter("emission_strength", 45.0)
	shader_mat.set_shader_parameter("fade_edge", 0.18)
	shader_mat.set_shader_parameter("beam_width", 0.036)
	shader_mat.set_shader_parameter("core_tightness", 55.0)
	shader_mat.set_shader_parameter("halo_tightness", 5.0)
	shader_mat.set_shader_parameter("core_strength", 3.2)
	shader_mat.set_shader_parameter("halo_strength", 0.6)
	_tracer_quad_mesh = quad
	_tracer_shader_material = shader_mat
	_tracer_shader_ready = true


## Prewarm: call from Player._ready() so the first shot doesn't stall on
## shader + material pipeline compilation. Prewarms both material variants
## on the shared CylinderMesh so whichever one is picked at runtime is
## already compiled.
static func prewarm(world_root: Node) -> void:
	_ensure_textures_loaded()
	if world_root == null or _tracer_mesh == null:
		return
	# Fallback material (always present).
	if _tracer_material != null:
		var dummy_fallback: MeshInstance3D = MeshInstance3D.new()
		dummy_fallback.mesh = _tracer_mesh
		dummy_fallback.material_override = _tracer_material
		dummy_fallback.position = Vector3(-0.08, 0.0, 0.0)
		dummy_fallback.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		dummy_fallback.visible = true
		world_root.add_child(dummy_fallback)
		if dummy_fallback.is_inside_tree():
			dummy_fallback.get_tree().create_timer(0.25).timeout.connect(dummy_fallback.queue_free)
		else:
			dummy_fallback.queue_free()
	# Shader pipeline (only if it built successfully).
	if _tracer_shader_ready and _tracer_shader_material != null and _tracer_quad_mesh != null:
		var dummy_shader: MeshInstance3D = MeshInstance3D.new()
		dummy_shader.mesh = _tracer_quad_mesh
		dummy_shader.material_override = _tracer_shader_material
		dummy_shader.position = Vector3(0.08, 0.0, 0.0)
		dummy_shader.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		dummy_shader.visible = true
		world_root.add_child(dummy_shader)
		if dummy_shader.is_inside_tree():
			dummy_shader.get_tree().create_timer(0.25).timeout.connect(dummy_shader.queue_free)
		else:
			dummy_shader.queue_free()


## Wire pool references. Call once from WeaponController._ready(). This loads
## shared mesh/material statics if prewarm() did not already do it, then calls
## tracer_pool.setup() with those references here.
##
## [param tracer_pool]  TracerPool node living in the scene tree (child of Player).
## [param flash_pool]   MuzzleFlashPool node living under the muzzle node.
static func set_pools(tracer_pool: TracerPool, flash_pool: MuzzleFlashPool) -> void:
	_ensure_textures_loaded()
	_tracer_pool = tracer_pool
	_flash_pool = flash_pool

	# Push shared resources into the tracer pool now that textures are loaded.
	if tracer_pool != null:
		tracer_pool.setup(
			_tracer_quad_mesh,
			_tracer_shader_material,
			_tracer_mesh,
			_tracer_material,
			_tracer_shader_ready,
		)

	# Push flash texture into flash pool.
	if flash_pool != null and _flash_texture != null:
		flash_pool.setup(_flash_texture)

	# Build the cached ray query object and exclude array (one-time).
	if _ray_query == null:
		_ray_query = PhysicsRayQueryParameters3D.new()
		_exclude_rids.resize(1)


## Fires one AR round: hitscan, muzzle flash (parented to muzzle node so it
## never lags when the player spins), and a travelling tracer.
##
## [param aim_origin] / [param aim_dir] come from the PLAYER'S CAMERA —
## raycast is camera-space so crosshair accuracy matches what the player sees.
## [param muzzle_node] is the AK muzzle Node3D. Flash is parented to it so it
## inherits the rifle's transform each frame (no lag on quick turns). Tracer
## reads its world position at spawn then flies world-space from there.
##
## PUBLIC API — signature is fixed. Callers (WeaponController, etc.) must not
## be updated when pool internals change.
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

	# 1. Hitscan from camera — reuse cached query + exclude array.
	var space: PhysicsDirectSpaceState3D = world_root.get_world_3d().direct_space_state
	var to_point: Vector3 = aim_origin + aim_dir.normalized() * max_range

	var hit: Dictionary = {}
	if _ray_query != null:
		# Reuse the cached query; only mutate the fields that change per shot.
		_ray_query.from = aim_origin
		_ray_query.to = to_point
		if shooter != null:
			_exclude_rids[0] = shooter.get_rid()
			_ray_query.exclude = _exclude_rids
		else:
			_ray_query.exclude = _empty_rids
		hit = space.intersect_ray(_ray_query)
	else:
		# Pool not wired yet — fall back to allocating path with one-time warning.
		if not _warned_no_ray_query:
			_warned_no_ray_query = true
			push_warning("PlayerFireVFX: _ray_query not initialised (call set_pools first) — falling back to per-shot allocation")
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(aim_origin, to_point)
		if shooter != null:
			query.exclude = [shooter.get_rid()]
		hit = space.intersect_ray(query)

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


## Visual-only AR shot — same flash + tracer as `spawn_ar_shot`, but skips
## damage. Used by remote player avatars to render a peer's shot (server is
## authoritative for damage; we just paint pixels).
##
## [param shooter_body] is excluded from the tracer-end raycast so the beam
## doesn't immediately collide with the firing peer's own collision capsule
## (the muzzle bone sits 0.5 m forward of the ak47 attachment, often well
## inside the body's 0.45 m capsule radius).
##
## We deliberately bypass the muzzle-flash pool here: the pool is parented
## under the LOCAL player's muzzle, so reusing it for a remote shot would
## render the flash at the wrong character. Allocating a per-shot Sprite3D
## under the remote muzzle is cheap (one shot per peer per ~100 ms cap).
## Tracer pool is fine because its `spawn()` takes explicit world positions.
##
## [param aim_origin] Camera-equivalent origin from the network packet.
## [param aim_dir]    Direction sent by the shooter; tracer flies along it.
## [param max_range]  Distance to draw the tracer if no hit point is known.
static func spawn_ar_visuals(
	world_root: Node,
	muzzle_node: Node3D,
	aim_origin: Vector3,
	aim_dir: Vector3,
	max_range: float = 100.0,
	shooter_body: CollisionObject3D = null
) -> void:
	if muzzle_node == null or not is_instance_valid(muzzle_node):
		return
	_ensure_textures_loaded()
	_spawn_muzzle_flash_at_node(muzzle_node)
	var muzzle_world: Vector3 = muzzle_node.global_transform.origin
	var to_point: Vector3 = _remote_tracer_end(muzzle_world, aim_origin, aim_dir, max_range)
	_spawn_remote_tracer_alloc(world_root, muzzle_world, to_point, shooter_body)


## Visual-only AR shot for cases where the remote avatar's muzzle node is not
## available yet. Keeps the local shooting path untouched.
static func spawn_ar_visuals_from_world(
	world_root: Node,
	muzzle_world: Vector3,
	aim_origin: Vector3,
	aim_dir: Vector3,
	max_range: float = 100.0,
	shooter_body: CollisionObject3D = null
) -> void:
	_ensure_textures_loaded()
	_spawn_muzzle_flash_at_world(world_root, muzzle_world)
	var to_point: Vector3 = _remote_tracer_end(muzzle_world, aim_origin, aim_dir, max_range)
	_spawn_remote_tracer_alloc(world_root, muzzle_world, to_point, shooter_body)


static func _remote_tracer_end(muzzle_world: Vector3, aim_origin: Vector3, aim_dir: Vector3, max_range: float) -> Vector3:
	var dir: Vector3 = aim_dir
	if dir.length_squared() < 0.0001:
		dir = Vector3.FORWARD
	dir = dir.normalized()
	var to_point: Vector3 = aim_origin + dir * max_range
	if muzzle_world.distance_squared_to(to_point) < 0.04:
		to_point = muzzle_world + dir * max_range
	return to_point


## Pool-bypassed tracer for remote-shot VFX. Always allocates a fresh mesh +
## Tween under [param world_root] so it's free of any local-side pool state.
##
## The end point is clipped against world geometry via a raycast so an aim
## that points into the floor produces a 1m tracer instead of a 100m one
## that buries itself before anyone could see it.
static func _spawn_remote_tracer_alloc(world_root: Node, from_pos: Vector3, to_pos: Vector3, shooter_body: CollisionObject3D = null) -> void:
	if world_root == null or not is_instance_valid(world_root):
		return
	# Clip the tracer end against world collision so floor-aimed shots stay
	# visible above the ground. Exclude the shooter's own body so we don't
	# clip immediately against the player's collision capsule.
	var clipped_to: Vector3 = _raycast_tracer_end(world_root, from_pos, to_pos, shooter_body)
	var distance: float = from_pos.distance_to(clipped_to)
	if distance < 0.5:
		# Too short to be readable — extend along the original aim so the
		# cylinder still flies a visible arc instead of degenerating.
		var dir: Vector3 = (to_pos - from_pos).normalized()
		clipped_to = from_pos + dir * 5.0
		distance = 5.0
	var mesh: MeshInstance3D = MeshInstance3D.new()
	mesh.mesh = _tracer_mesh
	mesh.material_override = _tracer_material
	world_root.add_child(mesh)
	mesh.global_position = from_pos
	var up_ref: Vector3 = Vector3.UP
	var forward: Vector3 = (clipped_to - from_pos).normalized()
	if absf(forward.dot(Vector3.UP)) > 0.99:
		up_ref = Vector3.FORWARD
	mesh.look_at(clipped_to, up_ref)
	# CylinderMesh's length is along local +Y; rotate -90° around X so the
	# cylinder runs along -Z (the look_at forward direction).
	mesh.rotate_object_local(Vector3.RIGHT, -PI / 2.0)
	const BULLET_SPEED: float = 80.0
	# Floor at 0.15 s so the tracer is unmistakably moving — anything shorter
	# reads as a static flash and got reported as "stuck in place" tracers.
	var travel_time: float = clampf(distance / BULLET_SPEED, 0.15, 0.35)
	var tween: Tween = mesh.create_tween()
	tween.tween_property(mesh, "global_position", clipped_to, travel_time) \
		.from(from_pos) \
		.set_trans(Tween.TRANS_LINEAR)
	tween.tween_callback(mesh.queue_free)


## Returns the first world-collision hit between `from_pos` and `to_pos`,
## or `to_pos` (clamped to 30 m) if nothing was hit. The shooter's body is
## excluded so the muzzle bone (which sits inside the player capsule) can't
## clip the ray to ~0 m and produce a stuck "frozen at muzzle" tracer.
static func _raycast_tracer_end(world_root: Node, from_pos: Vector3, to_pos: Vector3, shooter_body: CollisionObject3D = null) -> Vector3:
	var node3d: Node3D = world_root as Node3D
	if node3d == null:
		return _clamp_tracer_far(from_pos, to_pos)
	var world: World3D = node3d.get_world_3d()
	if world == null:
		return _clamp_tracer_far(from_pos, to_pos)
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null:
		return _clamp_tracer_far(from_pos, to_pos)
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from_pos, to_pos)
	if shooter_body != null and is_instance_valid(shooter_body):
		query.exclude = [shooter_body.get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	if not hit.is_empty():
		return hit.get("position", to_pos)
	return _clamp_tracer_far(from_pos, to_pos)


## Cap the tracer at 30 m when no collision was hit — visually punchy and
## avoids the sub-floor stub the original 100 m extrapolation produced.
static func _clamp_tracer_far(from_pos: Vector3, to_pos: Vector3) -> Vector3:
	const MAX_VISIBLE: float = 30.0
	var dist: float = from_pos.distance_to(to_pos)
	if dist <= MAX_VISIBLE:
		return to_pos
	var dir: Vector3 = (to_pos - from_pos).normalized()
	return from_pos + dir * MAX_VISIBLE


static func _spawn_muzzle_flash_at_world(world_root: Node, world_pos: Vector3) -> void:
	var parent: Node3D = world_root as Node3D
	if parent == null or not is_instance_valid(parent) or _flash_texture == null:
		return
	var sprite: Sprite3D = Sprite3D.new()
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.shaded = false
	sprite.pixel_size = 0.00028
	sprite.texture = _flash_texture
	sprite.rotation.z = randf() * TAU
	parent.add_child(sprite)
	sprite.global_position = world_pos
	if parent.is_inside_tree():
		var done_t: SceneTreeTimer = parent.get_tree().create_timer(0.05)
		done_t.timeout.connect(sprite.queue_free)
	else:
		sprite.queue_free()


## Pool-bypassed muzzle flash spawn — always allocates a fresh Sprite3D as a
## child of [param parent]. Used for remote-player shots where the flash must
## appear at the remote muzzle, not at the local pool's prewarmed position.
static func _spawn_muzzle_flash_at_node(parent: Node3D) -> void:
	if parent == null or not is_instance_valid(parent) or _flash_texture == null:
		return
	var sprite: Sprite3D = Sprite3D.new()
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.shaded = false
	sprite.pixel_size = 0.00028
	sprite.texture = _flash_texture
	sprite.rotation.z = randf() * TAU
	parent.add_child(sprite)
	sprite.position = Vector3.ZERO
	if parent.is_inside_tree():
		var done_t: SceneTreeTimer = parent.get_tree().create_timer(0.05)
		done_t.timeout.connect(sprite.queue_free)
	else:
		sprite.queue_free()


## Spawn flash. Routes through pool if available; allocates otherwise.
## Muzzle-parenting guarantee is maintained by both paths:
##   - Pool path: MuzzleFlashPool lives as a child of the muzzle node, so all
##     its sprites are already in the muzzle's subtree — no reparenting needed.
##   - Fallback path: allocates a Sprite3D and adds it to muzzle_node directly.
static func _spawn_muzzle_flash(parent: Node3D) -> void:
	if parent == null:
		return

	# Pool path — preferred.
	if _flash_pool != null and is_instance_valid(_flash_pool):
		_flash_pool.activate_flash()
		return

	# Fallback allocating path (pool not wired). Warn once to avoid log spam.
	if not _warned_no_flash_pool:
		_warned_no_flash_pool = true
		push_warning("PlayerFireVFX: flash pool not set — falling back to per-shot Sprite3D allocation. Call set_pools() from WeaponController._ready().")
	if _flash_texture == null:
		return
	var sprite: Sprite3D = Sprite3D.new()
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.shaded = false
	sprite.pixel_size = 0.00028
	sprite.texture = _flash_texture
	sprite.rotation.z = randf() * TAU
	parent.add_child(sprite)
	sprite.position = Vector3.ZERO
	if parent.is_inside_tree():
		var done_t: SceneTreeTimer = parent.get_tree().create_timer(0.05)
		done_t.timeout.connect(sprite.queue_free)
	else:
		sprite.queue_free()


## Spawn a thin round glowing tracer that travels from muzzle to hit point.
## Routes through TracerPool if available; allocates a one-shot Tween otherwise.
## Cylinder center is placed AT the muzzle. Front half (0.4m) extends out of
## the barrel — visible streak. Rear half is inside the rifle mesh — hidden
## by the gun geometry, so the player sees the tracer appear to exit the muzzle.
static func _spawn_tracer(world_root: Node, muzzle_node: Node3D, to_pos: Vector3, aim_dir: Vector3) -> void:
	if muzzle_node == null or not is_instance_valid(muzzle_node):
		return

	var muzzle_world: Vector3 = muzzle_node.global_transform.origin

	# Pool path — preferred.
	if _tracer_pool != null and is_instance_valid(_tracer_pool):
		_tracer_pool.spawn(muzzle_world, to_pos, _tracer_shader_ready)
		return

	# Fallback allocating path (pool not wired). Warn once to avoid log spam.
	if not _warned_no_tracer_pool:
		_warned_no_tracer_pool = true
		push_warning("PlayerFireVFX: tracer pool not set — falling back to per-shot MeshInstance3D+Tween allocation. Call set_pools() from WeaponController._ready().")
	# 80 m/s is arcade-readable — real bullet at 700+ m/s would be invisible
	# on a 60fps screen for any gameplay-range shot. Travel time caps at
	# ~0.35s so long shots still arrive quickly.
	const BULLET_SPEED: float = 80.0
	var forward: Vector3 = aim_dir.normalized()
	var mesh: MeshInstance3D = MeshInstance3D.new()
	if _tracer_shader_ready and _tracer_quad_mesh != null and _tracer_shader_material != null:
		mesh.mesh = _tracer_quad_mesh
		mesh.material_override = _tracer_shader_material
	else:
		mesh.mesh = _tracer_mesh
		mesh.material_override = _tracer_material
	world_root.add_child(mesh)
	mesh.global_position = muzzle_world
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
