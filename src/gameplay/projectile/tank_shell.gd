class_name TankShell
extends Node3D

## Forward-moving raycast projectile. Used by both tank shells and helicopter
## missiles — the firer calls [method setup] to specify damage source/amount
## and to add a self-hit exception to the internal RayCast3D.
## On collision: applies damage to a HealthComponent if present, spawns impact
## VFX, and frees itself.
##
## Implements: design/gdd/combat/tank_shell.md

@export var speed: float = 60.0
@export var lifetime: float = 3.0

## PackedScene for the shell impact VFX.
@export var impact_scene: PackedScene = preload("res://scenes/projectile/shell_impact.tscn")

## Collision mask controlling which physics layers this shell tests against.
## Default layer 1 = world/terrain, layer 2 = vehicles. Adjust per-project.
@export_flags_3d_physics var collision_mask: int = 0b11

## Damage dealt to a HealthComponent on hit. Set via [method setup] by the firer.
@export var damage: int = 100
## Identifies the firing weapon for VFX/scoring branches.
@export var damage_source: int = DamageTypes.Source.TANK_SHELL
## When non-empty AND running networked, the shell sends a vehicle_hit_claim
## packet to the server on impact (server applies authoritative damage).
## When empty, the shell behaves like a solo-mode projectile and damages the
## HealthComponent locally. Set via [method setup_network] by vehicle controllers.
@export var network_projectile_id: String = ""
## When false, skip the local take_damage call — used together with
## network_projectile_id so we don't double-apply damage on top of the server.
@export var apply_local_damage: bool = true
## Splash / area-of-effect radius (m). When > 0, on impact the shell sphere-
## queries every CollisionObject3D within this radius and applies damage to
## any HealthComponent it finds. 0 = single-target (raycast direct hit only).
## Why: a raw raycast strike requires hitting the target dead-on; AOE makes
## the RPG / shell feel like an explosion instead of a sniper bullet.
@export var aoe_radius: float = 0.0

var _remaining_life: float
var _ray: RayCast3D
## Body to ignore on the first frame (the firing vehicle). Set via [method setup]
## BEFORE add_child so _ready can apply the exception when constructing the ray.
var _shooter: CollisionObject3D = null
var _pool_owner: Node = null
var _pool_active: bool = true
var _base_lifetime: float = 0.0
var _core_mesh: MeshInstance3D = null
var _core_default_mesh: Mesh = null
var _core_default_transform: Transform3D
var _core_default_scale: Vector3 = Vector3.ONE
var _core_default_material: Material = null
var _warmup_skip_particles: bool = false


## Configure damage source/amount and the firing vehicle to ignore for self-hit.
## MUST be called BEFORE add_child so _ready picks up the values when wiring
## the RayCast3D exception.
func setup(source: int, dmg: int, shooter: CollisionObject3D) -> void:
	damage_source = source
	damage = dmg
	_shooter = shooter


## Configure network-authoritative mode: shell sends a hit-claim packet on
## impact and skips local HP mutation. Used by vehicle controllers (tank,
## heli) so server is authoritative for damage. Must be called before
## add_child.
func setup_network(projectile_id: String, apply_local: bool = false) -> void:
	network_projectile_id = projectile_id
	apply_local_damage = apply_local


func set_pool_owner(pool_owner: Node) -> void:
	_pool_owner = pool_owner


func is_pool_idle() -> bool:
	return _pool_owner != null and not _pool_active


func set_warmup_skip_particles(disabled: bool) -> void:
	_warmup_skip_particles = disabled
	if disabled:
		_set_particle_emitters(false)


func activate_from_pool(
	source: int,
	dmg: int,
	shooter: CollisionObject3D,
	projectile_id: String,
	apply_local: bool,
	origin: Vector3,
	aim_dir: Vector3,
	lifetime_override: float = -1.0
) -> void:
	_pool_active = true
	_warmup_skip_particles = false
	visible = true
	setup(source, dmg, shooter)
	setup_network(projectile_id, apply_local)
	lifetime = lifetime_override if lifetime_override > 0.0 else _base_lifetime
	_remaining_life = lifetime
	_reset_core_visual()
	global_position = origin
	var dir: Vector3 = aim_dir.normalized()
	if dir.length_squared() < 0.0001:
		dir = Vector3.FORWARD
	var up_ref: Vector3 = Vector3.UP
	if absf(dir.dot(Vector3.UP)) > 0.95:
		up_ref = Vector3.FORWARD
	look_at(origin + dir, up_ref)
	_ensure_ray()
	_configure_ray()
	_restart_particle_emitters()
	set_physics_process(true)


