class_name DroneController
extends CharacterBody3D

const _VISUAL_CONVEX_COLLIDERS := preload("res://src/gameplay/vehicle/visual_convex_colliders.gd")

## Emitted after the drone has been teleported back to its spawn point and
## physics is re-enabled. FPV HUD listens to clear the "DRONE OFFLINE" overlay.
signal respawned
## Emitted when this drone is destroyed locally (kamikaze, bullets, missile).
## VehicleSync forwards to the server so other clients see the explosion.
signal self_destructed(at_position: Vector3)

## Helicopter-style FPV drone controller (arcade flight model).
## Body only YAWS — never pitches or rolls — so the rigid-mounted FPV camera
## stays level and accuracy stays high. Visual strafe-tilt is applied to the
## child Model node only, so the camera (sibling FPVMount) is unaffected.
##
## Controls:
##   Space     — lift up (collective)
##   Ctrl / C  — descend / dive
##   W A S D   — strafe in body's yaw-aligned local frame (like helicopter)
##   Mouse X   — yaw the body
##   Mouse Y   — camera pitch only (body stays level)
##
## Less stable than the helicopter on purpose:
##   - lighter horizontal damping → drone drifts further on release
##   - vertical_damping is light + no auto-hover → gravity always pulls,
##     pilot must hold Space to maintain altitude
##   - slower yaw / tilt smoothing → "floaty" feel
##
## Implements: design/gdd/drone-system.md

# ---------------------------------------------------------------------------
# Exports — Camera
# ---------------------------------------------------------------------------

## Path to the Camera3D used for the first-person view.
@export_node_path("Camera3D") var fpv_camera_path: NodePath = ^"FPVMount/FPVCamera"
## Path to the Node3D the FPV camera is parented to. Mouse Y rotates this node
## (camera pitch only). Sibling of Model so visual body-tilt does not affect view.
@export_node_path("Node3D") var fpv_mount_path: NodePath = ^"FPVMount"
## Path to the visual model node — receives strafe-tilt for feel without
## rotating the body or the camera mount.
@export_node_path("Node3D") var model_path: NodePath = ^"Model"

# ---------------------------------------------------------------------------
# Exports — Flight: Lift
# ---------------------------------------------------------------------------

## Upward acceleration (m/s²) while Space is held.
@export var lift_acceleration: float = 14.0
## Downward acceleration (m/s²) while Ctrl/C is held (adds to gravity).
@export var lift_down_acceleration: float = 8.0
## World-space gravity (m/s²). Always pulls — there is no auto-hover.
@export var gravity: float = 9.8

# ---------------------------------------------------------------------------
# Exports — Flight: Strafe
# ---------------------------------------------------------------------------

## Movement speed (m/s) when WASD is held. Velocity snaps toward this in the
## current yaw-aligned local frame; damping bleeds it back when input releases.
@export var strafe_speed: float = 10.0

# ---------------------------------------------------------------------------
# Exports — Flight: Damping (lighter than helicopter — drone "floats")
# ---------------------------------------------------------------------------

## Horizontal velocity drag (1/s). Lower than helicopter (2.0) — drone drifts.
@export var horizontal_damping: float = 1.0
## Vertical velocity drag (1/s). Bleeds vertical speed gently — does NOT counter
## gravity, so released Space still drifts down.
@export var vertical_damping: float = 0.5
## Maximum fall speed (m/s). Hard ceiling so the drone can't accelerate to
## terminal velocity values that would tunnel through terrain colliders.
@export var terminal_fall_speed: float = 12.0
## Seconds after drone activation during which kamikaze detonation is
## suppressed. Why: when the player presses E the drone activates with the
## pilot's body literally next to it (collision_mask=3 picks the soldier
## up immediately). Without this grace, the first physics tick instantly
## detonates the drone on its own pilot. After this short window the rule
## flips to "any contact with a damageable target = kamikaze" so an enemy
## drone hovering down onto a player kills them even at near-zero speed.
@export var activation_grace_seconds: float = 0.5

# ---------------------------------------------------------------------------
# Exports — Yaw (mouse X)
# ---------------------------------------------------------------------------

