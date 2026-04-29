class_name HelicopterController
extends CharacterBody3D

const _VEHICLE_DUST_VFX := preload("res://src/gameplay/vfx/vehicle_dust_vfx.gd")

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

@export_group("Camera Pitch")
## Radians per screen pixel of mouse Y. Drives camera tilt ONLY (body doesn't pitch).
@export var camera_pitch_sensitivity: float = 0.0025
@export var camera_min_pitch_deg: float = -45.0
@export var camera_max_pitch_deg: float = 45.0
@export var invert_camera_pitch: bool = true

@export_group("Missiles")
## Shell scene spawned when firing a missile (reuses tank shell visual).
@export var missile_scene: PackedScene = preload("res://scenes/projectile/tank_shell.tscn")
## Seconds between individual missile shots.
@export var missile_fire_cooldown: float = 0.25
## Seconds to reload after all missiles are spent.
@export var missile_reload_time: float = 3.0
## Names of missile meshes in the GLB (in firing order).
@export var missile_names: PackedStringArray = ["r1", "r2", "r3", "r4"]
## Label that displays the reload countdown. Auto-found if left empty.
@export_node_path("Label") var reload_label_path: NodePath

@export_group("Rotor Nodes")
## Leave empty to auto-find by node name in GLB hierarchy.
@export_node_path("Node3D") var main_rotor_path: NodePath
@export_node_path("Node3D") var tail_rotor_path: NodePath
## Local axis the main rotor spins around (top rotor = UP).
@export var main_rotor_axis: Vector3 = Vector3.UP
## Local axis the tail rotor spins around. Try FORWARD / BACK / RIGHT
## until the tail rotor disc spins like a disc (not tumbles).
@export var tail_rotor_axis: Vector3 = Vector3.FORWARD

@export_group("Rotor Dust")
@export var rotor_dust_enabled: bool = true
@export var rotor_dust_max_ground_distance: float = 7.0
@export var rotor_dust_ground_offset: float = 0.08
@export var rotor_dust_min_speed: float = 6.0
@export_flags_3d_physics var rotor_dust_collision_mask: int = 1

@export_group("Crash Debris")
## Name of the main-rotor Node3D in the GLB hierarchy to use as a subtree
## for rotor-disc debris. Leave empty to skip rotor disc debris.
@export var debris_main_rotor_subtree_name: String = "Object_10"
## Names of individual MeshInstance3D nodes to spawn as separate tumbling
## pieces on death (one RigidBody3D per entry). Defaults to the 4 missile
## meshes so unfired missiles scatter when the helicopter explodes — any
## already-fired (hidden) missile is skipped at runtime.
@export var debris_blade_mesh_names: PackedStringArray = ["r1", "r2", "r3", "r4"]
## Name of the tail-boom Node3D subtree to detach as a single debris piece.
## Leave empty to skip tail-boom debris.
@export var debris_tail_subtree_name: String = "Circle_003_12"
## Mass (kg) for the rotor disc debris body.
@export var debris_rotor_mass: float = 60.0
## Mass (kg) for each individual blade debris body.
@export var debris_blade_mass: float = 20.0
## Mass (kg) for the tail-boom debris body.
@export var debris_tail_mass: float = 80.0
## Upward launch velocity (m/s) shared by all crash debris pieces.
@export var debris_upward_vel: float = 6.0
## Maximum random horizontal drift (m/s) for crash debris.
@export var debris_h_drift_max: float = 4.0
## Maximum random tumble angular velocity (rad/s) for crash debris.
@export var debris_tumble_max: float = 8.0
## Seconds before debris bodies are freed. 0 = match wreck_burn_seconds.
@export var debris_lifetime: float = 0.0

