class_name PlayerController
extends Node3D

## Third-person infantry controller — implements design/gdd/player-controller.md.
## Local-only at MVP (no networking yet — pending ADR-0002 / S1-003 networking prototype).
##
## Structure (intentional, user-requested):
## The root is an empty [Node3D] container. Physics lives on the child [Body]
## CharacterBody3D. The camera rig (CameraPivot → SpringArm3D → Camera3D) is a
## sibling of Body so its transform can be adjusted independently in the editor.
## The script on this root reads input, drives [Body] via physics, and syncs
## the CameraPivot's world transform to the body each physics tick.
##
## Movement is acceleration-based (soft ramp, not instant). Target velocity is
## derived from WASD input rotated into body-yaw space. Actual velocity lerps
## toward target using [member accel_rate_grounded]. Gravity decouples vertical
## motion.
##
## State machine: IDLE / WALK / SPRINT / CROUCH / ADS / AIRBORNE / DISABLED.
## Sprint requires forward-dominant input (dot(input, forward) > 0.5) AND
## stamina > 0 AND not locked out. Stamina lockout triggers at 0, clears at 30.
##
## KNOWN TECH DEBT (per .claude/rules/gameplay-code.md): all tuning values are
## @export defaults rather than loaded from a Resource file. Refactor to
## PlayerTuningResource in Sprint 3 or post-MVP.

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

signal stamina_changed(current: float, maximum: float)
signal sprint_lockout_changed(locked: bool)
signal jumped
signal active_changed(is_active: bool)

# ---------------------------------------------------------------------------
# Exports — Movement (see GDD § Tuning Knobs)
# ---------------------------------------------------------------------------

@export_group("Speeds (m/s)")
@export var walk_speed: float = 3.5
@export var sprint_speed: float = 5.5
@export var crouch_speed: float = 1.75
@export var ads_speed: float = 2.5
## Multiplier applied to movement speed when walking backward (input.y > 0).
@export var backward_speed_multiplier: float = 0.5

@export_group("Dev Speed Boost")
## Dev-only fast-travel multiplier. Toggled on/off by double-tapping Tab so a
## developer can inspect the map from the player's POV without leaving the
## game. Not shipped in release builds of the GDD — remove this export group
## and the tab handler before gold.
@export var dev_speed_boost_multiplier: float = 4.0
## Max seconds between two Tab presses that still count as a double-tap.
@export var dev_double_tap_threshold_sec: float = 0.4

@export_group("Acceleration")
@export var accel_rate_grounded: float = 12.0
@export var accel_rate_airborne: float = 2.0
@export var max_accel_per_tick: float = 2.5

@export_group("Jump / Gravity")
@export var jump_impulse: float = 5.5
@export var gravity: float = 12.5

@export_group("Stamina")
@export var stamina_max: float = 100.0
@export var stamina_sprint_drain_rate: float = 15.0
## Stamina drained per jump. Default 0 = Fortnite-style free jump. Set > 0 to
## enforce the GDD's original "jump costs stamina" rule.
@export var stamina_jump_cost: float = 0.0
@export var stamina_regen_delay: float = 1.0
@export var stamina_regen_rate: float = 25.0
@export var stamina_sprint_lockout_threshold: float = 30.0

@export_group("Look")
@export var mouse_sensitivity_deg_per_px: float = 0.09
@export var pitch_clamp_deg: float = 85.0
@export var ads_sensitivity_multiplier: float = 0.7
## Exponential smoothing on mouse input for camera "weight" feel. 0 = instant
## (most responsive), higher = more lag. Typical subtle range: 0.0–0.3.
@export_range(0.0, 1.0, 0.05) var mouse_smoothing: float = 0.0

@export_group("Camera Sync")
## Vertical offset from [member _body] origin to the camera pivot
## (shoulder/neck height — lower than head for Fortnite-style over-shoulder
## look-down). Camera pivot follows body position + this offset each tick.
## SpringArm3D on the pivot then applies the shoulder X-offset and arm length.
@export var camera_pivot_height: float = 1.5

@export_group("Strafe lean")
## Max roll angle (degrees) applied to the body when strafing A/D. Adds
## visual weight to sideways movement without rotating the body or camera.
## Pure cosmetic — does not affect aim, collision is not rebuilt.
@export var body_lean_max_deg: float = 2.0
## How fast the body rolls into / out of the lean.
@export var body_lean_rate: float = 10.0

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

enum State { IDLE, WALK, SPRINT, CROUCH, ADS, AIRBORNE, DISABLED }

var _active: bool = true
var _state: int = State.IDLE

