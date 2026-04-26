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

var _remaining_life: float
var _ray: RayCast3D
## Body to ignore on the first frame (the firing vehicle). Set via [method setup]
## BEFORE add_child so _ready can apply the exception when constructing the ray.
var _shooter: CollisionObject3D = null


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


func _ready() -> void:
	_remaining_life = lifetime

	_ray = RayCast3D.new()
	add_child(_ray)
	# Cast slightly ahead each frame — length matches one frame of travel at max speed.
	# Using 1/30 s as a conservative frame floor so fast shells never tunnel.
	_ray.target_position = Vector3(0.0, 0.0, -(speed / 30.0))
	_ray.collision_mask = collision_mask
	_ray.enabled = true
	# Physics-level filter so the shell never hits the vehicle that fired it.
	if _shooter != null:
		_ray.add_exception(_shooter)


func _physics_process(delta: float) -> void:
	# Check collision BEFORE moving so the ray sweeps the path we are about to cover.
	if _ray.is_colliding():
		var collider: Node = _ray.get_collider() as Node
		_apply_damage_if_health(collider)
		_spawn_impact(_ray.get_collision_point(), _ray.get_collision_normal())
		queue_free()
		return

	translate(Vector3(0.0, 0.0, -speed * delta))
	_remaining_life -= delta
	if _remaining_life <= 0.0:
		queue_free()


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

	var impact: Node3D = impact_scene.instantiate() as Node3D
	if impact == null:
		push_error("TankShell: impact_scene did not instantiate as Node3D")
		return

	# Place in world space via the scene root so the VFX is not parented to the
	# shell (which will queue_free immediately).
	var world_root: Node = get_tree().current_scene
	world_root.add_child(impact)
	impact.global_position = hit_point

	# Orient so impact local +Y aligns with the surface normal. Using
	# Quaternion(from, to) handles edge cases (parallel vectors) correctly,
	# unlike the manual cross-product approach which produces a degenerate
	# basis when hit_normal is parallel to FORWARD or RIGHT.
	if hit_normal.length_squared() > 0.001:
		impact.global_transform.basis = Basis(Quaternion(Vector3.UP, hit_normal.normalized()))


## Send an explosion shake event to every registered receiver (the player's
## CameraFeelController). Base trauma is picked per damage source so a tank
## shell shakes harder than a heli missile. Receivers apply distance falloff
## themselves — this just tells them "a big boom happened HERE, of THAT type".
func _broadcast_shake(hit_point: Vector3) -> void:
	var base_trauma: float = _base_trauma_for_source()
	if base_trauma <= 0.0:
		return
	for receiver: Node in get_tree().get_nodes_in_group("camera_shake_receivers"):
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
