class_name VehicleSwitcher
extends Node

## Vehicle activation state manager. E-key cycles through all wired vehicles
## (player → tank → helicopter → drone), skipping any that are null (not
## configured) or destroyed. If no player_path is set, starts on the first
## available vehicle instead of crashing.
##
## Updates ChaseCamera target_path, yaw_source_path, offset, and look_offset
## when a vehicle is activated programmatically. When the player is active,
## their embedded camera takes over and the external ChaseCamera is disabled.
## Implements: design/gdd/vehicle_switching.md (pending)

@export_node_path var player_path: NodePath
@export_node_path var tank_path: NodePath
@export_node_path var helicopter_path: NodePath
@export_node_path var drone_path: NodePath
@export_node_path("Camera3D") var chase_camera_path: NodePath

## FPV post-process CanvasLayer — shown only when drone is active.
@export_node_path("CanvasLayer") var fpv_post_process_path: NodePath
## FPV HUD CanvasLayer — shown only when drone is active.
@export_node_path("CanvasLayer") var fpv_hud_path: NodePath

## NodePath to the tank's turret — used as the camera yaw source when tank is active.
@export_node_path("Node3D") var tank_yaw_source_path: NodePath

@export_group("Camera Offsets — Tank")
@export var tank_camera_offset: Vector3 = Vector3(2.5, 2.2, 0.0)
@export var tank_camera_look_offset: Vector3 = Vector3(0.0, 1.3, 0.0)

@export_group("Camera Offsets — Helicopter")
@export var helicopter_camera_offset: Vector3 = Vector3(0.0, 2.2, -3.3)
@export var helicopter_camera_look_offset: Vector3 = Vector3(0.0, 1.8, 0.0)

@export_group("Camera Offsets — Drone")
@export var drone_camera_offset: Vector3 = Vector3(0.0, 0.75, 1.5)
@export var drone_camera_look_offset: Vector3 = Vector3(0.0, 0.0, 0.0)

## 0 = player, 1 = tank, 2 = helicopter, 3 = drone.
var _active_index: int = 0
var _player: PlayerController
var _tank: TankController
var _helicopter: HelicopterController
var _drone: DroneController
var _camera: ChaseCamera
var _fpv_post_process: CanvasLayer = null
var _fpv_hud: CanvasLayer = null


func _ready() -> void:
	_player = get_node_or_null(player_path) as PlayerController
	_tank = get_node_or_null(tank_path) as TankController
	_helicopter = get_node_or_null(helicopter_path) as HelicopterController
	_drone = get_node_or_null(drone_path) as DroneController
	_camera = get_node_or_null(chase_camera_path) as ChaseCamera
	_fpv_post_process = get_node_or_null(fpv_post_process_path) as CanvasLayer
	_fpv_hud = get_node_or_null(fpv_hud_path) as CanvasLayer

	if _player == null:
		push_warning("VehicleSwitcher: player_path not set or not a PlayerController")
	if _tank == null:
		push_warning("VehicleSwitcher: tank_path not set or not a TankController")
	if _helicopter == null:
		push_warning("VehicleSwitcher: helicopter_path not set or not a HelicopterController")
	if _drone == null:
		push_warning("VehicleSwitcher: drone_path not set or not a DroneController")
	if _camera == null:
		push_warning("VehicleSwitcher: chase_camera_path not set or not a ChaseCamera")
	if _fpv_post_process == null and not fpv_post_process_path.is_empty():
		push_warning("VehicleSwitcher: fpv_post_process_path not set or not a CanvasLayer")
	if _fpv_hud == null and not fpv_hud_path.is_empty():
		push_warning("VehicleSwitcher: fpv_hud_path not set or not a CanvasLayer")

	# Initialise all to inactive, then activate the first available slot.
	if _tank:
		_tank.set_active(false)
	if _helicopter:
		_helicopter.set_active(false)
	if _drone:
		_drone.set_active(false)
	if _player:
		_player.set_active(false)
	if _camera != null:
		_camera.current = false
	if _fpv_post_process != null:
		_fpv_post_process.visible = false
	if _fpv_hud != null:
		_fpv_hud.visible = false
	# Prefer player → tank → helicopter → drone, whichever exists first.
	_active_index = _first_available_index()
	_activate_by_index(_active_index)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event: InputEventKey = event
		if key_event.pressed and not key_event.echo and key_event.keycode == KEY_E:
			_toggle_vehicle()


