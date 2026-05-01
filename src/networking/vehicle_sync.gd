extends Node

## Network sync wrapper for a single vehicle (Tank / Helicopter / Drone).
## Lives as a child of the vehicle root in Main.tscn. Detects whether the
## local controller is currently active by reading
## `_controller.is_physics_processing()`, then either:
##
##   - sends `vehicle_transform` 30 Hz (we're driving),
##   - or interpolates the local body's transform toward the server snapshot
##     (someone else drives, or it's parked).
##
## Implements: docs/architecture/adr-0005-node-authoritative-server.md

@export var vehicle_id: String = "tank"
@export var send_rate_hz: float = 30.0
@export var interp_speed: float = 12.0
## Path to the controller node — used to detect "am I driving?" by reading
## `is_physics_processing()`. PlayerController, TankController etc. all have
## physics turned off when set_active(false).
@export_node_path var controller_path: NodePath
## Path to the moveable Node3D whose transform represents the vehicle pose.
## For Tank/Heli/Drone scenes this is usually the scene root itself.
@export_node_path("Node3D") var body_path: NodePath
## Wire-protocol projectile id sent in `vehicle_fire` packets. Empty string
## disables fire forwarding (e.g. drone has no projectile yet).
@export var projectile_id: String = "tank_shell"
## Push the scene-authored start transform to the server after connect so
## parked vehicles do not snap back to stale server constants.
@export var sync_scene_spawn_on_connect: bool = true

const _WEB_BRIDGE_PATH: NodePath = ^"/root/WebBridge"

var _controller: Node = null
var _body: Node3D = null
var _send_accumulator: float = 0.0
var _last_was_driving: bool = false

# Latest server snapshot for this vehicle (used when not driving).
var _server_pos: Vector3 = Vector3.ZERO
var _server_rot: Vector3 = Vector3.ZERO
var _server_aim_yaw: float = 0.0
var _server_aim_pitch: float = 0.0
var _server_driver: int = -1
var _server_alive: bool = true
var _has_server_state: bool = false
var _spawn_sync_sent: bool = false


func _ready() -> void:
	if OS.has_feature("web"):
		send_rate_hz = minf(send_rate_hz, 20.0)
	_controller = get_node_or_null(controller_path)
	_body = get_node_or_null(body_path) as Node3D
	if _body == null:
		# Sensible fallback: the vehicle root we're parented to.
		_body = get_parent() as Node3D
	if _body == null:
		push_warning("[veh-sync %s] body unresolved — disabling" % vehicle_id)
		set_process(false)
		return
	if not _has_network_manager():
		set_process(false)
		return
	NetworkManager.snapshot_received.connect(_on_snapshot)
	if sync_scene_spawn_on_connect:
		NetworkManager.connected_to_server.connect(_on_connected_to_server)
		if NetworkManager.is_online():
			call_deferred("_send_scene_spawn_sync")
	# Wire local fire signals so when this peer is driving and the controller
	# fires a projectile, we forward the spawn pose to the server which then
	# broadcasts a `vehicle_fire` vfx_event for remote viewers.
	if _controller != null and _controller.has_signal("fired_with_aim"):
		_controller.connect("fired_with_aim", _on_local_fired)
	# Drone kamikaze and any other local self-destruct path → forward so
	# remote viewers see the explosion + smoke trail.
	if _controller != null and _controller.has_signal("self_destructed"):
		_controller.connect("self_destructed", _on_local_self_destructed)


func _has_network_manager() -> bool:
	return get_node_or_null("/root/NetworkManager") != null


func _is_driving_locally() -> bool:
	if _controller == null:
		return false
	if _controller.has_method("is_locally_driven"):
		return bool(_controller.call("is_locally_driven"))
	if not _controller.has_method("is_physics_processing"):
		return false
	return bool(_controller.call("is_physics_processing"))


func _on_connected_to_server(_peer_id: int, _team: String) -> void:
	_send_scene_spawn_sync()


func _send_scene_spawn_sync() -> void:
	if _spawn_sync_sent or not sync_scene_spawn_on_connect:
		return
	if _body == null or not _has_network_manager() or not NetworkManager.is_online():
		return
	var aim_yaw: float = _body.rotation.y
	var aim_pitch: float = 0.0
	if _controller != null:
		if _controller.has_method("get_aim_yaw"):
			aim_yaw = float(_controller.call("get_aim_yaw"))
		if _controller.has_method("get_aim_pitch"):
			aim_pitch = float(_controller.call("get_aim_pitch"))
	NetworkManager.send_vehicle_spawn_sync(vehicle_id, _body.global_position, _body.rotation, aim_yaw, aim_pitch)
	_spawn_sync_sent = true


func _get_health_component() -> HealthComponent:
	var owner: Node = _body
	if owner == null:
		owner = get_parent()
	if owner == null:
		return null
	return owner.get_node_or_null("HealthComponent") as HealthComponent


func _is_locally_destroyed() -> bool:
	var health: HealthComponent = _get_health_component()
	return health != null and health.is_destroyed()


