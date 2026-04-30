class_name RemotePlayer
extends CharacterBody3D

## Visual stand-in for a non-local player. The server is authoritative for
## position; this node interpolates between the most recent server snapshot
## and the previously-seen one to hide the 30 Hz tick on a 60 Hz render.
##
## Implements: docs/architecture/adr-0005-node-authoritative-server.md

const RED_COLOR: Color = Color(0.82, 0.27, 0.27)
const BLUE_COLOR: Color = Color(0.23, 0.49, 0.85)

## Lerp factor per second. 15 = ~93 % closure in 0.2 s; tighter than that
## starts to look snappy on a 30 Hz feed.
@export var interp_speed: float = 15.0

var peer_id: int = -1
var team: String = ""
var display_name: String = ""

var _target_pos: Vector3 = Vector3.ZERO
var _target_rot_y: float = 0.0

@onready var _mesh: MeshInstance3D = $Mesh
@onready var _label: Label3D = $Label3D


func setup(p_peer_id: int, p_team: String, initial_pos: Vector3, initial_rot_y: float, p_display_name: String = "") -> void:
	peer_id = p_peer_id
	team = p_team
	display_name = p_display_name.strip_edges()
	global_position = initial_pos
	rotation.y = initial_rot_y
	_target_pos = initial_pos
	_target_rot_y = initial_rot_y
	_apply_team_color(RED_COLOR if team == "red" else BLUE_COLOR)
	_label.text = display_name if display_name != "" else "P%d" % peer_id


func _apply_team_color(color: Color) -> void:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.7
	_mesh.set_surface_override_material(0, mat)


func update_from_snapshot(pos: Vector3, rot_y: float) -> void:
	_target_pos = pos
	_target_rot_y = rot_y


func _process(delta: float) -> void:
	# Lerp position. We don't use move_and_slide because the server is
	# authoritative — collisions are server's job once damage lands.
	var t: float = clamp(interp_speed * delta, 0.0, 1.0)
	global_position = global_position.lerp(_target_pos, t)
	rotation.y = lerp_angle(rotation.y, _target_rot_y, t)
