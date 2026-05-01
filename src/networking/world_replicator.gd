class_name WorldReplicator
extends Node3D

## Listens to NetworkManager and mirrors the server's view of the world into
## the local scene by spawning / updating / despawning RemotePlayer avatars
## (one per non-local peer). Routes per-peer events (damage, death, respawn,
## anim_event) to the matching avatar.
##
## Implements: docs/architecture/adr-0005-node-authoritative-server.md

const REMOTE_PLAYER_SCENE: PackedScene = preload("res://scenes/player/remote_player.tscn")
const RPG_ROCKET_SCENE: PackedScene = preload("res://scenes/projectile/rpg_rocket.tscn")

# Bone paths inside the remote player's skeleton — match the local player.
const _AK_MUZZLE_PATH: String = "Body/Visual/Player/Skeleton3D/ak47/Muzzle"
const _RPG_MUZZLE_PATH: String = "Body/Visual/Player/Skeleton3D/rocketbullet"
const _REMOTE_FIRE_QUEUE_TTL_MSEC: int = 500
const _REMOTE_FIRE_QUEUE_MAX_PER_PEER: int = 8

## When true, also spawn a remote-player avatar for the local peer (debug
## third-person view of own snapshot fidelity). Off in normal play.
@export var include_local_peer: bool = false

var _remote_players: Dictionary = {}  # peer_id (int) -> RemotePlayer Node3D
var _last_local_vehicle: String = ""  # tracks what we last reported to React
var _vehicle_alive: Dictionary = {}  # vehicle_id (String) -> bool
var _vehicle_vfx_started: Dictionary = {}  # vehicle_id (String) -> bool
var _network_smoke_anchors: Dictionary = {}  # vfx key (String) -> Node3D
var _pending_remote_fire_events: Dictionary = {}  # peer_id (int) -> Array[Dictionary]


func _ready() -> void:
	if not _network_manager_available():
		push_warning("[net] WorldReplicator: NetworkManager autoload missing")
		return
	NetworkManager.snapshot_received.connect(_on_snapshot)
	NetworkManager.player_left.connect(_on_player_left)
	NetworkManager.disconnected_from_server.connect(_clear_all)
	NetworkManager.damage_received.connect(_on_damage)
	NetworkManager.death_received.connect(_on_death)
	NetworkManager.respawn_received.connect(_on_respawn)
	NetworkManager.anim_event.connect(_on_anim_event)
	NetworkManager.vfx_event.connect(_on_vfx_event)


func _network_manager_available() -> bool:
	return get_node_or_null("/root/NetworkManager") != null


# ---------------------------------------------------------------------------
# Snapshot handling: spawn / update / despawn
# ---------------------------------------------------------------------------

func _on_snapshot(_tick: int, _server_t: int, players: Array, vehicles: Array) -> void:
	var seen: Dictionary = {}
	for raw in players:
		if not (raw is Dictionary):
			continue
		var p_dict: Dictionary = raw
		var pid: int = int(p_dict.get("id", -1))
		if pid < 0:
			continue
		if not include_local_peer and pid == NetworkManager.local_peer_id:
			continue
		seen[pid] = true
		var team: String = String(p_dict.get("team", ""))
		var display_name: String = String(p_dict.get("display_name", "Player%d" % pid))
		var pos: Vector3 = _vec3_from_array(p_dict.get("pos", null))
		var rot_y: float = float(p_dict.get("rot_y", 0.0))
		var hp: int = int(p_dict.get("hp", 100))
		var max_hp: int = int(p_dict.get("max_hp", 100))
		var alive: bool = bool(p_dict.get("alive", true))
		var weapon: String = String(p_dict.get("weapon", "ak"))
		var move_state: String = String(p_dict.get("move_state", "idle"))
		var rp: Node3D = _remote_players.get(pid)
		if rp == null or not is_instance_valid(rp):
			rp = _spawn(pid, team, display_name, pos, rot_y)
		if rp != null and rp.has_method("update_from_snapshot"):
			rp.call("update_from_snapshot", pos, rot_y, hp, max_hp, alive, weapon, move_state, display_name)
		if rp != null and is_instance_valid(rp):
			_flush_pending_remote_fire_events(pid)

	# Despawn anyone the server no longer reports.
	for pid_old: int in _remote_players.keys():
		if not seen.has(pid_old):
			_despawn(pid_old)

	_sync_vehicle_vfx(vehicles)
	_sync_local_vehicle_hud(vehicles)


