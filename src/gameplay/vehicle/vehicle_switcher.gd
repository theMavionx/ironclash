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
## Why: drone is small so the previous 3.5m radius required pixel-perfect
## positioning to trigger E-interaction. Match tank/heli radius so the player
## can walk up "next to" the drone and press E without snapping to the exact
## centre. Drones spawn near the base now (in front of tanks), and the
## interaction flow expects the player to glance at the drone and tap E.
@export var drone_enter_radius: float = 5.5
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
		# Search every TankController/HelicopterController/DroneController in the
		# scene, not just the configured main slots. Without this, the player
		# could only enter the FIRST vehicle of each type (e.g. Tank), and all
		# other instances (Tank2/3/4, Helicopter2, Drone2) — including enemy
		# base vehicles — were unreachable for local control even when
		# standing right next to them.
		var chosen: Node = _nearest_enterable_vehicle()
		if chosen == null:
			return
		# Re-bind the appropriate slot to the chosen instance so the existing
		# activate/camera-rebind code paths drive THIS vehicle.
		if chosen is TankController:
			_tank = chosen as TankController
			_activate_by_index(1)
		elif chosen is HelicopterController:
			_helicopter = chosen as HelicopterController
			_activate_by_index(2)
		elif chosen is DroneController:
			_drone = chosen as DroneController
			_activate_by_index(3)
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


## Find the closest TankController/HelicopterController/DroneController in the
## scene that the player is within the appropriate enter radius of. Returns
## null when nothing is in range. Searches the whole scene tree so secondary
## base vehicles (Tank2/Tank3/Helicopter2/Drone2) are reachable too.
func _nearest_enterable_vehicle() -> Node:
	if _player == null:
		return null
	var player_pos: Vector3 = _player.get_interaction_position()
	var best: Node = null
	var best_dist: float = INF
	for vehicle: Node in _all_vehicles_in_scene():
		if not (vehicle is Node3D):
			continue
		if _is_vehicle_destroyed(vehicle):
			continue
		var dist: float = _planar_distance(player_pos, (vehicle as Node3D).global_position)
		var radius: float = _enter_radius_for_vehicle(vehicle)
		if dist <= radius and dist < best_dist:
			best_dist = dist
			best = vehicle
	return best


func _enter_radius_for_vehicle(vehicle: Node) -> float:
	if vehicle is TankController:
		return tank_enter_radius
	if vehicle is HelicopterController:
		return helicopter_enter_radius
	if vehicle is DroneController:
		return drone_enter_radius
	return 0.0


func _is_vehicle_destroyed(vehicle: Node) -> bool:
	if vehicle == null:
		return false
	var health: HealthComponent = vehicle.get_node_or_null("HealthComponent") as HealthComponent
	return health != null and health.is_destroyed()


func _all_vehicles_in_scene() -> Array[Node]:
	var result: Array[Node] = []
	var root: Node = get_tree().current_scene
	if root == null:
		root = get_parent()
	if root != null:
		_collect_all_vehicles_recursive(root, result)
	return result


func _collect_all_vehicles_recursive(node: Node, out: Array[Node]) -> void:
	if node is TankController or node is HelicopterController or node is DroneController:
		if not out.has(node):
			out.append(node)
	for child: Node in node.get_children():
		_collect_all_vehicles_recursive(child, out)


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
	# Drone exit is special: the player was never physically in the drone, so
	# we don't teleport them anywhere — they resume control wherever they
	# were standing. Also disconnect the auto-exit signal so it doesn't fire
	# next time someone else takes the drone.
	if _active_index == 3:
		if _drone != null and _drone.self_destructed.is_connected(_on_active_drone_self_destructed):
			_drone.self_destructed.disconnect(_on_active_drone_self_destructed)
		_activate_by_index(0)
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