## Radians of yaw target per pixel of mouse X motion.
@export var mouse_sensitivity: float = 0.0025
## Smoothing rate from current yaw toward target. Lower = laggier (heli uses 10).
@export var yaw_smooth_speed: float = 8.0

# ---------------------------------------------------------------------------
# Exports — Camera Pitch (mouse Y)
# ---------------------------------------------------------------------------

## Radians of camera pitch per pixel of mouse Y motion.
@export var camera_pitch_sensitivity: float = 0.0025
## Min camera pitch (degrees). Wide range so pilot can dive-look at kamikaze targets.
@export var camera_min_pitch_deg: float = -75.0
## Max camera pitch (degrees).
@export var camera_max_pitch_deg: float = 60.0
## When true, mouse-up → look-down (flight-sim feel). False = standard FPS.
@export var invert_camera_pitch: bool = false

# ---------------------------------------------------------------------------
# Exports — Visual Tilt (Model node only — camera unaffected)
# ---------------------------------------------------------------------------

## Max visual pitch tilt (deg) when strafing forward/back.
@export var max_pitch_tilt_deg: float = 18.0
## Max visual roll tilt (deg) when strafing left/right.
@export var max_roll_tilt_deg: float = 15.0
## How fast the Model node tilts in/out of strafe pose. Lower than heli (6) — floaty.
@export var tilt_smooth_speed: float = 4.0

# ---------------------------------------------------------------------------
# Exports — Limits
# ---------------------------------------------------------------------------

## Maximum world-space Y the drone can reach (matches helicopter ceiling).
@export var max_altitude: float = 50.0

@export_group("Combat")
## Minimum impact speed (m/s) for a TERRAIN crash to count as kamikaze.
## Free-fall from spawn altitude tops out around ~5 m/s and cruise descent
## sits ~7 m/s, so 10 m/s leaves a comfortable gap — drones gently landing
## near the ground simply bounce, while a deliberate dive that tops out at
## the terminal fall speed (12 m/s) cleanly detonates on impact.
## Contact with a player / vehicle health target detonates regardless of
## speed (an enemy drone hovering down onto you should still kill you).
@export var kamikaze_speed_threshold: float = 10.0
## Damage dealt to a HealthComponent on kamikaze impact (high to one-shot anything).
@export var kamikaze_damage: int = 999
## Seconds the drone wreck burns after a kamikaze detonation before respawning.
@export var respawn_delay: float = 10.0

@export_group("Destroyed Wreck")
## Initial downward speed applied on non-kamikaze death so the wreck cannot hover.
@export var wreck_initial_drop_speed: float = 2.2
## Clamp fall speed to avoid physics spikes in browser builds.
@export var wreck_terminal_fall_speed: float = 17.0
## Horizontal drift applied if the drone was hovering when destroyed.
@export var wreck_crash_drift_speed: float = 8.0
## Random angular speed range used while the wreck falls before impact.
@export var wreck_tumble_speed_min: float = 0.45
@export var wreck_tumble_speed_max: float = 1.25
## Air drag while the wreck tumbles down. Higher = less stone-like drop.
@export var wreck_air_drag: float = 0.18
## How much spinning propellers soften gravity during the first crash seconds.
@export var wreck_rotor_lift_gravity_scale: float = 0.42

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

@export_group("Collision Mesh")
@export var rebuild_collision_from_visual_mesh: bool = true
## Drone keeps web fallback box: the FPV mesh is small and irregular, and the
## web convex rebuild was causing drones to spawn inside their own rebuilt
## colliders / get displaced on game start. The authored 2x0.6x2 box is
## already a tight fit for the airframe; tank/heli benefit from the rebuild
## but drone does not.
@export var rebuild_collision_on_web: bool = false
@export var collision_mesh_min_size: Vector3 = Vector3(0.04, 0.04, 0.04)
@export var collision_mesh_max_shapes: int = 8
@export var collision_mesh_ignore_names: PackedStringArray = PackedStringArray()
@export var warn_missing_propeller_nodes: bool = false

# ---------------------------------------------------------------------------
# Private state
# ---------------------------------------------------------------------------

