class_name TankController
extends CharacterBody3D

## Basic tank drive controller.
## Reads forward/turn input, moves the body, rotates wheels, scrolls tread UVs,
## aims turret and barrel with the mouse, and fires shells on left-click.
## Implements: design/gdd/tank_movement.md

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const WHEEL_COUNT: int = 7

# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

enum ForwardAxis {
	NEG_Z,  ## -Z  (Godot default "forward" for most imported meshes)
	POS_Z,  ## +Z
	NEG_X,  ## -X
	POS_X,  ## +X
}

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted each time the tank fires a shell.
signal fired

# ---------------------------------------------------------------------------
# Exports — movement
# ---------------------------------------------------------------------------

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
## Turret mesh — visual reference only (used for camera yaw_source).
@export_node_path("Node3D") var turret_path: NodePath
## Barrel mesh — visual reference only.
@export_node_path("Node3D") var barrel_path: NodePath
## Skeleton3D that rigs the tank (hull/turret/barrel bones). Bone-based aim
## makes rotation pivot around the real hinges (hull -> turret -> barrel).
@export_node_path("Skeleton3D") var skeleton_path: NodePath = NodePath("Model/Armature/Skeleton3D")
@export var turret_bone_name: String = "Bone.001"
@export var barrel_bone_name: String = "Bone.002"
## Axis (in bone-local space) around which the turret yaws.
## Default RIGHT matches Blender bones whose local X maps to world Y.
@export var turret_bone_axis: Vector3 = Vector3.RIGHT
## Axis (in bone-local space) around which the barrel pitches.
@export var barrel_bone_axis: Vector3 = Vector3.DOWN
## Radians per screen pixel of mouse motion.
@export var mouse_sensitivity: float = 0.00255
@export var min_pitch_deg: float = -70.0
@export var max_pitch_deg: float = 10.0
## Flip vertical mouse direction for barrel pitch.
@export var invert_pitch: bool = true

@export_group("Firing")
## Scene spawned when firing (left click). Spawns at the barrel muzzle.
@export var shell_scene: PackedScene = preload("res://scenes/projectile/tank_shell.tscn")
## Optional muzzle-flash sprite played at the barrel tip on each shot.
@export var muzzle_flash_scene: PackedScene = preload("res://scenes/projectile/muzzle_flash.tscn")
## Extra world-space offset applied to the muzzle flash only (not the shell).
## Use to nudge the flash down/up to the visual barrel centreline.
@export var muzzle_flash_extra_offset: Vector3 = Vector3(0.0, -0.6, 0.0)
## Position for the muzzle flash in BARREL-local space. Keep closer to the
## barrel bone than the shell spawn (shell flies out, flash stays at the muzzle).
@export var muzzle_flash_local_offset: Vector3 = Vector3(0.0, 3.6, 0.0)
## Cooldown between shots in seconds.
@export var fire_cooldown: float = 0.4
## Muzzle position in the BARREL BONE's local frame. For this model the bone's
## local +Y points out the muzzle, so the muzzle tip is at (0, 3, 0).
## Tweak in Inspector if shell spawns off-muzzle.
@export var muzzle_local_offset: Vector3 = Vector3(0.0, 4.2, 0.0)
## Direction the muzzle points in the BARREL BONE's local frame.
## For Blender-exported rigs the bone's +Y often runs along its length.
@export var muzzle_local_forward: Vector3 = Vector3(0.0, 1.0, 0.0)

# ---------------------------------------------------------------------------
# Private variables
# ---------------------------------------------------------------------------

@onready var _model: Node3D = $Model
@onready var _health: HealthComponent = $HealthComponent

var _is_destroyed: bool = false

var _wheels_left: Array[Node3D] = []
var _wheels_right: Array[Node3D] = []
var _tread_material_left: ShaderMaterial
var _tread_material_right: ShaderMaterial
var _tread_uv_offset: float = 0.0

var _turret: Node3D
var _barrel: Node3D
var _skeleton: Skeleton3D
var _turret_bone: int = -1
var _barrel_bone: int = -1
var _yaw_delta: float = 0.0
var _pitch_delta: float = 0.0
var _hull_yaw: float = 0.0
var _current_turn_rate: float = 0.0

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _active: bool = true
var _fire_timer: float = 0.0
## Flag set by _unhandled_input, consumed at end of _physics_process so the
## shot uses the bone pose written THIS frame (not the stale previous-frame pose).
var _fire_requested: bool = false

