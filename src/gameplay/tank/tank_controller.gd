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
## Same as [signal fired] but carries the spawn pose so network sync can
## replicate the shell on remote clients without re-running the camera ray.
signal fired_with_aim(spawn_origin: Vector3, aim_dir: Vector3)

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

@export_group("Tread Marks")
## Spawn black decal stripes under the tracks as the tank drives.
@export var tread_marks_enabled: bool = true
## Distance (m) the tank must travel between consecutive mark pairs. Lower = denser trail.
@export var tread_mark_spacing: float = 0.5
## Width (m) of one mark — lateral size across the track.
@export var tread_mark_width: float = 0.22
## Length (m) of one mark — along travel direction. Should be ≥ spacing for a continuous trail.
@export var tread_mark_length: float = 1.4
## Vertical projection range (m). Larger = the decal still hits ground on bumpy terrain.
@export var tread_mark_height: float = 1.0
## Distance (m) between left and right tread centerlines (gauge).
## Set to 0 to auto-derive from average WheelLeft/WheelRight X positions.
@export var tread_mark_gauge: float = 0.0
## Local Z offset (m) of the spawn point. Default 0 = under tank center; negative = forward.
@export var tread_mark_z_offset: float = 0.0
## Seconds before a mark fades out and is freed.
@export var tread_mark_lifetime: float = 5.0
## Starting opacity of a mark (0..1). Lower = lighter / more translucent track.
@export_range(0.0, 1.0) var tread_mark_initial_alpha: float = 0.5
## Hard cap on simultaneously alive marks. Older marks are freed FIFO when exceeded.
@export var tread_mark_max_alive: int = 240

@export_group("Cook-Off (Turret Debris)")
## Mass of the detached turret RigidBody3D (kg). Still applied so the physics
## material + damping feel right, but launch velocity is set directly.
@export var cook_off_mass: float = 500.0
## Initial upward VELOCITY in m/s. 12 m/s → ~7m apex (v²/2g).
@export var cook_off_upward_velocity: float = 12.0
## Max horizontal drift velocity in m/s. Random ±value per axis.
@export var cook_off_horizontal_drift: float = 1.5
## Tumble angular velocity magnitude in rad/s (chaotic mid-air rotation).
@export var cook_off_tumble_velocity: float = 6.0
## Seconds before the turret wreck despawns. 0 = match wreck_burn_seconds.
@export var cook_off_lifetime: float = 0.0

@export_group("Destroyed Wreck")
## Seconds the destroyed tank smokes before the wreck, smoke, and debris disappear.
@export var wreck_burn_seconds: float = 20.0

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
var _spawn_collision_layer: int = 0
var _spawn_collision_mask: int = 0
## Flag set by _unhandled_input, consumed at end of _physics_process so the
## shot uses the bone pose written THIS frame (not the stale previous-frame pose).
var _fire_requested: bool = false

## Distance accumulator since last mark pair was spawned (m, horizontal only).
var _tread_distance_acc: float = 0.0
## Tank's horizontal position last physics tick — diff drives the accumulator.
var _last_tread_pos: Vector3 = Vector3.ZERO
## FIFO of currently-alive tread mark nodes (oldest first). Holds Decal on
## desktop / Forward+ / Mobile and MeshInstance3D quads on web (Compatibility
## renderer doesn't support Decals — they silently render nothing).
var _tread_decals: Array[Node3D] = []
## Cached at _ready: web platform uses MeshInstance3D quads, others use Decals.
static var _USE_DECALS: bool = not OS.has_feature("web")
## Black flat-shaded material shared by all web-fallback tread quads. Built
## once on first spawn so we don't allocate one per mark.
static var _tread_quad_material: StandardMaterial3D = null
## PlaneMesh resource shared by all web-fallback tread marks (horizontal — FACE_Y).
static var _tread_quad_mesh: PlaneMesh = null
## Resolved gauge in meters — either tread_mark_gauge (if > 0) or auto-derived
## from wheel positions one frame after _ready. Decals are spawned at ±half this
## value laterally. Default 1.0 m matches the current StylizedTank model; used
## as fallback when auto-derive fails (e.g. bone-driven wheels at Node3D origin).
var _resolved_tread_gauge: float = 1.0
## Tiny white texture used by all decals; tinted to black via modulate.
## Static so all tanks share one texture (decal projects nothing without a texture).
static var _tread_decal_texture: Texture2D = null

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


