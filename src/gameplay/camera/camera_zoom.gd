class_name CameraZoom
extends Camera3D

## Mouse-wheel zoom for a static camera.
## Moves the camera along its current direction-to-origin vector.
## Attach to any Camera3D — no Input Map actions required.

@export var zoom_step: float = 1.5
@export var min_distance: float = 3.0
@export var max_distance: float = 40.0
@export var smoothing: float = 8.0

var _target_position: Vector3


func _ready() -> void:
	_target_position = position


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mouse_event: InputEventMouseButton = event
		match mouse_event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_zoom(-zoom_step)
			MOUSE_BUTTON_WHEEL_DOWN:
				_zoom(zoom_step)


func _process(delta: float) -> void:
	position = position.lerp(_target_position, clamp(smoothing * delta, 0.0, 1.0))


func _zoom(amount: float) -> void:
	var current_distance: float = _target_position.length()
	if current_distance <= 0.0:
		return
	var new_distance: float = clamp(current_distance + amount, min_distance, max_distance)
	_target_position = _target_position.normalized() * new_distance
