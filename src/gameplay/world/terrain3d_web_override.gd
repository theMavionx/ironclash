extends Terrain3D

@export var web_shader: Shader

## Web shader declares packed arrays (ivec4[256] + vec4[512]) instead of the
## addon's int[1024] + vec2[1024] to fit Safari's 16 KB UBO cap. The plugin
## doesn't know about these packed names, so we re-pack from the plugin's
## flat data on a timer so we always win the race with the plugin's
## periodic material_set_param("_region_map", ...) updates.
const _PLUGIN_REGION_ARRAY_SIZE: int = 1024
var _packed_repush_timer: Timer = null


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
	call_deferred("_push_packed_region_arrays")
	_start_packed_repush_timer()
	print("[terrain-web] override enabled")


## Re-push the packed region arrays at 1 Hz so they survive the plugin's own
## update cycle (which pushes the unpacked addon-format names like
## "_region_map" but never the packed names we use).
func _start_packed_repush_timer() -> void:
	if _packed_repush_timer != null:
		return
	_packed_repush_timer = Timer.new()
	_packed_repush_timer.wait_time = 1.0
	_packed_repush_timer.one_shot = false
	_packed_repush_timer.autostart = true
	add_child(_packed_repush_timer)
	_packed_repush_timer.timeout.connect(_push_packed_region_arrays)


func _push_packed_region_arrays() -> void:
	if data == null or material == null:
		return
	var src_map: PackedInt32Array = data.get_region_map()
	if src_map.size() != _PLUGIN_REGION_ARRAY_SIZE:
		return
	var src_locs: PackedVector2Array = data.get_region_locations()
	# Pack int[1024] into ivec4[256] (4 ints per element).
	var packed_map: PackedInt32Array = PackedInt32Array()
	packed_map.resize(_PLUGIN_REGION_ARRAY_SIZE)
	for i: int in range(_PLUGIN_REGION_ARRAY_SIZE):
		packed_map[i] = src_map[i]
	# Pack vec2[N] into vec4[ceil(N/2)] (2 vec2s per element); pad with zero.
	var packed_locs: PackedVector4Array = PackedVector4Array()
	packed_locs.resize(_PLUGIN_REGION_ARRAY_SIZE / 2)
	var loc_count: int = src_locs.size()
	for i: int in range(packed_locs.size()):
		var a: Vector2 = src_locs[i * 2] if i * 2 < loc_count else Vector2.ZERO
		var b: Vector2 = src_locs[i * 2 + 1] if (i * 2 + 1) < loc_count else Vector2.ZERO
		packed_locs[i] = Vector4(a.x, a.y, b.x, b.y)
	# Terrain3DMaterial isn't a plain Material — material.get_rid() returns
	# null. The addon exposes get_material_rid() to get the actual GPU RID
	# (see addons/terrain_3d/src/ui.gd:322 for the same pattern).
	var mat_rid: RID = material.get_material_rid() if material.has_method("get_material_rid") else material.get_rid()
	if not mat_rid.is_valid():
		return
	# RenderingServer.material_set_param accepts the int array as-is for the
	# packed ivec4 uniform — Godot reinterprets every 4 ints as one ivec4.
	RenderingServer.material_set_param(mat_rid, "_region_map_packed", packed_map)
	RenderingServer.material_set_param(mat_rid, "_region_locations_packed", packed_locs)


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
