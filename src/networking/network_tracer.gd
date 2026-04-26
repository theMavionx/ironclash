extends Node3D

## Lightweight tracer line for remote players' shots. Spawned by
## WorldReplicator on every `vfx_event` muzzle_flash. Fades out and frees
## itself — no pool yet (one shot at 10 Hz × 9 peers = 90 spawns/sec, GC
## can handle that. Pool comes when bandwidth profiling demands it.)

@export var lifetime_seconds: float = 0.08
@export var beam_length_meters: float = 100.0
@export var beam_thickness: float = 0.04

var _elapsed: float = 0.0
var _mesh_node: MeshInstance3D = null


func setup(origin: Vector3, dir: Vector3, range_meters: float = 0.0) -> void:
	if range_meters > 0.0:
		beam_length_meters = range_meters
	global_position = origin
	# Orient the +Z axis along `dir` (mesh is built along +Z below).
	if dir.length_squared() > 0.0001:
		look_at(origin + dir.normalized(), Vector3.UP)


func _ready() -> void:
	# Build the beam programmatically — no .tscn needed.
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(beam_thickness, beam_thickness, beam_length_meters)
	_mesh_node = MeshInstance3D.new()
	_mesh_node.mesh = box
	# Push origin to one end so position = shooter origin, mesh extends forward.
	_mesh_node.position = Vector3(0.0, 0.0, beam_length_meters * 0.5)
	# Rotate the box to align its Z extent with our forward (already correct,
	# Box.size.z extends ±half along Z which is what we want).
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.85, 0.4, 0.9)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.disable_receive_shadows = true
	mat.no_depth_test = false
	_mesh_node.set_surface_override_material(0, mat)
	add_child(_mesh_node)


func _process(delta: float) -> void:
	_elapsed += delta
	var t: float = clamp(_elapsed / lifetime_seconds, 0.0, 1.0)
	if _mesh_node != null:
		var mat: StandardMaterial3D = _mesh_node.get_surface_override_material(0)
		if mat != null:
			var alpha: float = lerp(0.9, 0.0, t)
			mat.albedo_color = Color(1.0, 0.85, 0.4, alpha)
	if _elapsed >= lifetime_seconds:
		queue_free()
