class_name ChaseCamera
extends Camera3D

## Orbital third-person camera. Follows [member target_path]'s position but
## orbits around it based on [member yaw_source_path]'s Y rotation. For a tank,
## yaw_source = the turret, so moving the mouse rotates the turret AND the
## camera together (the view is always behind where the gun points). The hull
## steers independently underneath.
## Runs in physics tick to stay in sync with CharacterBody3D.

@export_node_path("Node3D") var target_path: NodePath
## Node whose world-space Y rotation drives the camera's orbit direction.
## Typically the tank turret. If not set, falls back to [member target_path].
@export_node_path("Node3D") var yaw_source_path: NodePath
## Offset from target in the yaw source's (rotated) local frame.
## Positive X = behind, positive Y = above.
@export var offset: Vector3 = Vector3(2.5, 2.2, 0.0)
@export var look_offset: Vector3 = Vector3(0.0, 1.3, 0.0)

var _target: Node3D
var _yaw_source: Node3D


func _ready() -> void:
	_target = get_node_or_null(target_path) as Node3D
	if _target == null:
		push_warning("ChaseCamera: target_path not set or not a Node3D (%s)" % target_path)
		return
	_yaw_source = get_node_or_null(yaw_source_path) as Node3D
	if _yaw_source == null:
		_yaw_source = _target
	_update_camera()


func _physics_process(_delta: float) -> void:
	if _target == null:
		return
	_update_camera()


func _update_camera() -> void:
	var yaw: float = _yaw_source.global_rotation.y
	var yaw_rot: Basis = Basis(Vector3.UP, yaw)
	global_position = _target.global_position + yaw_rot * offset
	look_at(_target.global_position + look_offset, Vector3.UP)
