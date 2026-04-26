extends Node3D

## Visual stand-in for a non-local player. Server owns position, HP, and
## alive state — this script mirrors snapshots into the local Body so the
## same PlayerAnimController works without any network awareness on its part.
##
## Animation events (fire / reload) come from the network `anim_event`
## payload, routed by WorldReplicator. Damage / death / respawn likewise.
##
## Implements: docs/architecture/adr-0005-node-authoritative-server.md

@export var interp_speed: float = 15.0

var peer_id: int = -1
var team: String = ""

var _target_pos: Vector3 = Vector3.ZERO
var _target_rot_y: float = 0.0
var _last_pos: Vector3 = Vector3.ZERO
var _last_snapshot_msec: int = 0
var _alive: bool = true
var _hp: int = 100
var _max_hp: int = 100
var _weapon: String = "ak"
var _move_state: String = "idle"
## Target Y offset applied to the body to fake a crouch pose. Lerped each frame.
var _target_body_y_offset: float = 0.0
var _current_body_y_offset: float = 0.0

@onready var _body: CharacterBody3D = $Body
@onready var _health: Node = $Body/HealthComponent
@onready var _label: Label3D = $Label3D


func _ready() -> void:
	# The local player.tscn adds a "Muzzle" Node3D under ak47 via an editable
	# scene-instance override (offset 0.5m along the barrel). Remote scenes
	# don't carry that override — so we re-create it at the same offset here
	# the first frame the skeleton is wired up. WorldReplicator's
	# `Body/Visual/Player/Skeleton3D/ak47/Muzzle` lookup then resolves and the
	# server's muzzle_flash + tracer event paints onto the actual rifle bone.
	_ensure_ak_muzzle()


func _ensure_ak_muzzle() -> void:
	var skel: Node = get_node_or_null("Body/Visual/Player/Skeleton3D")
	if skel == null:
		return
	var ak47: Node = skel.get_node_or_null("ak47")
	if ak47 == null:
		return
	if ak47.get_node_or_null("Muzzle") != null:
		return
	var muzzle: Node3D = Node3D.new()
	muzzle.name = "Muzzle"
	# Local-space offset MUST match player.tscn line 72 — keep in sync if the
	# local file ever retunes the muzzle position.
	muzzle.transform = Transform3D(Basis.IDENTITY, Vector3(0.5, 0.04, 0))
	ak47.add_child(muzzle)


func setup(p_peer_id: int, p_team: String, initial_pos: Vector3, initial_rot_y: float) -> void:
	peer_id = p_peer_id
	team = p_team
	if _body != null:
		_body.global_position = initial_pos
		_body.rotation.y = initial_rot_y
	_target_pos = initial_pos
	_target_rot_y = initial_rot_y
	_last_pos = initial_pos
	_last_snapshot_msec = Time.get_ticks_msec()
	_refresh_label()


func update_from_snapshot(pos: Vector3, rot_y: float, hp: int, max_hp: int, alive: bool, weapon: String = "", move_state: String = "") -> void:
	var now: int = Time.get_ticks_msec()
	var dt_ms: float = max(1.0, float(now - _last_snapshot_msec))
	var dt: float = dt_ms / 1000.0
	if _body != null:
		# Drive Body.velocity from snapshot delta so PlayerAnimController's
		# locomotion blend (idle↔run) reacts to network-driven movement.
		var delta_pos: Vector3 = pos - _last_pos
		_body.velocity = delta_pos / max(dt, 0.001)
	_target_pos = pos
	_target_rot_y = rot_y
	_last_pos = pos
	_last_snapshot_msec = now
	if _hp != hp or _max_hp != max_hp or _alive != alive:
		_hp = hp
		_max_hp = max_hp
		if _alive != alive:
			_alive = alive
			visible = alive
		_refresh_label()
	# Sync weapon if the server says it differs from what we have. This is the
	# late-join recovery path — for live updates the explicit `weapon_select`
	# anim_event already drives the swap.
	if weapon != "" and weapon != _weapon:
		_weapon = weapon
		var ac: Node = get_node_or_null("PlayerAnimController")
		if ac != null and ac.has_method("set_weapon"):
			ac.call("set_weapon", _weapon_string_to_enum(weapon))
	if move_state != "" and move_state != _move_state:
		_move_state = move_state
		_target_body_y_offset = -0.45 if move_state == "crouch" else 0.0


## PlayerAnimController.Weapon enum: { AR = 0, RPG = 1 }. Mirrors the wire
## strings sent by NetworkPlayerSync.
const _WEAPON_AR: int = 0
const _WEAPON_RPG: int = 1


func play_anim_event(state: String, weapon: String) -> void:
	var ac: Node = get_node_or_null("PlayerAnimController")
	if ac == null:
		return
	# Make sure the animation tree knows which weapon's idle/run/burst to use
	# before we trigger the action. Without this, a fresh remote player who
	# never received a weapon_select event would play AR_Reload while the
	# AR mesh stays hidden behind RPG mesh, etc.
	if weapon != "" and ac.has_method("set_weapon"):
		ac.call("set_weapon", _weapon_string_to_enum(weapon))
		_weapon = weapon
	match state:
		"fire":
			if ac.has_method("play_fire"):
				ac.call("play_fire")
		"reload":
			if ac.has_method("play_reload"):
				ac.call("play_reload")
		"weapon_select":
			if ac.has_method("play_select"):
				ac.call("play_select", _weapon_string_to_enum(weapon))
		_:
			pass


static func _weapon_string_to_enum(s: String) -> int:
	match s:
		"rpg":
			return _WEAPON_RPG
		_:
			return _WEAPON_AR


func on_damage(_amount: int, new_hp: int) -> void:
	_hp = new_hp
	_refresh_label()


func on_death() -> void:
	_alive = false
	visible = false


func on_respawn(pos: Vector3) -> void:
	_alive = true
	visible = true
	_hp = _max_hp
	if _body != null:
		_body.global_position = pos
		_body.velocity = Vector3.ZERO
	_target_pos = pos
	_last_pos = pos
	_refresh_label()


func _process(delta: float) -> void:
	if _body == null:
		return
	# Crouch fake — smoothly drop the body Y so the visible mesh squats.
	# 6 lerp/sec is slow enough that the transition reads, fast enough not to
	# look laggy after a network state change.
	_current_body_y_offset = lerp(_current_body_y_offset, _target_body_y_offset, clamp(6.0 * delta, 0.0, 1.0))
	var aim_pos: Vector3 = _target_pos + Vector3(0, _current_body_y_offset, 0)
	var t: float = clamp(interp_speed * delta, 0.0, 1.0)
	_body.global_position = _body.global_position.lerp(aim_pos, t)
	_body.rotation.y = lerp_angle(_body.rotation.y, _target_rot_y, t)


func _refresh_label() -> void:
	if _label == null:
		return
	_label.text = "P%d %s  %d/%d" % [peer_id, team, _hp, _max_hp]
	_label.modulate = Color(1.0, 0.45, 0.45) if team == "red" else Color(0.5, 0.75, 1.0)