var _active: bool = true
## Set by VehicleSync when a non-local peer is flying this drone — keeps
## propellers spinning even though our `_physics_process` is suspended.
var _remote_driver_active: bool = false
## Yaw target accumulated from mouse X motion (radians).
var _yaw_target: float = 0.0
## Smoothed yaw applied to the body each tick.
var _yaw_current: float = 0.0
## Camera pitch (radians) — applied to FPVMount only; body stays level.
var _camera_pitch: float = 0.0
## Smoothed visual tilt of the Model node (radians).
var _pitch_tilt_current: float = 0.0
var _roll_tilt_current: float = 0.0

var _fpv_camera: Camera3D = null
var _fpv_mount: Node3D = null
var _model: Node3D = null
var _current_rotor_speed: float = 0.0
## Velocity snapshot taken BEFORE move_and_slide each physics tick — used as
## the impact speed for kamikaze detection (move_and_slide may zero velocity
## on collision, hiding the actual approach speed).
var _pre_slide_velocity: Vector3 = Vector3.ZERO
## Seconds remaining before the drone is allowed to detonate. Set in
## set_active(true), decremented in _physics_process. See
## [member activation_grace_seconds] for the why.
var _activation_grace_remaining: float = 0.0
## Initial transform captured in _ready — drone respawns to this position.
var _spawn_transform: Transform3D
@onready var _health: HealthComponent = $HealthComponent
var _is_destroyed: bool = false
var _wreck_burning: bool = false
var _wreck_tumble_velocity: Vector3 = Vector3.ZERO
var _auto_respawn_after_burn: bool = false
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
## Activating recaptures mouse input, switches the FPV camera on, and resyncs the
## yaw target to the body's current yaw so the drone does not snap-turn on entry.
func set_active(is_active: bool) -> void:
	_active = is_active
	# Destroyed wrecks keep physics running so they fall under gravity until
	# the respawn timer fires.
	if _is_destroyed:
		set_physics_process(not _wreck_burning)
		if _fpv_camera != null:
			_fpv_camera.current = is_active
		return
	set_physics_process(is_active)
	if not is_active:
		velocity = Vector3.ZERO
		_activation_grace_remaining = 0.0
		if _fpv_camera != null:
			_fpv_camera.current = false
	else:
		WebPointerLock.capture_for_activation()
		_yaw_target = global_rotation.y
		_yaw_current = _yaw_target
		# Block kamikaze detonation while the pilot is still standing next to
		# the drone (collision_mask=3 picks up the soldier's body the same
		# frame physics resumes). After this short window any contact with a
		# damageable target = kamikaze, regardless of speed.
		_activation_grace_remaining = activation_grace_seconds
		if _fpv_camera != null:
			_fpv_camera.current = true


## Returns 0.0 — drone body never pitches in this design (FPV camera handles
## look pitch). Returning 0 keeps ChaseCamera level when the drone is inactive.
func get_aim_pitch() -> float:
	return 0.0


## Returns drone body's world yaw — ChaseCamera reads this to orbit correctly
## when the drone is INACTIVE and the chase camera is the active renderer.
func get_aim_yaw() -> float:
	return global_rotation.y


## Synthetic throttle (0..1) for HUD readouts. Space = 1.0, Ctrl/C = 0.0,
## neutral = 0.5. The flight model is no longer accumulator-based.
func get_throttle() -> float:
	if not _active or _is_destroyed:
		return 0.0
	if Input.is_key_pressed(KEY_SPACE):
		return 1.0
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_C):
		return 0.0
	return 0.5

# ---------------------------------------------------------------------------
# Built-in virtual methods
# ---------------------------------------------------------------------------

func _ready() -> void:
	_current_rotor_speed = idle_rotor_speed_rad_per_sec
	_spawn_transform = global_transform
	_yaw_target = global_rotation.y
	_yaw_current = _yaw_target
	if _health != null:
		_health.destroyed.connect(_on_self_destroyed)

	_fpv_camera = get_node_or_null(fpv_camera_path) as Camera3D
	_fpv_mount = get_node_or_null(fpv_mount_path) as Node3D
	_model = get_node_or_null(model_path) as Node3D
	if _fpv_camera == null:
		push_warning("DroneController: fpv_camera_path not set or not a Camera3D (%s)" % fpv_camera_path)
	if _fpv_mount == null:
		push_warning("DroneController: fpv_mount_path not set or not a Node3D (%s)" % fpv_mount_path)
	if _model == null:
		push_warning("DroneController: model_path not set or not a Node3D (%s)" % model_path)
	else:
		_rebuild_visual_mesh_collision()

	_setup_propellers()