## Called by VehicleSync for remote drivers. The server sends absolute turret
## yaw plus barrel pitch; this controller converts it back to local bone poses.
func set_remote_aim(aim_yaw: float, aim_pitch: float) -> void:
	if _active or _is_destroyed:
		return
	_yaw_delta = aim_yaw
	_pitch_delta = clampf(aim_pitch, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))
	_hull_yaw = rotation.y
	_apply_aim_pose()


## Enable or disable this vehicle.
## Inactive vehicles halt physics processing and zero out velocity.
## Reactivating recaptures mouse input automatically.
##
## On the inactive→active edge we ALSO re-sync our cached yaw values to
## whatever `rotation.y` currently is. While inactive, vehicle_sync.gd lerps
## the tank's body toward the server snapshot — meaning `rotation.y` may have
## drifted since [_ready] populated `_hull_yaw`. If we don't refresh, the
## first physics frame applies a stale `turret_local_yaw = _yaw_delta -
## _hull_yaw` delta against the WRONG hull base, the turret bone visually
## skews, and ChaseCamera (which reads `_yaw_delta` via [get_aim_yaw])
## positions itself rotated relative to the actual hull facing. That was the
## intermittent "camera ends up to the side of the tank" bug.
func set_active(is_active: bool) -> void:
	if is_active and not _active and not _is_destroyed:
		_hull_yaw = rotation.y
		_yaw_delta = _hull_yaw
	_active = is_active
	if _is_destroyed:
		set_physics_process(false)
		velocity = Vector3.ZERO
		return
	set_physics_process(is_active)
	if not is_active:
		velocity = Vector3.ZERO
	else:
		WebPointerLock.capture_for_activation()


func is_locally_driven() -> bool:
	return _active and not _is_destroyed


func apply_network_destroyed() -> void:
	if _is_destroyed:
		return
	_mark_health_destroyed_no_signal()
	_on_destroyed(DamageTypes.Source.TANK_SHELL)


func apply_network_respawned() -> void:
	visible = true
	collision_layer = _spawn_collision_layer
	collision_mask = _spawn_collision_mask
	_is_destroyed = false
	velocity = Vector3.ZERO
	if _health != null:
		_health.reset()
	if _turret is MeshInstance3D:
		(_turret as MeshInstance3D).visible = true
	if _barrel is MeshInstance3D:
		(_barrel as MeshInstance3D).visible = true
	DestructionVFX.clear_charred(self)
	DestructionVFX.clear_vfx(self)
	set_physics_process(_active)


func _mark_health_destroyed_no_signal() -> void:
	if _health != null and _health.has_method("force_destroyed"):
		_health.call("force_destroyed", DamageTypes.Source.TANK_SHELL, false)

# ---------------------------------------------------------------------------
# Built-in virtual methods
# ---------------------------------------------------------------------------

func _ready() -> void:
	_spawn_collision_layer = collision_layer
	_spawn_collision_mask = collision_mask
	_collect_wheels()
	_setup_tread_materials()
	_hull_yaw = rotation.y
	# Start turret aimed where the hull is facing.
	_yaw_delta = _hull_yaw
	# Defer by a frame so Skeleton3D has fully resolved bone transforms
	# before we snapshot the meshes' world bases.
	call_deferred("_capture_turret_and_barrel")
	WebPointerLock.capture_for_activation()
	if _health != null:
		_health.destroyed.connect(_on_destroyed)
	_last_tread_pos = global_position
	if _tread_decal_texture == null:
		_tread_decal_texture = _build_white_texture()
	# Defer gauge resolution so the Skeleton3D has already pushed bone transforms
	# into bone-driven wheel meshes — otherwise their global_position would still
	# be at the tank origin and auto-derive returns ~0.
	call_deferred("_resolve_tread_gauge")


