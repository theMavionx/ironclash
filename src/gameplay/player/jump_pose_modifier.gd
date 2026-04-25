@tool
extends SkeletonModifier3D

## Procedural jump pose — tucks the knees forward while airborne so jumps
## don't look like a running-in-air glitch. Runs after AnimationTree output.
##
## The GLB has no dedicated jump animation; rather than wiring Mixamo or
## stitching from scratch we lean into the fact that the lower body is
## already on the locomotion layer and just bias the leg bones procedurally
## during flight time.
##
## Blend-in when airborne (fast), blend-out when grounded (slightly slower
## for a small "settling" feel on landing).

@export var left_upleg_name: String = "soldier_LeftUpLeg"
@export var right_upleg_name: String = "soldier_RightUpLeg"
@export var left_leg_name: String = "soldier_LeftLeg"
@export var right_leg_name: String = "soldier_RightLeg"

## Upper-leg forward rotation in degrees (knee pulled toward chest).
@export var upleg_tuck_deg: float = 15.0
## Lower-leg counter rotation in degrees (shin folds back under thigh).
@export var leg_tuck_deg: float = 25.0
## How fast the tuck amount ramps IN when airborne (per second).
@export var tuck_in_rate: float = 14.0
## How fast the tuck amount eases OUT after landing (per second).
@export var tuck_out_rate: float = 7.0
## Flip sign if tuck bends the wrong direction (rig-dependent).
@export var tuck_sign: float = -1.0

@export_node_path("CharacterBody3D") var body_path: NodePath

var _body: CharacterBody3D
var _upleg_indices: Array[int] = []
var _leg_indices: Array[int] = []
## 0 = on ground, 1 = fully airborne tuck. Smoothly lerps between.
var _tuck: float = 0.0
var _prev_msec: int = 0


func _ready() -> void:
	_prev_msec = Time.get_ticks_msec()
	_resolve()


func _resolve() -> void:
	_body = get_node_or_null(body_path) as CharacterBody3D
	var skel: Skeleton3D = get_skeleton()
	if skel == null:
		return
	_upleg_indices.clear()
	_leg_indices.clear()
	for n: String in [left_upleg_name, right_upleg_name]:
		var i: int = skel.find_bone(n)
		if i >= 0:
			_upleg_indices.append(i)
		else:
			push_warning("JumpPoseModifier: upleg bone '" + n + "' not found")
	for n: String in [left_leg_name, right_leg_name]:
		var i: int = skel.find_bone(n)
		if i >= 0:
			_leg_indices.append(i)
		else:
			push_warning("JumpPoseModifier: leg bone '" + n + "' not found")


func _process_modification() -> void:
	var skel: Skeleton3D = get_skeleton()
	if skel == null or _body == null:
		_resolve()
		skel = get_skeleton()
		if skel == null or _body == null:
			return

	# Delta via msec diff — _process_modification is not guaranteed to get a
	# regular Node delta callback, and SkeletonModifier3D.get_process_delta_time
	# can return 0 on some frames.
	var now: int = Time.get_ticks_msec()
	var delta: float = max(0.0, float(now - _prev_msec) / 1000.0)
	_prev_msec = now

	var target: float = 0.0 if _body.is_on_floor() else 1.0
	var rate: float = tuck_in_rate if target > _tuck else tuck_out_rate
	var t: float = clampf(rate * delta, 0.0, 1.0)
	_tuck = lerp(_tuck, target, t)

	if _tuck < 0.005:
		return  # grounded — let anim pose pass through untouched

	var up_amount: float = _tuck * deg_to_rad(upleg_tuck_deg) * tuck_sign
	var leg_amount: float = _tuck * deg_to_rad(leg_tuck_deg) * tuck_sign
	for idx: int in _upleg_indices:
		_apply_x_rotation(skel, idx, up_amount)
	# Lower leg rotates the OPPOSITE direction so shin folds toward thigh
	# instead of continuing the upleg's swing.
	for idx: int in _leg_indices:
		_apply_x_rotation(skel, idx, -leg_amount)


func _apply_x_rotation(skel: Skeleton3D, idx: int, amount: float) -> void:
	if idx < 0:
		return
	var base: Quaternion = skel.get_bone_pose_rotation(idx)
	var extra := Quaternion(Vector3.RIGHT, amount)
	skel.set_bone_pose_rotation(idx, base * extra)
