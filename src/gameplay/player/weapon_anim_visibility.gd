@tool
class_name WeaponAnimVisibility
extends Node

## Per-animation and per-frame visibility controller for the player
## character's weapon attachments.
##
## Listens to [signal AnimationPlayer.animation_started] for the base visibility
## state per animation (AR loadout vs RPG loadout), and polls
## [member AnimationPlayer.current_animation_position] during the two reload
## animations for frame-accurate swaps between hand-held and rifle-mounted parts.
##
## GLB import FPS is 30 (see Model/Player/SolderBoyFinal.glb.import), so frame N
## corresponds to N / 30 seconds.
##
## Visibility rules (per user spec 2026-04-21):
##
## AR_Burst / AR_Idle / AR_RunF / AR_Select:
##   AK parts visible; RPG parts, akmagazine, rocketbullet hidden.
##
## AR_Reload:
##   AK parts visible, RPG parts hidden.
##   akmagazine_low: hidden frames 1-47, visible from 48.
##   akmagazine:     hidden 1-12, visible 13-47, hidden from 48.
##
## RPG_Burst / RPG_Idle / RPG_RunF / RPG_Select:
##   RPG parts visible; AK parts, akmagazine, rocketbullet hidden.
##
## RPG_Reload:
##   RPG parts visible, AK parts hidden.
##   rocketbullet_low: hidden 1-41, visible from 42.
##   rocketbullet:     hidden 1-16, visible 17-61, hidden from 62.

const FPS: float = 30.0

@export_node_path("AnimationPlayer") var animation_player_path: NodePath = ^"../Visual/AnimationPlayer"
@export_node_path("Skeleton3D") var skeleton_path: NodePath = ^"../Visual/Player/Skeleton3D"

var _anim: AnimationPlayer
var _skel: Skeleton3D

# Grouped toggles
var _ak47_parts: Array[Node3D] = []
var _rpg_parts: Array[Node3D] = []

# Individual toggles (reload swap logic)
var _akmagazine: Node3D
var _akmagazine_low: Node3D
var _rocketbullet: Node3D
var _rocketbullet_low: Node3D

# Cache — re-apply base state only when the animation name changes, so
# per-frame polling is cheap.
var _last_anim_name: String = ""


func _ready() -> void:
	_resolve_refs()


func _resolve_refs() -> void:
	_anim = get_node_or_null(animation_player_path) as AnimationPlayer
	_skel = get_node_or_null(skeleton_path) as Skeleton3D
	if _anim == null:
		push_warning("WeaponAnimVisibility: AnimationPlayer not found at %s" % animation_player_path)
		return
	if _skel == null:
		push_warning("WeaponAnimVisibility: Skeleton3D not found at %s" % skeleton_path)
		return

	_ak47_parts = [
		_find_bone("ak47"),
		_find_bone("akderriere_low"),
		_find_bone("aktrigger_low"),
	]
	_rpg_parts = [
		_find_bone("rocketlaucher"),
		_find_bone("rockethaut_low"),
		_find_bone("rockethaut_low_001"),
		_find_bone("rockettrigger_low"),
	]
	_akmagazine = _find_bone("akmagazine")
	_akmagazine_low = _find_bone("akmagazine_low")
	_rocketbullet = _find_bone("rocketbullet")
	_rocketbullet_low = _find_bone("rocketbullet_low")


func _find_bone(n: String) -> Node3D:
	var node: Node = _skel.get_node_or_null(NodePath(n))
	if node == null:
		push_warning("WeaponAnimVisibility: '%s' not found under %s" % [n, _skel.get_path()])
	return node as Node3D


