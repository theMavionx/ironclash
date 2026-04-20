class_name DroneController
extends CharacterBody3D

## Emitted after the drone has been teleported back to its spawn point and
## physics is re-enabled. FPV HUD listens to clear the "DRONE OFFLINE" overlay.
signal respawned

## FPV drone controller — full Mode 2 acro flight model.
## WASD: W/S = throttle accumulator (0..1), A/D = yaw rate.
## Mouse: X = roll, Y = pitch (drone body tilts; camera is rigid-mounted).
## Tilt drives translation: thrust = (drone local UP) × throttle × max_thrust.
## Pure acro feel — no auto-leveling. Mouse stops → drone holds the angle.
## Implements: design/gdd/drone-controller.md (pending)

# ---------------------------------------------------------------------------
# Exports — Camera
# ---------------------------------------------------------------------------

## Path to the Camera3D used for the first-person view.
@export_node_path("Camera3D") var fpv_camera_path: NodePath = ^"FPVMount/FPVCamera"
## Path to the Node3D the FPV camera is parented to. Set ONCE in _ready
## to apply a static uptilt — never written at runtime (camera is rigid-mounted
## to the drone body so view tilts with the body, true FPV).
@export_node_path("Node3D") var fpv_mount_path: NodePath = ^"FPVMount"
## Static FPV camera uptilt in degrees. Real racing drones tilt the camera up
## so the pilot sees forward while flying nose-down at speed.
@export var fpv_camera_uptilt_deg: float = 30.0

# ---------------------------------------------------------------------------
# Exports — Flight: Thrust
# ---------------------------------------------------------------------------

## Peak thrust acceleration (m/s²) along the drone's local up axis.
@export var max_thrust: float = 20.0
## Throttle (0..1) at which thrust exactly counters gravity.
## Should equal gravity / max_thrust for a steady hover at this value.
@export var hover_throttle: float = 0.5
## Rate at which W/S keys change the throttle accumulator (units/s).
@export var throttle_rate: float = 1.0
## World-space gravity (m/s²). Match Project Settings physics gravity.
@export var gravity: float = 9.8

# ---------------------------------------------------------------------------
# Exports — Flight: Rotation (Mode 2 acro)
# ---------------------------------------------------------------------------

## Maximum pitch rate (degrees/s) — clamps mouse Y impulses per frame.
@export var max_pitch_rate_deg: float = 360.0
## Maximum roll rate (degrees/s) — clamps mouse X impulses per frame.
@export var max_roll_rate_deg: float = 360.0
## Maximum yaw rate (degrees/s) from A/D keys.
@export var max_yaw_rate_deg: float = 180.0
## Mouse sensitivity: degrees of body rotation per pixel of mouse motion.
@export var mouse_sensitivity_deg_per_px: float = 0.3

# ---------------------------------------------------------------------------
# Exports — Flight: Linear Damping
# ---------------------------------------------------------------------------

## Horizontal velocity drag (1/s) — drones brake noticeably without lateral thrust.
@export var horizontal_damping: float = 1.5
## Vertical velocity drag (1/s) — separate from gravity; helps hover feel.
@export var vertical_damping: float = 0.8

# ---------------------------------------------------------------------------
# Exports — Limits
# ---------------------------------------------------------------------------

## Maximum world-space Y the drone can reach (matches helicopter ceiling).
@export var max_altitude: float = 50.0

@export_group("Combat")
## Minimum impact speed (m/s) for a body collision to count as kamikaze.
## Below this, the drone bounces / slides without dealing damage.
@export var kamikaze_speed_threshold: float = 6.0
## Damage dealt to a HealthComponent on kamikaze impact (high to one-shot anything).
@export var kamikaze_damage: int = 999
## Seconds the drone is "OFFLINE" after a kamikaze detonation before respawning.
@export var respawn_delay: float = 1.5

@export_group("Rotor Animation")
## Maximum rotor angular speed at full throttle (radians/s).
@export var max_rotor_speed_rad_per_sec: float = 60.0
## Minimum rotor angular speed while armed / spooling (radians/s).
@export var idle_rotor_speed_rad_per_sec: float = 16.0
## Lerp rate at which rotor speed ramps up or down (per second).
@export var rotor_spool_speed: float = 5.0
## Local axis each propeller blade group rotates around.
@export var propeller_rotation_axis: Vector3 = Vector3.UP
## Node names of the propeller blades in MOTOR-GROUPED SEQUENTIAL order.
## Blades [0..2] = motor 1, [3..5] = motor 2, [6..8] = motor 3, [9..11] = motor 4.
@export var propeller_node_names: PackedStringArray = [
	"BezierCurve_004__0_001", "BezierCurve_004__0_002", "BezierCurve_004__0_003",
	"BezierCurve_004__0_004", "BezierCurve_004__0_005", "BezierCurve_004__0_006",
	"BezierCurve_004__0_007", "BezierCurve_004__0_008", "BezierCurve_004__0_009",
	"BezierCurve_004__0_010", "BezierCurve_004__0_011", "BezierCurve_004__0_012",
]
## How many blade meshes per motor (used to group consecutive entries).
@export var blades_per_motor: int = 3

