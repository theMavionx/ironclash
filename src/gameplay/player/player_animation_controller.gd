class_name PlayerAnimController
extends Node

## Player character animation driver.
##
## Owns base locomotion (idle / run per weapon) and one-shot actions
## (fire / reload / select) triggered by [WeaponController]. Only one
## animation plays on the [AnimationPlayer] at a time — actions fully replace
## locomotion for their duration. Bone-mask layering (fire while running) would
## need an [AnimationTree] and is deferred post-MVP.
##
## Animation names come from the imported GLB (design/gdd/animations.md):
##   AR_Idle / AR_RunF / AR_Burst / AR_Reload / AR_Select
##   RPG_Idle / RPG_RunF / RPG_Burst / RPG_Reload / RPG_Select

signal action_finished(action: int)

enum Weapon { AR, RPG }
enum Action { NONE, FIRE, RELOAD, SELECT }
enum MoveDir { IDLE, FORWARD, BACKWARD }

@export_group("Movement anim")
## Horizontal velocity magnitude below which the player is considered idle.
@export var move_threshold: float = 0.5
## Run animation speed multiplier at the reference walk speed.
@export var run_speed_scale: float = 2.0
## Fixed run-anim speed used when velocity exceeds [member reference_walk_speed]
## + ~0.5 m/s (i.e. sprinting). Overrides the proportional calculation so the
## anim never spins up infinitely fast.
@export var sprint_animation_speed: float = 2.5
## World-space velocity (m/s) at which the run anim plays at
## [member run_speed_scale]. Should match walk_speed in player_controller.gd.
@export var reference_walk_speed: float = 7.0
## Cross-fade duration (seconds) between animations. 0 = hard snap.
@export var blend_time: float = 0.2

@export_group("Paths")
@export_node_path("AnimationPlayer") var animation_player_path: NodePath = ^"../Body/Visual/AnimationPlayer"
@export_node_path("CharacterBody3D") var body_path: NodePath = ^"../Body"

# Lookup: weapon → { action → anim_name or [idle_name, run_name] }.
# Using a nested Dictionary because GDScript lacks a cleaner 2D lookup.
const ANIM_NAMES: Dictionary = {
	Weapon.AR: {
		Action.NONE:   ["AR_Idle", "AR_RunF"],
		Action.FIRE:   "AR_Burst",
		Action.RELOAD: "AR_Reload",
		Action.SELECT: "AR_Select",
	},
	Weapon.RPG: {
		Action.NONE:   ["RPG_Idle", "RPG_RunF"],
		Action.FIRE:   "RPG_Burst",
		Action.RELOAD: "RPG_Reload",
		Action.SELECT: "RPG_Select",
	},
}

var _anim: AnimationPlayer
var _body: CharacterBody3D
var _weapon: int = Weapon.AR
var _action: int = Action.NONE


func _ready() -> void:
	_anim = get_node_or_null(animation_player_path) as AnimationPlayer
	_body = get_node_or_null(body_path) as CharacterBody3D
	if _anim == null:
		push_warning("PlayerAnimController: AnimationPlayer not found at %s" % animation_player_path)
		return
	if _body == null:
		push_warning("PlayerAnimController: Body not found at %s" % body_path)

	# Loop locomotion clips, leave action (one-shot) clips non-looping so
	# animation_finished fires reliably.
	for weapon_key in ANIM_NAMES.keys():
		var actions: Dictionary = ANIM_NAMES[weapon_key]
		for action_key in actions.keys():
			var entry = actions[action_key]
			var names: Array = entry if entry is Array else [entry]
			var loop_it: bool = action_key == Action.NONE
			for anim_name in names:
				if _anim.has_animation(anim_name):
					var mode: int = Animation.LOOP_LINEAR if loop_it else Animation.LOOP_NONE
					_anim.get_animation(anim_name).loop_mode = mode

	_anim.playback_default_blend_time = blend_time
	_anim.animation_finished.connect(_on_anim_finished)

	# Start in weapon-specific idle.
	_play_locomotion(MoveDir.IDLE)

# ---------------------------------------------------------------------------
# Public API (called by WeaponController)
# ---------------------------------------------------------------------------

func set_weapon(w: int) -> void:
	_weapon = w

func play_fire() -> void:
	_play_action(Action.FIRE)

func play_reload() -> void:
	_play_action(Action.RELOAD)

func play_select(w: int) -> void:
	_weapon = w
	_play_action(Action.SELECT)

func is_busy() -> bool:
	return _action != Action.NONE

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if _anim == null:
		return
	if _action != Action.NONE:
		return  # One-shot in progress; don't override locomotion.
	_play_locomotion(_get_movement_direction())


func _play_locomotion(dir: int) -> void:
	if _body == null:
		return
	var weapon_anims: Array = ANIM_NAMES[_weapon][Action.NONE]
	var idle_name: String = weapon_anims[0]
	var run_name: String = weapon_anims[1]

	var want: String
	var speed: float

	if dir == MoveDir.IDLE:
		want = idle_name
		speed = 1.0
	else:
		want = run_name
		var horiz_mag: float = Vector2(_body.velocity.x, _body.velocity.z).length()
		var magnitude: float
		if horiz_mag > reference_walk_speed + 0.5:
			magnitude = sprint_animation_speed
		else:
			magnitude = (horiz_mag / reference_walk_speed) * run_speed_scale
		speed = magnitude if dir == MoveDir.FORWARD else -magnitude

	if _anim.current_animation != want and _anim.has_animation(want):
		_anim.play(want)
	_anim.speed_scale = speed


func _play_action(action: int) -> void:
	if _anim == null:
		return
	var anim_name: String = ANIM_NAMES[_weapon][action]
	if not _anim.has_animation(anim_name):
		push_warning("PlayerAnimController: animation '%s' not found" % anim_name)
		return
	_action = action
	# stop() + play() forces a restart even when the same action fires rapidly
	# (AR auto-fire re-triggers AR_Burst every ar_fire_interval_sec — without a
	# restart, play() on the already-current anim is a no-op and the visual
	# decouples from the ammo counter).
	_anim.stop()
	_anim.speed_scale = 1.0
	_anim.play(anim_name)


func _on_anim_finished(anim_name: String) -> void:
	if _action == Action.NONE:
		return  # Locomotion clips loop — this shouldn't fire for them.
	var expected: String = ANIM_NAMES[_weapon][_action]
	if anim_name != expected:
		return  # Stale signal (weapon switched mid-action) — ignore.
	var finished_action: int = _action
	_action = Action.NONE
	action_finished.emit(finished_action)


func _get_movement_direction() -> int:
	if _body == null:
		return MoveDir.IDLE
	var horiz: Vector3 = Vector3(_body.velocity.x, 0.0, _body.velocity.z)
	if horiz.length() < move_threshold:
		return MoveDir.IDLE
	var forward: Vector3 = -_body.global_transform.basis.z
	return MoveDir.FORWARD if horiz.dot(forward) > 0.0 else MoveDir.BACKWARD
