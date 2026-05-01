extends Terrain3D

@export var web_shader: Shader
@export var enable_web_shader_override: bool = true

func _ready() -> void:
	if not OS.has_feature("web"):
		return
	if not enable_web_shader_override:
		return
	if web_shader == null or material == null:
		return

	material.set_shader_override(web_shader)
	material.enable_shader_override(true)
	material.update()
