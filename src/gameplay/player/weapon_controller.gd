class_name WeaponController
extends Node

## Player weapon state + input handler.
##
## Tracks current weapon (AR / RPG), ammo counts per weapon, and drives
## [PlayerAnimController] for fire / reload / select actions. Emits signals
## for the HUD — does not touch UI directly (per .claude/rules/gameplay-code.md).
##
## Input (raw keys — MVP; migrate to InputMap post-MVP):
##   1  → select AR     2  → select RPG
##   LMB (hold)         → fire AR (auto)
##   LMB (single click) → fire RPG (single-shot, auto-reloads after)
##   R                  → reload AR (manual; RPG has no manual reload)
##
## KNOWN TECH DEBT (per .claude/rules/gameplay-code.md): all tuning values are
## @export defaults rather than loaded from a Resource file. Matches the
## existing PlayerController convention — will refactor to a shared
## PlayerTuningResource post-MVP.

signal ammo_changed(weapon: int, current: int, maximum: int)
signal weapon_switched(weapon: int)
signal fired(weapon: int)

@export_group("AR (Kalash)")
@export var ar_mag_size: int = 30
## Minimum seconds between auto-fire triggers while LMB is held. 0.1 ≈ 600 RPM.
@export var ar_fire_interval_sec: float = 0.1
## Damage per AR bullet dealt to any HealthComponent the hitscan strikes.
@export var ar_damage: int = 10
## Hitscan max range (metres).
@export var ar_max_range: float = 500.0
## Seconds between LMB press and first bullet spawn. Gives the fire animation
## time to transition from low-ready pose to raised-firing pose — prevents
## bullets from visually spawning while the rifle is still at the hip.
@export var ar_raise_delay_sec: float = 0.3

@export_group("RPG")
@export var rpg_mag_size: int = 1

@export_group("Paths")
@export_node_path("Node") var anim_controller_path: NodePath = ^"../PlayerAnimController"
## Camera used as the hitscan origin. Ray travels along camera forward for
## crosshair-accurate aim (classic FPS pattern).
@export_node_path("Camera3D") var camera_path: NodePath = ^"../CameraPivot/SpringArm3D/CameraRig/Camera3D"
## Node3D at the visual muzzle tip of the rifle — where the flash and tracer
## visually originate. Parented to the AK47 BoneAttachment3D so it follows
## the rifle's actual pose (including the aim-look modifier's spine bend).
## Drag to fine-tune offset along the barrel in the Inspector.
@export_node_path("Node3D") var muzzle_path: NodePath = ^"../Body/Visual/Player/Skeleton3D/ak47/Muzzle"
## PhysicsBody3D to exclude from the hitscan (usually the player's own body).
@export_node_path("CollisionObject3D") var shooter_path: NodePath = ^"../Body"

var _anim_ctrl: PlayerAnimController
var _camera: Camera3D
var _muzzle: Node3D
var _shooter: CollisionObject3D
## Seconds since LMB was first pressed for a fire burst. -1 = no active burst.
## Keeps counting even AFTER LMB release so a single click still fires once
## when the raise delay completes (no-trigger-no-shot bug fix).
var _ar_fire_held_time: float = -1.0
## Previous-frame LMB state — used to detect rising edge (click start).
var _ar_lmb_was_pressed: bool = false
var _current_weapon: int = PlayerAnimController.Weapon.AR
var _ar_ammo: int = 30
var _rpg_ammo: int = 1
## True while a select / reload / RPG-fire sequence is locking input.
## AR fire does NOT set this (auto-fire must keep working while AR_Burst loops).
var _is_busy: bool = false
var _time_since_last_fire: float = 999.0


func _ready() -> void:
	_anim_ctrl = get_node_or_null(anim_controller_path) as PlayerAnimController
	if _anim_ctrl == null:
		push_warning("WeaponController: PlayerAnimController not found at %s" % anim_controller_path)
		return
	_camera = get_node_or_null(camera_path) as Camera3D
	_muzzle = get_node_or_null(muzzle_path) as Node3D
	_shooter = get_node_or_null(shooter_path) as CollisionObject3D
	if _camera == null:
		push_warning("WeaponController: camera_path unset — AR tracer will not fire")
	if _muzzle == null:
		push_warning("WeaponController: muzzle_path unset — flash/tracer fall back to camera position")
	_ar_ammo = ar_mag_size
	_rpg_ammo = rpg_mag_size
	_anim_ctrl.set_weapon(_current_weapon)
	_anim_ctrl.action_finished.connect(_on_action_finished)
	# Broadcast initial state so HUD can paint first frame without guessing.
	weapon_switched.emit(_current_weapon)
	_emit_current_ammo()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func get_current_weapon() -> int:
	return _current_weapon

func get_current_ammo() -> int:
	return _ar_ammo if _current_weapon == PlayerAnimController.Weapon.AR else _rpg_ammo