func _rebuild_visual_mesh_collision() -> void:
	if not rebuild_collision_from_visual_mesh:
		return
	if OS.has_feature("web") and not rebuild_collision_on_web:
		return

	var ignore_names := PackedStringArray(collision_mesh_ignore_names)
	for propeller_name: String in propeller_node_names:
		if not ignore_names.has(propeller_name):
			ignore_names.append(propeller_name)

	var built: int = _VISUAL_CONVEX_COLLIDERS.rebuild(
		self,
		_model,
		collision_mesh_min_size,
		ignore_names,
		collision_mesh_max_shapes
	)
	if built == 0:
		push_warning("DroneController: visual mesh collision build failed; keeping scene fallback shape")


func _setup_propellers() -> void:
	# Resolve all blade nodes, then split into motor groups of [blades_per_motor].
	var resolved_blades: Array[Node3D] = []
	var missing_names: PackedStringArray = PackedStringArray()
	for prop_name: String in propeller_node_names:
		var node: Node3D = _find_descendant_by_name(self, prop_name) as Node3D
		if node == null:
			missing_names.append(prop_name)
			continue
		resolved_blades.append(node)
	if warn_missing_propeller_nodes and not missing_names.is_empty():
		push_warning("DroneController: %d propeller nodes not found" % missing_names.size())

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
	if not _active or _is_destroyed:
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			WebPointerLock.capture_from_user_gesture()
			return
	if event is InputEventMouseMotion:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			return
		var motion: InputEventMouseMotion = event
		# Mouse X → yaw target. Negative because mouse-right should yaw clockwise
		# from above (right-handed Y-up: clockwise = negative rotation).
		_yaw_target -= motion.relative.x * mouse_sensitivity
		# Mouse Y → camera pitch (body untouched). Mouse-down looks down when inverted.
		var pitch_sign: float = -1.0 if invert_camera_pitch else 1.0
		_camera_pitch = clampf(
			_camera_pitch - motion.relative.y * camera_pitch_sensitivity * pitch_sign,
			deg_to_rad(camera_min_pitch_deg),
			deg_to_rad(camera_max_pitch_deg),
		)


## Called by VehicleSync every snapshot to flag remote driver.
func set_remote_driver_active(active: bool) -> void:
	_remote_driver_active = active


func is_locally_driven() -> bool:
	return _active and not _is_destroyed


func _process(delta: float) -> void:
	# Local controller running its own physics? Skip — _physics_process spins.
	if _active or _is_destroyed:
		return
	# Remote pilot is flying this drone but our physics is suspended; keep
	# propellers visually animated so observers see it "alive".
	_animate_propellers(_remote_driver_active, delta)


func _physics_process(delta: float) -> void:
	# Destroyed wreck: only gravity + collision until _respawn() flips the flag.
	if _is_destroyed:
		_wreck_fall(delta)
		return

	if not _active:
		return

	if _activation_grace_remaining > 0.0:
		_activation_grace_remaining = maxf(_activation_grace_remaining - delta, 0.0)

	_apply_yaw(delta)
	_apply_camera_pitch()
	_apply_lift_and_strafe(delta)
	_apply_visual_tilt(delta)
	_clamp_altitude_and_floor()

	# Snapshot impact velocity BEFORE move_and_slide — collisions may zero it.
	_pre_slide_velocity = velocity
	move_and_slide()
	# Anti-tunnel: web's CharacterBody3D occasionally lets the small drone
	# sweep through thin terrain colliders mid-frame. After the slide,
	# raycast straight down — if ground sits ABOVE the drone's bottom, we've
	# clipped through. Snap up so we're sitting on the surface again.
	_anti_tunnel_ground_snap()
	_check_kamikaze_collisions()

	var is_armed: bool = Input.is_key_pressed(KEY_SPACE) or velocity.length_squared() > 1.0
	_animate_propellers(is_armed, delta)


