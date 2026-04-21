@tool
class_name WeaponAnimVisibility
extends Node

## Per-animation and per-frame visibility controller for the player character's
## weapon attachments.
##
## Reads state DIRECTLY from the runtime [AnimationTree] — does NOT depend on
## [PlayerAnimController] class_name resolution (Godot 4.3 has a cache bug where
## `has_method()` reports true but `.call()` fails for newly-added methods on
## class_name-typed references, and it's not always cleared by deleting
## `.godot/`). Reading via NodePath + duck-typed Node calls is immune.
##
## State derivation:
##   - Current weapon (AR / RPG): inspect the locomotion BlendSpace1D's idle
##     node's animation name (PlayerAnimController swaps this on weapon change).
##   - Active action: check `parameters/oneshot/active` on the tree; if true,
##     read the action_anim node's animation name.
##   - Action playback position: tracked here via wall clock (when the action
##     anim name changes we note the msec; delta is "seconds since started").
##
## GLB import FPS is 30, so frame N = N/30 seconds.
##
## Visibility rules (per user spec 2026-04-21):
##
## AR base (idle / run / burst / select):
##   AK parts visible; RPG parts, akmagazine, rocketbullet hidden.
## AR_Reload:
##   akmagazine_low hidden 1-47 / visible 48+
##   akmagazine     hidden 1-12 / visible 13-47 / hidden 48+
## RPG base:
##   RPG parts visible; AK parts, akmagazine, rocketbullet hidden.
## RPG_Reload:
##   rocketbullet_low hidden 1-41 / visible 42+
##   rocketbullet     hidden 1-16 / visible 17-61 / hidden 62+

const FPS: float = 30.0

@export_node_path("Skeleton3D") var skeleton_path: NodePath = ^"../Visual/Player/Skeleton3D"
## Path to the AnimationTree that PlayerAnimController builds at runtime. The
## tree is a child of PlayerAnimController named "PlayerAnimTree".
@export_node_path("AnimationTree") var animation_tree_path: NodePath = ^"../../PlayerAnimController/PlayerAnimTree"

var _skel: Skeleton3D
var _tree: AnimationTree

# Grouped toggles
var _ak47_parts: Array[Node3D] = []
var _rpg_parts: Array[Node3D] = []

# Individual toggles (reload swap logic)
var _akmagazine: Node3D
var _akmagazine_low: Node3D
var _rocketbullet: Node3D
var _rocketbullet_low: Node3D

# Cache — re-apply base state only when the effective anim tag changes.
var _last_anim_tag: String = ""
# Wall-clock start of current action anim (for frame-indexed reload swaps).
var _action_start_msec: int = 0
var _current_action_anim: String = ""


func _ready() -> void:
	_resolve_refs()


func _resolve_refs() -> void:
	_skel = get_node_or_null(skeleton_path) as Skeleton3D
	_tree = get_node_or_null(animation_tree_path) as AnimationTree
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
	# Lazy re-resolve — @tool mode may run before children are ready.
	if _skel == null:
		_resolve_refs()
		if _skel == null:
			return
	if _tree == null:
		# Tree is built in PlayerAnimController._ready at runtime — only exists
		# during play, not in @tool editor preview. Fall back to AR base.
		_tree = get_node_or_null(animation_tree_path) as AnimationTree
		if _tree == null:
			_apply_tag_if_changed("AR_Base")
			return

	var anim_tag: String = _derive_anim_tag()
	_apply_tag_if_changed(anim_tag)

	# Per-frame reload swaps.
	if anim_tag == "AR_Reload" or anim_tag == "RPG_Reload":
		var elapsed_sec: float = float(Time.get_ticks_msec() - _action_start_msec) / 1000.0
		var frame: int = int(elapsed_sec * FPS)
		if anim_tag == "AR_Reload":
			_apply_ar_reload_frame(frame)
		else:
			_apply_rpg_reload_frame(frame)


func _derive_anim_tag() -> String:
	# If OneShot is active → an action is playing.
	var active_val: Variant = _tree.get("parameters/oneshot/active")
	var is_active: bool = (active_val is bool and bool(active_val))

	if is_active:
		# Read action_anim node's current animation name from the BlendTree.
		var root: AnimationNodeBlendTree = _tree.tree_root as AnimationNodeBlendTree
		if root != null and root.has_node("action_anim"):
			var action_node: AnimationNodeAnimation = root.get_node("action_anim") as AnimationNodeAnimation
			if action_node != null:
				var anim_name: String = action_node.animation
				# Track start time so frame-indexed reload swaps work.
				if anim_name != _current_action_anim:
					_current_action_anim = anim_name
					_action_start_msec = Time.get_ticks_msec()
				return anim_name

	# No active action → derive base tag from locomotion's idle animation name.
	_current_action_anim = ""
	var root2: AnimationNodeBlendTree = _tree.tree_root as AnimationNodeBlendTree
	if root2 != null and root2.has_node("locomotion"):
		var loco: AnimationNodeBlendSpace1D = root2.get_node("locomotion") as AnimationNodeBlendSpace1D
		if loco != null and loco.get_blend_point_count() > 0:
			var idle_node: AnimationNodeAnimation = loco.get_blend_point_node(0) as AnimationNodeAnimation
			if idle_node != null:
				return "RPG_Base" if idle_node.animation == "RPG_Idle" else "AR_Base"
	return "AR_Base"


func _apply_tag_if_changed(anim_tag: String) -> void:
	if anim_tag != _last_anim_tag:
		_apply_base_state(anim_tag)
		_last_anim_tag = anim_tag

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
	if _akmagazine_low != null: _akmagazine_low.visible = true
	if _akmagazine != null: _akmagazine.visible = false
	if _rocketbullet != null: _rocketbullet.visible = false
	if _rocketbullet_low != null: _rocketbullet_low.visible = false


func _set_rpg_base() -> void:
	_set_group(_ak47_parts, false)
	_set_group(_rpg_parts, true)
	if _akmagazine != null: _akmagazine.visible = false
	if _akmagazine_low != null: _akmagazine_low.visible = false
	if _rocketbullet_low != null: _rocketbullet_low.visible = true
	if _rocketbullet != null: _rocketbullet.visible = false


func _set_ar_reload_initial() -> void:
	_set_group(_ak47_parts, true)
	_set_group(_rpg_parts, false)
	if _rocketbullet != null: _rocketbullet.visible = false
	if _rocketbullet_low != null: _rocketbullet_low.visible = false
	if _akmagazine_low != null: _akmagazine_low.visible = false
	if _akmagazine != null: _akmagazine.visible = false


func _set_rpg_reload_initial() -> void:
	_set_group(_ak47_parts, false)
	_set_group(_rpg_parts, true)
	if _akmagazine != null: _akmagazine.visible = false
	if _akmagazine_low != null: _akmagazine_low.visible = false
	if _rocketbullet_low != null: _rocketbullet_low.visible = false
	if _rocketbullet != null: _rocketbullet.visible = false

# ---------------------------------------------------------------------------
# Per-frame visibility updates during reload animations
# ---------------------------------------------------------------------------

func _apply_ar_reload_frame(frame: int) -> void:
	if _akmagazine_low != null:
		_akmagazine_low.visible = frame >= 48
	if _akmagazine != null:
		_akmagazine.visible = (frame >= 13 and frame < 48)


func _apply_rpg_reload_frame(frame: int) -> void:
	if _rocketbullet_low != null:
		_rocketbullet_low.visible = frame >= 42
	if _rocketbullet != null:
		_rocketbullet.visible = (frame >= 17 and frame < 62)
