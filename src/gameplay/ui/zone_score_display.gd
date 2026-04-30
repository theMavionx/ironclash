class_name ZoneScoreDisplay
extends CanvasLayer

## HUD label that aggregates points earned across every RedZone in the scene.
## Each RedZone added to the score_zones group emits point_earned on every
## accrued whole point; we sum across all of them.

@export var label_prefix: String = "Очки: "

var _total_score: int = 0
@onready var _label: Label = $Root/ScoreLabel
@onready var _root: Control = $Root


func _ready() -> void:
	if OS.has_feature("web"):
		_root.visible = false
	# Defer one frame so RedZones have run their _ready and joined the group.
	await get_tree().process_frame
	_connect_to_zones()
	_refresh()


func _connect_to_zones() -> void:
	for zone in get_tree().get_nodes_in_group(RedZone.GROUP):
		var rz := zone as RedZone
		if rz == null:
			continue
		if not rz.point_earned.is_connected(_on_point_earned):
			rz.point_earned.connect(_on_point_earned)


func _on_point_earned() -> void:
	_total_score += 1
	_refresh()


func _refresh() -> void:
	_label.text = label_prefix + str(_total_score)