## Distance threshold (m) below which we snap the player to the ground on
## exit. If the ground is farther than this below the candidate, we leave
## the player at the candidate's altitude and let PlayerController gravity
## carry them down — that's how a helicopter eject in mid-air should feel.
const _EXIT_AERIAL_DROP_THRESHOLD: float = 4.0


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
	# Aerial eject: ground is too far below. Leave the player at vehicle
	# altitude — gravity in PlayerController will carry them down. Without
	# this, exiting a flying helicopter teleports the player straight to the
	# ground, which feels like a glitch.
	if candidate.y - hit_pos.y > _EXIT_AERIAL_DROP_THRESHOLD:
		return candidate
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
		# Restore visibility / collisions BEFORE re-enabling input, otherwise
		# the first physics tick after set_active(true) runs against the
		# disabled-collision body and the player can phase through walls.
		if _player.has_method("set_embarked"):
			_player.call("set_embarked", false)
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
		# Player is now "inside the tank" — hide the soldier model and remove
		# its collision so projectiles/explosions can't hit the embarked
		# soldier through the tank shell.
		if _player.has_method("set_embarked"):
			_player.call("set_embarked", true)
	# Disable every vehicle except _tank (which may be a freshly chosen
	# enemy/secondary tank, not the originally configured one).
	_deactivate_all_vehicles_except(_tank)
	if _tank:
		_tank.set_active(true)
	# Restore chase camera as the active renderer.
	if _camera != null and _tank != null:
		_camera.current = true
		var tank_node_path: NodePath = _tank.get_path()
		# tank_yaw_source_path is configured relative to the scene root pointing
		# at the FIRST tank's turret. Translate that to the equivalent path
		# inside the currently chosen tank by reusing the tail of the path.
		var yaw_path: NodePath = _resolve_tank_yaw_path(_tank)
		_camera.rebind(
			tank_node_path,
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


## Resolve the turret yaw-source NodePath for an arbitrary tank instance by
## reusing the well-known relative subpath inside the tank scene
## (Model/Armature/Skeleton3D/TankBody_001).
func _resolve_tank_yaw_path(tank: TankController) -> NodePath:
	const TURRET_RELATIVE: String = "Model/Armature/Skeleton3D/TankBody_001"
	var turret: Node = tank.get_node_or_null(TURRET_RELATIVE)
	if turret != null:
		return turret.get_path()
	return tank.get_path()


func _activate_helicopter() -> void:
	if _player:
		_player.set_active(false)
		# Same reasoning as tank: hide the embarked soldier inside the heli.
		if _player.has_method("set_embarked"):
			_player.call("set_embarked", true)
	_deactivate_all_vehicles_except(_helicopter)
	if _helicopter:
		_helicopter.set_active(true)
	# Restore chase camera as the active renderer.
	if _camera != null and _helicopter != null:
		_camera.current = true
		var heli_path: NodePath = _helicopter.get_path()
		_camera.rebind(
			heli_path,
			heli_path,
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
		# Drone is REMOTE-PILOTED. The player stays standing wherever they
		# were when they pressed E — they don't physically enter the drone.
		# So we suspend their input/camera but keep the body visible and
		# collidable. set_embarked stays FALSE for drone control.
		_player.set_active(false)
	_deactivate_all_vehicles_except(_drone)
	if _drone:
		_drone.set_active(true)  # Also sets _fpv_camera.current = true internally.
		# Auto-exit player back to infantry when this drone crashes/is shot
		# down, so the user isn't stranded staring at a dead wreck.
		if _drone.has_signal("self_destructed") and not _drone.self_destructed.is_connected(_on_active_drone_self_destructed):
			_drone.self_destructed.connect(_on_active_drone_self_destructed)
	# Disable chase camera — FPV camera on drone takes over rendering.
	if _camera != null and _drone != null:
		_camera.current = false
		# Still update target so it stays in sync if drone is deactivated.
		var drone_node_path: NodePath = _drone.get_path()
		_camera.rebind(drone_node_path, drone_node_path, drone_camera_offset, drone_camera_look_offset)
	# Show FPV overlays.
	if _fpv_post_process != null:
		_fpv_post_process.visible = true
	if _fpv_hud != null:
		_fpv_hud.visible = true


## Drone we are currently piloting blew up / crashed. Pop the player back to
## infantry so they aren't stuck in FPV looking at a wreck. Drone scene
## handles its own respawn timer separately.
func _on_active_drone_self_destructed(_at_position: Vector3) -> void:
	if _active_index != 3:
		return
	if _drone != null and _drone.self_destructed.is_connected(_on_active_drone_self_destructed):
		_drone.self_destructed.disconnect(_on_active_drone_self_destructed)
	_activate_by_index(0)


func _deactivate_all_scene_vehicles() -> void:
	_deactivate_all_vehicles_except(null)


## Deactivate every TankController / HelicopterController / DroneController in
## the scene except [param except]. Replaces the older "main slots + extras"
## split, which fell apart once the player could enter any vehicle in the
## scene (the dynamic _tank/_helicopter/_drone re-binding broke the static
## extras list).
func _deactivate_all_vehicles_except(except: Node) -> void:
	for vehicle: Node in _all_vehicles_in_scene():
		if vehicle == except:
			continue
		if vehicle.has_method("set_active"):
			vehicle.call("set_active", false)


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