func _process(delta: float) -> void:
	if not _has_network_manager() or not NetworkManager.is_online():
		return
	if _is_locally_destroyed():
		if _last_was_driving:
			_last_was_driving = false
			NetworkManager.send_vehicle_exit()
			print("[veh-sync %s] exit (local destroyed)" % vehicle_id)
		if _controller != null and _controller.has_method("set_remote_driver_active"):
			_controller.call("set_remote_driver_active", false)
		return
	var driving: bool = _is_driving_locally()
	if driving != _last_was_driving:
		_last_was_driving = driving
		if driving:
			NetworkManager.send_vehicle_enter(vehicle_id)
			print("[veh-sync %s] enter (local driver)" % vehicle_id)
		else:
			# We could be exiting THIS vehicle, but the server only cares
			# which peer is driving — sending vehicle_exit unconditionally is
			# fine; server clears any vehicle this peer was driving.
			NetworkManager.send_vehicle_exit()
			print("[veh-sync %s] exit (local stopped driving)" % vehicle_id)

	if driving:
		_send_accumulator += delta
		var period: float = 1.0 / send_rate_hz
		if _send_accumulator >= period:
			_send_accumulator = 0.0
			_send_transform()
		return

	# Not driving — lerp toward the server snapshot if we have one.
	if not _has_server_state:
		return
	if not _server_alive:
		return
	# If server says I'm the driver but our local controller is inactive (rare
	# transient — e.g. just exited but server hasn't processed yet), still
	# follow my own state. Otherwise lerp.
	if _server_driver == NetworkManager.local_peer_id:
		return
	var t: float = clamp(interp_speed * delta, 0.0, 1.0)
	_body.global_position = _body.global_position.lerp(_server_pos, t)
	_body.rotation = Vector3(
		lerp_angle(_body.rotation.x, _server_rot.x, t),
		lerp_angle(_body.rotation.y, _server_rot.y, t),
		lerp_angle(_body.rotation.z, _server_rot.z, t),
	)
	if _controller != null and _controller.has_method("set_remote_aim"):
		_controller.call("set_remote_aim", _server_aim_yaw, _server_aim_pitch)


func _send_transform() -> void:
	var pos: Vector3 = _body.global_position
	var rot: Vector3 = _body.rotation
	var vel: Vector3 = Vector3.ZERO
	# Only CharacterBody3D / RigidBody3D-style nodes expose .velocity. Use a
	# duck-typed has-property check via property list.
	if _body is CharacterBody3D:
		vel = (_body as CharacterBody3D).velocity
	elif _body is RigidBody3D:
		vel = (_body as RigidBody3D).linear_velocity
	var aim_yaw: float = rot.y
	var aim_pitch: float = 0.0
	if _controller != null:
		if _controller.has_method("get_aim_yaw"):
			aim_yaw = float(_controller.call("get_aim_yaw"))
		if _controller.has_method("get_aim_pitch"):
			aim_pitch = float(_controller.call("get_aim_pitch"))
	NetworkManager.send_vehicle_transform(vehicle_id, pos, rot, vel, aim_yaw, aim_pitch)


func _on_local_self_destructed(_at: Vector3) -> void:
	if not _has_network_manager() or not NetworkManager.is_online():
		return
	# Only the active local driver should authoritatively report destruction;
	# bystanders should not (server would reject anyway, but skip for clarity).
	if not _is_driving_locally():
		return
	NetworkManager.send_message({
		"t": "vehicle_self_destruct",
		"vehicle_id": vehicle_id,
	})


func _on_local_fired(spawn_origin: Vector3, aim_dir: Vector3) -> void:
	if not _has_network_manager() or not NetworkManager.is_online():
		return
	if not _is_driving_locally() or projectile_id == "":
		return
	NetworkManager.send_message({
		"t": "vehicle_fire",
		"vehicle_id": vehicle_id,
		"projectile": projectile_id,
		"origin": [spawn_origin.x, spawn_origin.y, spawn_origin.z],
		"dir": [aim_dir.x, aim_dir.y, aim_dir.z],
		"client_t": Time.get_ticks_msec(),
	})


func _on_snapshot(_tick: int, _server_t: int, _players: Array, vehicles: Array) -> void:
	for raw in vehicles:
		if not (raw is Dictionary):
			continue
		var v: Dictionary = raw
		if String(v.get("id", "")) != vehicle_id:
			continue
		var pos_arr: Array = v.get("pos", [0, 0, 0])
		var rot_arr: Array = v.get("rot", [0, 0, 0])
		if pos_arr.size() < 3 or rot_arr.size() < 3:
			return
		var had_server_state: bool = _has_server_state
		var was_alive: bool = _server_alive
		_server_pos = Vector3(float(pos_arr[0]), float(pos_arr[1]), float(pos_arr[2]))
		_server_rot = Vector3(float(rot_arr[0]), float(rot_arr[1]), float(rot_arr[2]))
		_server_aim_yaw = float(v.get("aim_yaw", _server_rot.y))
		_server_aim_pitch = float(v.get("aim_pitch", 0.0))
		_server_driver = int(v.get("driver_peer_id", -1))
		_server_alive = bool(v.get("alive", true))
		_has_server_state = true
		if _server_alive and had_server_state and not was_alive:
			_body.global_position = _server_pos
			_body.rotation = _server_rot
			if _controller != null and _controller.has_method("apply_network_respawned"):
				_controller.call("apply_network_respawned")
			if _controller != null and _controller.has_method("set_remote_aim"):
				_controller.call("set_remote_aim", _server_aim_yaw, _server_aim_pitch)
		# Tell the controller whether a non-local peer is currently driving so
		# heli rotors / drone propellers keep spinning even though our local
		# _physics_process is suspended.
		if _controller != null and _controller.has_method("set_remote_driver_active"):
			var remote_drives: bool = _server_driver >= 0 and _server_driver != NetworkManager.local_peer_id
			_controller.call("set_remote_driver_active", remote_drives)
		return