func _on_destroyed(_by_source: int) -> void:
	if _is_destroyed:
		return
	_is_destroyed = true
	set_physics_process(false)
	velocity = Vector3.ZERO
	DestructionVFX.spawn_explosion(get_tree().current_scene, global_position + Vector3(0, 1.2, 0))
	DestructionVFX.apply_charred(self)
	DestructionVFX.spawn_smoke_fire(self, 1.2, true, wreck_burn_seconds)
	_spawn_cook_off_debris()
	_schedule_wreck_hide()


## Detach turret+barrel as a free-flying RigidBody3D wreck — "cook-off"
## effect when the tank's ammunition detonates. The WHOLE Model subtree is
## duplicated onto the RigidBody3D (hull/wheels hidden), so the skeleton +
## skin bindings stay intact — this is the only way skinned meshes render
## in Godot 4.3 without a live skeleton.
func _spawn_cook_off_debris() -> void:
	if _skeleton == null or _turret_bone == -1 or _barrel_bone == -1:
		push_warning("TankController: skeleton/bones missing, skipping cook-off")
		return
	var debris_lifetime: float = cook_off_lifetime
	if debris_lifetime <= 0.0:
		debris_lifetime = wreck_burn_seconds
	# Capture current bone rotations to freeze on the debris skeleton.
	var turret_pose: Quaternion = _skeleton.get_bone_pose_rotation(_turret_bone)
	var barrel_pose: Quaternion = _skeleton.get_bone_pose_rotation(_barrel_bone)
	# Spawn the RigidBody AT the turret bone's world pose — this way the
	# rigidbody's rotation pivot matches the visible turret, so it tumbles
	# around its own centre instead of swinging in an arc (which was causing
	# the turret to dip below ground during rotation).
	var turret_bone_local: Transform3D = _skeleton.get_bone_global_pose(_turret_bone)
	var spawn_world: Transform3D = _skeleton.global_transform * turret_bone_local
	var world_root: Node = get_tree().current_scene
	if world_root == null:
		world_root = get_parent()
	# Keep only the turret + barrel meshes on the debris. The bone mesh names
	# come from the existing turret/barrel NodePaths (last path element).
	var keep_names: PackedStringArray = PackedStringArray([
		turret_path.get_name(turret_path.get_name_count() - 1),
		barrel_path.get_name(barrel_path.get_name_count() - 1),
	])
	DestructionVFX.spawn_turret_debris(
		world_root,
		_model,
		_turret_bone,
		_barrel_bone,
		turret_pose,
		barrel_pose,
		spawn_world,
		turret_bone_local,
		keep_names,
		cook_off_mass,
		cook_off_upward_velocity,
		cook_off_horizontal_drift,
		cook_off_tumble_velocity,
		debris_lifetime
	)
	# Hide originals on the live hull so there's no "double turret".
	if _turret is MeshInstance3D:
		(_turret as MeshInstance3D).visible = false
	if _barrel is MeshInstance3D:
		(_barrel as MeshInstance3D).visible = false


func _schedule_wreck_hide() -> void:
	if wreck_burn_seconds <= 0.0:
		return
	get_tree().create_timer(wreck_burn_seconds).timeout.connect(_hide_destroyed_wreck)


func _hide_destroyed_wreck() -> void:
	if not _is_destroyed:
		return
	DestructionVFX.clear_vfx(self)
	DestructionVFX.clear_charred(self)
	velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	visible = false
	set_physics_process(false)


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseMotion:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			return
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
			if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
				WebPointerLock.capture_from_user_gesture()
				return
			_fire_requested = true
	elif event is InputEventKey:
		var key_event: InputEventKey = event
		if key_event.pressed and key_event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif key_event.pressed and key_event.keycode == KEY_F1:
			WebPointerLock.capture_from_user_gesture()


## Always-on tick for visuals that should keep working when a remote peer is
## driving this tank (our `_physics_process` is suspended in that case).
## Tread marks are position-driven, so calling `_update_tread_marks` while
## VehicleSync lerps the body works without any extra plumbing.
func _process(_delta: float) -> void:
	if _active or _is_destroyed:
		return
	_update_tread_marks()


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

	_update_tread_marks()

	# Decrement fire cooldown.
	if _fire_timer > 0.0:
		_fire_timer -= delta

	_apply_aim_pose()

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
	_apply_aim_pose()