## Tell the React HUD whether the local peer is driving a vehicle, and push
## its current HP each snapshot so the React HUD can paint a vehicle bar.
func _sync_local_vehicle_hud(vehicles: Array) -> void:
	if NetworkManager.local_peer_id < 0:
		return
	var driving: Dictionary = {}
	for raw in vehicles:
		if not (raw is Dictionary):
			continue
		var v: Dictionary = raw
		if int(v.get("driver_peer_id", -1)) != NetworkManager.local_peer_id:
			continue
		driving = v
		break
	if not has_node("/root/WebBridge"):
		return
	var bridge: Node = get_node("/root/WebBridge")
	if not bridge.has_method("send_event"):
		return
	if driving.is_empty():
		if _last_local_vehicle != "":
			bridge.send_event("vehicle_drive_end", {})
			_last_local_vehicle = ""
		return
	var vid: String = String(driving.get("id", ""))
	if vid != _last_local_vehicle:
		_last_local_vehicle = vid
		bridge.send_event("vehicle_drive_start", {"vehicle_id": vid})
	bridge.send_event("vehicle_hp", {
		"vehicle_id": vid,
		"hp": int(driving.get("hp", 0)),
		"max_hp": int(driving.get("max_hp", 100)),
		"alive": bool(driving.get("alive", true)),
	})


func _spawn(peer_id: int, team: String, display_name: String, pos: Vector3, rot_y: float) -> Node3D:
	var rp: Node3D = REMOTE_PLAYER_SCENE.instantiate()
	add_child(rp)
	if rp.has_method("setup"):
		rp.call("setup", peer_id, team, pos, rot_y, display_name)
	_remote_players[peer_id] = rp
	print("[net] spawned remote peer=%d name=%s team=%s at %s" % [peer_id, display_name, team, pos])
	return rp


func _despawn(peer_id: int) -> void:
	var rp: Node3D = _remote_players.get(peer_id)
	if rp != null and is_instance_valid(rp):
		rp.queue_free()
		print("[net] despawned remote peer=%d" % peer_id)
	_remote_players.erase(peer_id)


func _on_player_left(peer_id: int) -> void:
	_despawn(peer_id)


func _clear_all() -> void:
	for pid: int in _remote_players.keys():
		var rp: Node3D = _remote_players[pid]
		if is_instance_valid(rp):
			rp.queue_free()
	_remote_players.clear()
	for key: String in _network_smoke_anchors.keys():
		var anchor: Node3D = _network_smoke_anchors[key]
		if is_instance_valid(anchor):
			anchor.queue_free()
	_network_smoke_anchors.clear()
	_vehicle_alive.clear()
	_vehicle_vfx_started.clear()
	_pending_remote_fire_events.clear()


# ---------------------------------------------------------------------------
# Per-peer event routing
# ---------------------------------------------------------------------------

func _on_damage(payload: Dictionary) -> void:
	var victim_id: int = int(payload.get("victim", -1))
	if victim_id == NetworkManager.local_peer_id:
		return  # local player handled by NetworkPlayerSync
	var rp: Node3D = _remote_players.get(victim_id)
	if rp != null and rp.has_method("on_damage"):
		rp.call("on_damage", int(payload.get("amount", 0)), int(payload.get("new_hp", 0)))


func _on_death(payload: Dictionary) -> void:
	var victim_id: int = int(payload.get("victim", -1))
	if victim_id == NetworkManager.local_peer_id:
		return
	var rp: Node3D = _remote_players.get(victim_id)
	if rp != null and rp.has_method("on_death"):
		rp.call("on_death")


func _on_respawn(payload: Dictionary) -> void:
	var pid: int = int(payload.get("peer_id", -1))
	if pid == NetworkManager.local_peer_id:
		return
	var rp: Node3D = _remote_players.get(pid)
	if rp == null:
		return
	if rp.has_method("on_respawn"):
		var pos: Vector3 = _vec3_from_array(payload.get("pos", null))
		rp.call("on_respawn", pos)