func deactivate_for_pool() -> void:
	_pool_active = false
	visible = false
	_remaining_life = 0.0
	_shooter = null
	network_projectile_id = ""
	apply_local_damage = true
	lifetime = _base_lifetime if _base_lifetime > 0.0 else lifetime
	_reset_core_visual()
	if _ray != null and is_instance_valid(_ray):
		_ray.enabled = false
		_ray.clear_exceptions()
	_set_particle_emitters(false)
	set_physics_process(false)


func set_lifetime_remaining(seconds: float) -> void:
	lifetime = maxf(seconds, 0.01)
	_remaining_life = lifetime


func _ready() -> void:
	_base_lifetime = lifetime
	_remaining_life = lifetime

	_cache_core_visual()
	_ensure_ray()
	_configure_ray()
	# Cast slightly ahead each frame — length matches one frame of travel at max speed.
	# Using 1/30 s as a conservative frame floor so fast shells never tunnel.
	if _pool_owner != null:
		deactivate_for_pool()
	elif not _warmup_skip_particles:
		_restart_particle_emitters()
	# Physics-level filter so the shell never hits the vehicle that fired it.


func _physics_process(delta: float) -> void:
	if _pool_owner != null and not _pool_active:
		return
	# Check collision BEFORE moving so the ray sweeps the path we are about to cover.
	if _ray.is_colliding():
		var collider: Node = _ray.get_collider() as Node
		var hit_point: Vector3 = _ray.get_collision_point()
		_apply_damage_if_health(collider)
		if aoe_radius > 0.0:
			_apply_aoe_damage(hit_point, collider)
		_spawn_impact(hit_point, _ray.get_collision_normal())
		_finish_projectile()
		return

	translate(Vector3(0.0, 0.0, -speed * delta))
	_remaining_life -= delta
	if _remaining_life <= 0.0:
		_finish_projectile()


func _ensure_ray() -> void:
	if _ray != null and is_instance_valid(_ray):
		return
	_ray = get_node_or_null("ProjectileRay") as RayCast3D
	if _ray == null:
		_ray = RayCast3D.new()
		_ray.name = "ProjectileRay"
		add_child(_ray)


func _configure_ray() -> void:
	if _ray == null:
		return
	# Cast slightly ahead each frame - length matches one frame of travel at max speed.
	# Using 1/30 s as a conservative frame floor so fast shells never tunnel.
	_ray.target_position = Vector3(0.0, 0.0, -(speed / 30.0))
	_ray.collision_mask = collision_mask
	_ray.clear_exceptions()
	_ray.enabled = _pool_owner == null or _pool_active
	# Physics-level filter so the shell never hits the vehicle that fired it.
	if _shooter != null and is_instance_valid(_shooter):
		_ray.add_exception(_shooter)


func _finish_projectile() -> void:
	if _pool_owner != null and is_instance_valid(_pool_owner) and _pool_owner.has_method("release_projectile"):
		_pool_owner.call("release_projectile", self)
		return
	queue_free()


func _cache_core_visual() -> void:
	_core_mesh = get_node_or_null("CoreMesh") as MeshInstance3D
	if _core_mesh == null:
		return
	_core_default_mesh = _core_mesh.mesh
	_core_default_transform = _core_mesh.transform
	_core_default_scale = _core_mesh.scale
	_core_default_material = _core_mesh.material_override


func _reset_core_visual() -> void:
	if _core_mesh == null or not is_instance_valid(_core_mesh):
		return
	_core_mesh.mesh = _core_default_mesh
	_core_mesh.transform = _core_default_transform
	_core_mesh.scale = _core_default_scale
	_core_mesh.material_override = _core_default_material