var _yaw: float = 0.0
var _pitch: float = 0.0
var _mouse_delta: Vector2 = Vector2.ZERO
## Low-pass-filtered mouse delta when [member mouse_smoothing] > 0.
var _mouse_delta_smoothed: Vector2 = Vector2.ZERO

var _is_crouching: bool = false
var _is_ads: bool = false
## True for one physics tick after a jump input press, consumed in [method _try_jump].
var _wants_jump: bool = false

var _stamina: float = 100.0
var _last_drain_time_msec: int = 0
var _sprint_locked_out: bool = false

## Dev-only: double-tap-Tab fast-travel toggle.
var _dev_speed_boost_active: bool = false
var _last_tab_press_msec: int = -1

@onready var _body: CharacterBody3D = $Body
@onready var _health: HealthComponent = $Body/HealthComponent
@onready var _camera_pivot: Node3D = $CameraPivot
@onready var _camera: Camera3D = $CameraPivot/SpringArm3D/CameraRig/Camera3D

# ---------------------------------------------------------------------------
# Public API (matches ChaseCamera's expectations — mirrors Tank/Drone)
# ---------------------------------------------------------------------------

func get_aim_yaw() -> float:
	return _yaw

func get_aim_pitch() -> float:
	return _pitch

func get_stamina() -> float:
	return _stamina

func is_sprint_locked_out() -> bool:
	return _sprint_locked_out

## Enable/disable controller. Disabled = in vehicle / dead / match not ACTIVE.
func set_active(is_active: bool) -> void:
	if _active == is_active:
		return
	_active = is_active
	set_physics_process(is_active)
	set_process_unhandled_input(is_active)
	if _camera != null:
		_camera.current = is_active
	if is_active:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_state = State.IDLE
	else:
		if _body != null:
			_body.velocity = Vector3.ZERO
		_mouse_delta = Vector2.ZERO
		_state = State.DISABLED
	active_changed.emit(is_active)

## Respawn at a world position facing a yaw (radians). Called by Respawn system.
func respawn_at(spawn_position: Vector3, facing_yaw: float = 0.0) -> void:
	if _body != null:
		_body.global_position = spawn_position
		_body.velocity = Vector3.ZERO
	_yaw = facing_yaw
	_pitch = 0.0
	_stamina = stamina_max
	_sprint_locked_out = false
	_is_crouching = false
	_is_ads = false
	if _health != null:
		_health.reset()
	stamina_changed.emit(_stamina, stamina_max)
	sprint_lockout_changed.emit(false)
	set_active(true)

# ---------------------------------------------------------------------------
# Built-in
# ---------------------------------------------------------------------------

func _ready() -> void:
	_stamina = stamina_max
	# Initial yaw from the root node's rotation, if any was set in the editor.
	_yaw = rotation.y
	# The root Node3D's rotation is not used for gameplay — only _yaw drives
	# the body. Zero root rotation so the scene transform stays neutral.
	rotation = Vector3.ZERO
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _health != null:
		_health.destroyed.connect(_on_self_destroyed)
	if _body != null:
		_body.rotation.y = _yaw
	# Initial camera-pivot sync so the first frame is not snapped to world origin.
	_sync_camera_pivot()
	stamina_changed.emit(_stamina, stamina_max)


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return

	# Esc releases the mouse so the player can click on another window or the
	# editor. Clicking back into the game window re-captures it.
	if event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			_mouse_delta = Vector2.ZERO
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	# While the cursor is free, the first click back into the window recaptures
	# it instead of firing (prevents accidental shots on focus-regain).
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return

	if event is InputEventMouseMotion:
		# Only track delta when captured — otherwise the cursor is free and
		# mouse movement should not rotate the view.
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_mouse_delta += (event as InputEventMouseMotion).relative
	elif event.is_action_pressed("jump"):
		# Queue one jump — consumed next physics tick in _try_jump(). Flag
		# pattern avoids missing a single-frame press when physics runs slower
		# than display.
		_wants_jump = true
	elif event.is_action_pressed("interact"):
		pass  # Hook for vehicle entry / drone entry.
	elif event is InputEventKey:
		# Dev-only: double-tap Tab toggles a 4× movement speed for map inspection.
		# Raw keycode check — Tab is not in InputMap yet (reserved for scoreboard).
		var key_ev := event as InputEventKey
		if key_ev.pressed and not key_ev.echo and key_ev.keycode == KEY_TAB:
			var now_msec: int = Time.get_ticks_msec()
			var gap_sec: float = INF if _last_tab_press_msec < 0 \
					else float(now_msec - _last_tab_press_msec) / 1000.0
			if gap_sec <= dev_double_tap_threshold_sec:
				_dev_speed_boost_active = not _dev_speed_boost_active
				_last_tab_press_msec = -1  # reset so 3rd tap doesn't chain-toggle
			else:
				_last_tab_press_msec = now_msec