func _on_vfx_event(payload: Dictionary) -> void:
	var kind: String = String(payload.get("kind", ""))
	match kind:
		"muzzle_flash":
			_handle_muzzle_flash(payload)
		"explosion":
			_spawn_network_explosion(payload)
		"smoke_fire_start":
			_start_network_smoke_fire(payload)
		"smoke_fire_stop":
			_stop_network_smoke_fire(payload)
		"vehicle_fire":
			_handle_vehicle_fire(payload)
		_:
			pass


func _handle_vehicle_fire(payload: Dictionary) -> void:
	var pid: int = int(payload.get("peer_id", -1))
	# Skip own — local controller already spawned the shell visually.
	if pid == NetworkManager.local_peer_id:
		return
	var origin: Vector3 = _vec3_from_array(payload.get("pos", null))
	var dir: Vector3 = _vec3_from_array(payload.get("dir", null))
	if dir.length_squared() < 0.0001:
		return
	var projectile: String = String(payload.get("projectile", "tank_shell"))
	# Both tank and heli currently reuse the tank_shell scene as the visual
	# missile (per existing code) — same scene path is fine for both.
	var scene_path: String = "res://scenes/projectile/tank_shell.tscn"
	if not ResourceLoader.exists(scene_path):
		return
	var scene: PackedScene = load(scene_path)
	var shell: Node3D = scene.instantiate() as Node3D
	if shell == null:
		return
	# Visual-only: damage 0; source picks the right screen-shake amplitude
	# (TANK_SHELL = strongest, HELI_MISSILE = milder).
	var src: int = DamageTypes.Source.TANK_SHELL if projectile == "tank_shell" else DamageTypes.Source.HELI_MISSILE
	if shell.has_method("setup"):
		shell.call("setup", src, 0, null)
	get_tree().current_scene.add_child(shell)
	shell.global_position = origin
	var up_ref: Vector3 = Vector3.UP
	if absf(dir.normalized().dot(Vector3.UP)) > 0.95:
		up_ref = Vector3.FORWARD
	shell.look_at(origin + dir.normalized(), up_ref)


func _handle_muzzle_flash(payload: Dictionary) -> void:
	var pid: int = int(payload.get("peer_id", -1))
	# Skip own muzzle flash — local weapon_controller already handled it.
	if pid == NetworkManager.local_peer_id:
		return
	var origin: Vector3 = _vec3_from_array(payload.get("pos", null))
	var dir: Vector3 = _vec3_from_array(payload.get("dir", null))
	if dir.length_squared() < 0.0001:
		return
	var weapon: String = String(payload.get("weapon", "ak"))
	var rp: Node3D = _remote_players.get(pid)
	if rp == null or not is_instance_valid(rp):
		_queue_remote_fire_event(pid, payload)
		return
	if weapon == "rpg":
		_spawn_remote_rpg_rocket(rp, dir)
	else:
		_spawn_remote_ar_visuals(rp, origin, dir)


func _queue_remote_fire_event(peer_id: int, payload: Dictionary) -> void:
	if peer_id < 0:
		return
	var queue: Array = _pending_remote_fire_events.get(peer_id, [])
	var copy: Dictionary = payload.duplicate(true)
	copy["_queued_msec"] = Time.get_ticks_msec()
	queue.append(copy)
	while queue.size() > _REMOTE_FIRE_QUEUE_MAX_PER_PEER:
		queue.pop_front()
	_pending_remote_fire_events[peer_id] = queue


func _flush_pending_remote_fire_events(peer_id: int) -> void:
	if not _pending_remote_fire_events.has(peer_id):
		return
	var rp: Node3D = _remote_players.get(peer_id)
	if rp == null or not is_instance_valid(rp):
		return
	var queue: Array = _pending_remote_fire_events.get(peer_id, [])
	_pending_remote_fire_events.erase(peer_id)
	var now_msec: int = Time.get_ticks_msec()
	for raw in queue:
		if not (raw is Dictionary):
			continue
		var payload: Dictionary = raw
		if now_msec - int(payload.get("_queued_msec", now_msec)) > _REMOTE_FIRE_QUEUE_TTL_MSEC:
			continue
		var dir: Vector3 = _vec3_from_array(payload.get("dir", null))
		if dir.length_squared() < 0.0001:
			continue
		var weapon: String = String(payload.get("weapon", "ak"))
		if weapon == "rpg":
			_spawn_remote_rpg_rocket(rp, dir)
		else:
			var origin: Vector3 = _vec3_from_array(payload.get("pos", null))
			_spawn_remote_ar_visuals(rp, origin, dir)


