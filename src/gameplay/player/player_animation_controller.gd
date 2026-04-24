class_name PlayerAnimController
extends Node

## Player character animation driver — AnimationTree-based with upper-body
## bone mask layering.
##
## Builds an [AnimationTree] programmatically in [method _ready] so the
## scene file stays clean and the bone filter can be edited in code. Tree
## topology:
##
##     BlendTree root
##       locomotion  (BlendSpace1D: idle↔run)  ──┐
##       action_anim (AnimationNodeAnimation)  ──┼──► oneshot ─► output
##                                               │
##     oneshot (OneShot, filtered to upper body)─┘
##
## The OneShot node has [member AnimationNodeOneShot.filter_enabled] = true and
## only the upper-body track paths enabled. When an action fires, its animation
## replaces the upper body; the legs and hips keep playing locomotion. This is
## the Godot equivalent of a TPS "upper-body layer".
##
## Animation names come from the imported GLB (design/gdd/animations.md):
##   AR_Idle / AR_RunF / AR_Burst / AR_Reload / AR_Select
##   RPG_Idle / RPG_RunF / RPG_Burst / RPG_Reload / RPG_Select
##
## Previous implementation (pre-2026-04-21) used the AnimationPlayer directly
## and could not split layers — reloading while running froze the legs. This
## refactor fixes that per user spec.

signal action_finished(action: int)
signal action_started(action: int, anim_name: String)

enum Weapon { AR, RPG }
enum Action { NONE, FIRE, RELOAD, SELECT }
enum MoveDir { IDLE, FORWARD, BACKWARD }

# Upper-body bone list. Track paths in animations look like
# "Player/Skeleton3D:soldier_Spine" — the prefix is set via
# [member skeleton_track_prefix]. The OneShot filter accepts these full paths.
const UPPER_BODY_BONES: PackedStringArray = [
	"soldier_Spine", "soldier_Spine1", "soldier_Spine2",
	"soldier_Neck", "soldier_Head",
	"soldier_LeftShoulder", "soldier_LeftArm", "soldier_LeftForeArm", "soldier_LeftHand",
	"soldier_LeftHandThumb1", "soldier_LeftHandThumb2", "soldier_LeftHandThumb3",
	"soldier_LeftHandMiddle1", "soldier_LeftHandMiddle2", "soldier_LeftHandMiddle3",
	"soldier_LeftHandIndex1", "soldier_LeftHandIndex2", "soldier_LeftHandIndex3",
	"soldier_LeftHandRing1", "soldier_LeftHandRing2", "soldier_LeftHandRing3",
	"soldier_LeftHandPinky1", "soldier_LeftHandPinky2", "soldier_LeftHandPinky3",
	"soldier_RightShoulder", "soldier_RightArm", "soldier_RightForeArm", "soldier_RightHand",
	"soldier_RightHandThumb1", "soldier_RightHandThumb2", "soldier_RightHandThumb3",
	"soldier_RightHandIndex1", "soldier_RightHandIndex2", "soldier_RightHandIndex3",
	"soldier_RightHandMiddle1", "soldier_RightHandMiddle2", "soldier_RightHandMiddle3",
	"soldier_RightHandRing1", "soldier_RightHandRing2", "soldier_RightHandRing3",
	"soldier_RightHandPinky1", "soldier_RightHandPinky2", "soldier_RightHandPinky3",
]

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

@export_group("Movement anim")
## Horizontal velocity magnitude below which the player is considered idle.
@export var move_threshold: float = 0.5
## Playback multiplier applied to the run clip at [member reference_walk_speed].
## Below that speed the multiplier scales linearly with velocity.
## 1.0 = play the clip at its native pace. Raise if feet slide forward;
## lower if legs look like they're running faster than the world.
@export var run_speed_scale: float = 1.0
## Fixed playback multiplier used when the player is sprinting (velocity
## exceeds [member reference_walk_speed] + ~0.5 m/s). Clamps against infinite
## spin-up on very high velocities.
@export var sprint_animation_speed: float = 1.4
## World-space velocity (m/s) at which the run anim plays at
## [member run_speed_scale]. Should match walk_speed in player_controller.gd.
@export var reference_walk_speed: float = 3.5

@export_group("Tree blend")
## OneShot fade-in time (seconds). Lower = snappier action transition.
@export var action_fadein: float = 0.1
## OneShot fade-out time (seconds).
@export var action_fadeout: float = 0.15
## Seconds to blend between idle and run in the locomotion blend space.
@export var locomotion_blend_smoothing: float = 6.0

