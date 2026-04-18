class_name TankController
extends CharacterBody3D

## Basic tank drive controller.
## Reads forward input, moves the body, rotates wheels, scrolls tread UVs.
## Implements: design/gdd/tank_movement.md

enum ForwardAxis {
	NEG_Z,  ## -Z  (Godot default "forward" for most imported meshes)
	POS_Z,  ## +Z
	NEG_X,  ## -X
	POS_X,  ## +X
}

@export var move_speed: float = 8.0
## Scales actual body translation without affecting wheel/tread animation speed.
@export var body_speed_scale: float = 0.1
@export var wheel_radius: float = 5.25
@export var tread_scroll_multiplier: float = 0.08
@export var wheel_rotation_axis: Vector3 = Vector3.BACK
## Which local axis points toward the front of the tank mesh.
## Change this in the Inspector if the tank drives backwards or sideways.
@export var forward_axis: ForwardAxis = ForwardAxis.NEG_Z
@export var tread_texture: Texture2D
## When true, wheels and treads animate but the body does not translate.
## Useful for visually tuning wheel/tread rotation without driving off.
@export var movement_locked: bool = false

@export_group("Steering")
## Maximum rotation speed of the hull in radians per second.
@export var turn_speed: float = 0.45
## How quickly the steering input ramps up/down. Lower = smoother start/stop.
@export var turn_acceleration: float = 4.0

@export_group("Aiming")
## Turret mesh — aimed by mouse (world-space yaw).
@export_node_path("Node3D") var turret_path: NodePath
## Barrel mesh — follows turret yaw, pitches with mouse Y.
@export_node_path("Node3D") var barrel_path: NodePath
## Radians per screen pixel of mouse motion.
@export var mouse_sensitivity: float = 0.00255
@export var min_pitch_deg: float = -10.0
@export var max_pitch_deg: float = 30.0
## Flip vertical mouse direction for barrel pitch.
@export var invert_pitch: bool = false

@onready var _model: Node3D = $Model

var _wheels_left: Array[Node3D] = []
var _wheels_right: Array[Node3D] = []
var _tread_material_left: ShaderMaterial
var _tread_material_right: ShaderMaterial
var _tread_uv_offset: float = 0.0

var _turret: Node3D
var _barrel: Node3D
var _initial_turret_basis: Basis = Basis.IDENTITY
var _barrel_relative_to_turret: Basis = Basis.IDENTITY
var _yaw_delta: float = 0.0
var _pitch_delta: float = 0.0
var _hull_yaw: float = 0.0

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)


func _ready() -> void:
	_collect_wheels()
	_setup_tread_materials()
	_hull_yaw = rotation.y
	# Defer by a frame so Skeleton3D has fully resolved bone transforms
	# before we snapshot the meshes' world bases.
	call_deferred("_capture_turret_and_barrel")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _capture_turret_and_barrel() -> void:
	_turret = get_node_or_null(turret_path) as Node3D
	_barrel = get_node_or_null(barrel_path) as Node3D
	if _turret:
		_initial_turret_basis = _turret.global_basis
	if _turret and _barrel:
		# Barrel's rotation relative to the turret at startup — preserved so
		# the barrel stays attached to the turret regardless of yaw.
		_barrel_relative_to_turret = _initial_turret_basis.inverse() * _barrel.global_basis


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		_yaw_delta -= motion.relative.x * mouse_sensitivity
		var pitch_sign: float = -1.0 if invert_pitch else 1.0
		_pitch_delta = clamp(
			_pitch_delta - motion.relative.y * mouse_sensitivity * pitch_sign,
			deg_to_rad(min_pitch_deg),
			deg_to_rad(max_pitch_deg)
		)
	elif event is InputEventKey:
		var key_event: InputEventKey = event
		if key_event.pressed and key_event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif key_event.pressed and key_event.keycode == KEY_F1:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _collect_wheels() -> void:
	for i in range(1, 8):
		var left: Node3D = _model.get_node_or_null("WheelLeft%d" % i) as Node3D
		var right: Node3D = _model.get_node_or_null("WheelRight%d" % i) as Node3D
		if left:
			_wheels_left.append(left)
		if right:
			_wheels_right.append(right)


