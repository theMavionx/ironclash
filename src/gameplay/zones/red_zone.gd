class_name RedZone
extends Node3D

## Capture-zone-style scoring volume. Awards [member points_per_second] every
## second a player body, or the locally driven tank/helicopter, stays inside.
##
## Emits [signal score_changed] on every accumulator tick so HUD can refresh
## without polling.

signal score_changed(new_score: int)
signal point_earned
signal player_entered
signal player_exited

const GROUP: String = "score_zones"
const TEAM_NEUTRAL: String = ""
const TEAM_RED: String = "red"
const TEAM_BLUE: String = "blue"

@export var points_per_second: float = 1.0
## Currently-accumulated score. Persists for the lifetime of the scene.
@export var score: int = 0
## Bodies whose collision_layer overlaps this mask are counted as "in zone".
## Player Body is on layer 2 (see scenes/player/player.tscn).
@export_flags_3d_physics var tracked_collision_layer: int = 2
@export var capture_radius: float = 5.0
@export var capture_height: float = 8.0
@export var vehicle_capture_height: float = 80.0
@export var flag_move_seconds: float = 5.0
@export var flag_top_y: float = 5.4
@export var flag_low_y: float = 0.65
@export var fallback_team: String = TEAM_RED
@export var zone_id: String = ""

@onready var _zone_mesh: MeshInstance3D = get_node_or_null("Mesh") as MeshInstance3D
@onready var _area: Area3D = get_node_or_null("Area3D") as Area3D
@onready var _flag_rig: Node3D = get_node_or_null("FlagRig") as Node3D
@onready var _flag_pivot: Node3D = get_node_or_null("FlagRig/FlagPivot") as Node3D
@onready var _flag_mesh: MeshInstance3D = get_node_or_null("FlagRig/FlagPivot/Flag") as MeshInstance3D

var _tracked_bodies: Dictionary = {}
var _vehicle_roots: Array[Node3D] = []
var _presence_count: int = 0
var _accumulator: float = 0.0
var _owner_team: String = TEAM_NEUTRAL
var _capture_team: String = TEAM_NEUTRAL
var _flag_tween: Tween = null
var _zone_material: StandardMaterial3D = null
var _flag_material: StandardMaterial3D = null
var _server_authoritative: bool = false


func _ready() -> void:
	add_to_group(GROUP)
	if _area == null:
		push_warning("RedZone: missing Area3D child")
		return
	_area.collision_mask = tracked_collision_layer
	_area.body_entered.connect(_on_body_entered)
	_area.body_exited.connect(_on_body_exited)
	_prepare_zone_visuals()
	_prepare_flag_visuals()
	call_deferred("_refresh_vehicle_refs")


func _physics_process(delta: float) -> void:
	var presence: Dictionary = _collect_presence()
	var total: int = int(presence.get("total", 0))
	_update_presence_signal(total)
	if not _server_authoritative:
		_update_score(delta, total)
		_update_local_capture(presence.get("teams", {}))


func apply_server_match_state(msg: Dictionary) -> void:
	if zone_id.is_empty():
		return
	_server_authoritative = true
	if String(msg.get("state", "waiting")) != "in_progress":
		_apply_server_flag_owner(TEAM_NEUTRAL)
		return
	var zones: Array = msg.get("zones", [])
	for raw_zone in zones:
		if not (raw_zone is Dictionary):
			continue
		var zone: Dictionary = raw_zone
		if String(zone.get("id", "")) != zone_id:
			continue
		var owner: String = _normalize_server_owner(String(zone.get("owner", "neutral")))
		var capture_team: String = _normalize_server_owner(String(zone.get("capture_team", "neutral")))
		var progress: float = clampf(float(zone.get("capture_progress", 0.0)), 0.0, 1.0)
		_apply_server_zone_state(owner, capture_team, progress)
		return


