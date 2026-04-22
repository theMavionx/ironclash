class_name AmmoDisplay
extends CanvasLayer

## Minimal ammo HUD — bottom-right of the screen.
## Subscribes to [signal WeaponController.ammo_changed] and
## [signal WeaponController.weapon_switched] for live updates.
##
## Format: "AR  30 / 30"  or  "RPG  1 / 1".

@export_node_path("Node") var weapon_controller_path: NodePath = ^"../WeaponController"

var _weapon_ctrl: WeaponController
@onready var _label: Label = $Root/AmmoLabel


func _ready() -> void:
	_weapon_ctrl = get_node_or_null(weapon_controller_path) as WeaponController
	if _weapon_ctrl == null:
		push_warning("AmmoDisplay: WeaponController not found at %s" % weapon_controller_path)
		return
	_weapon_ctrl.ammo_changed.connect(_on_ammo_changed)
	_weapon_ctrl.weapon_switched.connect(_on_weapon_switched)
	_refresh()


func _refresh() -> void:
	if _weapon_ctrl == null:
		return
	_on_ammo_changed(
		_weapon_ctrl.get_current_weapon(),
		_weapon_ctrl.get_current_ammo(),
		_weapon_ctrl.get_current_mag_size()
	)


func _on_ammo_changed(weapon: int, current: int, maximum: int) -> void:
	var weapon_name: String = "AR" if weapon == PlayerAnimController.Weapon.AR else "RPG"
	_label.text = "%s  %d / %d" % [weapon_name, current, maximum]


func _on_weapon_switched(_weapon: int) -> void:
	_refresh()