func _setup_tread_materials() -> void:
	var shader: Shader = load("res://src/gameplay/tank/tread_scroll.gdshader") as Shader
	if shader == null:
		push_warning("TankController: tread shader missing")
		return
	_tread_material_left = _build_tread_material(shader)
	_tread_material_right = _build_tread_material(shader)
	_apply_material_to_first_mesh_under("TreadLeft", _tread_material_left)
	_apply_material_to_first_mesh_under("TreadRight", _tread_material_right)


func _build_tread_material(shader: Shader) -> ShaderMaterial:
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	if tread_texture:
		mat.set_shader_parameter("albedo_texture", tread_texture)
	return mat


## Finds a descendant node by [param container_name] anywhere under the model,
## then applies [param material] to the first [MeshInstance3D] descendant of it.
func _apply_material_to_first_mesh_under(container_name: String, material: ShaderMaterial) -> void:
	var container: Node = _find_descendant_by_name(_model, container_name)
	if container == null:
		push_warning("TankController: tread container '%s' not found under Model" % container_name)
		return
	var mesh: MeshInstance3D = _find_first_mesh(container)
	if mesh == null:
		push_warning("TankController: no MeshInstance3D under %s" % container.get_path())
		return
	mesh.material_override = material


func _find_descendant_by_name(root: Node, target_name: String) -> Node:
	if root.name == target_name:
		return root
	for child in root.get_children():
		var found: Node = _find_descendant_by_name(child, target_name)
		if found:
			return found
	return null


func _find_first_mesh(root: Node) -> MeshInstance3D:
	if root is MeshInstance3D:
		return root
	for child in root.get_children():
		var found: MeshInstance3D = _find_first_mesh(child)
		if found:
			return found
	return null


func _physics_process(delta: float) -> void:
	var input_forward: float = Input.get_action_strength("move_forward")
	if Input.is_key_pressed(KEY_S):
		input_forward -= 1.0
	var desired_speed: float = input_forward * move_speed

	var turn_input: float = 0.0
	if Input.is_key_pressed(KEY_D):
		turn_input += 1.0
	if Input.is_key_pressed(KEY_A):
		turn_input -= 1.0

	if movement_locked:
		velocity.x = 0.0
		velocity.z = 0.0
	else:
		if absf(turn_input) > 0.001:
			_hull_yaw -= turn_input * turn_speed * delta
			rotation.y = _hull_yaw
		var forward: Vector3 = _get_forward_vector()
		var body_speed: float = desired_speed * body_speed_scale
		velocity.x = forward.x * body_speed
		velocity.z = forward.z * body_speed

	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = 0.0

	move_and_slide()

	# Apply yaw only — barrel inherits turret yaw via stored relative offset.
	# Pitch disabled temporarily until we confirm yaw alignment works with
	# the skeleton-parented meshes.
	var yaw_rot: Basis = Basis(Vector3.UP, _yaw_delta)
	var turret_world_basis: Basis = yaw_rot * _initial_turret_basis
	if _turret:
		_turret.global_basis = turret_world_basis
	if _barrel:
		_barrel.global_basis = turret_world_basis * _barrel_relative_to_turret

	_animate_wheels(desired_speed, delta)
	_animate_treads(desired_speed, delta)


## Returns the world-space forward vector for the currently selected ForwardAxis.
func _get_forward_vector() -> Vector3:
	match forward_axis:
		ForwardAxis.NEG_Z:
			return -global_transform.basis.z
		ForwardAxis.POS_Z:
			return global_transform.basis.z
		ForwardAxis.NEG_X:
			return -global_transform.basis.x
		ForwardAxis.POS_X:
			return global_transform.basis.x
	return -global_transform.basis.z


func _animate_wheels(linear_speed: float, delta: float) -> void:
	if wheel_radius <= 0.0:
		return
	var rotation_delta: float = (linear_speed / wheel_radius) * delta
	for wheel in _wheels_left:
		wheel.rotate_object_local(wheel_rotation_axis, rotation_delta)
	for wheel in _wheels_right:
		wheel.rotate_object_local(wheel_rotation_axis, rotation_delta)


func _animate_treads(linear_speed: float, delta: float) -> void:
	_tread_uv_offset += linear_speed * tread_scroll_multiplier * delta
	if _tread_material_left:
		_tread_material_left.set_shader_parameter("uv_offset", _tread_uv_offset)
	if _tread_material_right:
		_tread_material_right.set_shader_parameter("uv_offset", _tread_uv_offset)