func _check_kamikaze_collisions() -> void:
	if _is_destroyed:
		return
	# Don't detonate during the activation grace window — see set_active().
	if _activation_grace_remaining > 0.0:
		return
	var threshold_sq: float = kamikaze_speed_threshold * kamikaze_speed_threshold
	var fast_enough: bool = _pre_slide_velocity.length_squared() >= threshold_sq
	for i: int in range(get_slide_collision_count()):
		var col: KinematicCollision3D = get_slide_collision(i)
		var collider: Node = col.get_collider() as Node
		if collider == null or collider == self:
			continue
		# Don't blow up on the local pilot. Even after the activation grace
		# expires, the pilot is still standing right next to the drone they
		# just took control of (player keeps gravity-collision while drone-
		# piloting unlike tank/heli where set_embarked hides the body).
		if _is_local_pilot_body(collider):
			continue
		var target_health: HealthComponent = _find_health_component(collider)
		if target_health != null:
			# Damageable target (player / vehicle) — detonate on ANY contact
			# regardless of speed. Activation grace already covers the only
			# "false positive" case (own pilot at spawn).
			if _is_networked():
				_send_kamikaze_claim(collider)
			else:
				target_health.take_damage(kamikaze_damage, DamageTypes.Source.DRONE_KAMIKAZE)
			if _health != null:
				_health.take_damage(kamikaze_damage, DamageTypes.Source.DRONE_KAMIKAZE)
			return
		# Terrain / wall / static prop — only detonate if the drone hit fast
		# enough to count as a deliberate dive. Slow landings just bounce.
		if fast_enough and _health != null:
			_health.take_damage(kamikaze_damage, DamageTypes.Source.DRONE_KAMIKAZE)
			return


func _is_networked() -> bool:
	var nm: Node = get_node_or_null("/root/NetworkManager")
	if nm == null:
		return false
	if not nm.has_method("is_online"):
		return false
	return bool(nm.call("is_online"))


func _send_kamikaze_claim(collider: Node) -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if nm == null or not nm.has_method("send_message"):
		return
	# Walk up the collider hierarchy to find a target identifier the server
	# knows about (peer_id for player avatars, vehicle_id for tank/heli/drone).
	var node: Node = collider
	var msg: Dictionary = {
		"t": "vehicle_hit_claim",
		"projectile": "drone_kamikaze",
		# Why: server validates that the shooter is the registered driver of
		# the claimed vehicle. With Drone+Drone2 in the scene, hardcoding
		# "drone" causes Drone2 claims to be rejected as not_driver. Read the
		# real vehicle_id from the child VehicleSync so each drone instance
		# claims under its own id.
		"vehicle_id": _resolve_self_vehicle_id(),
		"client_t": Time.get_ticks_msec(),
	}
	while node != null:
		var lower: String = node.name.to_lower()
		if lower.begins_with("tank") or lower.begins_with("helicopter"):
			msg["target_vehicle_id"] = lower
			break
		if "peer_id" in node:
			var pid: int = int(node.get("peer_id"))
			if pid > 0:
				msg["target_peer_id"] = pid
				break
		node = node.get_parent()
	if msg.has("target_peer_id") or msg.has("target_vehicle_id"):
		nm.call("send_message", msg)


## Drone half-height matches the BoxShape3D y-extent in scenes/drone/drone.tscn.
const _DRONE_HALF_HEIGHT: float = 0.3
## How far below the drone we'll cast the recovery ray. If terrain is found
## within this distance below origin, we assume tunneling and snap up.
const _ANTI_TUNNEL_PROBE: float = 3.0


## Cast a ray from drone origin straight down. If terrain is found ABOVE
## (drone.y - half_height), our box has clipped through the ground — snap
## the drone up to (terrain_y + half_height + small_epsilon).
func _anti_tunnel_ground_snap() -> void:
	if _is_destroyed:
		return
	var world: World3D = get_world_3d()
	if world == null:
		return
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null:
		return
	var from_pos: Vector3 = global_position + Vector3.UP * _ANTI_TUNNEL_PROBE
	var to_pos: Vector3 = global_position - Vector3.UP * _ANTI_TUNNEL_PROBE
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from_pos, to_pos)
	query.collide_with_areas = false
	query.exclude = [get_rid()]
	# Only static terrain / world geometry, not vehicles or players (those
	# trigger kamikaze, not snap).
	query.collision_mask = 1
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return
	var ground_y: float = float((hit["position"] as Vector3).y)
	var min_drone_y: float = ground_y + _DRONE_HALF_HEIGHT + 0.05
	if global_position.y < min_drone_y:
		var pos: Vector3 = global_position
		pos.y = min_drone_y
		global_position = pos
		# Cancel downward velocity so we don't immediately re-tunnel next frame.
		if velocity.y < 0.0:
			velocity.y = 0.0