# ---------------------------------------------------------------------------
# Public methods
# ---------------------------------------------------------------------------

## Returns the barrel's current pitch angle in radians. Read by ChaseCamera
## so the view tilts up/down with aim.
func get_aim_pitch() -> float:
	return _pitch_delta


## Returns the turret's absolute world yaw. Since the bone pose compensates
## for hull rotation, the turret's world yaw equals [member _yaw_delta].
func get_aim_yaw() -> float:
	return _yaw_delta


## Enable or disable this vehicle.
## Inactive vehicles halt physics processing and zero out velocity.
## Reactivating recaptures mouse input automatically.
func set_active(is_active: bool) -> void:
	_active = is_active
	set_physics_process(is_active)
	if not is_active:
		velocity = Vector3.ZERO
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

# ---------------------------------------------------------------------------
# Built-in virtual methods
# ---------------------------------------------------------------------------

func _ready() -> void:
	_collect_wheels()
	_setup_tread_materials()
	_hull_yaw = rotation.y
	# Start turret aimed where the hull is facing.
	_yaw_delta = _hull_yaw
	# Defer by a frame so Skeleton3D has fully resolved bone transforms
	# before we snapshot the meshes' world bases.
	call_deferred("_capture_turret_and_barrel")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _health != null:
		_health.destroyed.connect(_on_destroyed)


func _on_destroyed(_by_source: int) -> void:
	_is_destroyed = true
	set_physics_process(false)
	velocity = Vector3.ZERO
	DestructionVFX.apply_charred(self)
	DestructionVFX.spawn_smoke_fire(self, 1.2)


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		_yaw_delta -= motion.relative.x * mouse_sensitivity
		var pitch_sign: float = -1.0 if invert_pitch else 1.0
		_pitch_delta = clamp(
			_pitch_delta - motion.relative.y * mouse_sensitivity * pitch_sign,
			deg_to_rad(min_pitch_deg),
			deg_to_rad(max_pitch_deg)
		)
	elif event is InputEventMouseButton:
		var mouse_btn: InputEventMouseButton = event
		if mouse_btn.pressed and mouse_btn.button_index == MOUSE_BUTTON_LEFT:
			_fire_requested = true
	elif event is InputEventKey:
		var key_event: InputEventKey = event
		if key_event.pressed and key_event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif key_event.pressed and key_event.keycode == KEY_F1:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if not _active:
		return

	# Direct key reads — project.godot only has "move_forward" action mapped.
	var input_forward: float = Input.get_action_strength("move_forward")
	if Input.is_key_pressed(KEY_S):
		input_forward -= 1.0
	var turn_input: float = 0.0
	if Input.is_key_pressed(KEY_D):
		turn_input += 1.0
	if Input.is_key_pressed(KEY_A):
		turn_input -= 1.0
	var desired_speed: float = input_forward * move_speed

	if movement_locked:
		velocity.x = 0.0
		velocity.z = 0.0
	else:
		# Smooth turn rate toward target using turn_acceleration (was unused before).
		var target_turn_rate: float = turn_input * turn_speed
		_current_turn_rate = move_toward(_current_turn_rate, target_turn_rate, turn_acceleration * delta)
		if absf(_current_turn_rate) > 0.0001:
			_hull_yaw -= _current_turn_rate * delta
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

	# Decrement fire cooldown.
	if _fire_timer > 0.0:
		_fire_timer -= delta

	# Bone-driven aim: rotate the turret bone by yaw and the barrel bone by
	# pitch. Skeleton3D handles hierarchy (barrel is a child of turret) and
	# pivots (bone origins) correctly.
	if _skeleton:
		# Compensate hull yaw so the turret stays at its absolute world aim.
		# When the hull rotates via A/D, bone pose counters it so the turret
		# visually "slips" against the hull and stays aimed where the mouse points.
		var turret_local_yaw: float = _yaw_delta - _hull_yaw
		if _turret_bone != -1:
			_skeleton.set_bone_pose_rotation(_turret_bone, Quaternion(turret_bone_axis, turret_local_yaw))
		if _barrel_bone != -1:
			_skeleton.set_bone_pose_rotation(_barrel_bone, Quaternion(barrel_bone_axis, _pitch_delta))

	_animate_wheels(desired_speed, delta)
	_animate_treads(desired_speed, delta)

	# Process deferred fire request AFTER bone poses are current this frame.
	if _fire_requested:
		_fire_requested = false
		_try_fire()