@export_group("Paths")
@export_node_path("AnimationPlayer") var animation_player_path: NodePath = ^"../Body/Visual/AnimationPlayer"
@export_node_path("CharacterBody3D") var body_path: NodePath = ^"../Body"

@export_group("Bone filter")
## Prefix used to build OneShot filter paths. Must match the animation track
## path prefix for skeleton bones. For SolderBoyFinal.glb this is
## "Player/Skeleton3D:" (the GLB's inner root node is "Player").
@export var skeleton_track_prefix: String = "Player/Skeleton3D:"

var _anim: AnimationPlayer
var _body: CharacterBody3D
var _tree: AnimationTree
var _weapon: int = Weapon.AR
var _action: int = Action.NONE
var _current_action_anim: String = ""
var _action_start_msec: int = 0
## Smoothed locomotion blend position (0 = idle, 1 = run). Set per-frame.
var _loco_blend: float = 0.0


func _ready() -> void:
	_anim = get_node_or_null(animation_player_path) as AnimationPlayer
	_body = get_node_or_null(body_path) as CharacterBody3D
	if _anim == null:
		push_warning("PlayerAnimController: AnimationPlayer not found at " + str(animation_player_path))
		return
	if _body == null:
		push_warning("PlayerAnimController: Body not found at " + str(body_path))

	_configure_loops()
	_build_animation_tree()

# ---------------------------------------------------------------------------
# Public API (called by WeaponController)
# ---------------------------------------------------------------------------

func set_weapon(w: int) -> void:
	if _weapon == w:
		return
	_weapon = w
	_apply_weapon_locomotion()

func play_fire() -> void:
	_play_action(Action.FIRE)

func play_reload() -> void:
	_play_action(Action.RELOAD)

func play_select(w: int) -> void:
	_weapon = w
	_apply_weapon_locomotion()
	_play_action(Action.SELECT)

func is_busy() -> bool:
	return _action != Action.NONE

func get_current_weapon() -> int:
	return _weapon

## Currently-playing action animation name, or "" if no action is active.
## Used by WeaponAnimVisibility to know which base weapon visibility to apply.
func get_current_action_anim() -> String:
	return _current_action_anim if _action != Action.NONE else ""

## Wall-clock time since [method play_fire] / [method play_reload] /
## [method play_select] was called, in seconds. Approximates the current
## animation playback position (within ~action_fadein of the true value).
func get_current_action_position() -> float:
	if _action == Action.NONE:
		return 0.0
	return float(Time.get_ticks_msec() - _action_start_msec) / 1000.0

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

func _configure_loops() -> void:
	# Loop locomotion clips, make actions one-shot so OneShot can detect end.
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


func _build_animation_tree() -> void:
	_tree = AnimationTree.new()
	_tree.name = "PlayerAnimTree"
	add_child(_tree)
	_tree.anim_player = _tree.get_path_to(_anim)

	var root := AnimationNodeBlendTree.new()

	# Locomotion: BlendSpace1D with two points (idle at 0, run at 1).
	var loco := AnimationNodeBlendSpace1D.new()
	loco.min_space = 0.0
	loco.max_space = 1.0
	loco.snap = 0.0  # smooth interpolation between points
	var loco_names: Array = ANIM_NAMES[_weapon][Action.NONE]
	var idle_node := AnimationNodeAnimation.new()
	idle_node.animation = loco_names[0]
	loco.add_blend_point(idle_node, 0.0)
	var run_node := AnimationNodeAnimation.new()
	run_node.animation = loco_names[1]
	loco.add_blend_point(run_node, 1.0)
	root.add_node("locomotion", loco, Vector2(100, 100))

	# Action animation (upper body) — single node that we retarget per action.
	var action_anim := AnimationNodeAnimation.new()
	action_anim.animation = ANIM_NAMES[_weapon][Action.FIRE]  # placeholder
	root.add_node("action_anim", action_anim, Vector2(100, 300))

	# TimeScale on locomotion only — actions stay at native speed.
	var loco_scale := AnimationNodeTimeScale.new()
	root.add_node("loco_scale", loco_scale, Vector2(250, 100))

	# OneShot: plays action_anim over locomotion, filtered to upper body only.
	var oneshot := AnimationNodeOneShot.new()
	oneshot.fadein_time = action_fadein
	oneshot.fadeout_time = action_fadeout
	oneshot.autorestart = false
	oneshot.filter_enabled = true
	for bone_name: String in UPPER_BODY_BONES:
		oneshot.set_filter_path(NodePath(skeleton_track_prefix + bone_name), true)
	root.add_node("oneshot", oneshot, Vector2(500, 200))

	# Wire: locomotion → loco_scale → oneshot.in, action_anim → oneshot.shot.
	root.connect_node("loco_scale", 0, "locomotion")
	root.connect_node("oneshot", 0, "loco_scale")
	root.connect_node("oneshot", 1, "action_anim")
	root.connect_node("output", 0, "oneshot")

	_tree.tree_root = root
	_tree.active = true


