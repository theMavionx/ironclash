class_name ChaseCamera
extends Camera3D

## Orbital third-person camera. Follows [member target_path]'s position but
## orbits around it based on [member yaw_source_path]'s Y rotation. For a tank,
## yaw_source = the turret, so moving the mouse rotates the turret AND the
## camera together (the view is always behind where the gun points). The hull
## steers independently underneath.
## Runs in physics tick to stay in sync with CharacterBody3D.

@export_node_path("Node3D") var target_path: NodePath
## Node whose world-space Y rotation drives the camera's orbit direction.
## Typically the tank turret. If not set, falls back to [member target_path].
@export_node_path("Node3D") var yaw_source_path: NodePath
## Offset from target in the yaw source's (rotated) local frame.
## Positive X = behind, positive Y = above.
@export var offset: Vector3 = Vector3(2.5, 2.2, 0.0)
@export var look_offset: Vector3 = Vector3(0.0, 1.3, 0.0)
## How much the camera look-target shifts vertically per radian of barrel pitch.
## Higher = camera tilts more dramatically with aim. 0 = camera ignores pitch.
@export var pitch_look_scale: float = 3.0
## When true, pitch rotates the view direction as an angle instead of only
## shifting the look target. Useful for high/far vehicle cameras like heli.
@export var use_angular_pitch: bool = false
@export var pitch_angle_scale: float = 1.0
## Flip sign if mouse-up ends up looking DOWN instead of UP.
@export var invert_aim_pitch: bool = true

@export_group("Manual Orbit (Arrow Keys)")
## Speed in radians per second the camera orbits around the target when the
## user holds the arrow keys. Useful to look at the front/sides of the vehicle.
@export var arrow_orbit_speed: float = 2.0
## How fast the manual orbit decays back to zero after arrows are released.
## 0 = sticky (keeps orbit offset), larger = snaps back to default view.
@export var arrow_orbit_decay: float = 0.0

var _target: Node3D
var _yaw_source: Node3D
## Extra yaw added to camera orbit from arrow key input.
var _manual_yaw: float = 0.0


func _ready() -> void:
	_resolve_targets()
	_update_camera()


func rebind(
	new_target_path: NodePath,
	new_yaw_source_path: NodePath,
	new_offset: Vector3,
	new_look_offset: Vector3,
	reset_manual_orbit: bool = true,
	new_use_angular_pitch: bool = false,
	new_pitch_angle_scale: float = 1.0,
	new_pitch_look_scale: float = NAN
) -> void:
	target_path = new_target_path
	yaw_source_path = new_yaw_source_path
	offset = new_offset
	look_offset = new_look_offset
	use_angular_pitch = new_use_angular_pitch
	pitch_angle_scale = new_pitch_angle_scale
	if not is_nan(new_pitch_look_scale):
		pitch_look_scale = new_pitch_look_scale
	if reset_manual_orbit:
		_manual_yaw = 0.0
	_resolve_targets()
	_update_camera()


func _resolve_targets() -> void:
	_target = get_node_or_null(target_path) as Node3D
	if _target == null:
		push_warning("ChaseCamera: target_path not set or not a Node3D (%s)" % target_path)
		return
	_yaw_source = get_node_or_null(yaw_source_path) as Node3D
	if _yaw_source == null:
		_yaw_source = _target


func _physics_process(delta: float) -> void:
	if _target == null:
		return
	_read_arrow_input(delta)
	_update_camera()


func _read_arrow_input(delta: float) -> void:
	var arrow_input: float = 0.0
	if Input.is_key_pressed(KEY_RIGHT):
		arrow_input += 1.0
	if Input.is_key_pressed(KEY_LEFT):
		arrow_input -= 1.0
	if arrow_input != 0.0:
		_manual_yaw -= arrow_input * arrow_orbit_speed * delta
	elif arrow_orbit_decay > 0.0:
		_manual_yaw = move_toward(_manual_yaw, 0.0, arrow_orbit_decay * delta)


func _update_camera() -> void:
	if _target == null or _yaw_source == null:
		return
	var yaw: float
	if _target and _target.has_method("get_aim_yaw"):
		yaw = _target.call("get_aim_yaw")
	else:
		yaw = _yaw_source.global_rotation.y
	# Add manual orbit offset from arrow keys (accumulated).
	yaw += _manual_yaw
	# Camera stays on a fixed yaw-rotated offset around the target.
	var yaw_rot: Basis = Basis(Vector3.UP, yaw)
	global_position = _target.global_position + yaw_rot * offset

	# Tilt the view by shifting the look target vertically with barrel pitch.
	# Target stays roughly centered on screen; view tilts up/down with aim.
	var pitch: float = 0.0
	if _target and _target.has_method("get_aim_pitch"):
		pitch = _target.call("get_aim_pitch")
	if invert_aim_pitch:
		pitch = -pitch
	var base_look_target: Vector3 = _target.global_position + look_offset
	if use_angular_pitch:
		var forward: Vector3 = base_look_target - global_position
		if forward.length_squared() > 0.0001:
			forward = forward.normalized()
			var right: Vector3 = forward.cross(Vector3.UP)
			if right.length_squared() > 0.0001:
				right = right.normalized()
				forward = forward.rotated(right, pitch * pitch_angle_scale)
				look_at(global_position + forward, Vector3.UP)
				return
	var pitch_y: float = pitch * pitch_look_scale
	look_at(base_look_target + Vector3(0.0, pitch_y, 0.0), Vector3.UP)
