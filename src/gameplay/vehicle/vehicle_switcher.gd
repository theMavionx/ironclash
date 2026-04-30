class_name VehicleSwitcher
extends Node

## Current behavior: E/interact enters only the nearest live vehicle within its
## interaction radius, and exits back to infantry when already driving/flying.
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
@export var tank_camera_pitch_look_scale: float = 3.0

@export_group("Camera Offsets — Helicopter")
@export var helicopter_camera_offset: Vector3 = Vector3(0.0, 5.6, -14.0)
@export var helicopter_camera_look_offset: Vector3 = Vector3(0.0, 2.4, 0.0)
@export var helicopter_camera_pitch_angle_scale: float = 1.0

@export_group("Camera Offsets — Drone")
@export var drone_camera_offset: Vector3 = Vector3(0.0, 0.75, 1.5)
@export var drone_camera_look_offset: Vector3 = Vector3(0.0, 0.0, 0.0)

@export_group("Interaction")
@export var tank_enter_radius: float = 5.5
@export var helicopter_enter_radius: float = 6.5
@export var drone_enter_radius: float = 3.5
@export var exit_side_distance: float = 2.2
@export var exit_ground_probe_up: float = 4.0
@export var exit_ground_probe_down: float = 60.0
@export var exit_ground_collision_mask: int = 1
@export var auto_disable_extra_scene_vehicles: bool = true

## 0 = player, 1 = tank, 2 = helicopter, 3 = drone.
var _active_index: int = 0
var _player: PlayerController
var _tank: TankController
var _helicopter: HelicopterController
var _drone: DroneController
var _camera: ChaseCamera
var _fpv_post_process: CanvasLayer = null
var _fpv_hud: CanvasLayer = null
var _extra_scene_vehicles: Array[Node] = []


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

	if auto_disable_extra_scene_vehicles:
		_collect_extra_scene_vehicles()

	# Initialise all to inactive, then activate the first available slot.
	_deactivate_all_scene_vehicles()
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
	if event.is_action_pressed("interact"):
		_handle_interact_pressed()
		WebPointerLock.capture_from_user_gesture()
		get_viewport().set_input_as_handled()


func _handle_interact_pressed() -> void:
	if _active_index == 0:
		var vehicle_index: int = _nearest_enterable_vehicle_index()
		if vehicle_index != 0:
			_activate_by_index(vehicle_index)
	else:
		_exit_vehicle_to_player()


func _get_vehicle_at(index: int) -> Node:
	match index:
		0: return _player
		1: return _tank
		2: return _helicopter
		3: return _drone
	return null


func _first_available_index() -> int:
	if _player != null:
		return 0
	for i: int in range(1, 4):
		if _get_vehicle_at(i) != null and not _is_index_destroyed(i):
			return i
	return 0


func _activate_by_index(index: int) -> void:
	_active_index = index
	match index:
		0: _activate_player()
		1: _activate_tank()
		2: _activate_helicopter()
		3: _activate_drone()


func _nearest_enterable_vehicle_index() -> int:
	if _player == null:
		return 0
	var player_pos: Vector3 = _player.get_interaction_position()
	var best_index: int = 0
	var best_dist: float = INF
	for index: int in range(1, 4):
		var vehicle: Node3D = _get_vehicle_at(index) as Node3D
		if vehicle == null or _is_index_destroyed(index):
			continue
		var dist: float = _planar_distance(player_pos, vehicle.global_position)
		if dist <= _enter_radius_for_index(index) and dist < best_dist:
			best_dist = dist
			best_index = index
	return best_index


func _enter_radius_for_index(index: int) -> float:
	match index:
		1: return tank_enter_radius
		2: return helicopter_enter_radius
		3: return drone_enter_radius
	return 0.0


func _planar_distance(a: Vector3, b: Vector3) -> float:
	var delta: Vector3 = a - b
	delta.y = 0.0
	return delta.length()


func _exit_vehicle_to_player() -> void:
	if _player == null:
		return
	var vehicle: Node3D = _get_vehicle_at(_active_index) as Node3D
	if vehicle != null:
		var exit_pos: Vector3 = _find_exit_position(vehicle)
		var facing_yaw: float = _yaw_to_face(exit_pos - vehicle.global_position)
		_player.place_at(exit_pos, facing_yaw)
	_activate_by_index(0)


