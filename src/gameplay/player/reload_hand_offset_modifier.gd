@tool
extends SkeletonModifier3D

## Applies a small rotational offset to the left arm bone so the
## rocket-insertion hand reaches the RPG tube during RPG_Reload. The imported
## animation has the left hand stop ~2cm short of the tube opening — fixing
## that authored pose is out of scope, so we nudge the arm procedurally and
## only while RPG_Reload is actually playing.
##
## Reads AnimationTree's oneshot + action_anim state (not PlayerAnimController)
## to stay immune to the Godot 4.3 class_name cache bug the WeaponAnimVisibility
## refactor had to work around.

## Bone to offset. soldier_LeftArm = upper-arm bone in Mixamo rigs; rotating
## here swings the whole arm chain toward/away from the body.
@export var target_bone_name: String = "soldier_LeftArm"
## Only apply offset while this animation is active on the OneShot node.
@export var active_anim_name: String = "RPG_Reload"
## Euler offset in degrees (X, Y, Z) applied to the bone on top of animation
## output. Tune all three in the Inspector until the hand meets the tube.
@export var offset_euler_deg: Vector3 = Vector3(0.0, 50.0, 0.0)
## How fast the offset blends in once RPG_Reload starts (per second).
@export var blend_in_rate: float = 18.0
## Blend-out after reload ends. Slightly slower feels more organic.
@export var blend_out_rate: float = 14.0
## Animation tree path — must match PlayerAnimController's tree.
@export_node_path("AnimationTree") var animation_tree_path: NodePath = \
		^"../../../../PlayerAnimController/PlayerAnimTree"

var _tree: AnimationTree
var _bone_idx: int = -1
var _strength: float = 0.0
var _prev_msec: int = 0


func _ready() -> void:
	_prev_msec = Time.get_ticks_msec()
	_resolve()


func _resolve() -> void:
	_tree = get_node_or_null(animation_tree_path) as AnimationTree
	var skel: Skeleton3D = get_skeleton()
	if skel == null:
		return
	_bone_idx = skel.find_bone(target_bone_name)
	if _bone_idx < 0:
		push_warning("ReloadHandOffsetModifier: bone '" + target_bone_name + "' not found")


func _process_modification() -> void:
	var skel: Skeleton3D = get_skeleton()
	if skel == null or _bone_idx < 0:
		_resolve()
		skel = get_skeleton()
		if skel == null or _bone_idx < 0:
			return
	if _tree == null:
		_tree = get_node_or_null(animation_tree_path) as AnimationTree
		# No tree yet → offset stays 0, nothing to do (editor preview case).
		if _tree == null:
			return

	var now: int = Time.get_ticks_msec()
	var delta: float = max(0.0, float(now - _prev_msec) / 1000.0)
	_prev_msec = now

	var target: float = 0.0
	var active_val: Variant = _tree.get("parameters/oneshot/active")
	if active_val is bool and bool(active_val):
		var root: AnimationNodeBlendTree = _tree.tree_root as AnimationNodeBlendTree
		if root != null and root.has_node("action_anim"):
			var action_node: AnimationNodeAnimation = root.get_node("action_anim") as AnimationNodeAnimation
			if action_node != null and String(action_node.animation) == active_anim_name:
				target = 1.0

	var rate: float = blend_in_rate if target > _strength else blend_out_rate
	var t: float = clampf(rate * delta, 0.0, 1.0)
	_strength = lerp(_strength, target, t)

	if _strength < 0.01:
		return

	var scale: float = _strength * PI / 180.0
	var euler: Vector3 = Vector3(
		offset_euler_deg.x * scale,
		offset_euler_deg.y * scale,
		offset_euler_deg.z * scale,
	)
	var offset: Quaternion = Quaternion.from_euler(euler)
	var base: Quaternion = skel.get_bone_pose_rotation(_bone_idx)
	skel.set_bone_pose_rotation(_bone_idx, base * offset)