# ---------------------------------------------------------------------------
# Private methods
# ---------------------------------------------------------------------------

func _capture_turret_and_barrel() -> void:
	_turret = get_node_or_null(turret_path) as Node3D
	_barrel = get_node_or_null(barrel_path) as Node3D
	_skeleton = get_node_or_null(skeleton_path) as Skeleton3D
	if _skeleton:
		_turret_bone = _skeleton.find_bone(turret_bone_name)
		_barrel_bone = _skeleton.find_bone(barrel_bone_name)
		if _turret_bone == -1:
			push_warning("TankController: turret bone '%s' not found" % turret_bone_name)
		if _barrel_bone == -1:
			push_warning("TankController: barrel bone '%s' not found" % barrel_bone_name)
	else:
		push_warning("TankController: skeleton not found at %s" % skeleton_path)


func _collect_wheels() -> void:
	for i in range(1, WHEEL_COUNT + 1):
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


func _try_fire() -> void:
	if _fire_timer > 0.0 or shell_scene == null:
		return
	if _skeleton == null or _barrel_bone == -1:
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return
	_fire_timer = fire_cooldown
	var shell: TankShell = shell_scene.instantiate() as TankShell
	var parent: Node = get_tree().current_scene
	if parent == null:
		parent = get_parent()
	# setup() MUST run before add_child so _ready wires the self-hit exception.
	shell.setup(DamageTypes.Source.TANK_SHELL, 100, self)
	parent.add_child(shell)
	# Spawn ALWAYS at the barrel's muzzle tip (barrel-local offset).
	var barrel_world: Transform3D = _skeleton.global_transform * _skeleton.get_bone_global_pose(_barrel_bone)
	shell.global_position = barrel_world * muzzle_local_offset
	# CROSSHAIR CONVERGENCE: trace a ray from the camera through screen centre
	# to find what the crosshair is pointing at, then aim the shell FROM the
	# muzzle TO that point. Otherwise the muzzle (below/behind camera) fires
	# parallel to the camera forward → shells visibly land below the crosshair
	# at short range (classic shooter parallax).
	var cam_forward: Vector3 = -camera.global_transform.basis.z
	var cam_pos: Vector3 = camera.global_position
	var target_point: Vector3 = cam_pos + cam_forward * 1000.0
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(cam_pos, target_point)
	query.exclude = [self.get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	if not hit.is_empty():
		target_point = hit.get("position", target_point)
	var aim_dir: Vector3 = (target_point - shell.global_position).normalized()
	# Avoid look_at() failing when aim is near-parallel to world up.
	var up_ref: Vector3 = Vector3.UP
	if absf(aim_dir.dot(Vector3.UP)) > 0.95:
		up_ref = Vector3.FORWARD
	shell.look_at(shell.global_position + aim_dir, up_ref)
	# Spawn muzzle flash. Orient so its local -Z = aim direction (sparks emit
	# along -Z, so they burst in the firing direction). Transform set BEFORE
	# add_child so _ready sees correct pose and particle direction is correct.
	if muzzle_flash_scene:
		var flash: Node3D = muzzle_flash_scene.instantiate() as Node3D
		# Flash position = closer to barrel than shell spawn.
		var flash_pos: Vector3 = barrel_world * muzzle_flash_local_offset + muzzle_flash_extra_offset
		var flash_xform: Transform3D = Transform3D(Basis.IDENTITY, flash_pos)
		flash_xform = flash_xform.looking_at(flash_pos + aim_dir, up_ref)
		flash.transform = flash_xform
		parent.add_child(flash)
	fired.emit()


## Tank's local forward vector in hull-local space (before world yaw).
func _get_tank_forward_local() -> Vector3:
	match forward_axis:
		ForwardAxis.NEG_Z:
			return Vector3(0, 0, -1)
		ForwardAxis.POS_Z:
			return Vector3(0, 0, 1)
		ForwardAxis.NEG_X:
			return Vector3(-1, 0, 0)
		ForwardAxis.POS_X:
			return Vector3(1, 0, 0)
	return Vector3(0, 0, -1)


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