@export_group("Destroyed Wreck")
## Seconds the destroyed helicopter smokes before the wreck, smoke, and debris disappear.
@export var wreck_burn_seconds: float = 20.0
## Initial downward speed applied on death so stale floor state/snapshots cannot leave it hovering.
@export var wreck_initial_drop_speed: float = 2.2
## Clamp fall speed to avoid physics spikes in browser builds.
@export var wreck_terminal_fall_speed: float = 17.0
## Horizontal drift applied if the helicopter was hovering when destroyed.
@export var wreck_crash_drift_speed: float = 8.0
## Random angular speed range used while the wreck falls before impact.
@export var wreck_tumble_speed_min: float = 0.45
@export var wreck_tumble_speed_max: float = 1.25
## Air drag while the wreck autorotates down. Higher = less stone-like drop.
@export var wreck_air_drag: float = 0.18
## How much spinning rotors soften gravity during the first seconds of the crash.
@export var wreck_rotor_lift_gravity_scale: float = 0.42

var _active: bool = true
var _current_rotor_speed: float = 0.0
var _main_rotor: Node3D
var _tail_rotor: Node3D
var _rotor_dust: CPUParticles3D = null
## Set by VehicleSync when a non-local peer is driving — keeps rotors spinning
## even though our `_physics_process` is suspended.
var _remote_driver_active: bool = false


## Called by VehicleSync every snapshot. When true, our `_process` continues
## animating rotors so observers see the heli "alive".
func set_remote_driver_active(active: bool) -> void:
	_remote_driver_active = active


func is_locally_driven() -> bool:
	return _active and not _is_destroyed


func _process(delta: float) -> void:
	if _is_destroyed:
		_set_rotor_dust_emitting(false)
		return
	# When the local controller is active, _physics_process drives rotors.
	if _active:
		return
	_animate_rotors(_remote_driver_active, delta)
	_update_rotor_dust()

## Target yaw accumulated from mouse input (radians).
var _yaw_target: float = 0.0
## Current smoothed yaw applied to the body.
var _yaw_current: float = 0.0
## Current smoothed pitch tilt (radians).
var _pitch_tilt_current: float = 0.0
## Current smoothed roll tilt (radians).
var _roll_tilt_current: float = 0.0
## Camera pitch angle accumulated from mouse Y (affects camera only, not body).
var _camera_pitch: float = 0.0

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

@onready var _health: HealthComponent = $HealthComponent
var _is_destroyed: bool = false
var _spawn_collision_layer: int = 0
var _spawn_collision_mask: int = 0
var _wreck_burning: bool = false
var _wreck_tumble_velocity: Vector3 = Vector3.ZERO

## Missile meshes collected from the model at _ready (in order).
var _missiles: Array[MeshInstance3D] = []
var _missile_fire_timer: float = 0.0
var _missile_reload_timer: float = 0.0
var _is_reloading: bool = false
var _reload_label: Label

signal missile_fired
## Same as [signal missile_fired] but carries the spawn pose so network sync
## can replicate the missile on remote clients.
signal fired_with_aim(spawn_origin: Vector3, aim_dir: Vector3)
signal reload_started
signal reload_finished


func _ready() -> void:
	_spawn_collision_layer = collision_layer
	_spawn_collision_mask = collision_mask
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

	_setup_rotor_dust()

	_yaw_target = rotation.y
	_yaw_current = rotation.y
	# Start rotors at idle so they're visibly spinning from frame 1.
	_current_rotor_speed = idle_rotor_speed_rad_per_sec

	# Collect missile meshes by name.
	for missile_name in missile_names:
		var m: MeshInstance3D = _find_descendant_by_name(self, missile_name) as MeshInstance3D
		if m:
			_missiles.append(m)
		else:
			push_warning("HelicopterController: missile mesh '%s' not found" % missile_name)

	if not reload_label_path.is_empty():
		_reload_label = get_node_or_null(reload_label_path) as Label
	if _reload_label:
		_reload_label.text = ""

	if _health != null:
		_health.destroyed.connect(_on_destroyed)


