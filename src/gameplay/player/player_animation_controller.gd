class_name PlayerAnimController
extends Node

## Minimal player animation driver. MVP-simple: plays AR_Idle when standing,
## AR_RunF when moving. No fire / reload / select / class-switch yet.
## All other animations will be wired in a later iteration.

## Horizontal velocity magnitude below which the player is considered idle.
@export var move_threshold: float = 0.5

@export_node_path("AnimationPlayer") var animation_player_path: NodePath = ^"../Body/Visual/AnimationPlayer"
@export_node_path("CharacterBody3D") var body_path: NodePath = ^"../Body"

const IDLE_ANIM: String = "AR_Idle"
const RUN_ANIM: String = "AR_RunF"

var _anim: AnimationPlayer
var _body: CharacterBody3D


func _ready() -> void:
	_anim = get_node_or_null(animation_player_path) as AnimationPlayer
	_body = get_node_or_null(body_path) as CharacterBody3D
	if _anim == null:
		push_warning("PlayerAnimController: AnimationPlayer not found at %s" % animation_player_path)
		return
	if _body == null:
		push_warning("PlayerAnimController: Body not found at %s" % body_path)

	# Force loop on both animations (GLB imports often default to one-shot).
	for anim_name in [IDLE_ANIM, RUN_ANIM]:
		if _anim.has_animation(anim_name):
			_anim.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR

	# Start in idle.
	if _anim.has_animation(IDLE_ANIM):
		_anim.play(IDLE_ANIM)


func _physics_process(_delta: float) -> void:
	if _anim == null:
		return
	var want: String = RUN_ANIM if _is_moving() else IDLE_ANIM
	if _anim.current_animation != want and _anim.has_animation(want):
		_anim.play(want)


func _is_moving() -> bool:
	if _body == null:
		return false
	var horiz: Vector2 = Vector2(_body.velocity.x, _body.velocity.z)
	return horiz.length() > move_threshold
