class_name OrbitCamera
extends Camera3D

## Orbits around a target node using arrow keys; zoom with mouse wheel.
## If no target is assigned, orbits world origin.

@export var target: Node3D
@export var rotation_speed: float = 2.0 ## radians per second
@export var zoom_step: float = 1.5
@export var min_distance: float = 0.5
@export var max_distance: float = 60.0
@export var min_pitch_deg: float = -15.0
@export var max_pitch_deg: float = 80.0
@export var initial_distance: float = 14.0
@export var initial_yaw_deg: float = 0.0
@export var initial_pitch_deg: float = 30.0

var _yaw: float = 0.0
var _pitch: float = 0.0
var _distance: float = 0.0


func _ready() -> void:
	_yaw = deg_to_rad(initial_yaw_deg)
	_pitch = deg_to_rad(initial_pitch_deg)
	_distance = initial_distance
	_update_transform()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mouse_event: InputEventMouseButton = event
		match mouse_event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_distance = clamp(_distance - zoom_step, min_distance, max_distance)
			MOUSE_BUTTON_WHEEL_DOWN:
				_distance = clamp(_distance + zoom_step, min_distance, max_distance)


func _process(delta: float) -> void:
	var yaw_input: float = 0.0
	var pitch_input: float = 0.0
	if Input.is_key_pressed(KEY_RIGHT):
		yaw_input += 1.0
	if Input.is_key_pressed(KEY_LEFT):
		yaw_input -= 1.0
	if Input.is_key_pressed(KEY_UP):
		pitch_input += 1.0
	if Input.is_key_pressed(KEY_DOWN):
		pitch_input -= 1.0

	if yaw_input != 0.0:
		_yaw -= yaw_input * rotation_speed * delta
	if pitch_input != 0.0:
		var min_pitch: float = deg_to_rad(min_pitch_deg)
		var max_pitch: float = deg_to_rad(max_pitch_deg)
		_pitch = clamp(_pitch + pitch_input * rotation_speed * delta, min_pitch, max_pitch)

	_update_transform()


func _update_transform() -> void:
	var target_pos: Vector3 = target.global_position if target else Vector3.ZERO
	var offset: Vector3 = Vector3(
		sin(_yaw) * cos(_pitch),
		sin(_pitch),
		cos(_yaw) * cos(_pitch)
	) * _distance
	global_position = target_pos + offset
	look_at(target_pos, Vector3.UP)