func _toggle_vehicle() -> void:
	# Cycle through indices 0..3, skipping null-wired or destroyed vehicles.
	for _attempt: int in range(4):
		_active_index = (_active_index + 1) % 4
		if _get_vehicle_at(_active_index) != null and not _is_index_destroyed(_active_index):
			break
	_activate_by_index(_active_index)


func _get_vehicle_at(index: int) -> Node:
	match index:
		0: return _player
		1: return _tank
		2: return _helicopter
		3: return _drone
	return null


func _first_available_index() -> int:
	for i: int in range(4):
		if _get_vehicle_at(i) != null and not _is_index_destroyed(i):
			return i
	return 0


func _activate_by_index(index: int) -> void:
	match index:
		0: _activate_player()
		1: _activate_tank()
		2: _activate_helicopter()
		3: _activate_drone()


func _is_index_destroyed(index: int) -> bool:
	var vehicle: Node = null
	match index:
		0: return false  # Player destroyed handling is separate (respawn system)
		1: vehicle = _tank
		2: vehicle = _helicopter
		3: vehicle = _drone
	if vehicle == null:
		return false
	var health: HealthComponent = vehicle.get_node_or_null("HealthComponent") as HealthComponent
	return health != null and health.is_destroyed()


func _activate_player() -> void:
	if _tank:
		_tank.set_active(false)
	if _helicopter:
		_helicopter.set_active(false)
	if _drone:
		_drone.set_active(false)
	if _player:
		_player.set_active(true)  # Player's embedded camera becomes current.
	# Disable external chase camera — player's internal camera is current now.
	if _camera != null:
		_camera.current = false
	# Hide FPV overlays.
	if _fpv_post_process != null:
		_fpv_post_process.visible = false
	if _fpv_hud != null:
		_fpv_hud.visible = false


func _activate_tank() -> void:
	if _player:
		_player.set_active(false)
	if _helicopter:
		_helicopter.set_active(false)
	if _drone:
		_drone.set_active(false)  # Also sets _fpv_camera.current = false internally.
	if _tank:
		_tank.set_active(true)
	# Restore chase camera as the active renderer.
	if _camera != null:
		_camera.current = true
		_camera.target_path = tank_path
		_camera.yaw_source_path = tank_yaw_source_path if not tank_yaw_source_path.is_empty() else tank_path
		_camera.offset = tank_camera_offset
		_camera.look_offset = tank_camera_look_offset
		# Re-resolve camera targets at runtime.
		_camera._ready()
	# Hide FPV overlays.
	if _fpv_post_process != null:
		_fpv_post_process.visible = false
	if _fpv_hud != null:
		_fpv_hud.visible = false


func _activate_helicopter() -> void:
	if _player:
		_player.set_active(false)
	if _tank:
		_tank.set_active(false)
	if _drone:
		_drone.set_active(false)  # Also sets _fpv_camera.current = false internally.
	if _helicopter:
		_helicopter.set_active(true)
	# Restore chase camera as the active renderer.
	if _camera != null:
		_camera.current = true
		_camera.target_path = helicopter_path
		_camera.yaw_source_path = helicopter_path  # Heli body itself is the yaw source.
		_camera.offset = helicopter_camera_offset
		_camera.look_offset = helicopter_camera_look_offset
		# Re-resolve camera targets at runtime.
		_camera._ready()
	# Hide FPV overlays.
	if _fpv_post_process != null:
		_fpv_post_process.visible = false
	if _fpv_hud != null:
		_fpv_hud.visible = false


func _activate_drone() -> void:
	if _player:
		_player.set_active(false)
	if _tank:
		_tank.set_active(false)
	if _helicopter:
		_helicopter.set_active(false)
	if _drone:
		_drone.set_active(true)  # Also sets _fpv_camera.current = true internally.
	# Disable chase camera — FPV camera on drone takes over rendering.
	if _camera != null:
		_camera.current = false
		# Still update target so it stays in sync if drone is deactivated.
		_camera.target_path = drone_path
		_camera.yaw_source_path = drone_path
		_camera.offset = drone_camera_offset
		_camera.look_offset = drone_camera_look_offset
		_camera._ready()
	# Show FPV overlays.
	if _fpv_post_process != null:
		_fpv_post_process.visible = true
	if _fpv_hud != null:
		_fpv_hud.visible = true
