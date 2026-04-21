class_name CameraFeelController
extends Node

## Cosmetic camera effects layer — does NOT affect gameplay state or aim.
##
## Applies per-frame offsets to [Camera3D] (local transform and FOV) to give
## the otherwise-static camera a sense of weight and responsiveness:
##   - Head bob            (Y-offset sine wave while moving on foot)
##   - Landing impact      (quick dip + ease-out recovery on ground touchdown)
##   - Camera tilt / lean  (small Z roll toward strafe direction)
##   - FOV pulse           (base → sprint FOV ramp)
##   - Fire recoil kick    (camera pitch kick on weapon fire)
##
## Reads [PlayerController] state (velocity, grounded, sprint) and connects to
## [WeaponController] `fired` signal for recoil. All offsets are applied to
## the [Camera3D] node directly (NOT to CameraPivot, which is owned by
## PlayerController and syncs each physics tick).
##
## Per .claude/rules/gameplay-code.md: "NO direct references to UI code — use
## events/signals". This node only reads gameplay state and writes Camera3D —
## no UI coupling.

@export_node_path("PlayerController") var player_controller_path: NodePath = ^".."
@export_node_path("Camera3D") var camera_path: NodePath = ^"../CameraPivot/SpringArm3D/CameraRig/Camera3D"
@export_node_path("Node") var weapon_controller_path: NodePath = ^"../WeaponController"

@export_group("Head bob")
## OFF by default — head bob is an FPS convention and disorients in TPS
## (Fortnite / similar third-person shooters don't use it). Set true only if
## intentionally going for a handheld-camera feel.
@export var bob_enabled: bool = false
@export var bob_amplitude: float = 0.012
@export var bob_frequency_walk: float = 5.0
@export var bob_frequency_sprint: float = 7.5
## How quickly bob fades in/out when starting/stopping movement (higher = snappier).
@export var bob_fade_rate: float = 8.0

@export_group("Landing impact")
@export var landing_enabled: bool = true
## Dip depth per 1 m/s of downward velocity at touchdown (scaled + clamped).
@export var landing_dip_per_mps: float = 0.012
@export var landing_max_dip: float = 0.12
## Fall speed below which landing impact is ignored (small hops / terrain bumps).
## Raise this if dips trigger during normal walking on uneven ground.
@export var landing_min_impact_speed: float = 4.5
## Recovery speed of the dip (higher = snappier return).
@export var landing_recovery_rate: float = 9.0

@export_group("Camera tilt (lean)")
@export var tilt_enabled: bool = true
## Max roll in degrees at full strafe velocity.
@export var tilt_max_degrees: float = 2.0
## Strafe-velocity magnitude that maps to full tilt. Should be near walk_speed.
@export var tilt_reference_speed: float = 7.0
@export var tilt_smoothing: float = 8.0

@export_group("FOV pulse")
@export var fov_enabled: bool = true
@export var fov_base: float = 80.0
@export var fov_sprint: float = 86.0
@export var fov_smoothing: float = 5.0

@export_group("Fire recoil kick")
## OFF by default per user request 2026-04-22 — AR rapid-fire accumulation was
## too shaky. Re-enable here or tune the per-weapon pitch values below if you
## want visible recoil later.
@export var recoil_enabled: bool = false
## Pitch kick in degrees on AR shot.
@export var recoil_ar_pitch: float = 1.5
## Pitch kick in degrees on RPG shot.
@export var recoil_rpg_pitch: float = 7.0
## Random yaw jitter added per shot (±range in degrees).
@export var recoil_yaw_jitter: float = 0.4
## Exponential decay rate of recoil offset (higher = faster settle).
@export var recoil_decay_rate: float = 14.0

var _player: PlayerController
var _camera: Camera3D
var _weapon: WeaponController

# Cached base Camera3D local transform (translation + rotation) — all offsets
# are applied on top of this baseline.
var _cam_base_position: Vector3
var _cam_base_rotation: Vector3

# Head bob state.
var _bob_phase: float = 0.0
var _bob_strength: float = 0.0  # eased amount [0..1]

# Landing impact state.
var _was_on_floor: bool = true
var _last_airborne_velocity_y: float = 0.0
var _landing_offset: float = 0.0  # current downward dip (positive = dipped)

# Tilt (smoothed).
var _tilt_current_deg: float = 0.0

# FOV (smoothed).
var _fov_current: float = 80.0

# Recoil accumulator — decays toward 0 each frame.
var _recoil_pitch_deg: float = 0.0
var _recoil_yaw_deg: float = 0.0

# RNG for yaw jitter.
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_player = get_node_or_null(player_controller_path) as PlayerController
	_camera = get_node_or_null(camera_path) as Camera3D
	_weapon = get_node_or_null(weapon_controller_path) as WeaponController

	if _player == null:
		push_warning("CameraFeelController: PlayerController not found at " + str(player_controller_path))
	if _camera == null:
		push_warning("CameraFeelController: Camera3D not found at " + str(camera_path))
		return

	_cam_base_position = _camera.transform.origin
	_cam_base_rotation = _camera.rotation
	_fov_current = _camera.fov
	_rng.randomize()

	if _weapon != null:
		_weapon.fired.connect(_on_weapon_fired)
	else:
		push_warning("CameraFeelController: WeaponController not found — recoil disabled")