func _physics_process(delta: float) -> void:
	if not _active or _body == null:
		return

	_apply_look(delta)
	_update_action_states()
	_update_state_machine()

	var target_velocity: Vector3 = _compute_target_velocity()
	_apply_horizontal_movement(target_velocity, delta)
	_try_jump()
	_apply_gravity(delta)
	_body.move_and_slide()

	_update_strafe_lean(delta)
	_sync_camera_pivot()
	_update_stamina(delta)

# ---------------------------------------------------------------------------
# Look
# ---------------------------------------------------------------------------

func _apply_look(delta: float) -> void:
	var sens_rad: float = deg_to_rad(mouse_sensitivity_deg_per_px)
	if _is_ads:
		sens_rad *= ads_sensitivity_multiplier

	# Optional low-pass filter on mouse input. At mouse_smoothing=0 this is an
	# instant pass-through; at higher values the camera "catches up" behind the
	# raw input for a subtle weighty feel. Framerate-independent via delta.
	var effective_delta: Vector2
	if mouse_smoothing > 0.0:
		var catchup: float = clampf((1.0 - mouse_smoothing) * 60.0 * delta, 0.0, 1.0)
		_mouse_delta_smoothed = _mouse_delta_smoothed.lerp(_mouse_delta, catchup)
		effective_delta = _mouse_delta_smoothed
		# Partially consume the raw buffer so it doesn't accumulate forever.
		_mouse_delta = _mouse_delta.lerp(Vector2.ZERO, catchup)
	else:
		effective_delta = _mouse_delta
		_mouse_delta = Vector2.ZERO
		_mouse_delta_smoothed = Vector2.ZERO

	# Mouse right → yaw left (convention for FPS/TPS).
	_yaw -= effective_delta.x * sens_rad
	# Inverted Y: mouse up (delta.y < 0) → camera tilts DOWN.
	_pitch += effective_delta.y * sens_rad

	var pitch_limit: float = deg_to_rad(pitch_clamp_deg)
	_pitch = clampf(_pitch, -pitch_limit, pitch_limit)

	# Body rotates with yaw (capsule faces look direction).
	if _body != null:
		_body.rotation.y = _yaw

## Pulls the CameraPivot's world transform to track the Body and aim direction.
## Called each physics tick AFTER move_and_slide so the pivot is never one frame
## behind the body's actual position.
func _sync_camera_pivot() -> void:
	if _body == null or _camera_pivot == null:
		return
	_camera_pivot.global_position = _body.global_position + Vector3(0.0, camera_pivot_height, 0.0)
	# Euler order YXZ applies Y first then X — standard FPS yaw+pitch gimbal.
	# Negative _pitch so mouse-up → camera looks up (visual confirm: nose tips up).
	_camera_pivot.rotation = Vector3(-_pitch, _yaw, 0.0)

# ---------------------------------------------------------------------------
# Action / state machine
# ---------------------------------------------------------------------------

func _update_action_states() -> void:
	var crouch_held: bool = Input.is_action_pressed("crouch")
	if crouch_held:
		_is_crouching = true
	elif _is_crouching:
		_is_crouching = false  # MVP: no ceiling check.
	_is_ads = Input.is_action_pressed("ads")


func _update_state_machine() -> void:
	if not _body.is_on_floor():
		_state = State.AIRBORNE
		return

	var input_vector: Vector2 = _get_move_input()
	var wants_sprint: bool = Input.is_action_pressed("sprint")

	if _is_ads:
		_state = State.ADS
	elif _is_crouching:
		_state = State.CROUCH
	elif input_vector.length_squared() < 0.01:
		_state = State.IDLE
	elif wants_sprint and _can_sprint(input_vector):
		_state = State.SPRINT
	else:
		_state = State.WALK


func _can_sprint(input_vector: Vector2) -> bool:
	if _sprint_locked_out:
		return false
	if _stamina <= 0.0:
		return false
	# Forward-dominant requirement. input.y < -0.5 means W is held strongly.
	return input_vector.y < -0.5

# ---------------------------------------------------------------------------
# Velocity
# ---------------------------------------------------------------------------