func _apply_server_zone_state(owner: String, capture_team: String, progress: float) -> void:
	if owner != _owner_team:
		_apply_server_flag_owner(owner)
		if owner != TEAM_NEUTRAL and _flag_pivot != null:
			_set_flag_y(flag_low_y)
			_tween_flag_y(flag_top_y, flag_move_seconds)
		return

	if capture_team != TEAM_NEUTRAL and capture_team != owner:
		_capture_team = capture_team
		_apply_flag_color(owner)
		_apply_zone_color(owner)
		if _flag_tween != null:
			_flag_tween.kill()
			_flag_tween = null
		_set_flag_y(lerpf(flag_top_y, flag_low_y, progress))
		return

	_capture_team = TEAM_NEUTRAL
	_apply_zone_color(owner)
	if _flag_tween == null:
		_set_flag_y(flag_top_y)


func _apply_server_flag_owner(owner: String) -> void:
	if _flag_tween != null:
		_flag_tween.kill()
		_flag_tween = null
	_capture_team = TEAM_NEUTRAL
	_owner_team = owner
	_apply_flag_color(owner)
	_apply_zone_color(owner)
	if owner == TEAM_NEUTRAL:
		_set_flag_y(flag_top_y)


func _update_score(delta: float, presence_total: int) -> void:
	if presence_total <= 0 or points_per_second <= 0.0:
		return
	# Time-based, not tick-based: at 60 Hz physics * 1 pt/sec we accumulate
	# 0.0167 per tick; emit `score_changed` only when the int score actually
	# crosses a whole number to avoid HUD spam.
	_accumulator += points_per_second * delta
	if _accumulator >= 1.0:
		var earned: int = int(_accumulator)
		_accumulator -= float(earned)
		score += earned
		score_changed.emit(score)
		for _i in range(earned):
			point_earned.emit()


func _update_presence_signal(total: int) -> void:
	if _presence_count == 0 and total > 0:
		player_entered.emit()
	elif _presence_count > 0 and total == 0:
		player_exited.emit()
	_presence_count = total


func _collect_presence() -> Dictionary:
	var team_counts: Dictionary = {}
	var total: int = 0
	var stale_body_ids: Array[int] = []

	for id: int in _tracked_bodies.keys():
		var body: Node3D = _tracked_bodies[id] as Node3D
		if body == null or not is_instance_valid(body):
			stale_body_ids.append(id)
			continue
		var team: String = _team_from_body(body)
		if team == TEAM_NEUTRAL:
			continue
		total += 1
		team_counts[team] = int(team_counts.get(team, 0)) + 1

	for id: int in stale_body_ids:
		_tracked_bodies.erase(id)

	for vehicle: Node3D in _vehicle_roots:
		if vehicle == null or not is_instance_valid(vehicle):
			continue
		if not _is_locally_driven_vehicle(vehicle):
			continue
		if not _is_vehicle_inside_zone(vehicle):
			continue
		var team: String = _local_team()
		if team == TEAM_NEUTRAL:
			continue
		total += 1
		team_counts[team] = int(team_counts.get(team, 0)) + 1

	return {
		"total": total,
		"teams": team_counts,
	}


func _update_local_capture(team_counts: Dictionary) -> void:
	if team_counts.size() != 1:
		_cancel_pending_capture()
		return
	var present_team: String = String(team_counts.keys()[0])
	if present_team == TEAM_NEUTRAL:
		_cancel_pending_capture()
		return
	if present_team == _owner_team:
		_cancel_pending_capture()
		return
	if present_team == _capture_team:
		return
	_start_capture(present_team)


func _start_capture(team: String) -> void:
	if _flag_pivot == null:
		_owner_team = team
		_apply_flag_color(team)
		_apply_zone_color(team)
		return
	if _flag_tween != null:
		_flag_tween.kill()

	_capture_team = team
	_apply_zone_color(_owner_team)
	_flag_tween = _make_flag_tween()
	_flag_tween.tween_property(_flag_pivot, "position:y", flag_low_y, flag_move_seconds)
	_flag_tween.tween_callback(_on_flag_lowered.bind(team))
	_flag_tween.tween_property(_flag_pivot, "position:y", flag_top_y, flag_move_seconds)
	_flag_tween.tween_callback(_on_flag_raised.bind(team))


