extends Terrain3D

@export var web_shader: Shader

## Web shader uses a 8x8 region grid (down from the plugin's 32x32) to keep
## the uniform block under WebGL2's 16 KB minimum on Safari/Apple Silicon.
## See assets/shaders/terrain3d_web_lightweight.gdshader for the size math.
const _WEB_REGION_MAP_SIZE: int = 8
const _PLUGIN_REGION_MAP_SIZE: int = 32


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
	# Repack the plugin's 32x32 region map into the 8x8 layout the web shader
	# expects. Without this, our shader reads from indices that don't match
	# the plugin's data layout and the terrain renders blank / wrong.
	call_deferred("_repack_region_map_for_web_shader")
	print("[terrain-web] override enabled")


## Plugin populates _region_map (PackedInt32Array of size 32*32 = 1024) with
## region indices indexed by [grid_y * 32 + grid_x]. Our web shader declares
## _region_map[64] indexed by [grid_y * 8 + grid_x]. Take the central 8x8
## window of the plugin's grid (centered at world origin where our regions
## actually live) and re-upload it as the smaller array.
func _repack_region_map_for_web_shader() -> void:
	if data == null or material == null:
		return
	var src_map: PackedInt32Array = data.get_region_map()
	if src_map.size() != _PLUGIN_REGION_MAP_SIZE * _PLUGIN_REGION_MAP_SIZE:
		print("[terrain-web] unexpected region_map size=%d, skipping repack" % src_map.size())
		return
	var src_offset: int = _PLUGIN_REGION_MAP_SIZE / 2  # 16
	var dst_offset: int = _WEB_REGION_MAP_SIZE / 2    # 4
	var dst_map: PackedInt32Array = PackedInt32Array()
	dst_map.resize(_WEB_REGION_MAP_SIZE * _WEB_REGION_MAP_SIZE)
	for y: int in range(_WEB_REGION_MAP_SIZE):
		for x: int in range(_WEB_REGION_MAP_SIZE):
			var src_x: int = x - dst_offset + src_offset
			var src_y: int = y - dst_offset + src_offset
			dst_map[y * _WEB_REGION_MAP_SIZE + x] = src_map[src_y * _PLUGIN_REGION_MAP_SIZE + src_x]
	material.set_shader_parameter("_region_map", dst_map)
	material.set_shader_parameter("_region_map_size", _WEB_REGION_MAP_SIZE)
	print("[terrain-web] repacked region_map %dx%d -> %dx%d" % [
		_PLUGIN_REGION_MAP_SIZE, _PLUGIN_REGION_MAP_SIZE,
		_WEB_REGION_MAP_SIZE, _WEB_REGION_MAP_SIZE,
	])


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
