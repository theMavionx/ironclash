class_name Crosshair
extends CanvasLayer

## Static crosshair in the middle of the screen. Camera/view rotates with the
## mouse (classic FPS style). Mouse mode is captured by the active vehicle
## controller, not by this node.


func _ready() -> void:
	# React owns the browser HUD/crosshair. Keep the Godot version for editor
	# and native smoke tests only.
	if OS.has_feature("web"):
		visible = false
