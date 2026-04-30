extends Node3D

const GENERATED_GROUP: StringName = &"terrain_tree_collider"
const GENERATED_PREFIX: String = "TreeCollider_"

@export_node_path("Terrain3D") var terrain_path: NodePath
@export var enabled: bool = true
@export var build_delay_seconds: float = 0.75
@export var rebuild_passes: int = 12
@export var rebuild_interval_seconds: float = 0.5
@export var max_colliders: int = 768
@export var tree_mesh_ids: PackedInt32Array = PackedInt32Array([1, 2])
@export var collision_layer_value: int = 1
@export var collision_mask_value: int = 1
@export var small_tree_radius: float = 0.24
@export var small_tree_height: float = 4.2
@export var large_tree_radius: float = 0.34
@export var large_tree_height: float = 6.6

var _built_count: int = 0
var _last_signature: String = ""


func _ready() -> void:
	if not enabled:
		return
	call_deferred("_schedule_rebuild")


func _schedule_rebuild() -> void:
	if build_delay_seconds > 0.0:
		await get_tree().create_timer(build_delay_seconds).timeout
	else:
		await get_tree().process_frame
	if not is_inside_tree():
		return

	var attempts: int = maxi(rebuild_passes, 1)
	var last_reason: String = ""
	for attempt: int in range(attempts):
		var snapshot: Dictionary = _collect_tree_instances()
		if bool(snapshot.get("valid", false)):
			var signature: String = str(snapshot.get("signature", ""))
			if signature != _last_signature:
				_rebuild_from_instances(snapshot.get("instances", []))
				_last_signature = signature
		else:
			last_reason = str(snapshot.get("reason", "Terrain3D data is not ready."))

		if attempt < attempts - 1:
			if rebuild_interval_seconds > 0.0:
				await get_tree().create_timer(rebuild_interval_seconds).timeout
			else:
				await get_tree().process_frame
			if not is_inside_tree():
				return

	if _last_signature.is_empty() and not last_reason.is_empty():
		push_warning("TerrainTreeColliders: %s" % last_reason)


func _collect_tree_instances() -> Dictionary:
	var terrain: Node = get_node_or_null(terrain_path)
	if terrain == null:
		var parent := get_parent()
		if parent != null:
			terrain = parent.find_child("Terrain3D", false, false)
	if terrain == null or not terrain.has_method("get_data"):
		return {
			"valid": false,
			"reason": "Terrain3D node is missing.",
		}

	var terrain_data: Object = terrain.call("get_data")
	if terrain_data == null or not terrain_data.has_method("get_region_locations"):
		return {
			"valid": false,
			"reason": "Terrain3D data is not ready.",
		}

	var generated: Array[Dictionary] = []
	var counts_by_mesh: Dictionary = {}
	var origin_sum := Vector3.ZERO
	var region_world_size: float = 64.0
	if terrain.has_method("get_region_size") and terrain.has_method("get_vertex_spacing"):
		region_world_size = float(terrain.call("get_region_size")) * float(terrain.call("get_vertex_spacing"))

	for raw_location in terrain_data.call("get_region_locations"):
		var region_location := Vector2i(int(raw_location.x), int(raw_location.y))
		var region_offset := Vector3(
			float(region_location.x) * region_world_size,
			0.0,
			float(region_location.y) * region_world_size
		)
		var region: Object = terrain_data.call("get_region", region_location)
		if region == null or not region.has_method("get_instances"):
			continue

		var raw_instances: Variant = region.call("get_instances")
		if not (raw_instances is Dictionary):
			continue
		var instances: Dictionary = raw_instances
		for mesh_id: int in tree_mesh_ids:
			if not instances.has(mesh_id):
				continue
			origin_sum += _collect_mesh_instances(
				mesh_id,
				instances[mesh_id],
				region_offset,
				generated,
				counts_by_mesh
			)
			if generated.size() >= max_colliders:
				return _make_snapshot(generated, counts_by_mesh, origin_sum, true)

	return _make_snapshot(generated, counts_by_mesh, origin_sum, false)


func _collect_mesh_instances(
	mesh_id: int,
	cells: Variant,
	region_offset: Vector3,
	generated: Array[Dictionary],
	counts_by_mesh: Dictionary
) -> Vector3:
	var origin_sum := Vector3.ZERO
	if not (cells is Dictionary):
		return origin_sum

	for cell_key in cells.keys():
		var cell_data: Variant = cells[cell_key]
		if not (cell_data is Array) or cell_data.size() < 1:
			continue

		var transforms: Variant = cell_data[0]
		if not (transforms is Array):
			continue

		for transform_value in transforms:
			if not (transform_value is Transform3D):
				continue
			var tree_transform: Transform3D = transform_value
			tree_transform.origin += region_offset
			generated.append({
				"mesh_id": mesh_id,
				"transform": tree_transform,
			})
			counts_by_mesh[mesh_id] = int(counts_by_mesh.get(mesh_id, 0)) + 1
			origin_sum += tree_transform.origin
			if generated.size() >= max_colliders:
				return origin_sum

	return origin_sum


func _make_snapshot(
	instances: Array[Dictionary],
	counts_by_mesh: Dictionary,
	origin_sum: Vector3,
	truncated: bool
) -> Dictionary:
	return {
		"valid": true,
		"instances": instances,
		"signature": _make_signature(instances.size(), counts_by_mesh, origin_sum, truncated),
	}


func _make_signature(
	count: int,
	counts_by_mesh: Dictionary,
	origin_sum: Vector3,
	truncated: bool
) -> String:
	var keys: Array = counts_by_mesh.keys()
	keys.sort()

	var parts := PackedStringArray()
	parts.append("total:%d" % count)
	for key in keys:
		parts.append("%s:%d" % [str(key), int(counts_by_mesh[key])])
	parts.append("sum:%.2f,%.2f,%.2f" % [origin_sum.x, origin_sum.y, origin_sum.z])
	parts.append("truncated:%s" % str(truncated))
	return "|".join(parts)


func _rebuild_from_instances(instances: Array) -> void:
	_clear_generated_colliders()
	_built_count = 0

	for entry in instances:
		if not (entry is Dictionary):
			continue
		var tree_transform: Transform3D = entry.get("transform", Transform3D.IDENTITY)
		_add_tree_collider(int(entry.get("mesh_id", 0)), tree_transform)


func _add_tree_collider(mesh_id: int, tree_transform: Transform3D) -> void:
	var shape := CapsuleShape3D.new()
	var scale_y: float = maxf(tree_transform.basis.y.length(), 0.1)
	var scale_xz: float = maxf((tree_transform.basis.x.length() + tree_transform.basis.z.length()) * 0.5, 0.1)

	if mesh_id == 2:
		shape.radius = large_tree_radius * scale_xz
		shape.height = large_tree_height * scale_y
	else:
		shape.radius = small_tree_radius * scale_xz
		shape.height = small_tree_height * scale_y

	var body := StaticBody3D.new()
	body.name = "%s%d_%03d" % [GENERATED_PREFIX, mesh_id, _built_count + 1]
	body.collision_layer = collision_layer_value
	body.collision_mask = collision_mask_value
	body.add_to_group(GENERATED_GROUP)
	add_child(body)
	body.global_position = tree_transform.origin

	var collision := CollisionShape3D.new()
	collision.name = "TrunkCollision"
	collision.shape = shape
	collision.position = Vector3(0.0, shape.height * 0.5, 0.0)
	body.add_child(collision)
	_built_count += 1


func _clear_generated_colliders() -> void:
	for child: Node in get_children():
		if child.is_in_group(GENERATED_GROUP):
			remove_child(child)
			child.queue_free()
