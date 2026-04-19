class_name HelicopterController
extends CharacterBody3D

## Helicopter flight controller with rotor animation.
## Implements: design/gdd/helicopter_movement.md (pending)
## Space = lift thrust. WASD = strafe in local XZ. Mouse X = yaw only.
## Pitch is visual-only tilt derived from strafe input — not mouse-driven.

@export var max_rotor_speed_rad_per_sec: float = 30.0
@export var idle_rotor_speed_rad_per_sec: float = 8.0
@export var lift_acceleration: float = 12.0
@export var max_altitude: float = 50.0
@export var horizontal_damping: float = 2.0
@export var rotor_spool_speed: float = 1.5

@export_group("Strafe")
## Movement speed applied when pressing WASD.
@export var strafe_speed: float = 8.0
## Max tilt in degrees applied when strafing forward/back (visual feedback only).
@export var max_pitch_tilt_deg: float = 15.0
## Max tilt in degrees applied when strafing left/right (visual feedback only).
@export var max_roll_tilt_deg: float = 12.0
## How quickly the tilt smooths in/out (lerp rate per second).
@export var tilt_smooth_speed: float = 6.0

@export_group("Yaw")
## Radians per screen pixel of mouse X motion.
@export var mouse_sensitivity: float = 0.0025
## Smooth yaw: 0 = instant snap, higher = more lag/smoothness.
@export var yaw_smooth_speed: float = 10.0

@export_group("Rotor Nodes")
## Leave empty to auto-find by node name in GLB hierarchy.
@export_node_path("Node3D") var main_rotor_path: NodePath
@export_node_path("Node3D") var tail_rotor_path: NodePath
## Local axis the main rotor spins around (top rotor = UP).
@export var main_rotor_axis: Vector3 = Vector3.UP
## Local axis the tail rotor spins around. Try FORWARD / BACK / RIGHT
## until the tail rotor disc spins like a disc (not tumbles).
@export var tail_rotor_axis: Vector3 = Vector3.FORWARD

var _active: bool = true
var _current_rotor_speed: float = 0.0
var _main_rotor: Node3D
var _tail_rotor: Node3D

## Target yaw accumulated from mouse input (radians).
var _yaw_target: float = 0.0
## Current smoothed yaw applied to the body.
var _yaw_current: float = 0.0
## Current smoothed pitch tilt (radians).
var _pitch_tilt_current: float = 0.0
## Current smoothed roll tilt (radians).
var _roll_tilt_current: float = 0.0

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)


func _ready() -> void:
	# Prefer explicit NodePath, fall back to name-based search.
	if main_rotor_path and not main_rotor_path.is_empty():
		_main_rotor = get_node_or_null(main_rotor_path) as Node3D
	if _main_rotor == null:
		_main_rotor = _find_descendant_by_name(self, "Object_10") as Node3D
	if _main_rotor == null:
		push_warning("HelicopterController: main rotor 'Object_10' not found")

	if tail_rotor_path and not tail_rotor_path.is_empty():
		_tail_rotor = get_node_or_null(tail_rotor_path) as Node3D
	if _tail_rotor == null:
		# Circle_003_12 is the common parent of the hub (Object_37) and blades
		# (Object_39 inside Cube_003_11). Its origin is at the hub center, so
		# rotating it spins the whole assembly correctly around its hub.
		_tail_rotor = _find_descendant_by_name(self, "Circle_003_12") as Node3D
	if _tail_rotor == null:
		push_warning("HelicopterController: tail rotor pivot 'Circle_003_12' not found")

	_yaw_target = rotation.y
	_yaw_current = rotation.y
	# Start rotors at idle so they're visibly spinning from frame 1.
	_current_rotor_speed = idle_rotor_speed_rad_per_sec


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		# Only yaw from mouse — no pitch mouse control.
		_yaw_target -= motion.relative.x * mouse_sensitivity
	elif event is InputEventKey:
		var key_event: InputEventKey = event
		if key_event.pressed and key_event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif key_event.pressed and key_event.keycode == KEY_F1:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Enable or disable this vehicle. Inactive vehicles stop processing and zero velocity.