func _apply_aim_pose() -> void:
	# Bone-driven aim: rotate the turret bone by yaw and the barrel bone by
	# pitch. Skeleton3D handles hierarchy (barrel is a child of turret) and
	# pivots (bone origins) correctly.
	if _skeleton == null:
		return
	# Compensate hull yaw so the turret stays at its absolute world aim.
	# When the hull rotates via A/D, bone pose counters it so the turret
	# visually "slips" against the hull and stays aimed where the mouse points.
	var turret_local_yaw: float = _yaw_delta - _hull_yaw
	if _turret_bone != -1:
		_skeleton.set_bone_pose_rotation(_turret_bone, Quaternion(turret_bone_axis, turret_local_yaw))
	if _barrel_bone != -1:
		_skeleton.set_bone_pose_rotation(_barrel_bone, Quaternion(barrel_bone_axis, _pitch_delta))


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
	# Server is authoritative for this shot — local impact sends a hit-claim
	# packet instead of mutating HP. Solo play (no NetworkManager autoload)
	# falls back to local damage automatically inside the shell.
	if shell.has_method("setup_network"):
		shell.call("setup_network", "tank_shell", false)
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
	fired_with_aim.emit(shell.global_position, aim_dir)


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


# ---------------------------------------------------------------------------
# Tread Marks (ground decals)
# ---------------------------------------------------------------------------

## Track horizontal distance traveled and spawn a pair of black decals
## (left + right tracks) every [member tread_mark_spacing] meters. Skips
## while airborne so no marks float over jumps.
func _update_tread_marks() -> void:
	if not tread_marks_enabled or _is_destroyed:
		return
	if not is_on_floor():
		_last_tread_pos = global_position
		return
	var moved: Vector3 = global_position - _last_tread_pos
	moved.y = 0.0
	var step: float = moved.length()
	_last_tread_pos = global_position
	if step <= 0.0001:
		return
	_tread_distance_acc += step
	while _tread_distance_acc >= tread_mark_spacing:
		_tread_distance_acc -= tread_mark_spacing
		_spawn_tread_mark_pair()


func _spawn_tread_mark_pair() -> void:
	# Build a basis whose local Z-axis aligns with the tank's actual forward
	# direction in world space. We can't just use Basis(UP, _hull_yaw) because
	# the tank exposes `forward_axis` (the model's forward could be -Z, +Z, ±X);
	# only `_get_forward_vector()` knows the truth. The decal's size.z extent
	# spans both ±Z so direction (toward/away) doesn't matter — only the AXIS does.
	var forward: Vector3 = _get_forward_vector()
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return
	forward = forward.normalized()
	# Basis.looking_at points -Z at the target; size.z still spans the travel axis.
	var basis: Basis = Basis.looking_at(forward, Vector3.UP)
	var half_gauge: float = _resolved_tread_gauge * 0.5
	var left_local: Vector3 = Vector3(-half_gauge, 0.0, tread_mark_z_offset)
	var right_local: Vector3 = Vector3(half_gauge, 0.0, tread_mark_z_offset)
	_create_tread_decal(global_position + basis * left_local, basis)
	_create_tread_decal(global_position + basis * right_local, basis)


