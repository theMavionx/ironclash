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
@export var disable_light_shadows_on_web: bool = true
@export var web_ambient_light_energy: float = 1.35
@export var web_directional_light_multiplier: float = 1.15


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
	environment.set("ssao_enabled", false)
	environment.set("ssil_enabled", false)
	environment.ambient_light_energy = maxf(environment.ambient_light_energy, web_ambient_light_energy)
	_apply_web_light_budget(get_tree().current_scene)


func _apply_web_light_budget(root: Node) -> void:
	if root == null:
		return
	_apply_web_light_budget_to_node(root)


func _apply_web_light_budget_to_node(node: Node) -> void:
	if node is Light3D:
		var light: Light3D = node as Light3D
		if disable_light_shadows_on_web:
			light.shadow_enabled = false
		if light is DirectionalLight3D:
			light.light_energy *= web_directional_light_multiplier
	for child: Node in node.get_children():
		_apply_web_light_budget_to_node(child)