## Returns true if [param collider] is the local PlayerController's Body —
## the soldier that's currently piloting (or just piloted) this drone. Used
## to suppress kamikaze self-destruct when the pilot is still standing next
## to the drone hull. Walks the local scene root rather than caching to
## stay correct across player respawns.
func _is_local_pilot_body(collider: Node) -> bool:
	if collider == null:
		return false
	var tree: SceneTree = get_tree()
	if tree == null:
		return false
	var scene_root: Node = tree.current_scene
	if scene_root == null:
		return false
	var local_player: Node = scene_root.get_node_or_null("Player")
	if local_player == null:
		return false
	var local_body: Node = local_player.get_node_or_null("Body")
	return collider == local_body


## Read this drone instance's network vehicle_id from the sibling VehicleSync
## node. Falls back to "drone" if no VehicleSync is attached (solo play).
func _resolve_self_vehicle_id() -> String:
	var sync: Node = get_node_or_null("VehicleSync")
	if sync != null and "vehicle_id" in sync:
		var raw: String = String(sync.get("vehicle_id"))
		if raw != "":
			return raw
	return "drone"


## Locate a HealthComponent on the collider. Most vehicles parent it directly
## (Tank/Helicopter/Drone), but the Player parents it under "Body" — so fall
## back to a recursive search before giving up.
func _find_health_component(collider: Node) -> HealthComponent:
	var direct: HealthComponent = collider.get_node_or_null("HealthComponent") as HealthComponent
	if direct != null:
		return direct
	return collider.find_child("HealthComponent", true, false) as HealthComponent


# ---------------------------------------------------------------------------
# Private flight steps
# ---------------------------------------------------------------------------

func _apply_yaw(delta: float) -> void:
	# Frame-rate independent exponential blend toward target.
	var blend: float = 1.0 - exp(-yaw_smooth_speed * delta)
	_yaw_current = lerp_angle(_yaw_current, _yaw_target, blend)
	rotation.y = _yaw_current


func _apply_camera_pitch() -> void:
	if _fpv_mount == null:
		return
	_fpv_mount.rotation.x = _camera_pitch


func _apply_lift_and_strafe(delta: float) -> void:
	# Gravity always pulls — no auto-hover. Pilot must hold Space to climb.
	velocity.y -= gravity * delta
	if Input.is_key_pressed(KEY_SPACE):
		velocity.y += lift_acceleration * delta
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_C):
		velocity.y -= lift_down_acceleration * delta

	# Strafe — yaw-aligned local frame, snap toward target velocity (heli pattern).
	var strafe_input: Vector2 = Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		strafe_input.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		strafe_input.y += 1.0
	if Input.is_key_pressed(KEY_A):
		strafe_input.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		strafe_input.x += 1.0
	if strafe_input.length_squared() > 1.0:
		strafe_input = strafe_input.normalized()

	var yaw_basis: Basis = Basis(Vector3.UP, _yaw_current)
	var world_strafe: Vector3 = yaw_basis * Vector3(strafe_input.x, 0.0, strafe_input.y)
	var target_vx: float = world_strafe.x * strafe_speed
	var target_vz: float = world_strafe.z * strafe_speed

	# Light damping toward target — drone never quite snaps, leaves residual drift.
	# When no input, target is zero and damping bleeds momentum gradually.
	var horizontal_blend: float = 1.0 - exp(-horizontal_damping * delta)
	velocity.x = lerpf(velocity.x, target_vx, horizontal_blend)
	velocity.z = lerpf(velocity.z, target_vz, horizontal_blend)

	# Vertical damping is gentle — does NOT counter gravity, just bleeds spikes.
	velocity.y *= exp(-vertical_damping * delta)
	# Why: at terminal velocity (~20 m/s with default gravity / vertical_damping
	# settings) the drone moves ~0.33 m per 60-fps frame, which exceeds the
	# CharacterBody3D safe_margin and lets the drone tunnel through terrain
	# colliders. Cap fall speed so move_and_slide always resolves the floor
	# contact properly. Climb speed is unrestricted — pilot can shoot up freely.
	if velocity.y < -terminal_fall_speed:
		velocity.y = -terminal_fall_speed


