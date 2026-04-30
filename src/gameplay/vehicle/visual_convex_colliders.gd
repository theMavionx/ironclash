class_name VisualConvexColliders
extends RefCounted

const GENERATED_GROUP: StringName = &"visual_convex_collider"
const GENERATED_PREFIX: String = "AutoConvexCollider_"


static func rebuild(
		body: CollisionObject3D,
		visual_root: Node,
		min_size: Vector3,
		ignore_names: PackedStringArray = PackedStringArray(),
		max_shapes: int = 16,
		include_hidden: bool = false,
		clean: bool = true,
		simplify: bool = true
) -> int:
	if body == null or visual_root == null:
		return 0

	_set_manual_root_shapes_disabled(body, false)
	_remove_generated_shapes(body)

	var meshes: Array[Dictionary] = []
	_collect_meshes(body, visual_root, visual_root, ignore_names, include_hidden, meshes)
	meshes = meshes.filter(func(entry: Dictionary) -> bool:
		var aabb: AABB = entry["aabb"]
		return _is_useful_box(aabb, min_size)
	)
	meshes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["volume"]) > float(b["volume"])
	)

	if max_shapes > 0 and meshes.size() > max_shapes:
		meshes.resize(max_shapes)

	var built: int = 0
	for entry: Dictionary in meshes:
		var mesh_instance: MeshInstance3D = entry["mesh_instance"]
		if mesh_instance == null or mesh_instance.mesh == null:
			continue

		var convex: Shape3D = mesh_instance.mesh.create_convex_shape(clean, simplify)
		if convex == null:
			continue

		var collision := CollisionShape3D.new()
		collision.name = "%s%02d_%s" % [GENERATED_PREFIX, built + 1, _safe_name(str(entry["name"]))]
		collision.shape = convex
		collision.transform = body.global_transform.affine_inverse() * mesh_instance.global_transform
		collision.disabled = false
		collision.add_to_group(GENERATED_GROUP)
		body.add_child(collision)
		built += 1

	if built > 0:
		_set_manual_root_shapes_disabled(body, true)
	return built


static func _remove_generated_shapes(body: Node) -> void:
	for child: Node in body.get_children():
		var shape: CollisionShape3D = child as CollisionShape3D
		if shape != null and shape.is_in_group(GENERATED_GROUP):
			body.remove_child(shape)
			shape.queue_free()


static func _set_manual_root_shapes_disabled(body: Node, disabled: bool) -> void:
	for child: Node in body.get_children():
		var shape: CollisionShape3D = child as CollisionShape3D
		if shape != null and not shape.is_in_group(GENERATED_GROUP):
			shape.disabled = disabled


static func _collect_meshes(
		body: CollisionObject3D,
		node: Node,
		visual_root: Node,
		ignore_names: PackedStringArray,
		include_hidden: bool,
		out_meshes: Array[Dictionary]
) -> void:
	if _is_ignored(node, visual_root, ignore_names):
		return

	var mesh_instance: MeshInstance3D = node as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh != null:
		if include_hidden or mesh_instance.is_visible_in_tree():
			var aabb: AABB = _mesh_aabb_in_body_space(body, mesh_instance)
			out_meshes.append({
				"name": mesh_instance.name,
				"mesh_instance": mesh_instance,
				"aabb": aabb,
				"volume": _volume(aabb.size),
			})

	for child: Node in node.get_children():
		_collect_meshes(body, child, visual_root, ignore_names, include_hidden, out_meshes)


static func _mesh_aabb_in_body_space(body: CollisionObject3D, mesh_instance: MeshInstance3D) -> AABB:
	var mesh_aabb: AABB = mesh_instance.get_aabb()
	var mesh_end: Vector3 = mesh_aabb.position + mesh_aabb.size
	var corners: Array[Vector3] = [
		Vector3(mesh_aabb.position.x, mesh_aabb.position.y, mesh_aabb.position.z),
		Vector3(mesh_end.x, mesh_aabb.position.y, mesh_aabb.position.z),
		Vector3(mesh_aabb.position.x, mesh_end.y, mesh_aabb.position.z),
		Vector3(mesh_end.x, mesh_end.y, mesh_aabb.position.z),
		Vector3(mesh_aabb.position.x, mesh_aabb.position.y, mesh_end.z),
		Vector3(mesh_end.x, mesh_aabb.position.y, mesh_end.z),
		Vector3(mesh_aabb.position.x, mesh_end.y, mesh_end.z),
		Vector3(mesh_end.x, mesh_end.y, mesh_end.z),
	]
	var to_body: Transform3D = body.global_transform.affine_inverse() * mesh_instance.global_transform
	var result: AABB = AABB(to_body * corners[0], Vector3.ZERO)
	for i: int in range(1, corners.size()):
		result = result.expand(to_body * corners[i])
	return result


static func _is_ignored(node: Node, visual_root: Node, ignore_names: PackedStringArray) -> bool:
	if ignore_names.is_empty():
		return false
	var current: Node = node
	while current != null:
		if ignore_names.has(current.name):
			return true
		if current == visual_root:
			break
		current = current.get_parent()
	return false


static func _is_useful_box(aabb: AABB, min_size: Vector3) -> bool:
	var size: Vector3 = aabb.size
	if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
		return false
	return size.x >= min_size.x * 0.35 or size.y >= min_size.y * 0.35 or size.z >= min_size.z * 0.35


static func _volume(size: Vector3) -> float:
	return maxf(size.x, 0.0) * maxf(size.y, 0.0) * maxf(size.z, 0.0)


static func _safe_name(raw_name: String) -> String:
	var result: String = raw_name.strip_edges()
	if result.is_empty():
		return "mesh"
	result = result.replace(" ", "_")
	result = result.replace("/", "_")
	result = result.replace(":", "_")
	return result.substr(0, 28)