func _spawn_network_explosion(payload: Dictionary) -> void:
	var pos: Vector3 = Vector3.ZERO
	var vehicle_id: String = _payload_entity_id(payload)
	var target: Node3D = _vehicle_node_for_id(vehicle_id)
	if target != null:
		pos = target.global_position + Vector3(0.0, _vehicle_vfx_offset(vehicle_id), 0.0)
	elif _payload_has_vec3(payload, "pos"):
		pos = _vec3_from_array(payload.get("pos", null))
	else:
		return
	DestructionVFX.spawn_explosion(_scene_root(), pos, vehicle_id.to_lower() != "drone")


func _start_network_smoke_fire(payload: Dictionary) -> void:
	var vehicle_id: String = _payload_entity_id(payload)
	var target: Node3D = _vehicle_node_for_id(vehicle_id)
	if target != null:
		_start_vehicle_destroyed_vfx(vehicle_id, target)
		return

	if not _payload_has_vec3(payload, "pos"):
		return
	var key: String = _vfx_key(payload)
	_stop_network_smoke_by_key(key)

	var anchor: Node3D = Node3D.new()
	anchor.name = "NetworkSmokeFire_%s" % _safe_node_suffix(key)
	_scene_root().add_child(anchor)
	anchor.global_position = _vec3_from_array(payload.get("pos", null))
	_network_smoke_anchors[key] = anchor
	var duration: float = float(payload.get("duration", 0.0))
	DestructionVFX.spawn_smoke_fire(anchor, 0.0, true, duration)


func _stop_network_smoke_fire(payload: Dictionary) -> void:
	var vehicle_id: String = _payload_entity_id(payload)
	var target: Node3D = _vehicle_node_for_id(vehicle_id)
	if target != null:
		DestructionVFX.clear_vfx(target)
		_vehicle_vfx_started.erase(vehicle_id)
		return
	_stop_network_smoke_by_key(_vfx_key(payload))


func _spawn_remote_ar_visuals(rp: Node3D, origin: Vector3, dir: Vector3) -> void:
	var muzzle: Node3D = _get_or_create_remote_ak_muzzle(rp)
	var aim_origin: Vector3 = _fallback_remote_fire_origin(rp, origin)
	# Pass the remote shooter's Body so the tracer raycast doesn't clip
	# against the firer's own capsule (muzzle bone sits inside it).
	var body: CollisionObject3D = rp.get_node_or_null("Body") as CollisionObject3D
	# Use the same VFX pipeline the local weapon uses — flash + tracer share
	# the pre-warmed mesh/material statics in PlayerFireVFX.
	if muzzle != null:
		PlayerFireVFX.spawn_ar_visuals(_scene_root(), muzzle, aim_origin, dir, 100.0, body)
		return
	PlayerFireVFX.spawn_ar_visuals_from_world(_scene_root(), aim_origin, aim_origin, dir, 100.0, body)


func _get_or_create_remote_ak_muzzle(rp: Node3D) -> Node3D:
	var muzzle: Node3D = rp.get_node_or_null(_AK_MUZZLE_PATH) as Node3D
	if muzzle != null:
		return muzzle
	if rp.has_method("_ensure_ak_muzzle"):
		rp.call("_ensure_ak_muzzle")
		muzzle = rp.get_node_or_null(_AK_MUZZLE_PATH) as Node3D
		if muzzle != null:
			return muzzle
	var ak47: Node3D = rp.get_node_or_null("Body/Visual/Player/Skeleton3D/ak47") as Node3D
	if ak47 == null:
		return null
	muzzle = Node3D.new()
	muzzle.name = "Muzzle"
	muzzle.transform = Transform3D(Basis.IDENTITY, Vector3(0.5, 0.04, 0.0))
	ak47.add_child(muzzle)
	return muzzle