func _apply_visual_tilt(delta: float) -> void:
	# Visual tilt only on Model node — sibling FPVMount (and camera) unaffected.
	if _model == null:
		return
	var input_x: float = 0.0
	var input_z: float = 0.0
	if Input.is_key_pressed(KEY_W):
		input_z -= 1.0
	if Input.is_key_pressed(KEY_S):
		input_z += 1.0
	if Input.is_key_pressed(KEY_A):
		input_x -= 1.0
	if Input.is_key_pressed(KEY_D):
		input_x += 1.0

	# W (forward strafe) → nose down (negative pitch about local X).
	# D (right strafe)   → roll right (negative roll about local Z in Godot's Y-up).
	var target_pitch: float = input_z * deg_to_rad(max_pitch_tilt_deg)
	var target_roll: float = -input_x * deg_to_rad(max_roll_tilt_deg)

	var blend: float = 1.0 - exp(-tilt_smooth_speed * delta)
	_pitch_tilt_current = lerpf(_pitch_tilt_current, target_pitch, blend)
	_roll_tilt_current = lerpf(_roll_tilt_current, target_roll, blend)

	_model.rotation.x = _pitch_tilt_current
	_model.rotation.z = _roll_tilt_current


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
		# Parked with no lift input — rotors coast to a stop.
		target_speed = 0.0
	else:
		# Rotor speed scales with synthetic throttle for visual feedback.
		var throttle_visual: float = get_throttle()
		target_speed = idle_rotor_speed_rad_per_sec + \
			(max_rotor_speed_rad_per_sec - idle_rotor_speed_rad_per_sec) * throttle_visual

	_current_rotor_speed = lerpf(_current_rotor_speed, target_speed, rotor_spool_speed * delta)

	var angle_step: float = _current_rotor_speed * delta
	_spin_propellers(angle_step)


func _spin_propellers(angle_step: float) -> void:
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
	if _is_destroyed:
		return
	if _by_source == DamageTypes.Source.DRONE_KAMIKAZE:
		_is_destroyed = true
		_auto_respawn_after_burn = true
		_start_crash_burn(_pre_slide_velocity.length())
	else:
		_begin_wreck_fall(true)
	self_destructed.emit(global_position)

func apply_network_destroyed() -> void:
	if _is_destroyed:
		return
	_mark_health_destroyed_no_signal()
	_begin_wreck_fall(false)

func apply_network_respawned() -> void:
	_clear_destroyed_visual()
	if _health != null:
		_health.reset()
	_is_destroyed = false
	_wreck_burning = false
	_wreck_tumble_velocity = Vector3.ZERO
	_auto_respawn_after_burn = false
	_remote_driver_active = false
	velocity = Vector3.ZERO
	_current_rotor_speed = 0.0
	rotation.x = 0.0
	rotation.z = 0.0
	set_physics_process(_active)
	respawned.emit()


func _mark_health_destroyed_no_signal() -> void:
	if _health != null and _health.has_method("force_destroyed"):
		_health.call("force_destroyed", DamageTypes.Source.DRONE_KAMIKAZE, false)


func _begin_wreck_fall(auto_respawn: bool) -> void:
	_is_destroyed = true
	_wreck_burning = false
	_auto_respawn_after_burn = auto_respawn
	_remote_driver_active = false
	var horizontal_velocity: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	if horizontal_velocity.length() < 1.0:
		var forward: Vector3 = -global_transform.basis.z
		forward.y = 0.0
		if forward.length_squared() < 0.001:
			forward = Vector3.FORWARD
		horizontal_velocity = forward.normalized() * wreck_crash_drift_speed
		horizontal_velocity = horizontal_velocity.rotated(Vector3.UP, randf_range(-0.45, 0.45))
	velocity.x = horizontal_velocity.x
	velocity.z = horizontal_velocity.z
	velocity.y = -absf(wreck_initial_drop_speed)
	_wreck_tumble_velocity = Vector3(
		randf_range(wreck_tumble_speed_min, wreck_tumble_speed_max) * _random_sign(),
		randf_range(0.8, 1.9) * _random_sign(),
		randf_range(wreck_tumble_speed_min, wreck_tumble_speed_max) * _random_sign()
	)
	set_physics_process(true)