func _on_destroyed(_by_source: int) -> void:
	if _is_destroyed:
		return
	_is_destroyed = true
	_wreck_burning = false
	_remote_driver_active = false
	_set_rotor_dust_emitting(false)
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
	# FORCE physics on. The heli may have been inactive when shot from another
	# vehicle; the wreck must keep falling even if no one is piloting it.
	set_physics_process(true)


func _random_sign() -> float:
	return -1.0 if randf() < 0.5 else 1.0


## Wreck mode: fall first, then burn only after real ground impact.
func _wreck_fall(delta: float) -> void:
	if _wreck_burning:
		return
	_apply_crash_tumble(delta)
	_animate_crash_rotors(delta)
	var rotor_t: float = clampf(_current_rotor_speed / maxf(max_rotor_speed_rad_per_sec, 0.001), 0.0, 1.0)
	var gravity_scale: float = lerpf(1.0, wreck_rotor_lift_gravity_scale, rotor_t)
	velocity.y = maxf(velocity.y - _gravity * gravity_scale * delta, -absf(wreck_terminal_fall_speed))
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


func _animate_crash_rotors(delta: float) -> void:
	_current_rotor_speed = lerpf(_current_rotor_speed, 0.0, clampf(delta * 0.9, 0.0, 1.0))
	if _main_rotor:
		_main_rotor.rotate_object_local(main_rotor_axis, _current_rotor_speed * delta)
	if _tail_rotor:
		_tail_rotor.rotate_object_local(tail_rotor_axis, _current_rotor_speed * delta)


func _start_crash_burn(_impact_speed: float) -> void:
	if _wreck_burning:
		return
	_wreck_burning = true
	velocity = Vector3.ZERO
	_wreck_tumble_velocity = Vector3.ZERO
	DestructionVFX.spawn_explosion(get_tree().current_scene, global_position + Vector3(0.0, 1.0, 0.0))
	# Spawn/hide detachable parts before applying the charred overlay. The
	# Apache rotor uses broad transparent planes; copying it after charred would
	# turn those planes into giant black cards.
	_spawn_crash_debris()
	DestructionVFX.apply_charred(self)
	DestructionVFX.spawn_smoke_fire(self, 1.1, false, wreck_burn_seconds)
	_schedule_wreck_hide()
	set_physics_process(false)


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseMotion:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			return
		var motion: InputEventMouseMotion = event
		_yaw_target -= motion.relative.x * mouse_sensitivity
		# Mouse Y tilts the CAMERA only — helicopter body stays level.
		var pitch_sign: float = -1.0 if invert_camera_pitch else 1.0
		_camera_pitch = clamp(
			_camera_pitch - motion.relative.y * camera_pitch_sensitivity * pitch_sign,
			deg_to_rad(camera_min_pitch_deg),
			deg_to_rad(camera_max_pitch_deg)
		)
	elif event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
				WebPointerLock.capture_from_user_gesture()
				return
			_try_fire_missile()
	elif event is InputEventKey:
		var key_event: InputEventKey = event
		if key_event.pressed and key_event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif key_event.pressed and key_event.keycode == KEY_F1:
			WebPointerLock.capture_from_user_gesture()


## Returns the camera pitch angle in radians — read by ChaseCamera to tilt
## the view up/down without rotating the helicopter body.
func get_aim_pitch() -> float:
	return _camera_pitch


## Enable or disable this vehicle. Inactive vehicles stop processing and zero velocity.
## Once destroyed, physics stays ON so the wreck keeps falling regardless of
## whether the player is currently piloting another vehicle.
func set_active(is_active: bool) -> void:
	# On the inactive→active edge, re-sync our cached body yaw to whatever
	# rotation.y currently is. While inactive, vehicle_sync.gd lerps the body
	# toward the server snapshot — `rotation.y` may have drifted since
	# [_ready] populated `_yaw_target` / `_yaw_current`. Without this the heli
	# snaps mid-air to its old yaw (and ChaseCamera, which uses heli body as
	# yaw_source, ends up offset to the side).
	if is_active and not _active and not _is_destroyed:
		_yaw_target = rotation.y
		_yaw_current = rotation.y
	_active = is_active
	if _is_destroyed:
		set_physics_process(not _wreck_burning)
		return
	set_physics_process(is_active)
	if not is_active:
		velocity = Vector3.ZERO
		_set_rotor_dust_emitting(false)
	else:
		WebPointerLock.capture_for_activation()