func _restart_particle_emitters() -> void:
	if _warmup_skip_particles:
		return
	_set_particle_emitters(false)
	_set_particle_emitters(true)


func _set_particle_emitters(is_emitting: bool) -> void:
	_set_particle_emitters_recursive(self, is_emitting)


func _set_particle_emitters_recursive(root: Node, is_emitting: bool) -> void:
	for child: Node in root.get_children():
		if child is GPUParticles3D:
			var gpu: GPUParticles3D = child as GPUParticles3D
			gpu.visible = true
			gpu.emitting = is_emitting
			if is_emitting:
				gpu.visible = true
				gpu.restart()
		elif child is CPUParticles3D:
			var cpu: CPUParticles3D = child as CPUParticles3D
			cpu.visible = true
			cpu.emitting = is_emitting
			if is_emitting:
				cpu.visible = true
				cpu.restart()
		_set_particle_emitters_recursive(child, is_emitting)


func _apply_damage_if_health(collider: Node) -> void:
	if collider == null:
		return
	# Network-authoritative path: tell the server about the hit and let it
	# decide who took how much damage. Skip local HP mutation entirely so we
	# don't double-apply on top of the server's `damage` broadcast.
	if network_projectile_id != "" and _is_networked():
		_send_hit_claim(collider)
		return
	if not apply_local_damage:
		return
	var health: HealthComponent = collider.get_node_or_null("HealthComponent") as HealthComponent
	if health != null:
		health.take_damage(damage, damage_source)


## Splash damage at the impact point. Sphere-queries every CollisionObject3D
## within [member aoe_radius] and applies the same damage to any
## HealthComponent it finds (or, in networked play, sends a hit_claim per
## target). Skips [param primary_collider] (already damaged by the raycast).
func _apply_aoe_damage(impact_point: Vector3, primary_collider: Node) -> void:
	var world: World3D = get_world_3d()
	if world == null:
		return
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null:
		return
	var sphere: SphereShape3D = SphereShape3D.new()
	sphere.radius = aoe_radius
	var query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, impact_point)
	query.collide_with_areas = false
	query.collision_mask = collision_mask
	if _shooter != null and is_instance_valid(_shooter):
		query.exclude = [_shooter.get_rid()]
	var results: Array = space.intersect_shape(query, 32)
	var seen: Dictionary = {}
	var primary_id: int = primary_collider.get_instance_id() if primary_collider != null else 0
	for hit: Dictionary in results:
		var collider: Node = hit.get("collider", null) as Node
		if collider == null:
			continue
		var instance_id: int = collider.get_instance_id()
		if instance_id == primary_id:
			continue
		if seen.has(instance_id):
			continue
		seen[instance_id] = true
		_apply_damage_if_health(collider)


func _is_networked() -> bool:
	var nm: Node = get_node_or_null("/root/NetworkManager")
	if nm == null:
		return false
	if not nm.has_method("is_online"):
		return false
	return bool(nm.call("is_online"))


## Walk the collider hierarchy to find a target identifier the server knows
## about. Returns either a peer_id (for player Bodies) or a vehicle_id (for
## tank/helicopter/drone roots), or null if neither matched.
func _resolve_target(collider: Node) -> Dictionary:
	var node: Node = collider
	while node != null:
		# Vehicles in Main.tscn are named "Tank" / "Helicopter" / "Drone".
		var lower: String = node.name.to_lower()
		if lower == "tank" or lower == "helicopter" or lower == "drone":
			return {"vehicle_id": lower}
		# Local player root has a NetworkPlayerSync that knows our peer_id.
		var sync: Node = node.get_node_or_null("NetworkPlayerSync")
		if sync == null:
			# Some scenes parent the sync above the body — also check parent.
			sync = node.get_parent().get_node_or_null("NetworkPlayerSync") if node.get_parent() != null else null
		if sync != null:
			var nm = get_node_or_null("/root/NetworkManager")
			if nm != null:
				return {"peer_id": int(nm.local_peer_id)}
		# Remote player avatars store peer_id directly.
		if "peer_id" in node:
			var pid: int = int(node.get("peer_id"))
			if pid > 0:
				return {"peer_id": pid}
		node = node.get_parent()
	return {}