## Resolve the lateral spacing of tread marks. Honors `tread_mark_gauge` when
## the user set it explicitly (> 0), else auto-derives from the average lateral
## offset of WheelLeft / WheelRight nodes — so the tracks fall under the visible
## treads regardless of which tank model is loaded.
##
## Uses [code]global_position[/code] transformed back to tank-local space so
## bone-driven wheels (Node3D.position == origin, real offset baked into the
## skeleton) report their correct lateral offset. Falls back to the default
## [member _resolved_tread_gauge] if the derived value is implausibly small.
func _resolve_tread_gauge() -> void:
	if tread_mark_gauge > 0.0:
		_resolved_tread_gauge = tread_mark_gauge
		return
	if _wheels_left.is_empty() or _wheels_right.is_empty():
		return
	var inv: Transform3D = global_transform.affine_inverse()
	var sum_left: float = 0.0
	for w: Node3D in _wheels_left:
		sum_left += (inv * w.global_position).x
	var sum_right: float = 0.0
	for w: Node3D in _wheels_right:
		sum_right += (inv * w.global_position).x
	var avg_left: float = sum_left / _wheels_left.size()
	var avg_right: float = sum_right / _wheels_right.size()
	var derived: float = absf(avg_left - avg_right)
	# Sanity floor — bone-driven wheels in some rigs still report 0 if the
	# skeleton hasn't run a frame yet, or if wheels are nested under a
	# transform we can't see. Keep the safe default in that case.
	if derived >= 0.3:
		_resolved_tread_gauge = derived


func _create_tread_decal(world_pos: Vector3, yaw_basis: Basis) -> void:
	var parent: Node = get_tree().current_scene
	if parent == null:
		return
	var node: Node3D
	if _USE_DECALS:
		var decal: Decal = Decal.new()
		decal.texture_albedo = _tread_decal_texture
		decal.modulate = Color(0.0, 0.0, 0.0, tread_mark_initial_alpha)
		decal.size = Vector3(tread_mark_width, tread_mark_height, tread_mark_length)
		# Soften the lateral edges so adjacent marks blend instead of stamping rectangles.
		decal.upper_fade = 0.3
		decal.lower_fade = 0.3
		node = decal
	else:
		# Web fallback: a flat black quad laid on the ground. Shares one Mesh,
		# but each mark gets its own override material so it can fade alpha
		# independently of its neighbours.
		node = _build_tread_quad()
	parent.add_child(node)
	node.global_position = world_pos + Vector3(0.0, 0.02, 0.0)
	node.global_basis = yaw_basis
	_tread_decals.push_back(node)
	# Enforce FIFO cap — kill oldest immediately when over the limit.
	while _tread_decals.size() > tread_mark_max_alive:
		var oldest: Node3D = _tread_decals.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()
	# Fade out over lifetime, then free. Tween bound to SceneTree so it survives
	# tank destruction (mark still fades cleanly after a cook-off).
	var tween: Tween = get_tree().create_tween()
	if _USE_DECALS:
		tween.tween_property(node, "modulate:a", 0.0, tread_mark_lifetime)
	else:
		# Animate the per-mark material's albedo alpha. Material was built with
		# TRANSPARENCY_ALPHA already so the tween value reaches the rasterizer.
		var mi: MeshInstance3D = node as MeshInstance3D
		var mat: StandardMaterial3D = mi.get_surface_override_material(0) as StandardMaterial3D
		if mat != null:
			tween.tween_property(mat, "albedo_color:a", 0.0, tread_mark_lifetime)
	tween.tween_callback(func() -> void:
		if is_instance_valid(node):
			_tread_decals.erase(node)
			node.queue_free()
	)


## Build a flat horizontal PlaneMesh for the web tread-mark fallback. Uses
## a unique material per mark so we can independently fade each one's alpha
## without affecting siblings. Mesh resource itself is shared.
func _build_tread_quad() -> MeshInstance3D:
	if _tread_quad_mesh == null:
		# PlaneMesh sits flat on XZ when orientation = FACE_Y, with normal +Y.
		# That's exactly what we want for ground decals.
		var plane: PlaneMesh = PlaneMesh.new()
		plane.size = Vector2(tread_mark_width, tread_mark_length)
		plane.orientation = PlaneMesh.FACE_Y
		_tread_quad_mesh = plane
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = _tread_quad_mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Per-mark material so each can fade independently.
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.0, 0.0, 0.0, tread_mark_initial_alpha)
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.set_surface_override_material(0, mat)
	return mi


## 4×4 fully-white texture so the Decal has something to project. We tint to
## black via [member Decal.modulate] so no PNG asset is needed.
static func _build_white_texture() -> Texture2D:
	var img: Image = Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return ImageTexture.create_from_image(img)