func _fallback_remote_fire_origin(rp: Node3D, packet_origin: Vector3) -> Vector3:
	if packet_origin.length_squared() > 0.0001:
		return packet_origin
	var body: Node3D = rp.get_node_or_null("Body") as Node3D
	if body != null:
		return body.global_position + Vector3(0.0, 1.4, 0.0)
	return rp.global_position + Vector3(0.0, 1.4, 0.0)


func _spawn_remote_rpg_rocket(rp: Node3D, dir: Vector3) -> void:
	if RPG_ROCKET_SCENE == null:
		return
	var muzzle: Node3D = rp.get_node_or_null(_RPG_MUZZLE_PATH) as Node3D
	var spawn_origin: Vector3 = muzzle.global_transform.origin if muzzle != null else rp.global_transform.origin + Vector3.UP
	var rocket: Node3D = RPG_ROCKET_SCENE.instantiate()
	if rocket == null:
		return
	# Visual-only: 0 damage so collisions don't apply HP changes (server is
	# authoritative). Pass the remote player's Body as `shooter` so the rocket
	# doesn't immediately blow up on the shooter's own collider. Source is
	# PLAYER_RPG so impact still triggers screen shake on nearby cameras.
	if rocket.has_method("setup"):
		var body: Node = rp.get_node_or_null("Body")
		rocket.call("setup", DamageTypes.Source.PLAYER_RPG, 0, body)
	get_tree().current_scene.add_child(rocket)
	rocket.global_position = spawn_origin
	rocket.look_at(spawn_origin + dir.normalized(), Vector3.UP)


func _sync_vehicle_vfx(vehicles: Array) -> void:
	for raw in vehicles:
		if not (raw is Dictionary):
			continue
		var v: Dictionary = raw
		var vehicle_id: String = String(v.get("id", ""))
		if vehicle_id == "":
			continue
		var alive: bool = bool(v.get("alive", true))
		var had_state: bool = _vehicle_alive.has(vehicle_id)
		var was_alive: bool = bool(_vehicle_alive.get(vehicle_id, true))
		_vehicle_alive[vehicle_id] = alive

		if alive:
			if had_state and not was_alive:
				var restored: Node3D = _vehicle_node_for_id(vehicle_id)
				if restored != null:
					_apply_network_vehicle_respawned(restored)
				_clear_vehicle_destroyed_vfx(vehicle_id)
			continue

		if had_state and not was_alive:
			continue

		var target: Node3D = _vehicle_node_for_id(vehicle_id)
		if target != null:
			_start_vehicle_destroyed_vfx(vehicle_id, target)
		elif _payload_has_vec3(v, "pos"):
			var pos: Vector3 = _vec3_from_array(v.get("pos", null))
			DestructionVFX.spawn_explosion(_scene_root(), pos, vehicle_id.to_lower() != "drone")
			_start_network_smoke_fire({
				"entity_id": vehicle_id,
				"pos": [pos.x, pos.y, pos.z],
			})


func _start_vehicle_destroyed_vfx(vehicle_id: String, vehicle: Node3D) -> void:
	if bool(_vehicle_vfx_started.get(vehicle_id, false)):
		return
	_vehicle_vfx_started[vehicle_id] = true

	var vehicle_key: String = vehicle_id.to_lower()
	var controller_handles_destroyed: bool = vehicle.has_method("apply_network_destroyed")
	_apply_network_vehicle_destroyed(vehicle)
	var already_has_vfx: bool = vehicle.get_node_or_null("_DestructionVFX") != null
	var is_drone: bool = vehicle_key == "drone"
	var is_helicopter: bool = vehicle_key.begins_with("helicopter") or vehicle_key == "heli"
	# Controller-owned destruction may already have spawned attached VFX.
	# A second generic charred pass would also hit those smoke MeshInstances,
	# turning their transparent cards into black quads. Drone/heli also have
	# transparent rotor cards that their controllers hide at the right moment.
	if controller_handles_destroyed and (already_has_vfx or is_drone or is_helicopter):
		return
	if not is_drone:
		DestructionVFX.apply_charred(vehicle)
	if not already_has_vfx:
		var y_offset: float = _vehicle_vfx_offset(vehicle_id)
		DestructionVFX.spawn_explosion(
			_scene_root(),
			vehicle.global_position + Vector3(0.0, y_offset, 0.0),
			not is_drone
		)
		DestructionVFX.spawn_smoke_fire(vehicle, y_offset)