func _send_hit_claim(collider: Node) -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if nm == null:
		return
	var target: Dictionary = _resolve_target(collider)
	if target.is_empty():
		return  # hit terrain or unknown — no claim needed
	var msg: Dictionary = {
		"t": "vehicle_hit_claim",
		"projectile": network_projectile_id,
		"client_t": Time.get_ticks_msec(),
	}
	if target.has("peer_id"):
		msg["target_peer_id"] = target["peer_id"]
	if target.has("vehicle_id"):
		msg["target_vehicle_id"] = target["vehicle_id"]
	# Identify the firing vehicle (tank/heli) so server validates driver.
	# Drones don't fire shells — drone kamikaze sends its own claim path.
	if _shooter != null:
		var shooter_name: String = _shooter.name.to_lower()
		if shooter_name == "tank" or shooter_name == "helicopter":
			msg["vehicle_id"] = shooter_name
	if nm.has_method("send_message"):
		nm.call("send_message", msg)


func _spawn_impact(hit_point: Vector3, hit_normal: Vector3) -> void:
	# Broadcast explosion shake BEFORE spawning the impact VFX — shake kicks in
	# simultaneously with the visual/audio cue for maximum punch. Receivers
	# (CameraFeelController) are in the "camera_shake_receivers" group.
	_broadcast_shake(hit_point)

	if impact_scene == null:
		return

	var hub: Node = _find_combat_pool_hub()
	if hub != null and hub.has_method("spawn_impact"):
		if hub.call("spawn_impact", hit_point, hit_normal, impact_scene) != null:
			return

	var impact: Node3D = impact_scene.instantiate() as Node3D
	if impact == null:
		push_error("TankShell: impact_scene did not instantiate as Node3D")
		return

	# Place in world space via the scene root so the VFX is not parented to the
	# shell (which will queue_free immediately).
	if not is_inside_tree():
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var world_root: Node = tree.current_scene
	if world_root == null:
		return
	world_root.add_child(impact)
	impact.global_position = hit_point

	# Orient so impact local +Y aligns with the surface normal. Using
	# Quaternion(from, to) handles edge cases (parallel vectors) correctly,
	# unlike the manual cross-product approach which produces a degenerate
	# basis when hit_normal is parallel to FORWARD or RIGHT.
	if hit_normal.length_squared() > 0.001:
		impact.global_transform.basis = Basis(Quaternion(Vector3.UP, hit_normal.normalized()))


func _find_combat_pool_hub() -> Node:
	if not is_inside_tree():
		return null
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	for node: Node in tree.get_nodes_in_group(&"combat_pool_hub"):
		if node != null and is_instance_valid(node) and node.has_method("spawn_impact"):
			return node
	return null


## Send an explosion shake event to every registered receiver (the player's
## CameraFeelController). Base trauma is picked per damage source so a tank
## shell shakes harder than a heli missile. Receivers apply distance falloff
## themselves — this just tells them "a big boom happened HERE, of THAT type".
func _broadcast_shake(hit_point: Vector3) -> void:
	var base_trauma: float = _base_trauma_for_source()
	if base_trauma <= 0.0:
		return
	if not is_inside_tree():
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	for receiver: Node in tree.get_nodes_in_group("camera_shake_receivers"):
		if receiver.has_method("add_explosion_shake"):
			receiver.call("add_explosion_shake", hit_point, base_trauma)


## Peak trauma at point-blank per damage source. Tank shell (big HE round)
## hits hardest; heli missile is a smaller warhead; RPG sits in between.
## Non-projectile sources or anything not explicitly mapped returns 0 so
## stray damage paths (e.g. future kamikaze damage) don't shake the screen
## until deliberately configured.
func _base_trauma_for_source() -> float:
	match damage_source:
		DamageTypes.Source.TANK_SHELL:
			return 1.0
		DamageTypes.Source.PLAYER_RPG:
			return 0.9
		DamageTypes.Source.HELI_MISSILE:
			return 0.7
		_:
			return 0.0
