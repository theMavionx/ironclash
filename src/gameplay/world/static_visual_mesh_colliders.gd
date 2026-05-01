extends Node

const COLLISION_BODY_NAME: StringName = &"MeshCollisionBody"

@export var target_node_names: PackedStringArray = PackedStringArray()
@export var build_delay_seconds: float = 0.25
@export var include_hidden_meshes: bool = false
@export var collision_layer_value: int = 1
@export var collision_mask_value: int = 1
@export var max_shapes_per_target: int = 96
@export var max_shapes_per_frame: int = 4
@export var frames_between_targets: int = 1


func _ready() -> void:
	call_deferred("_schedule_rebuild")


func _schedule_rebuild() -> void:
	if build_delay_seconds > 0.0:
		await get_tree().create_timer(build_delay_seconds).timeout
	else:
		await get_tree().process_frame
	await rebuild_colliders()


func rebuild_colliders() -> void:
	var search_root: Node = get_parent()
	if search_root == null:
		return

	for target_name: String in target_node_names:
		var target: Node3D = search_root.get_node_or_null(target_name) as Node3D
		if target == null:
			push_warning("StaticVisualMeshColliders: target '%s' is missing." % target_name)
			continue
		await _rebuild_target(target)
		for _i: int in range(maxi(frames_between_targets, 0)):
			await get_tree().process_frame


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

	var meshes: Array[Dictionary] = []
	_collect_mesh_entries(target, target, meshes)

	var built_count: int = 0
	var frame_count: int = 0
	for entry: Dictionary in meshes:
		if built_count >= max_shapes_per_target:
			break
		var mesh_instance: MeshInstance3D = entry["mesh_instance"] as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var shape: Shape3D = mesh_instance.mesh.create_trimesh_shape()
		if shape == null:
			continue
		var collision := CollisionShape3D.new()
		collision.name = "MeshCollision_%02d_%s" % [built_count + 1, _safe_name(str(entry["name"]))]
		collision.shape = shape
		var local_transform: Transform3D = entry["transform"]
		collision.transform = local_transform
		body.add_child(collision)
		built_count += 1
		frame_count += 1
		if frame_count >= maxi(max_shapes_per_frame, 1):
			frame_count = 0
			await get_tree().process_frame
	if built_count == 0:
		target.remove_child(body)
		body.queue_free()


func _collect_mesh_entries(root: Node3D, node: Node, out_meshes: Array[Dictionary]) -> void:
	var mesh_instance: MeshInstance3D = node as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh != null:
		if include_hidden_meshes or mesh_instance.is_visible_in_tree():
			out_meshes.append({
				"name": mesh_instance.name,
				"mesh_instance": mesh_instance,
				"transform": root.global_transform.affine_inverse() * mesh_instance.global_transform,
			})

	for child: Node in node.get_children():
		if child.name == COLLISION_BODY_NAME:
			continue
		_collect_mesh_entries(root, child, out_meshes)


func _safe_name(raw_name: String) -> String:
	var result: String = raw_name.strip_edges()
	if result.is_empty():
		return "mesh"
	result = result.replace(" ", "_")
	result = result.replace("/", "_")
	result = result.replace(":", "_")
	return result.substr(0, 32)