func _clear_vehicle_destroyed_vfx(vehicle_id: String) -> void:
	var vehicle: Node3D = _vehicle_node_for_id(vehicle_id)
	if vehicle != null:
		DestructionVFX.clear_vfx(vehicle)
		DestructionVFX.clear_charred(vehicle)
	_vehicle_vfx_started.erase(vehicle_id)


func _apply_network_vehicle_destroyed(vehicle: Node3D) -> void:
	if vehicle.has_method("apply_network_destroyed"):
		vehicle.call("apply_network_destroyed")
		return
	var health: Node = vehicle.get_node_or_null("HealthComponent")
	if health != null and health.has_method("force_destroyed"):
		health.call("force_destroyed", 0, true)


func _apply_network_vehicle_respawned(vehicle: Node3D) -> void:
	if vehicle.has_method("apply_network_respawned"):
		vehicle.call("apply_network_respawned")
		return
	var health: Node = vehicle.get_node_or_null("HealthComponent")
	if health != null and health.has_method("reset"):
		health.call("reset")


func _on_anim_event(payload: Dictionary) -> void:
	var pid: int = int(payload.get("peer_id", -1))
	if pid == NetworkManager.local_peer_id:
		return
	var rp: Node3D = _remote_players.get(pid)
	if rp != null and rp.has_method("play_anim_event"):
		rp.call("play_anim_event", String(payload.get("state", "")), String(payload.get("weapon", "")))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _scene_root() -> Node:
	var root: Node = get_tree().current_scene
	if root == null:
		root = self
	return root


func _payload_entity_id(payload: Dictionary) -> String:
	if payload.has("entity_id"):
		return String(payload.get("entity_id"))
	if payload.has("vehicle_id"):
		return String(payload.get("vehicle_id"))
	return ""


func _vfx_key(payload: Dictionary) -> String:
	var entity_id: String = _payload_entity_id(payload)
	if entity_id != "":
		return "entity:%s" % entity_id
	if _payload_has_vec3(payload, "pos"):
		return "pos:%s" % str(_vec3_from_array(payload.get("pos", null)))
	return "event:%d" % Time.get_ticks_msec()


func _stop_network_smoke_by_key(key: String) -> void:
	var anchor: Node3D = _network_smoke_anchors.get(key)
	if anchor != null and is_instance_valid(anchor):
		anchor.queue_free()
	_network_smoke_anchors.erase(key)


func _vehicle_node_for_id(vehicle_id: String) -> Node3D:
	var name: String = ""
	var key: String = vehicle_id.to_lower()
	match key:
		"tank":
			name = "Tank"
		"tank2":
			name = "Tank2"
		"tank3":
			name = "Tank3"
		"tank4":
			name = "Tank4"
		"helicopter", "heli":
			name = "Helicopter"
		"helicopter2", "heli2":
			name = "Helicopter2"
		"drone":
			name = "Drone"
		_:
			return null

	var root: Node = _scene_root()
	var node: Node = root.get_node_or_null(name)
	if node is Node3D:
		return node as Node3D
	node = root.find_child(name, true, false)
	if node is Node3D:
		return node as Node3D
	return null


func _vehicle_vfx_offset(vehicle_id: String) -> float:
	var key: String = vehicle_id.to_lower()
	if key.begins_with("tank"):
		return 1.2
	if key.begins_with("helicopter") or key == "heli" or key == "heli2":
		return 1.5
	if key == "drone":
		return 0.4
	return 1.0


func _payload_has_vec3(payload: Dictionary, key: String) -> bool:
	var value: Variant = payload.get(key, null)
	return value is Array and (value as Array).size() >= 3


func _safe_node_suffix(value: String) -> String:
	return value.replace(":", "_").replace("/", "_").replace("\\", "_").replace(" ", "_")


static func _vec3_from_array(a: Variant) -> Vector3:
	if not (a is Array) or (a as Array).size() < 3:
		return Vector3.ZERO
	var arr: Array = a
	return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
