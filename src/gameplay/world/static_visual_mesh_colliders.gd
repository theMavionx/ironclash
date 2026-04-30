extends Node

const COLLISION_BODY_NAME: StringName = &"MeshCollisionBody"

@export var target_node_names: PackedStringArray = PackedStringArray()
@export var build_delay_seconds: float = 0.25
@export var include_hidden_meshes: bool = false
@export var collision_layer_value: int = 1
@export var collision_mask_value: int = 1
@export var max_shapes_per_target: int = 96


func _ready() -> void:
	call_deferred("_schedule_rebuild")


func _schedule_rebuild() -> void:
	if build_delay_seconds > 0.0:
		await get_tree().create_timer(build_delay_seconds).timeout
	else:
		await get_tree().process_frame
	rebuild_colliders()


func rebuild_colliders() -> void:
	var search_root: Node = get_parent()
	if search_root == null:
		return

	for target_name: String in target_node_names:
		var target: Node3D = search_root.get_node_or_null(target_name) as Node3D
		if target == null:
			push_warning("StaticVisualMeshColliders: target '%s' is missing." % target_name)
			continue
		_rebuild_target(target)


func _rebuild_target(target: Node3D) -> void:
	var previous_body: Node = target.get_node_or_null(NodePath(String(COLLISION_BODY_NAME)))
	if previous_body != null:
		target.remove_child(previous_body)
		previous_body.queue_free()

	var body := StaticBody3D.new()
	body.name = COLLISION_BODY_NAME
	body.collision_layer = collision_layer_value
	body.collision_mask = collision_mask_value
	target.add_child(body)

	var built_count: int = 0
	built_count = _collect_mesh_colliders(target, target, body, built_count)
	if built_count == 0:
		target.remove_child(body)
		body.queue_free()


func _collect_mesh_colliders(root: Node3D, node: Node, body: StaticBody3D, built_count: int) -> int:
	if built_count >= max_shapes_per_target:
		return built_count

	var mesh_instance: MeshInstance3D = node as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh != null:
		if include_hidden_meshes or mesh_instance.is_visible_in_tree():
			var shape: Shape3D = mesh_instance.mesh.create_trimesh_shape()
			if shape != null:
				var collision := CollisionShape3D.new()
				collision.name = "MeshCollision_%02d_%s" % [built_count + 1, _safe_name(str(mesh_instance.name))]
				collision.shape = shape
				collision.transform = root.global_transform.affine_inverse() * mesh_instance.global_transform
				body.add_child(collision)
				built_count += 1
				if built_count >= max_shapes_per_target:
					return built_count

	for child: Node in node.get_children():
		if child.name == COLLISION_BODY_NAME:
			continue
		built_count = _collect_mesh_colliders(root, child, body, built_count)
		if built_count >= max_shapes_per_target:
			return built_count

	return built_count


func _safe_name(raw_name: String) -> String:
	var result: String = raw_name.strip_edges()
	if result.is_empty():
		return "mesh"
	result = result.replace(" ", "_")
	result = result.replace("/", "_")
	result = result.replace(":", "_")
	return result.substr(0, 32)