func _process(delta: float) -> void:
	if _camera == null or _player == null:
		return

	var horiz_vel := Vector3(
		_player_velocity().x, 0.0, _player_velocity().z
	)
	var speed: float = horiz_vel.length()
	var grounded: bool = _player_grounded()
	var sprinting: bool = speed > _player.walk_speed + 0.5

	_update_landing_impact(delta, grounded)
	_update_head_bob(delta, speed, grounded, sprinting)
	_update_tilt(delta, horiz_vel)
	_update_fov(delta, sprinting)
	_update_recoil_decay(delta)

	# Compose final camera transform: base + bob + landing dip + tilt + recoil.
	var pos := _cam_base_position
	var bob_y: float = sin(_bob_phase) * bob_amplitude * _bob_strength
	pos.y += bob_y - _landing_offset

	var rot := _cam_base_rotation
	rot.x += deg_to_rad(_recoil_pitch_deg)
	rot.y += deg_to_rad(_recoil_yaw_deg)
	rot.z += deg_to_rad(_tilt_current_deg)

	_camera.position = pos
	_camera.rotation = rot
	_camera.fov = _fov_current


# ---------------------------------------------------------------------------
# State readers (hide field access from PlayerController public API drift)
# ---------------------------------------------------------------------------

func _player_velocity() -> Vector3:
	# PlayerController does not expose velocity directly; read from its body.
	var body: CharacterBody3D = _player.get_node_or_null("Body") as CharacterBody3D
	return body.velocity if body != null else Vector3.ZERO


func _player_grounded() -> bool:
	var body: CharacterBody3D = _player.get_node_or_null("Body") as CharacterBody3D
	return body.is_on_floor() if body != null else true

# ---------------------------------------------------------------------------
# Head bob
# ---------------------------------------------------------------------------

func _update_head_bob(delta: float, speed: float, grounded: bool, sprinting: bool) -> void:
	if not bob_enabled:
		_bob_strength = 0.0
		return
	var want_bob: float = 0.0
	if grounded and speed > 0.5:
		want_bob = clampf(speed / _player.walk_speed, 0.0, 1.3)
	var ease_t: float = clampf(bob_fade_rate * delta, 0.0, 1.0)
	_bob_strength = lerp(_bob_strength, want_bob, ease_t)

	var freq: float = bob_frequency_sprint if sprinting else bob_frequency_walk
	_bob_phase += freq * delta * TAU
	if _bob_phase > TAU * 100.0:
		_bob_phase = fmod(_bob_phase, TAU)

# ---------------------------------------------------------------------------
# Landing impact
# ---------------------------------------------------------------------------

func _update_landing_impact(delta: float, grounded: bool) -> void:
	if not landing_enabled:
		_landing_offset = 0.0
		_was_on_floor = grounded
		return

	# Track downward velocity while airborne so we know landing force.
	if not grounded:
		_last_airborne_velocity_y = _player_velocity().y

	# Rising edge: airborne → grounded.
	if grounded and not _was_on_floor:
		var fall_speed: float = absf(_last_airborne_velocity_y)
		if fall_speed >= landing_min_impact_speed:
			var dip: float = clampf(
				(fall_speed - landing_min_impact_speed) * landing_dip_per_mps,
				0.0, landing_max_dip
			)
			_landing_offset = dip  # positive = camera drops

	# Recover toward 0 with exponential decay.
	var t: float = clampf(landing_recovery_rate * delta, 0.0, 1.0)
	_landing_offset = lerp(_landing_offset, 0.0, t)
	_was_on_floor = grounded

# ---------------------------------------------------------------------------
# Camera tilt (lean on strafe)
# ---------------------------------------------------------------------------

func _update_tilt(delta: float, world_horiz_vel: Vector3) -> void:
	if not tilt_enabled:
		_tilt_current_deg = lerp(_tilt_current_deg, 0.0, clampf(tilt_smoothing * delta, 0.0, 1.0))
		return
	# Project world velocity onto body's local right axis → signed strafe speed.
	var body: CharacterBody3D = _player.get_node_or_null("Body") as CharacterBody3D
	if body == null:
		return
	var right: Vector3 = body.global_transform.basis.x
	var strafe_signed: float = world_horiz_vel.dot(right)
	var normalized: float = clampf(strafe_signed / tilt_reference_speed, -1.0, 1.0)
	# Lean AGAINST movement (right strafe → tilt left = positive Z roll).
	var target_deg: float = -normalized * tilt_max_degrees
	var t: float = clampf(tilt_smoothing * delta, 0.0, 1.0)
	_tilt_current_deg = lerp(_tilt_current_deg, target_deg, t)

# ---------------------------------------------------------------------------
# FOV pulse (sprint)
# ---------------------------------------------------------------------------

func _update_fov(delta: float, sprinting: bool) -> void:
	if not fov_enabled:
		_fov_current = lerp(_fov_current, fov_base, clampf(fov_smoothing * delta, 0.0, 1.0))
		return
	var target: float = fov_sprint if sprinting else fov_base
	var t: float = clampf(fov_smoothing * delta, 0.0, 1.0)
	_fov_current = lerp(_fov_current, target, t)

# ---------------------------------------------------------------------------
# Fire recoil kick
# ---------------------------------------------------------------------------

func _on_weapon_fired(weapon: int) -> void:
	if not recoil_enabled:
		return
	var kick_pitch: float = recoil_ar_pitch
	if weapon == PlayerAnimController.Weapon.RPG:
		kick_pitch = recoil_rpg_pitch
	# ADDITIVE — rapid AR fire stacks small kicks for a visible climb.
	_recoil_pitch_deg += kick_pitch
	_recoil_yaw_deg += _rng.randf_range(-recoil_yaw_jitter, recoil_yaw_jitter)


func _update_recoil_decay(delta: float) -> void:
	# Exponential decay toward 0.
	var t: float = clampf(recoil_decay_rate * delta, 0.0, 1.0)
	_recoil_pitch_deg = lerp(_recoil_pitch_deg, 0.0, t)
	_recoil_yaw_deg = lerp(_recoil_yaw_deg, 0.0, t)