func apply_network_destroyed() -> void:
	if _is_destroyed:
		return
	_mark_health_destroyed_no_signal()
	_on_destroyed(DamageTypes.Source.HELI_MISSILE)


func apply_network_respawned() -> void:
	visible = true
	collision_layer = _spawn_collision_layer
	collision_mask = _spawn_collision_mask
	_is_destroyed = false
	_wreck_burning = false
	_wreck_tumble_velocity = Vector3.ZERO
	_remote_driver_active = false
	_current_rotor_speed = 0.0
	velocity = Vector3.ZERO
	_set_rotor_dust_emitting(false)
	rotation.x = 0.0
	rotation.z = 0.0
	_pitch_tilt_current = 0.0
	_roll_tilt_current = 0.0
	if _health != null:
		_health.reset()
	_restore_debris_source_visibility()
	DestructionVFX.clear_charred(self)
	DestructionVFX.clear_vfx(self)
	set_physics_process(_active)


func _mark_health_destroyed_no_signal() -> void:
	if _health != null and _health.has_method("force_destroyed"):
		_health.call("force_destroyed", DamageTypes.Source.HELI_MISSILE, false)


func _physics_process(delta: float) -> void:
	# Destroyed wreck: only gravity + collision, no input/aim/rotors.
	# Runs whether the player is in this vehicle or not, so the wreck falls
	# even while the player is flying the drone.
	if _is_destroyed:
		_wreck_fall(delta)
		return

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
	_update_rotor_dust()
	_tick_missile_timers(delta)


func _tick_missile_timers(delta: float) -> void:
	if _missile_fire_timer > 0.0:
		_missile_fire_timer -= delta
	if _is_reloading:
		_missile_reload_timer -= delta
		if _reload_label:
			_reload_label.text = "Reloading: %.1fs" % maxf(_missile_reload_timer, 0.0)
		if _missile_reload_timer <= 0.0:
			_finish_reload()


func _try_fire_missile() -> void:
	if _is_reloading or _missile_fire_timer > 0.0 or _missiles.is_empty():
		return
	# Find next visible missile (in declared order).
	var next_missile: MeshInstance3D = null
	for m in _missiles:
		if m.visible:
			next_missile = m
			break
	if next_missile == null:
		_start_reload()
		return
	_missile_fire_timer = missile_fire_cooldown
	_spawn_missile(next_missile)
	next_missile.visible = false
	missile_fired.emit()
	# If that was the last one, start reload.
	var any_visible: bool = false
	for m in _missiles:
		if m.visible:
			any_visible = true
			break
	if not any_visible:
		_start_reload()