func _on_flag_lowered(team: String) -> void:
	_owner_team = team
	_capture_team = TEAM_NEUTRAL
	_apply_flag_color(team)
	_apply_zone_color(team)


func _on_flag_raised(team: String) -> void:
	if _capture_team == team:
		_capture_team = TEAM_NEUTRAL
	_flag_tween = null


func _cancel_pending_capture() -> void:
	if _capture_team == TEAM_NEUTRAL:
		return
	_capture_team = TEAM_NEUTRAL
	if _flag_tween != null:
		_flag_tween.kill()
		_flag_tween = null
	_apply_flag_color(_owner_team)
	_apply_zone_color(_owner_team)
	_set_flag_y(flag_top_y)


func _set_flag_y(y: float) -> void:
	if _flag_pivot == null:
		return
	var pivot_position: Vector3 = _flag_pivot.position
	pivot_position.y = y
	_flag_pivot.position = pivot_position


func _tween_flag_y(y: float, duration: float) -> void:
	if _flag_pivot == null:
		return
	if _flag_tween != null:
		_flag_tween.kill()
	_flag_tween = _make_flag_tween()
	_flag_tween.tween_property(_flag_pivot, "position:y", y, duration)
	_flag_tween.tween_callback(_clear_flag_tween)


func _make_flag_tween() -> Tween:
	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	return tween


func _clear_flag_tween() -> void:
	_flag_tween = null


func _prepare_flag_visuals() -> void:
	if _flag_pivot != null:
		var pivot_position: Vector3 = _flag_pivot.position
		pivot_position.y = flag_top_y
		_flag_pivot.position = pivot_position

	if _flag_mesh != null:
		var source_material: Material = _flag_mesh.material_override
		if source_material is StandardMaterial3D:
			_flag_material = (source_material as StandardMaterial3D).duplicate() as StandardMaterial3D
		else:
			_flag_material = StandardMaterial3D.new()
		_flag_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_flag_mesh.material_override = _flag_material
	_apply_flag_color(TEAM_NEUTRAL)
	_sync_flag_visual_scale()
	call_deferred("_sync_flag_visual_scale")


func _prepare_zone_visuals() -> void:
	if _zone_mesh == null:
		return
	var source_material: Material = _zone_mesh.material_override
	if source_material is StandardMaterial3D:
		_zone_material = (source_material as StandardMaterial3D).duplicate() as StandardMaterial3D
	else:
		_zone_material = StandardMaterial3D.new()
	_zone_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_zone_mesh.extra_cull_margin = maxf(_zone_mesh.extra_cull_margin, 1.0)
	_zone_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_zone_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_zone_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_zone_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_zone_material.set("disable_receive_shadows", true)
	_zone_material.emission_enabled = true
	_zone_material.emission_energy_multiplier = 1.2
	_zone_material.render_priority = 8
	_zone_mesh.material_override = _zone_material
	_apply_zone_color(TEAM_NEUTRAL)


func _apply_zone_color(team: String) -> void:
	if _zone_material == null:
		return
	var color: Color = _zone_color_for_team(team)
	_zone_material.albedo_color = color
	_zone_material.emission = Color(color.r, color.g, color.b, 1.0)
	_zone_material.emission_energy_multiplier = 1.35 if team != TEAM_NEUTRAL else 1.05


func _zone_color_for_team(team: String) -> Color:
	match team:
		TEAM_RED:
			return Color(1.0, 0.08, 0.04, 0.3)
		TEAM_BLUE:
			return Color(0.08, 0.42, 1.0, 0.3)
		_:
			return Color(1.0, 1.0, 1.0, 0.3)


