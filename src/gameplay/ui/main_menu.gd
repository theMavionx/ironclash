class_name MainMenuScene
extends Node3D

## Idle-loop main menu — instances SolderBoyFinal.glb, plays AR_Idle, and
## waits for the React PLAY button (delivered via WebBridge as `ui_play`)
## before swapping to the gameplay scene.
##
## React renders the title + PLAY button overlay on top of this scene; the
## scene itself only drives the 3D character + camera framing.

@export var idle_anim_name: String = "AR_Idle"
@export var fallback_idle_anim_name: String = "AR_RunF"
@export var main_scene_path: String = "res://Main.tscn"
@export_node_path("AnimationPlayer") var anim_player_path: NodePath = ^"Model/AnimationPlayer"

var _switching_scene: bool = false


func _ready() -> void:
	# Free the cursor — menu uses pointer-lock-free mouse navigation.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_play_idle()
	_register_play_handler()


func _play_idle() -> void:
	var anim: AnimationPlayer = get_node_or_null(anim_player_path) as AnimationPlayer
	if anim == null:
		push_warning("[menu] AnimationPlayer not found at %s" % anim_player_path)
		return
	# Loop the idle clip indefinitely. The GLB import sets loop_mode per anim;
	# force-loop here so we don't depend on import settings staying in sync.
	if anim.has_animation(idle_anim_name):
		anim.get_animation(idle_anim_name).loop_mode = Animation.LOOP_LINEAR
		anim.play(idle_anim_name)
	elif anim.has_animation(fallback_idle_anim_name):
		anim.get_animation(fallback_idle_anim_name).loop_mode = Animation.LOOP_LINEAR
		anim.play(fallback_idle_anim_name)
	else:
		push_warning("[menu] no idle anim found (tried %s, %s)" % [idle_anim_name, fallback_idle_anim_name])


func _register_play_handler() -> void:
	var bridge: Node = get_node_or_null(^"/root/WebBridge")
	if bridge == null or not bridge.has_method("register_handler"):
		# Editor / non-web fallback: press Enter to start. Useful for testing
		# the menu inside the Godot editor without React.
		set_process_input(true)
		return
	bridge.register_handler("ui_play", _on_ui_play)


func _input(event: InputEvent) -> void:
	# Native fallback only — runs when no WebBridge is available.
	if event is InputEventKey:
		var key: InputEventKey = event
		if key.pressed and not key.echo and (key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER):
			_start_match()


func _on_ui_play(_payload: Dictionary) -> void:
	_start_match()


func _start_match() -> void:
	if _switching_scene:
		return
	_switching_scene = true
	# Defer the scene change one frame so any other ui_play listeners
	# (NetworkManager) have a chance to run first under the menu's tree
	# context — change_scene_to_file frees us mid-flight otherwise.
	call_deferred("_do_switch")


func _do_switch() -> void:
	get_tree().change_scene_to_file(main_scene_path)
