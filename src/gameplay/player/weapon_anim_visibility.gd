@tool
class_name WeaponAnimVisibility
extends Node

## Per-animation and per-frame visibility controller for the player character's
## weapon attachments.
##
## Previously read [member AnimationPlayer.current_animation] directly. After
## the 2026-04-21 AnimationTree refactor, the tree drives the skeleton and
## AnimationPlayer.current_animation is no longer a reliable single source of
## truth. This controller now queries [PlayerAnimController] for the active
## action animation (if any) and the current weapon; otherwise it falls back
## to the weapon's base idle/run visibility.
##
## GLB import FPS is 30 (see Model/Player/SolderBoyFinal.glb.import), so frame
## N corresponds to N / 30 seconds.
##
## Visibility rules (per user spec 2026-04-21):
##
## AR base (idle / run / burst / select):
##   AK parts visible; RPG parts, akmagazine, rocketbullet hidden.
##
## AR_Reload (frame-indexed):
##   AK parts visible, RPG parts hidden.
##   akmagazine_low: hidden frames 1-47, visible from 48.
##   akmagazine:     hidden 1-12, visible 13-47, hidden from 48.
##
## RPG base (idle / run / burst / select):
##   RPG parts visible; AK parts, akmagazine, rocketbullet hidden.
##
## RPG_Reload (frame-indexed):
##   RPG parts visible, AK parts hidden.
##   rocketbullet_low: hidden 1-41, visible from 42.
##   rocketbullet:     hidden 1-16, visible 17-61, hidden from 62.

const FPS: float = 30.0

@export_node_path("Skeleton3D") var skeleton_path: NodePath = ^"../Visual/Player/Skeleton3D"
## PlayerAnimController — source of truth for weapon + active action + position.
## In editor (@tool) this may not resolve; the controller degrades gracefully
## and applies AR base visibility so the editor preview still shows correct parts.
@export_node_path("Node") var anim_controller_path: NodePath = ^"../../PlayerAnimController"

var _skel: Skeleton3D
var _ctrl: PlayerAnimController

# Grouped toggles
var _ak47_parts: Array[Node3D] = []
var _rpg_parts: Array[Node3D] = []

# Individual toggles (reload swap logic)
var _akmagazine: Node3D
var _akmagazine_low: Node3D
var _rocketbullet: Node3D
var _rocketbullet_low: Node3D

# Cache — re-apply base state only when the effective anim tag changes, so
# per-frame polling stays cheap.
var _last_anim_tag: String = ""


func _ready() -> void:
	_resolve_refs()


func _resolve_refs() -> void:
	_skel = get_node_or_null(skeleton_path) as Skeleton3D
	_ctrl = get_node_or_null(anim_controller_path) as PlayerAnimController
	if _skel == null:
		push_warning("WeaponAnimVisibility: Skeleton3D not found at " + str(skeleton_path))
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
		push_warning("WeaponAnimVisibility: '" + n + "' not found under " + str(_skel.get_path()))
	return node as Node3D


func _process(_delta: float) -> void:
	# Lazy re-resolve — @tool mode may run before children are fully set up,
	# or after script reload when cached vars become stale.
	if _skel == null:
		_resolve_refs()
		if _skel == null:
			return

	# Determine effective anim tag + position.
	# Tag: either the current action anim (e.g. "AR_Reload") or the weapon base
	# (e.g. "AR_Base" / "RPG_Base").
	var anim_tag: String = ""
	var action_pos: float = 0.0
	if _ctrl != null:
		var action_name: String = _ctrl.get_current_action_anim()
		if action_name != "":
			anim_tag = action_name
			action_pos = _ctrl.get_current_action_position()
		else:
			var w: int = _ctrl.get_current_weapon()
			anim_tag = "AR_Base" if w == PlayerAnimController.Weapon.AR else "RPG_Base"
	else:
		# No controller (editor preview, missing link) → default to AR base.
		anim_tag = "AR_Base"

	if anim_tag != _last_anim_tag:
		_apply_base_state(anim_tag)
		_last_anim_tag = anim_tag

	# Per-frame reload swaps (only when an actual reload animation is active).
	var frame: int = int(action_pos * FPS)
	match anim_tag:
		"AR_Reload":
			_apply_ar_reload_frame(frame)
		"RPG_Reload":
			_apply_rpg_reload_frame(frame)

# ---------------------------------------------------------------------------
# Base states (applied once per tag change)
# ---------------------------------------------------------------------------

func _apply_base_state(anim_tag: String) -> void:
	match anim_tag:
		"AR_Base", "AR_Burst", "AR_Select":
			_set_ar_base()
		"RPG_Base", "RPG_Burst", "RPG_Select":
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