func set_active(is_active: bool) -> void:
	_active = is_active
	set_physics_process(is_active)
	if not is_active:
		velocity = Vector3.ZERO
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if not _active:
		return

	var lifting: bool = Input.is_key_pressed(KEY_SPACE)
	var descending: bool = Input.is_key_pressed(KEY_SHIFT)

	# Vertical movement — Space up, Shift down, nothing = hover (no gravity).
	if lifting and global_position.y < max_altitude:
		velocity.y += lift_acceleration * delta
	elif descending:
		velocity.y -= lift_acceleration * delta
	else:
		# Smoothly decay vertical velocity toward zero — rotors hold position.
		var hover_damp: float = 1.0 - clamp(4.0 * delta, 0.0, 1.0)
		velocity.y *= hover_damp

	# Clamp so we don't exceed max altitude.
	if global_position.y >= max_altitude and velocity.y > 0.0:
		velocity.y = 0.0
	# Prevent sinking into the floor.
	if is_on_floor() and velocity.y < 0.0:
		velocity.y = 0.0

	# WASD strafe in the helicopter's current yaw-aligned local frame.
	# Signs are set so WASD matches screen-space directions from behind-camera view.
	var strafe_input: Vector2 = Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		strafe_input.y += 1.0
	if Input.is_key_pressed(KEY_S):
		strafe_input.y -= 1.0
	if Input.is_key_pressed(KEY_A):
		strafe_input.x += 1.0
	if Input.is_key_pressed(KEY_D):
		strafe_input.x -= 1.0
	strafe_input = strafe_input.normalized() if strafe_input.length() > 1.0 else strafe_input

	# Convert strafe input to world-space velocity using current yaw.
	var yaw_basis: Basis = Basis(Vector3.UP, _yaw_current)
	var world_strafe: Vector3 = yaw_basis * Vector3(strafe_input.x, 0.0, strafe_input.y)
	velocity.x = world_strafe.x * strafe_speed
	velocity.z = world_strafe.z * strafe_speed

	# Exponential damping only when no strafe input.
	if strafe_input.length_squared() < 0.01:
		var damp_factor: float = 1.0 - clamp(horizontal_damping * delta, 0.0, 1.0)
		velocity.x *= damp_factor
		velocity.z *= damp_factor

	# Smooth yaw toward target.
	_yaw_current = lerpf(_yaw_current, _yaw_target, clamp(yaw_smooth_speed * delta, 0.0, 1.0))

	# Compute target tilts from strafe input (visual only — no physics effect).
	var target_pitch_tilt: float = strafe_input.y * deg_to_rad(max_pitch_tilt_deg)
	var target_roll_tilt: float = -strafe_input.x * deg_to_rad(max_roll_tilt_deg)

	# Smooth the tilts.
	_pitch_tilt_current = lerpf(
		_pitch_tilt_current, target_pitch_tilt, clamp(tilt_smooth_speed * delta, 0.0, 1.0)
	)
	_roll_tilt_current = lerpf(
		_roll_tilt_current, target_roll_tilt, clamp(tilt_smooth_speed * delta, 0.0, 1.0)
	)

	# Apply yaw + visual tilts to helicopter body.
	rotation.y = _yaw_current
	rotation.x = _pitch_tilt_current
	rotation.z = _roll_tilt_current

	move_and_slide()

	_animate_rotors(lifting, delta)


func _animate_rotors(lifting: bool, delta: float) -> void:
	var target_speed: float

	if is_on_floor() and not lifting:
		# Parked on the ground — rotors stopped (Shift on ground is a no-op).
		target_speed = 0.0
	else:
		# Airborne or spooling up: idle baseline, scales with altitude.
		var altitude_t: float = clamp(global_position.y / max_altitude, 0.0, 1.0)
		target_speed = idle_rotor_speed_rad_per_sec + \
			(max_rotor_speed_rad_per_sec - idle_rotor_speed_rad_per_sec) * altitude_t

	_current_rotor_speed = lerpf(_current_rotor_speed, target_speed, rotor_spool_speed * delta)

	if _main_rotor:
		_main_rotor.rotate_object_local(main_rotor_axis, _current_rotor_speed * delta)
	if _tail_rotor:
		_tail_rotor.rotate_object_local(tail_rotor_axis, _current_rotor_speed * delta)


## Recursive depth-first search for a node with [param target_name].
func _find_descendant_by_name(root: Node, target_name: String) -> Node:
	if root.name == target_name:
		return root
	for child in root.get_children():
		var found: Node = _find_descendant_by_name(child, target_name)
		if found:
			return found
	return null