func _spawn_missile(from_mesh: Node3D) -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null or missile_scene == null:
		return
	var shell: TankShell = missile_scene.instantiate() as TankShell
	# setup() before add_child so the raycast self-hit exception is wired in _ready.
	shell.setup(DamageTypes.Source.HELI_MISSILE, 34, self)
	# Network-authoritative damage — same pattern as the tank shell. Local
	# missiles only do VFX; server applies damage via vehicle_hit_claim.
	if shell.has_method("setup_network"):
		shell.call("setup_network", "heli_missile", false)
	get_tree().current_scene.add_child(shell)
	shell.global_position = from_mesh.global_position
	# Crosshair convergence: trace from camera to find crosshair target, then
	# aim missile from the pod to that point — fixes parallax between the
	# camera (above/behind) and the missile pods (below).
	var cam_forward: Vector3 = -cam.global_transform.basis.z
	var cam_pos: Vector3 = cam.global_position
	var target_point: Vector3 = cam_pos + cam_forward * 1000.0
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(cam_pos, target_point)
	query.exclude = [self.get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	if not hit.is_empty():
		target_point = hit.get("position", target_point)
	var aim_dir: Vector3 = (target_point - shell.global_position).normalized()
	var up_ref: Vector3 = Vector3.UP
	if absf(aim_dir.dot(Vector3.UP)) > 0.95:
		up_ref = Vector3.FORWARD
	shell.look_at(shell.global_position + aim_dir, up_ref)
	# Notify any network sync wrapper riding alongside the local controller.
	fired_with_aim.emit(shell.global_position, aim_dir)


func _start_reload() -> void:
	_is_reloading = true
	_missile_reload_timer = missile_reload_time
	if _reload_label:
		_reload_label.text = "Reloading: %.1fs" % _missile_reload_timer
	reload_started.emit()


func _finish_reload() -> void:
	_is_reloading = false
	for m in _missiles:
		m.visible = true
	if _reload_label:
		_reload_label.text = ""
	reload_finished.emit()


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


func _setup_rotor_dust() -> void:
	if not rotor_dust_enabled:
		return
	_rotor_dust = _VEHICLE_DUST_VFX.make_rotor_dust()
	add_child(_rotor_dust)


func _update_rotor_dust() -> void:
	if _rotor_dust == null:
		return
	if not rotor_dust_enabled or _is_destroyed or _current_rotor_speed < rotor_dust_min_speed:
		_set_rotor_dust_emitting(false)
		return

	var hit: Dictionary = _rotor_ground_hit()
	if hit.is_empty():
		_set_rotor_dust_emitting(false)
		return
	var hit_pos: Vector3 = hit.get("position", global_position)
	var hit_normal: Vector3 = hit.get("normal", Vector3.UP)
	_rotor_dust.global_position = hit_pos + hit_normal.normalized() * rotor_dust_ground_offset
	_set_rotor_dust_emitting(true)


func _rotor_ground_hit() -> Dictionary:
	var world: World3D = get_world_3d()
	if world == null:
		return {}
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null:
		return {}
	var from_pos: Vector3 = global_position + Vector3.UP * 0.65
	var to_pos: Vector3 = global_position - Vector3.UP * rotor_dust_max_ground_distance
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		from_pos,
		to_pos,
		rotor_dust_collision_mask
	)
	query.collide_with_areas = false
	query.exclude = [get_rid()]
	return space.intersect_ray(query)


func _set_rotor_dust_emitting(is_emitting: bool) -> void:
	if _rotor_dust != null:
		_rotor_dust.emitting = is_emitting


## Recursive depth-first search for a node with [param target_name].
func _find_descendant_by_name(root: Node, target_name: String) -> Node:
	if root.name == target_name:
		return root
	for child in root.get_children():
		var found: Node = _find_descendant_by_name(child, target_name)
		if found:
			return found
	return null


func _restore_debris_source_visibility() -> void:
	if not debris_main_rotor_subtree_name.is_empty():
		_set_subtree_visible(_find_descendant_by_name(self, debris_main_rotor_subtree_name), true)
	if not debris_tail_subtree_name.is_empty():
		_set_subtree_visible(_find_descendant_by_name(self, debris_tail_subtree_name), true)
	for blade_name: String in debris_blade_mesh_names:
		var blade: Node = _find_descendant_by_name(self, blade_name)
		if blade is MeshInstance3D:
			(blade as MeshInstance3D).visible = true


func _set_subtree_visible(root: Node, is_visible: bool) -> void:
	if root == null:
		return
	if root is Node3D:
		(root as Node3D).visible = is_visible
	for child: Node in root.get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).visible = is_visible
		_set_subtree_visible(child, is_visible)


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
	_set_rotor_dust_emitting(false)
	collision_layer = 0
	collision_mask = 0
	visible = false
	set_physics_process(false)