# ---------------------------------------------------------------------------
# Private state
# ---------------------------------------------------------------------------

var _active: bool = true
## Throttle accumulator [0..1]. Persists between frames; W/S adjusts, no input holds.
var _throttle: float = 0.0
## Mouse motion accumulated across InputEventMouseMotion events between physics ticks.
## Consumed (zeroed) each _physics_process. Acro: no persistent angular velocity.
var _mouse_delta: Vector2 = Vector2.ZERO
var _fpv_camera: Camera3D = null
var _fpv_mount: Node3D = null
var _current_rotor_speed: float = 0.0
## Velocity snapshot taken BEFORE move_and_slide each physics tick — used as
## the impact speed for kamikaze detection (move_and_slide may zero velocity
## on collision, hiding the actual approach speed).
var _pre_slide_velocity: Vector3 = Vector3.ZERO
## Initial transform captured in _ready — drone respawns to this position.
var _spawn_transform: Transform3D
@onready var _health: HealthComponent = $HealthComponent
var _is_destroyed: bool = false
## Each entry: {"centroid": Vector3, "blades": Array[Dictionary]} where each
## blade dict holds {"node": Node3D, "offset": Vector3, "initial_basis": Basis}
## of its initial state in the drone's local frame.
var _motor_groups: Array[Dictionary] = []
## Accumulated rotation angle per motor (radians).
var _motor_angles: Array[float] = []

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Enable or disable this vehicle. Inactive drones halt physics and zero velocity.
## Activating recaptures mouse input and switches the FPV camera on.
func set_active(is_active: bool) -> void:
	_active = is_active
	# Destroyed wrecks keep physics running so they fall under gravity until
	# the respawn timer fires.
	if _is_destroyed:
		set_physics_process(true)
		if _fpv_camera != null:
			_fpv_camera.current = is_active
		return
	set_physics_process(is_active)
	if not is_active:
		velocity = Vector3.ZERO
		_mouse_delta = Vector2.ZERO
		if _fpv_camera != null:
			_fpv_camera.current = false
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if _fpv_camera != null:
			_fpv_camera.current = true


## Returns 0.0 — drone body pitch tilts dramatically during flight, and feeding
## that to ChaseCamera would lurch the third-person view when switching back.
## ChaseCamera should follow drone yaw only.
func get_aim_pitch() -> float:
	return 0.0


## Returns drone body's world yaw — ChaseCamera reads this to orbit correctly
## when the drone is INACTIVE and the chase camera is the active renderer.
func get_aim_yaw() -> float:
	return global_rotation.y


## Current throttle [0..1] for HUD readouts.
func get_throttle() -> float:
	return _throttle

# ---------------------------------------------------------------------------
# Built-in virtual methods
# ---------------------------------------------------------------------------

func _ready() -> void:
	# Start at hover throttle so dropping in feels neutral, not falling.
	_throttle = hover_throttle
	_current_rotor_speed = idle_rotor_speed_rad_per_sec
	_spawn_transform = global_transform
	if _health != null:
		_health.destroyed.connect(_on_self_destroyed)

	_fpv_camera = get_node_or_null(fpv_camera_path) as Camera3D
	_fpv_mount = get_node_or_null(fpv_mount_path) as Node3D
	if _fpv_camera == null:
		push_warning("DroneController: fpv_camera_path not set or not a Camera3D (%s)" % fpv_camera_path)
	if _fpv_mount == null:
		push_warning("DroneController: fpv_mount_path not set or not a Node3D (%s)" % fpv_mount_path)
	else:
		# Static uptilt baked once — camera is rigid-mounted to body from now on.
		# Negative X rotation tilts the view UP (Godot right-handed local frame).
		_fpv_mount.rotation.x = deg_to_rad(-fpv_camera_uptilt_deg)

	_setup_propellers()


