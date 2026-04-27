@tool
extends EditorScript

## ONE-SHOT FIX for Main.tscn bloat (160 MB → ~50 KB).
##
## Extracts the 6 embedded Terrain3D normal-map images out of Main.tscn into
## individual PNG files in textures/, then re-points each Terrain3DTextureAsset
## at the external file. This drops Main.tscn from a multi-MB monster to a
## small text scene that Git/GitHub accept (100 MB hard limit).
##
## HOW TO RUN:
##   1. Open this file in Godot's Script editor (double-click in FileSystem
##      panel, or File → Open... → tools/extract_terrain_normals.gd).
##   2. Top menu: File → Run (Ctrl+Shift+X). One run does everything.
##   3. Wait for "DONE" in the Output panel.
##   4. Save the scene (Ctrl+S).
##   5. Check Main.tscn file size — should be tiny now.
##   6. Commit + push.
##
## SAFETY:
##   - PNG files are written to textures/ — they show up in FileSystem after
##     the script forces a rescan.
##   - Asset references are reassigned to loaded externals before save, so on
##     scene save Godot serialises them as ExtResource not embedded data.
##   - If anything goes wrong, just don't save the scene (Ctrl+Z to revert).

const SCENE_PATH: String = "res://Main.tscn"
const NORMALS_DIR: String = "res://textures/"


func _run() -> void:
	print("[extract_terrain_normals] starting…")

	var fs: EditorFileSystem = EditorInterface.get_resource_filesystem()

	# Make sure the scene we want to edit is the active edited scene.
	if EditorInterface.get_edited_scene_root() == null \
			or EditorInterface.get_edited_scene_root().scene_file_path != SCENE_PATH:
		EditorInterface.open_scene_from_path(SCENE_PATH)
		await EditorInterface.get_base_control().get_tree().process_frame

	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		push_error("Main.tscn not loaded. Open it first.")
		return

	var terrain: Node = root.find_child("Terrain3D", true, false)
	if terrain == null:
		push_error("Terrain3D node not found under Main.tscn.")
		return

	var assets = terrain.get("assets")
	if assets == null:
		push_error("Terrain3D has no 'assets' resource.")
		return

	# Terrain3DAssets exposes texture access via get_texture_list() / texture_count.
	var texture_count: int = 0
	if assets.has_method("get_texture_count"):
		texture_count = assets.get_texture_count()
	else:
		var tlist = assets.get("texture_list")
		if tlist is Array:
			texture_count = tlist.size()
	if texture_count == 0:
		push_error("No terrain textures found in assets.")
		return

	print("[extract_terrain_normals] found %d textures" % texture_count)

	# Phase 1: save embedded normal images to PNG, remember (asset, path) pairs.
	var saved: Array = []
	for i in range(texture_count):
		var asset = null
		if assets.has_method("get_texture"):
			asset = assets.get_texture(i)
		else:
			asset = assets.get("texture_list")[i]
		if asset == null:
			continue
		var nrm: Texture2D = asset.get("normal_texture") as Texture2D
		if nrm == null:
			print("  [%d] '%s' — no normal_texture, skip" % [i, asset.get("name")])
			continue
		# If it's already an external resource, skip.
		if nrm.resource_path != "" and not nrm.resource_path.begins_with("local://"):
			print("  [%d] '%s' — already external (%s), skip" % [i, asset.get("name"), nrm.resource_path])
			continue
		var img: Image = nrm.get_image()
		if img == null:
			print("  [%d] '%s' — get_image() returned null, skip" % [i, asset.get("name")])
			continue
		var asset_name: String = String(asset.get("name")).to_lower()
		if asset_name == "":
			asset_name = "tex%d" % i
		var out_path: String = NORMALS_DIR + asset_name + "_normal.png"
		var err: int = img.save_png(out_path)
		if err != OK:
			push_error("save_png failed for %s: %d" % [out_path, err])
			continue
		print("  [%d] '%s' → %s (%dx%d)" % [i, asset_name, out_path, img.get_width(), img.get_height()])
		saved.append([asset, out_path])

	if saved.is_empty():
		print("[extract_terrain_normals] nothing to extract — done.")
		return

	# Phase 2: ask Godot to import the new PNG files. Wait for the reimport
	# signal so load() returns the actual imported Texture2D, not null.
	print("[extract_terrain_normals] scanning filesystem for new PNG files…")
	fs.scan()
	# scan() is synchronous on the file walk but reimport runs over multiple
	# frames. Wait until the importer is idle.
	while fs.is_scanning():
		await EditorInterface.get_base_control().get_tree().process_frame
	# Give the importer a few frames to actually run.
	for _i in range(30):
		await EditorInterface.get_base_control().get_tree().process_frame

	# Phase 3: reassign asset.normal_texture to the loaded external resource.
	for entry: Array in saved:
		var asset = entry[0]
		var path: String = entry[1]
		var ext_tex: Texture2D = load(path) as Texture2D
		if ext_tex == null:
			push_warning("Could not load freshly-saved %s — leaving asset alone" % path)
			continue
		asset.set("normal_texture", ext_tex)
		print("  reassigned %s → ExtResource(%s)" % [asset.get("name"), path])

	# Save the scene so the new ExtResource refs are persisted and the
	# embedded Image/ImageTexture sub_resources get pruned.
	var save_err: int = EditorInterface.save_scene()
	if save_err != OK:
		push_error("save_scene() returned error %d — press Ctrl+S manually." % save_err)
	else:
		print("[extract_terrain_normals] DONE — Main.tscn saved with external normals.")
		print("                          File size should drop dramatically. Check via `git status`.")
