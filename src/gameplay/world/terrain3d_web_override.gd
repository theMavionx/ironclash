extends Terrain3D

@export var web_shader: Shader


func _ready() -> void:
	if not OS.has_feature("web"):
		return
	if web_shader == null or material == null:
		print("[terrain-web] override skipped shader=%s material=%s" % [
			str(web_shader),
			str(material),
		])
		return

	print("[terrain-web] override start shader=%s material=%s renderer=%s" % [
		web_shader.resource_path,
		str(material),
		str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
	])
	_log_assets()
	_log_texture_profile()
	material.set_shader_override(web_shader)
	material.enable_shader_override(true)
	material.update()
	# Note: web shader hardcodes layer 0 + region origin (0,0) — no per-region
	# indirection needed for our single-region map. Keeps UBO under Safari's
	# 16 KB limit. See assets/shaders/terrain3d_web_lightweight.gdshader.
	print("[terrain-web] override enabled")


func _log_assets() -> void:
	var texture_count: int = 0
	var mesh_count: int = 0
	if assets != null:
		if assets.has_method("get_texture_count"):
			texture_count = int(assets.call("get_texture_count"))
		else:
			var textures: Variant = assets.get("texture_list")
			if textures is Array:
				texture_count = (textures as Array).size()
		if assets.has_method("get_mesh_count"):
			mesh_count = int(assets.call("get_mesh_count"))
		else:
			var meshes: Variant = assets.get("mesh_list")
			if meshes is Array:
				mesh_count = (meshes as Array).size()
	print("[terrain-web] assets textures=%d meshes=%d data=%s" % [
		texture_count,
		mesh_count,
		str(data),
	])


func _log_texture_profile() -> void:
	if assets == null:
		return
	var textures: Variant = assets.get("texture_list")
	if not (textures is Array):
		return
	var entries: Array[String] = []
	for texture_asset_variant: Variant in (textures as Array):
		var texture_asset: Object = texture_asset_variant as Object
		if texture_asset == null:
			continue
		var asset_name: String = str(texture_asset.get("name"))
		var albedo: Texture2D = texture_asset.get("albedo_texture") as Texture2D
		if albedo == null:
			entries.append("%s=none" % asset_name)
		else:
			entries.append("%s=%dx%d" % [asset_name, albedo.get_width(), albedo.get_height()])
	if not entries.is_empty():
		print("[terrain-web] texture profile %s" % ", ".join(PackedStringArray(entries)))