func _setup_propellers() -> void:
	# Resolve all blade nodes, then split into motor groups of [blades_per_motor].
	var resolved_blades: Array[Node3D] = []
	for prop_name: String in propeller_node_names:
		var node: Node3D = _find_descendant_by_name(self, prop_name) as Node3D
		if node == null:
			push_warning("DroneController: propeller node '%s' not found" % prop_name)
			continue
		resolved_blades.append(node)

	var per_motor: int = maxi(blades_per_motor, 1)
	var motor_count: int = resolved_blades.size() / per_motor
	for motor_index: int in range(motor_count):
		var blades: Array[Node3D] = []
		for b: int in range(per_motor):
			blades.append(resolved_blades[motor_index * per_motor + b])
		# Work in PARENT-LOCAL space — drone transform carries blades automatically.
		var centroid_local: Vector3 = Vector3.ZERO
		var count: int = 0
		var blade_states: Array[Dictionary] = []
		for blade: Node3D in blades:
			var mesh: MeshInstance3D = blade as MeshInstance3D
			if mesh == null:
				mesh = _find_first_mesh_instance(blade)
			if mesh == null or mesh.mesh == null:
				continue
			var visual_center_local: Vector3 = blade.position + blade.basis * mesh.mesh.get_aabb().get_center()
			centroid_local += visual_center_local
			count += 1
			blade_states.append({
				"node": blade,
				"initial_pos": blade.position,
				"initial_basis": blade.basis,
			})
		if count == 0:
			continue
		centroid_local /= float(count)
		for state: Dictionary in blade_states:
			state["offset"] = state["initial_pos"] - centroid_local
		_motor_groups.append({
			"centroid": centroid_local,
			"blades": blade_states,
		})
		_motor_angles.append(0.0)


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		# Accumulate raw pixel deltas; consumed and zeroed each physics tick.
		# Multiple motion events can fire between physics frames at high polling rates.
		_mouse_delta += motion.relative


func _physics_process(delta: float) -> void:
	# Destroyed wreck: only gravity + collision until _respawn() flips the flag.
	if _is_destroyed:
		_wreck_fall(delta)
		return

	if not _active:
		return

	_update_throttle(delta)
	_apply_body_rotation(delta)
	_apply_forces(delta)
	_clamp_altitude_and_floor()

	# Snapshot impact velocity BEFORE move_and_slide — collisions may zero it.
	_pre_slide_velocity = velocity
	move_and_slide()
	_check_kamikaze_collisions()

	_animate_propellers(_throttle > 0.05, delta)


func _check_kamikaze_collisions() -> void:
	if _is_destroyed:
		return
	var threshold_sq: float = kamikaze_speed_threshold * kamikaze_speed_threshold
	if _pre_slide_velocity.length_squared() < threshold_sq:
		return
	for i: int in range(get_slide_collision_count()):
		var col: KinematicCollision3D = get_slide_collision(i)
		var collider: Node = col.get_collider() as Node
		if collider == null:
			continue
		var target_health: HealthComponent = collider.get_node_or_null("HealthComponent") as HealthComponent
		if target_health != null:
			target_health.take_damage(kamikaze_damage, DamageTypes.Source.DRONE_KAMIKAZE)
		# Any high-speed impact (target or terrain) detonates the drone.
		if _health != null:
			_health.take_damage(kamikaze_damage, DamageTypes.Source.DRONE_KAMIKAZE)
		return


# ---------------------------------------------------------------------------
# Private flight steps
# ---------------------------------------------------------------------------

func _update_throttle(delta: float) -> void:
	var throttle_input: float = 0.0
	if Input.is_key_pressed(KEY_W):
		throttle_input += 1.0
	if Input.is_key_pressed(KEY_S):
		throttle_input -= 1.0
	_throttle = clampf(_throttle + throttle_input * throttle_rate * delta, 0.0, 1.0)


func _apply_body_rotation(delta: float) -> void:
	# Mouse → instant per-frame rotation. Mouse stops → rotation stops, angle holds.
	# Total rotation per second is frame-rate independent because mouse pixel
	# delta is summed across all events in the frame (high polling = smaller chunks).
	# Per-frame clamp prevents teleport-spins on huge mouse swipes.
	var sens_rad: float = deg_to_rad(mouse_sensitivity_deg_per_px)
	var max_pitch_per_frame: float = deg_to_rad(max_pitch_rate_deg) * delta
	var max_roll_per_frame: float = deg_to_rad(max_roll_rate_deg) * delta

	# Mouse forward (relative.y < 0) → nose down (positive rotation around RIGHT).
	var pitch_amount: float = clampf(-_mouse_delta.y * sens_rad, -max_pitch_per_frame, max_pitch_per_frame)
	# Mouse right (relative.x > 0) → roll right (positive rotation around FORWARD).
	var roll_amount: float = clampf(_mouse_delta.x * sens_rad, -max_roll_per_frame, max_roll_per_frame)
	_mouse_delta = Vector2.ZERO

	# Yaw — keys, continuous rate × delta. A = left (positive around UP).
	var yaw_input: float = 0.0
	if Input.is_key_pressed(KEY_A):
		yaw_input += 1.0
	if Input.is_key_pressed(KEY_D):
		yaw_input -= 1.0
	var yaw_amount: float = yaw_input * deg_to_rad(max_yaw_rate_deg) * delta

	if pitch_amount != 0.0:
		rotate_object_local(Vector3.RIGHT, pitch_amount)
	if yaw_amount != 0.0:
		rotate_object_local(Vector3.UP, yaw_amount)
	if roll_amount != 0.0:
		rotate_object_local(Vector3.FORWARD, roll_amount)