func _random_sign() -> float:
	return -1.0 if randf() < 0.5 else 1.0


## Wreck mode: fall first, then burn only after real ground impact.
func _wreck_fall(delta: float) -> void:
	if _wreck_burning:
		return
	_apply_crash_tumble(delta)
	_animate_crash_propellers(delta)
	var rotor_t: float = clampf(_current_rotor_speed / maxf(max_rotor_speed_rad_per_sec, 0.001), 0.0, 1.0)
	var gravity_scale: float = lerpf(1.0, wreck_rotor_lift_gravity_scale, rotor_t)
	velocity.y = maxf(velocity.y - gravity * gravity_scale * delta, -absf(wreck_terminal_fall_speed))
	var drag: float = exp(-wreck_air_drag * delta)
	velocity.x *= drag
	velocity.z *= drag
	if velocity.y < 0.0:
		velocity.y *= drag
	var impact_speed: float = maxf(-velocity.y, 0.0)
	move_and_slide()
	if is_on_floor():
		_start_crash_burn(impact_speed)


func _apply_crash_tumble(delta: float) -> void:
	rotation.x += _wreck_tumble_velocity.x * delta
	rotation.y += _wreck_tumble_velocity.y * delta
	rotation.z += _wreck_tumble_velocity.z * delta
	_wreck_tumble_velocity = _wreck_tumble_velocity.lerp(Vector3.ZERO, clampf(delta * 0.08, 0.0, 0.25))


func _animate_crash_propellers(delta: float) -> void:
	_current_rotor_speed = lerpf(_current_rotor_speed, 0.0, clampf(delta * 0.9, 0.0, 1.0))
	_spin_propellers(_current_rotor_speed * delta)


func _start_crash_burn(_impact_speed: float) -> void:
	if _wreck_burning:
		return
	_wreck_burning = true
	velocity = Vector3.ZERO
	_wreck_tumble_velocity = Vector3.ZERO
	_apply_destroyed_visual()
	if _auto_respawn_after_burn:
		var timer: SceneTreeTimer = get_tree().create_timer(respawn_delay)
		timer.timeout.connect(_respawn)
	set_physics_process(false)


func _respawn() -> void:
	# Restore drone to its initial position with a clean state.
	global_transform = _spawn_transform
	velocity = Vector3.ZERO
	_yaw_target = global_rotation.y
	_yaw_current = _yaw_target
	_camera_pitch = 0.0
	_pitch_tilt_current = 0.0
	_roll_tilt_current = 0.0
	if _fpv_mount != null:
		_fpv_mount.rotation.x = 0.0
	if _model != null:
		_model.rotation = Vector3.ZERO
	_clear_destroyed_visual()
	if _health != null:
		_health.reset()
	_is_destroyed = false
	_wreck_burning = false
	_wreck_tumble_velocity = Vector3.ZERO
	_auto_respawn_after_burn = false
	_current_rotor_speed = idle_rotor_speed_rad_per_sec
	if _active:
		set_physics_process(true)
	respawned.emit()


func _apply_destroyed_visual() -> void:
	DestructionVFX.spawn_explosion(get_tree().current_scene, global_position + Vector3(0, 0.4, 0), false)
	_set_propellers_visible(false)
	DestructionVFX.spawn_smoke_fire(self, 0.4, true, respawn_delay)


func _clear_destroyed_visual() -> void:
	_set_propellers_visible(true)
	DestructionVFX.clear_charred(self)
	DestructionVFX.clear_vfx(self)


func _set_propellers_visible(is_visible: bool) -> void:
	for group: Dictionary in _motor_groups:
		var blades: Array = group.get("blades", [])
		for raw_state in blades:
			if not (raw_state is Dictionary):
				continue
			var state: Dictionary = raw_state
			var blade: Node3D = state.get("node", null) as Node3D
			if blade != null and is_instance_valid(blade):
				blade.visible = is_visible


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