func _find_exit_position(vehicle: Node3D) -> Vector3:
	var side: Vector3 = vehicle.global_transform.basis.x
	side.y = 0.0
	if side.length_squared() < 0.001:
		side = Vector3.RIGHT
	side = side.normalized()
	var candidate: Vector3 = vehicle.global_position + side * exit_side_distance
	candidate.y += 0.25
	return _snap_exit_position_to_ground(vehicle, candidate)


func _snap_exit_position_to_ground(vehicle: Node3D, candidate: Vector3) -> Vector3:
	var space: PhysicsDirectSpaceState3D = vehicle.get_world_3d().direct_space_state
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		candidate + Vector3.UP * exit_ground_probe_up,
		candidate - Vector3.UP * exit_ground_probe_down,
		exit_ground_collision_mask
	)
	query.collide_with_areas = false
	if vehicle is CollisionObject3D:
		query.exclude = [(vehicle as CollisionObject3D).get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return candidate
	var hit_pos: Vector3 = hit.get("position", candidate)
	return hit_pos + Vector3.UP * 0.08


func _yaw_to_face(direction: Vector3) -> float:
	direction.y = 0.0
	if direction.length_squared() < 0.001:
		return 0.0
	direction = direction.normalized()
	return atan2(-direction.x, -direction.z)


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
	_deactivate_all_scene_vehicles()
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
	_deactivate_extra_scene_vehicles()
	if _helicopter:
		_helicopter.set_active(false)
	if _drone:
		_drone.set_active(false)  # Also sets _fpv_camera.current = false internally.
	if _tank:
		_tank.set_active(true)
	# Restore chase camera as the active renderer.
	if _camera != null:
		_camera.current = true
		var yaw_path: NodePath = tank_yaw_source_path if not tank_yaw_source_path.is_empty() else tank_path
		_camera.rebind(
			tank_path,
			yaw_path,
			tank_camera_offset,
			tank_camera_look_offset,
			true,
			false,
			1.0,
			tank_camera_pitch_look_scale
		)
	# Hide FPV overlays.
	if _fpv_post_process != null:
		_fpv_post_process.visible = false
	if _fpv_hud != null:
		_fpv_hud.visible = false


func _activate_helicopter() -> void:
	if _player:
		_player.set_active(false)
	_deactivate_extra_scene_vehicles()
	if _tank:
		_tank.set_active(false)
	if _drone:
		_drone.set_active(false)  # Also sets _fpv_camera.current = false internally.
	if _helicopter:
		_helicopter.set_active(true)
	# Restore chase camera as the active renderer.
	if _camera != null:
		_camera.current = true
		_camera.rebind(
			helicopter_path,
			helicopter_path,
			helicopter_camera_offset,
			helicopter_camera_look_offset,
			true,
			true,
			helicopter_camera_pitch_angle_scale
		)
	# Hide FPV overlays.
	if _fpv_post_process != null:
		_fpv_post_process.visible = false
	if _fpv_hud != null:
		_fpv_hud.visible = false


func _activate_drone() -> void:
	if _player:
		_player.set_active(false)
	_deactivate_extra_scene_vehicles()
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
		_camera.rebind(drone_path, drone_path, drone_camera_offset, drone_camera_look_offset)
	# Show FPV overlays.
	if _fpv_post_process != null:
		_fpv_post_process.visible = true
	if _fpv_hud != null:
		_fpv_hud.visible = true


func _deactivate_all_scene_vehicles() -> void:
	if _tank:
		_tank.set_active(false)
	if _helicopter:
		_helicopter.set_active(false)
	if _drone:
		_drone.set_active(false)
	_deactivate_extra_scene_vehicles()


func _deactivate_extra_scene_vehicles() -> void:
	for vehicle in _extra_scene_vehicles:
		if vehicle == null or not is_instance_valid(vehicle):
			continue
		if vehicle.has_method("set_active"):
			vehicle.call("set_active", false)


func _collect_extra_scene_vehicles() -> void:
	_extra_scene_vehicles.clear()
	var root: Node = get_tree().current_scene
	if root == null:
		root = get_parent()
	if root != null:
		_collect_extra_scene_vehicles_recursive(root)


func _collect_extra_scene_vehicles_recursive(node: Node) -> void:
	var is_vehicle: bool = node is TankController or node is HelicopterController or node is DroneController
	if is_vehicle and node != _tank and node != _helicopter and node != _drone:
		if not _extra_scene_vehicles.has(node):
			_extra_scene_vehicles.append(node)
	for child in node.get_children():
		_collect_extra_scene_vehicles_recursive(child)