func _apply_weapon_locomotion() -> void:
	if _tree == null:
		return
	var root := _tree.tree_root as AnimationNodeBlendTree
	if root == null:
		return
	var loco := root.get_node("locomotion") as AnimationNodeBlendSpace1D
	if loco == null:
		return
	var names: Array = ANIM_NAMES[_weapon][Action.NONE]
	var idle_node := loco.get_blend_point_node(0) as AnimationNodeAnimation
	var run_node := loco.get_blend_point_node(1) as AnimationNodeAnimation
	if idle_node != null:
		idle_node.animation = names[0]
	if run_node != null:
		run_node.animation = names[1]

# ---------------------------------------------------------------------------
# Per-tick updates
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _tree == null or _body == null:
		return

	# Smooth locomotion blend position toward velocity ratio.
	var horiz_mag: float = Vector2(_body.velocity.x, _body.velocity.z).length()
	var target_blend: float = 0.0
	if horiz_mag > move_threshold:
		target_blend = 1.0  # running
	_loco_blend = lerp(_loco_blend, target_blend, clampf(locomotion_blend_smoothing * delta, 0.0, 1.0))
	_tree.set("parameters/locomotion/blend_position", _loco_blend)

	# Scale locomotion playback speed to velocity so feet roughly match ground.
	# Sprint caps at [sprint_animation_speed]; below walk speed scales linearly
	# with [run_speed_scale] at the reference; idle plays at 1×.
	# Negative scale plays the run clip in reverse — used when moving backward
	# so legs step backward instead of looking like they jogged the wrong way.
	var speed_scale: float = 1.0
	var dir: int = _get_movement_direction()
	if horiz_mag > reference_walk_speed + 0.5:
		speed_scale = sprint_animation_speed
	elif horiz_mag > move_threshold:
		speed_scale = (horiz_mag / reference_walk_speed) * run_speed_scale
	if dir == MoveDir.BACKWARD:
		speed_scale = -speed_scale
	_tree.set("parameters/loco_scale/scale", speed_scale)

	# Detect OneShot completion → emit action_finished.
	if _action != Action.NONE:
		var active = _tree.get("parameters/oneshot/active")
		if active == false:
			var finished: int = _action
			_action = Action.NONE
			_current_action_anim = ""
			action_finished.emit(finished)

# ---------------------------------------------------------------------------
# Action playback
# ---------------------------------------------------------------------------

func _play_action(action: int) -> void:
	if _tree == null:
		return
	var anim_name: String = ANIM_NAMES[_weapon][action]
	if not _anim.has_animation(anim_name):
		push_warning("PlayerAnimController: animation '" + anim_name + "' not found")
		return
	var root := _tree.tree_root as AnimationNodeBlendTree
	var action_anim := root.get_node("action_anim") as AnimationNodeAnimation
	if action_anim != null:
		action_anim.animation = anim_name
	_action = action
	_current_action_anim = anim_name
	_action_start_msec = Time.get_ticks_msec()
	# ONE_SHOT_REQUEST_FIRE = 1. Fires / restarts the oneshot.
	_tree.set("parameters/oneshot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	action_started.emit(action, anim_name)


## Returns which direction relative to the body's forward the player is
## travelling, using velocity projection onto the body's local -Z axis.
func _get_movement_direction() -> int:
	if _body == null:
		return MoveDir.IDLE
	var horiz: Vector3 = Vector3(_body.velocity.x, 0.0, _body.velocity.z)
	if horiz.length() < move_threshold:
		return MoveDir.IDLE
	var forward: Vector3 = -_body.global_transform.basis.z
	return MoveDir.FORWARD if horiz.dot(forward) > 0.0 else MoveDir.BACKWARD
