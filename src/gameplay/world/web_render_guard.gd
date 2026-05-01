extends WorldEnvironment

## Browser-only render guard for Godot 4.3 Compatibility/WebGL.
##
## Glow and volumetric fog are fine in the editor/desktop path, but in WebGL
## glow's mip-chain render targets can become incomplete on some drivers
## ("Attachment level is not in the [base level, max level] range"). Keep the
## authored Environment in Main.tscn for desktop, then duplicate and simplify it
## only when running in the browser.

@export var disable_glow_on_web: bool = true
@export var disable_volumetric_fog_on_web: bool = true


func _ready() -> void:
	if not OS.has_feature("web"):
		return
	if environment == null:
		return

	environment = environment.duplicate(true) as Environment
	if environment == null:
		return

	if disable_glow_on_web:
		environment.glow_enabled = false
	if disable_volumetric_fog_on_web:
		environment.volumetric_fog_enabled = false