func get_current_mag_size() -> int:
	return ar_mag_size if _current_weapon == PlayerAnimController.Weapon.AR else rpg_mag_size

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	_time_since_last_fire += delta
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_ar_fire_held_time = -1.0
		_ar_lmb_was_pressed = false
		return
	# AR fire: rising-edge starts the raise timer, which keeps ticking until
	# the shot fires (even if LMB was released in the meantime — single-click
	# still fires once the raise animation completes).
	var lmb_now: bool = _current_weapon == PlayerAnimController.Weapon.AR \
			and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var rising_edge: bool = lmb_now and not _ar_lmb_was_pressed
	if rising_edge:
		_ar_fire_held_time = 0.0
		if not _is_busy and _ar_ammo > 0 and _anim_ctrl != null:
			_anim_ctrl.play_fire()
	# Tick the timer if a burst is in progress (started by rising edge),
	# regardless of whether LMB is still held.
	if _ar_fire_held_time >= 0.0:
		_ar_fire_held_time += delta
		_try_fire()
		# Burst ends when raise-delay has elapsed AND LMB is no longer held.
		# (If LMB is still held, we stay in auto-fire mode.)
		if _ar_fire_held_time >= ar_raise_delay_sec and not lmb_now:
			_ar_fire_held_time = -1.0
	_ar_lmb_was_pressed = lmb_now


func _unhandled_input(event: InputEvent) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventKey:
		var key_ev := event as InputEventKey
		if key_ev.pressed and not key_ev.echo:
			match key_ev.keycode:
				KEY_1: _switch_weapon(PlayerAnimController.Weapon.AR)
				KEY_2: _switch_weapon(PlayerAnimController.Weapon.RPG)
				KEY_R: _try_reload()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		# RPG fires on the press edge only (no auto). AR handled in _process.
		if mb.pressed \
				and mb.button_index == MOUSE_BUTTON_LEFT \
				and _current_weapon == PlayerAnimController.Weapon.RPG:
			_try_fire()

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

func _switch_weapon(w: int) -> void:
	if _is_busy:
		return
	if _current_weapon == w:
		return
	_current_weapon = w
	# Reset fire cooldown so the first shot after switching respects the new
	# weapon's fire interval (prevents instant fire if select anim is short).
	_time_since_last_fire = 0.0
	_is_busy = true
	_anim_ctrl.play_select(w)
	weapon_switched.emit(w)
	_emit_current_ammo()


func _try_fire() -> void:
	if _is_busy:
		return
	if _time_since_last_fire < ar_fire_interval_sec:
		return
	if _current_weapon == PlayerAnimController.Weapon.AR:
		if _ar_ammo <= 0:
			return  # Empty mag — dry-fire SFX hook would go here.
		# Wait for the weapon-raise animation to finish before the first
		# bullet of a burst. Subsequent shots auto-fire because
		# _ar_fire_held_time keeps growing while LMB stays held.
		if _ar_fire_held_time < ar_raise_delay_sec:
			return
		_ar_ammo -= 1
		_time_since_last_fire = 0.0
		_anim_ctrl.play_fire()
		_spawn_ar_fire_vfx()
		fired.emit(_current_weapon)
		_emit_current_ammo()
	else:
		if _rpg_ammo <= 0:
			return
		_rpg_ammo -= 1
		_time_since_last_fire = 0.0
		# RPG locks input until the auto-reload chain finishes in
		# _on_action_finished. AR does not lock — auto-fire must keep flowing.
		_is_busy = true
		_anim_ctrl.play_fire()
		fired.emit(_current_weapon)
		_emit_current_ammo()


func _try_reload() -> void:
	if _is_busy:
		return
	# Only AR reloads via R — RPG reloads automatically after firing.
	if _current_weapon != PlayerAnimController.Weapon.AR:
		return
	if _ar_ammo >= ar_mag_size:
		return
	_is_busy = true
	_anim_ctrl.play_reload()


func _on_action_finished(action: int) -> void:
	match action:
		PlayerAnimController.Action.SELECT:
			_is_busy = false
		PlayerAnimController.Action.RELOAD:
			if _current_weapon == PlayerAnimController.Weapon.AR:
				_ar_ammo = ar_mag_size
			else:
				_rpg_ammo = rpg_mag_size
			_is_busy = false
			_emit_current_ammo()
		PlayerAnimController.Action.FIRE:
			# RPG: after each shot the mag is empty → chain into reload. Keep
			# _is_busy true across the chain so input stays locked.
			if _current_weapon == PlayerAnimController.Weapon.RPG and _rpg_ammo <= 0:
				_anim_ctrl.play_reload()
			else:
				_is_busy = false


func _emit_current_ammo() -> void:
	ammo_changed.emit(_current_weapon, get_current_ammo(), get_current_mag_size())


func _spawn_ar_fire_vfx() -> void:
	if _camera == null:
		return
	var aim_origin: Vector3 = _camera.global_position
	var aim_dir: Vector3 = -_camera.global_transform.basis.z
	PlayerFireVFX.spawn_ar_shot(
		get_tree().current_scene,
		_muzzle,  # parent the flash here so it moves rigidly with the rifle
		aim_origin,
		aim_dir,
		_shooter,
		ar_damage,
		ar_max_range,
	)
