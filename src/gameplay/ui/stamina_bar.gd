class_name StaminaBar
extends CanvasLayer

## Minimal stamina HUD — bar at bottom-left of the screen.
## Subscribes to [signal PlayerController.stamina_changed] to update.
## Flashes red when sprint is locked out.
##
## Future per GDD (design/gdd/player-controller.md § UI Requirements):
## - Fade in when stamina < 100 OR actively draining
## - Fade out after 2s of being full + idle
## - Red flash on sprint-lockout attempt
## Current implementation: always visible, red tint while lockout active.

@export_node_path("Node") var player_controller_path: NodePath = ^".."

var _player: PlayerController
@onready var _bar: ProgressBar = $Root/StaminaBar


func _ready() -> void:
	_player = get_node_or_null(player_controller_path) as PlayerController
	if _player == null:
		push_warning("StaminaBar: PlayerController not found at %s" % player_controller_path)
		return
	_bar.max_value = _player.stamina_max
	_bar.value = _player.get_stamina()
	_player.stamina_changed.connect(_on_stamina_changed)
	_player.sprint_lockout_changed.connect(_on_lockout_changed)


func _on_stamina_changed(current: float, maximum: float) -> void:
	_bar.max_value = maximum
	_bar.value = current


func _on_lockout_changed(locked: bool) -> void:
	_bar.modulate = Color(1.0, 0.3, 0.3) if locked else Color.WHITE