## Detach helicopter parts as flying RigidBody3D debris on destruction.
## Three potential pieces:
##   1. Rotor disc — entire main-rotor subtree cloned via spawn_subtree_debris.
##   2. Blade(s) — individual MeshInstance3D nodes cloned via spawn_static_mesh_debris.
##   3. Tail boom — tail-rotor subtree cloned via spawn_subtree_debris.
##
## Each spawned RigidBody3D is parented to current_scene so it persists after
## this helicopter's node is charred/freed. Collision exception is added against
## this CharacterBody3D so the debris flies through the hull cleanly on frame 0.
## Original mesh nodes are hidden so the live helicopter looks like it shed them.
func _spawn_crash_debris() -> void:
	var scene_root: Node = get_tree().current_scene
	var debris_lifetime_to_use: float = debris_lifetime
	if debris_lifetime_to_use <= 0.0:
		debris_lifetime_to_use = wreck_burn_seconds
	var spawn_large_subtrees: bool = not OS.has_feature("web")

	# --- Rotor disc subtree ---
	if not debris_main_rotor_subtree_name.is_empty():
		var rotor_node: Node3D = _find_descendant_by_name(self, debris_main_rotor_subtree_name) as Node3D
		if rotor_node != null:
			if spawn_large_subtrees:
				DestructionVFX.spawn_subtree_debris(
					scene_root,
					rotor_node,
					rotor_node.global_transform,
					self,
					debris_rotor_mass,
					debris_upward_vel,
					debris_h_drift_max,
					debris_tumble_max,
					debris_lifetime_to_use
				)
			# Belt-and-braces: walk the subtree and hide every MeshInstance3D
			# directly. `rotor_node.visible = false` SHOULD cascade via
			# is_visible_in_tree(), but GLB imports occasionally put mesh
			# nodes outside the expected subtree hierarchy.
			rotor_node.visible = false
			DestructionVFX.hide_visible_meshes(rotor_node)
		else:
			push_warning("HelicopterController: debris_main_rotor_subtree_name '%s' not found" \
				% debris_main_rotor_subtree_name)

	# --- Individual blade / missile meshes ---
	# Skip already-fired missiles (visible = false). Their mesh is still in the
	# scene tree but hidden, and spawning debris for a missile that the player
	# already launched would be visually wrong (the missile isn't there anymore).
	for blade_name: String in debris_blade_mesh_names:
		var blade: MeshInstance3D = _find_descendant_by_name(self, blade_name) as MeshInstance3D
		if blade == null:
			push_warning("HelicopterController: debris blade mesh '%s' not found" % blade_name)
			continue
		if not blade.visible:
			# Already-fired missile (or manually hidden). Expected; no warning.
			continue
		DestructionVFX.spawn_static_mesh_debris(
			scene_root,
			blade,
			blade.global_transform,
			Vector3(0.3, 0.05, 2.5),
			debris_blade_mass,
			debris_upward_vel,
			debris_h_drift_max,
			debris_tumble_max,
			debris_lifetime_to_use
		)
		blade.visible = false

	# --- Tail-boom subtree ---
	if not debris_tail_subtree_name.is_empty():
		var tail_node: Node3D = _find_descendant_by_name(self, debris_tail_subtree_name) as Node3D
		if tail_node != null:
			if spawn_large_subtrees:
				DestructionVFX.spawn_subtree_debris(
					scene_root,
					tail_node,
					tail_node.global_transform,
					self,
					debris_tail_mass,
					debris_upward_vel,
					debris_h_drift_max,
					debris_tumble_max,
					debris_lifetime_to_use
				)
			tail_node.visible = false
			DestructionVFX.hide_visible_meshes(tail_node)
		else:
			push_warning("HelicopterController: debris_tail_subtree_name '%s' not found" \
				% debris_tail_subtree_name)