func _process(_delta: float) -> void:
	# Re-resolve refs lazily — @tool mode may run before children are fully
	# set up, or after script reload when cached vars become stale.
	if _anim == null:
		_resolve_refs()
		if _anim == null:
			return

	var anim_name: String = String(_anim.current_animation)

	# When the animation selection changes (or is cleared), re-apply base state.
	if anim_name != _last_anim_name:
		_apply_base_state(anim_name)
		_last_anim_name = anim_name

	# No active animation → nothing to poll. Querying current_animation_position
	# on an empty player spams a harmless-but-noisy warning.
	if anim_name == "":
		return

	# Per-frame updates for the two reload animations.
	var frame: int = int(_anim.current_animation_position * FPS)
	match anim_name:
		"AR_Reload":
			_apply_ar_reload_frame(frame)
		"RPG_Reload":
			_apply_rpg_reload_frame(frame)

# ---------------------------------------------------------------------------
# Base states (applied once per animation change)
# ---------------------------------------------------------------------------

func _apply_base_state(anim_name: String) -> void:
	match anim_name:
		"AR_Burst", "AR_Idle", "AR_RunF", "AR_Select":
			_set_ar_base()
		"RPG_Burst", "RPG_Idle", "RPG_RunF", "RPG_Select":
			_set_rpg_base()
		"AR_Reload":
			_set_ar_reload_initial()
		"RPG_Reload":
			_set_rpg_reload_initial()


func _set_group(nodes: Array, vis: bool) -> void:
	for n in nodes:
		if n != null:
			(n as Node3D).visible = vis


func _set_ar_base() -> void:
	_set_group(_ak47_parts, true)
	_set_group(_rpg_parts, false)
	# Standard AR pose: mag in rifle visible, mag-in-hand hidden.
	if _akmagazine_low != null: _akmagazine_low.visible = true
	if _akmagazine != null: _akmagazine.visible = false
	# All rocket parts hidden.
	if _rocketbullet != null: _rocketbullet.visible = false
	if _rocketbullet_low != null: _rocketbullet_low.visible = false


func _set_rpg_base() -> void:
	_set_group(_ak47_parts, false)
	_set_group(_rpg_parts, true)
	if _akmagazine != null: _akmagazine.visible = false
	if _akmagazine_low != null: _akmagazine_low.visible = false
	# Standard RPG pose: loaded rocket visible, rocket-in-hand hidden.
	if _rocketbullet_low != null: _rocketbullet_low.visible = true
	if _rocketbullet != null: _rocketbullet.visible = false


func _set_ar_reload_initial() -> void:
	_set_group(_ak47_parts, true)
	_set_group(_rpg_parts, false)
	if _rocketbullet != null: _rocketbullet.visible = false
	if _rocketbullet_low != null: _rocketbullet_low.visible = false
	# Frame 1: mag not yet in rifle, mag not yet in hand.
	if _akmagazine_low != null: _akmagazine_low.visible = false
	if _akmagazine != null: _akmagazine.visible = false


func _set_rpg_reload_initial() -> void:
	_set_group(_ak47_parts, false)
	_set_group(_rpg_parts, true)
	if _akmagazine != null: _akmagazine.visible = false
	if _akmagazine_low != null: _akmagazine_low.visible = false
	# Frame 1: rocket not yet loaded, rocket not yet in hand.
	if _rocketbullet_low != null: _rocketbullet_low.visible = false
	if _rocketbullet != null: _rocketbullet.visible = false

# ---------------------------------------------------------------------------
# Per-frame visibility updates during reload animations
# ---------------------------------------------------------------------------

func _apply_ar_reload_frame(frame: int) -> void:
	# akmagazine_low: hidden 1-47, visible from 48.
	if _akmagazine_low != null:
		_akmagazine_low.visible = frame >= 48
	# akmagazine: hidden 1-12, visible 13-47, hidden from 48.
	if _akmagazine != null:
		_akmagazine.visible = (frame >= 13 and frame < 48)


func _apply_rpg_reload_frame(frame: int) -> void:
	# rocketbullet_low: hidden 1-41, visible from 42.
	if _rocketbullet_low != null:
		_rocketbullet_low.visible = frame >= 42
	# rocketbullet: hidden 1-16, visible 17-61, hidden from 62.
	if _rocketbullet != null:
		_rocketbullet.visible = (frame >= 17 and frame < 62)