func _apply_forces(delta: float) -> void:
	# Gravity always pulls. At hover_throttle the thrust exactly cancels it.
	velocity.y -= gravity * delta

	# Thrust along drone's LOCAL up axis — tilt = translation.
	var local_up: Vector3 = global_basis.y
	velocity += local_up * (_throttle * max_thrust * delta)

	# Linear damping — exponential decay, frame-rate independent.
	var horizontal_decay: float = exp(-horizontal_damping * delta)
	velocity.x *= horizontal_decay
	velocity.z *= horizontal_decay
	velocity.y *= exp(-vertical_damping * delta)


func _clamp_altitude_and_floor() -> void:
	if global_position.y >= max_altitude and velocity.y > 0.0:
		velocity.y = 0.0
	if is_on_floor() and velocity.y < 0.0:
		velocity.y = 0.0


# ---------------------------------------------------------------------------
# Propeller animation (unchanged from prior implementation)
# ---------------------------------------------------------------------------

func _animate_propellers(is_armed: bool, delta: float) -> void:
	var target_speed: float
	if is_on_floor() and not is_armed:
		# Parked with throttle near zero — rotors coast to a stop.
		target_speed = 0.0
	else:
		# Rotor speed scales with throttle (replaces old altitude-based curve).
		target_speed = idle_rotor_speed_rad_per_sec + \
			(max_rotor_speed_rad_per_sec - idle_rotor_speed_rad_per_sec) * _throttle

	_current_rotor_speed = lerpf(_current_rotor_speed, target_speed, rotor_spool_speed * delta)

	var angle_step: float = _current_rotor_speed * delta
	for i: int in range(_motor_groups.size()):
		_motor_angles[i] += angle_step
		var centroid_local: Vector3 = _motor_groups[i]["centroid"]
		var rot: Basis = Basis(propeller_rotation_axis, _motor_angles[i])
		for state: Dictionary in _motor_groups[i]["blades"]:
			var blade: Node3D = state["node"]
			var offset: Vector3 = state["offset"]
			var initial_basis: Basis = state["initial_basis"]
			blade.position = centroid_local + rot * offset
			blade.basis = rot * initial_basis


# ---------------------------------------------------------------------------
# Destruction & respawn
# ---------------------------------------------------------------------------

func _on_self_destroyed(_by_source: int) -> void:
	_is_destroyed = true
	# Zero horizontal velocity so the wreck drops, doesn't keep cruising forward.
	# Physics stays ENABLED so the wreck falls under gravity until respawn.
	velocity.x = 0.0
	velocity.z = 0.0
	_mouse_delta = Vector2.ZERO
	_apply_destroyed_visual()
	# Schedule respawn — player sees the wreck plummet for ~1.5s before teleport.
	var timer: SceneTreeTimer = get_tree().create_timer(respawn_delay)
	timer.timeout.connect(_respawn)


## Wreck mode: gravity-only fall + slide, no input, no rotation, no propellers.
func _wreck_fall(delta: float) -> void:
	if is_on_floor():
		velocity = Vector3.ZERO
	else:
		velocity.y -= gravity * delta
	move_and_slide()


func _respawn() -> void:
	# Restore drone to its initial position with a clean state.
	global_transform = _spawn_transform
	velocity = Vector3.ZERO
	_throttle = hover_throttle
	_mouse_delta = Vector2.ZERO
	_clear_destroyed_visual()
	if _health != null:
		_health.reset()
	_is_destroyed = false
	# Re-enable physics if drone is still the active vehicle.
	if _active:
		set_physics_process(true)
	respawned.emit()


func _apply_destroyed_visual() -> void:
	DestructionVFX.apply_charred(self)
	DestructionVFX.spawn_smoke_fire(self, 0.4)


func _clear_destroyed_visual() -> void:
	DestructionVFX.clear_charred(self)
	DestructionVFX.clear_vfx(self)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _find_first_mesh_instance(root: Node) -> MeshInstance3D:
	if root is MeshInstance3D:
		return root
	for child: Node in root.get_children():
		var found: MeshInstance3D = _find_first_mesh_instance(child)
		if found != null:
			return found
	return null


## Recursive depth-first search for a node whose [member Node.name] matches
## [param target_name]. Returns [code]null[/code] when not found.
func _find_descendant_by_name(root: Node, target_name: String) -> Node:
	if root.name == target_name:
		return root
	for child: Node in root.get_children():
		var found: Node = _find_descendant_by_name(child, target_name)
		if found != null:
			return found
	return null