func _apply_flag_color(team: String) -> void:
	if _flag_material == null:
		return
	match team:
		TEAM_RED:
			_flag_material.albedo_color = Color(0.95, 0.08, 0.05, 1.0)
		TEAM_BLUE:
			_flag_material.albedo_color = Color(0.08, 0.35, 1.0, 1.0)
		_:
			_flag_material.albedo_color = Color(1.0, 1.0, 1.0, 1.0)


func _sync_flag_visual_scale() -> void:
	if _flag_rig == null:
		return
	var scale_from_parent: Vector3 = global_transform.basis.get_scale()
	_flag_rig.scale = Vector3(
		_safe_inverse(scale_from_parent.x),
		_safe_inverse(scale_from_parent.y),
		_safe_inverse(scale_from_parent.z)
	)


func _safe_inverse(value: float) -> float:
	if is_zero_approx(value):
		return 1.0
	return 1.0 / absf(value)


func _refresh_vehicle_refs() -> void:
	_vehicle_roots.clear()
	var root: Node = get_tree().current_scene
	if root == null:
		root = get_tree().root
	_collect_vehicle_refs(root)


func _collect_vehicle_refs(node: Node) -> void:
	if node is TankController or node is HelicopterController:
		_vehicle_roots.append(node as Node3D)
	for child: Node in node.get_children():
		_collect_vehicle_refs(child)


func _is_locally_driven_vehicle(vehicle: Node3D) -> bool:
	return vehicle.has_method("is_locally_driven") and bool(vehicle.call("is_locally_driven"))


func _is_vehicle_inside_zone(vehicle: Node3D) -> bool:
	var offset: Vector3 = vehicle.global_position - global_position
	if absf(offset.y) > vehicle_capture_height:
		return false
	var horizontal_distance: float = Vector2(offset.x, offset.z).length()
	return horizontal_distance <= _capture_world_radius()


func _capture_world_radius() -> float:
	var zone_scale: Vector3 = global_transform.basis.get_scale()
	var horizontal_scale: float = max(0.001, (absf(zone_scale.x) + absf(zone_scale.z)) * 0.5)
	return capture_radius * horizontal_scale


func _team_from_body(body: Node3D) -> String:
	var cursor: Node = body
	var depth: int = 0
	while cursor != null and depth < 8:
		if "team" in cursor:
			var team: String = _normalize_team(String(cursor.get("team")))
			if team != TEAM_NEUTRAL:
				return team
		if cursor.has_node("NetworkPlayerSync"):
			if cursor.has_method("is_physics_processing") and not bool(cursor.call("is_physics_processing")):
				return TEAM_NEUTRAL
			return _local_team()
		if cursor is TankController or cursor is HelicopterController:
			if _is_locally_driven_vehicle(cursor as Node3D):
				return _local_team()
		cursor = cursor.get_parent()
		depth += 1
	return _local_team()


func _local_team() -> String:
	var tree_root: Window = get_tree().root
	var network_manager: Node = tree_root.get_node_or_null("NetworkManager")
	if network_manager != null and "local_team" in network_manager:
		var team: String = _normalize_team(String(network_manager.get("local_team")))
		if team != TEAM_NEUTRAL:
			return team
	return _normalize_team(fallback_team)


func _normalize_team(team: String) -> String:
	var normalized: String = team.strip_edges().to_lower()
	if normalized == TEAM_RED or normalized == TEAM_BLUE:
		return normalized
	return TEAM_NEUTRAL


func _normalize_server_owner(owner: String) -> String:
	if owner.strip_edges().to_lower() == "neutral":
		return TEAM_NEUTRAL
	return _normalize_team(owner)


func _on_body_entered(body: Node3D) -> void:
	_tracked_bodies[body.get_instance_id()] = body


func _on_body_exited(body: Node3D) -> void:
	_tracked_bodies.erase(body.get_instance_id())
