@tool
extends SkeletonModifier3D

## Procedurally pitches the upper body (spine chain + head) toward the camera
## look direction, so the character's head and attached weapon always aim at
## the crosshair (screen center). Runs as a [SkeletonModifier3D] child of the
## [Skeleton3D] — executes AFTER the [AnimationTree] has computed the base
## pose, additive on top.
##
## Weapon aim comes "for free" because the RightHand bone inherits spine
## rotation (weapon attachment is a BoneAttachment3D on RightHandIndex1).
##
## Implements design/gdd/player-controller.md § Aim (TODO).

## Spine bone names to distribute pitch across. Each receives
## [member spine_weight] of the total pitch.
@export var spine_bone_names: PackedStringArray = [
	"soldier_Spine", "soldier_Spine1", "soldier_Spine2",
]
@export var head_bone_name: String = "soldier_Head"
## Per-spine-bone fraction of pitch. 3 × 0.12 = 0.36 total spine rotation —
## weapon aims ~36% of camera pitch, torso stays mostly upright.
@export var spine_weight: float = 0.12
## Additional pitch on the head bone. Head rotates ~30% extra on top of spine,
## so it aims more where the camera looks without bending the torso heavily.
@export var head_weight: float = 0.3
## Flip if aim direction is inverted (depends on rig's bone axis conventions).
@export var pitch_sign: float = 1.0
## NodePath to a Node exposing `get_aim_pitch() -> float` (radians).
@export_node_path var pitch_source_path: NodePath

var _pitch_source: Node
var _spine_indices: Array[int] = []
var _head_idx: int = -1


func _ready() -> void:
	_resolve()


func _resolve() -> void:
	_pitch_source = get_node_or_null(pitch_source_path)
	var skel: Skeleton3D = get_skeleton()
	if skel == null:
		return
	_spine_indices.clear()
	for n: String in spine_bone_names:
		var i: int = skel.find_bone(n)
		if i >= 0:
			_spine_indices.append(i)
		else:
			push_warning("AimLookModifier: spine bone '" + n + "' not found")
	_head_idx = skel.find_bone(head_bone_name)
	if _head_idx < 0:
		push_warning("AimLookModifier: head bone '" + head_bone_name + "' not found")


func _process_modification() -> void:
	var skel: Skeleton3D = get_skeleton()
	if skel == null:
		return
	if _pitch_source == null or not _pitch_source.has_method("get_aim_pitch"):
		# Lazy re-resolve — in @tool mode the source node may not be ready on
		# first tick, and after script reload the cached ref is stale.
		_resolve()
		if _pitch_source == null or not _pitch_source.has_method("get_aim_pitch"):
			return
	var pitch: float = _pitch_source.call("get_aim_pitch") * pitch_sign
	for idx: int in _spine_indices:
		_apply_x_rotation(skel, idx, pitch * spine_weight)
	_apply_x_rotation(skel, _head_idx, pitch * head_weight)


func _apply_x_rotation(skel: Skeleton3D, idx: int, amount: float) -> void:
	if idx < 0:
		return
	var base: Quaternion = skel.get_bone_pose_rotation(idx)
	var extra := Quaternion(Vector3.RIGHT, amount)
	skel.set_bone_pose_rotation(idx, base * extra)