func _compute_target_velocity() -> Vector3:
	if _state == State.DISABLED:
		return Vector3.ZERO

	var input_vector: Vector2 = _get_move_input()
	if input_vector.length_squared() < 0.001:
		return Vector3.ZERO

	# Rotate input into world space by Body yaw.
	var forward: Vector3 = -_body.global_transform.basis.z
	var right: Vector3 = _body.global_transform.basis.x
	var direction: Vector3 = (right * input_vector.x + forward * -input_vector.y).normalized()

	var speed: float = _current_max_speed()
	# Backward movement (S dominant) is slower than forward.
	if input_vector.y > 0.0:
		speed *= backward_speed_multiplier
	# Dev fast-travel (double-tap Tab). Applied after backward multiplier so
	# backward speed still scales linearly with the boost.
	if _dev_speed_boost_active:
		speed *= dev_speed_boost_multiplier
	return direction * speed


func _current_max_speed() -> float:
	match _state:
		State.IDLE:     return 0.0
		State.WALK:     return walk_speed
		State.SPRINT:   return sprint_speed
		State.CROUCH:   return crouch_speed
		State.ADS:      return ads_speed
		State.AIRBORNE: return walk_speed
		_:              return 0.0


func _apply_horizontal_movement(target_velocity: Vector3, delta: float) -> void:
	var current_horiz: Vector3 = Vector3(_body.velocity.x, 0.0, _body.velocity.z)
	var target_horiz: Vector3 = Vector3(target_velocity.x, 0.0, target_velocity.z)

	var rate: float = accel_rate_grounded if _body.is_on_floor() else accel_rate_airborne
	var velocity_delta: Vector3 = (target_horiz - current_horiz) * rate * delta

	if velocity_delta.length() > max_accel_per_tick:
		velocity_delta = velocity_delta.normalized() * max_accel_per_tick

	current_horiz += velocity_delta
	_body.velocity.x = current_horiz.x
	_body.velocity.z = current_horiz.z


func _apply_gravity(delta: float) -> void:
	if _body.is_on_floor() and _body.velocity.y < 0.0:
		_body.velocity.y = 0.0
	else:
		_body.velocity.y -= gravity * delta


## Rolls the body on its Z axis toward the strafe direction for visual weight.
## Body yaw stays locked to mouse (chase-cam), camera unaffected. Pure cosmetic —
## capsule tilts a few degrees but collision impact is negligible at ±8°.
func _update_strafe_lean(delta: float) -> void:
	if _body == null:
		return
	var input: Vector2 = _get_move_input()
	# A = -1 → lean left (positive Z roll in Godot's -Z forward convention).
	# D = +1 → lean right (negative Z roll).
	var target_roll: float = -input.x * deg_to_rad(body_lean_max_deg)
	var t: float = clampf(body_lean_rate * delta, 0.0, 1.0)
	_body.rotation.z = lerp_angle(_body.rotation.z, target_roll, t)


## Consumes [member _wants_jump] and applies vertical impulse if grounded.
## Costs [member stamina_jump_cost] stamina (default 0 = Fortnite-parity).
## Called before [method _apply_gravity] so the impulse isn't immediately
## eaten by the grounded-clamp branch above.
func _try_jump() -> void:
	if not _wants_jump:
		return
	_wants_jump = false
	if not _body.is_on_floor():
		return  # Airborne at the tick the press landed — drop it (no double-jump).
	_body.velocity.y = jump_impulse
	if stamina_jump_cost > 0.0:
		_stamina = maxf(0.0, _stamina - stamina_jump_cost)
		stamina_changed.emit(_stamina, stamina_max)
	jumped.emit()

# ---------------------------------------------------------------------------
# Stamina
# ---------------------------------------------------------------------------

func _update_stamina(delta: float) -> void:
	var old_stamina: float = _stamina
	var now_msec: int = Time.get_ticks_msec()

	if _state == State.SPRINT:
		_stamina = maxf(0.0, _stamina - stamina_sprint_drain_rate * delta)
		_last_drain_time_msec = now_msec
	else:
		var since_drain_sec: float = float(now_msec - _last_drain_time_msec) / 1000.0
		if since_drain_sec >= stamina_regen_delay and _stamina < stamina_max:
			_stamina = minf(stamina_max, _stamina + stamina_regen_rate * delta)

	if _stamina <= 0.0 and not _sprint_locked_out:
		_sprint_locked_out = true
		sprint_lockout_changed.emit(true)
	elif _sprint_locked_out and _stamina >= stamina_sprint_lockout_threshold:
		_sprint_locked_out = false
		sprint_lockout_changed.emit(false)

	if not is_equal_approx(old_stamina, _stamina):
		stamina_changed.emit(_stamina, stamina_max)

# ---------------------------------------------------------------------------
# Input helpers
# ---------------------------------------------------------------------------

func _get_move_input() -> Vector2:
	return Input.get_vector("move_left", "move_right", "move_forward", "move_back")

# ---------------------------------------------------------------------------
# Death
# ---------------------------------------------------------------------------

func _on_self_destroyed(_by_source: int) -> void:
	set_active(false)
