class_name VehicleSwitcher
extends Node

## Toggles the active vehicle between tank and helicopter with the E key.
## Updates ChaseCamera target_path, yaw_source_path, offset, and look_offset on each switch.
## Implements: design/gdd/vehicle_switching.md (pending)

@export_node_path var tank_path: NodePath
@export_node_path var helicopter_path: NodePath
@export_node_path("Camera3D") var chase_camera_path: NodePath

## NodePath to the tank's turret — used as the camera yaw source when tank is active.
@export_node_path("Node3D") var tank_yaw_source_path: NodePath

@export_group("Camera Offsets — Tank")
@export var tank_camera_offset: Vector3 = Vector3(2.5, 2.2, 0.0)
@export var tank_camera_look_offset: Vector3 = Vector3(0.0, 1.3, 0.0)

@export_group("Camera Offsets — Helicopter")
@export var helicopter_camera_offset: Vector3 = Vector3(0.0, 2.2, -3.3)
@export var helicopter_camera_look_offset: Vector3 = Vector3(0.0, 1.8, 0.0)

var _active_index: int = 0
var _tank: TankController
var _helicopter: HelicopterController
var _camera: ChaseCamera


func _ready() -> void:
	_tank = get_node_or_null(tank_path) as TankController
	_helicopter = get_node_or_null(helicopter_path) as HelicopterController
	_camera = get_node_or_null(chase_camera_path) as ChaseCamera

	if _tank == null:
		push_warning("VehicleSwitcher: tank_path not set or not a TankController")
	if _helicopter == null:
		push_warning("VehicleSwitcher: helicopter_path not set or not a HelicopterController")
	if _camera == null:
		push_warning("VehicleSwitcher: chase_camera_path not set or not a ChaseCamera")

	# Initialise: tank active, helicopter inactive.
	if _helicopter:
		_helicopter.set_active(false)
	if _tank:
		_tank.set_active(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event: InputEventKey = event
		if key_event.pressed and not key_event.echo and key_event.keycode == KEY_E:
			_toggle_vehicle()


func _toggle_vehicle() -> void:
	_active_index = 1 - _active_index  # flip 0 <-> 1

	match _active_index:
		0:
			_activate_tank()
		1:
			_activate_helicopter()


func _activate_tank() -> void:
	if _helicopter:
		_helicopter.set_active(false)
	if _tank:
		_tank.set_active(true)
	if _camera == null:
		return
	_camera.target_path = tank_path
	_camera.yaw_source_path = tank_yaw_source_path if not tank_yaw_source_path.is_empty() else tank_path
	_camera.offset = tank_camera_offset
	_camera.look_offset = tank_camera_look_offset
	# Re-resolve camera targets at runtime.
	_camera._ready()


func _activate_helicopter() -> void:
	if _tank:
		_tank.set_active(false)
	if _helicopter:
		_helicopter.set_active(true)
	if _camera == null:
		return
	_camera.target_path = helicopter_path
	_camera.yaw_source_path = helicopter_path  # Heli body itself is the yaw source.
	_camera.offset = helicopter_camera_offset
	_camera.look_offset = helicopter_camera_look_offset
	# Re-resolve camera targets at runtime.
	_camera._ready()
