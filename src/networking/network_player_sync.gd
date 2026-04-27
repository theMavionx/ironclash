extends Node

## Non-invasive network bridge for the local PlayerController.
## Lives as a child of the Player root in Main.tscn. Reads the controller's
## public API and Body transform — does NOT modify any existing player code.
##
## Outbound:
##   - 30 Hz `transform` packets (pos, yaw, pitch, velocity).
##   - `fire` packets when the local player presses the fire input.
##
## Inbound:
##   - `damage` for victim == local_peer_id → forwarded into HealthComponent.
##   - `death`  for victim == local_peer_id → set_active(false).
##   - `respawn` for peer_id == local_peer_id → respawn_at(server_pos).
##
## Implements: docs/architecture/adr-0005-node-authoritative-server.md

@export var send_rate_hz: float = 30.0
@export var weapon_id: String = "ak"

# Mapping PlayerAnimController.Weapon enum int → wire string. Order must match
# the enum: { AR = 0, RPG = 1 }.
## Wire-protocol weapon ids — MUST match keys in `assets/data/balance/weapons.json`
## and the registry on the server. Index order matches PlayerAnimController's
## Weapon enum (AR=0 → "ak", RPG=1 → "rpg"). Mismatch causes the server to
## silently drop fire events.
const _WEAPON_NAMES: PackedStringArray = ["ak", "rpg"]
# PlayerAnimController.Action enum: { NONE = 0, FIRE = 1, RELOAD = 2, SELECT = 3 }.
const _ACTION_FIRE: int = 1
const _ACTION_RELOAD: int = 2
const _ACTION_SELECT: int = 3

var _send_accumulator: float = 0.0
var _fire_seq: int = 0

# Resolved at _ready via the parent. Kept as Variant so we don't need
# class_name imports (which the global script class cache hates when the
# referenced files haven't been editor-scanned yet).
var _player: Node3D = null
var _body: CharacterBody3D = null
var _health: Node = null
var _camera: Camera3D = null
var _anim_controller: Node = null
var _weapon_controller: Node = null


func _ready() -> void:
	_player = get_parent() as Node3D
	if _player == null:
		push_error("[net-sync] parent is not a Node3D — must be child of the Player root")
		set_process(false)
		set_process_unhandled_input(false)
		return
	_body = _player.get_node_or_null("Body") as CharacterBody3D
	_health = _player.get_node_or_null("Body/HealthComponent")
	_camera = _player.get_node_or_null("CameraPivot/SpringArm3D/CameraRig/Camera3D") as Camera3D
	_anim_controller = _player.get_node_or_null("PlayerAnimController")
	_weapon_controller = _player.get_node_or_null("WeaponController")
	if _body == null:
		push_warning("[net-sync] Body not found at expected path; transform send disabled")
	if _anim_controller != null and _anim_controller.has_signal("action_started"):
		# Mirror reload / weapon-select to the network. Fire is sent separately
		# via the WeaponController.fired signal below.
		_anim_controller.connect("action_started", _on_anim_action_started)
	# Hook every actual shot — covers AR auto-fire (LMB held) which the input
	# action only triggers on the press edge. Each emitted `fired` is one
	# network packet, matching the local fire-rate.
	if _weapon_controller != null and _weapon_controller.has_signal("fired"):
		_weapon_controller.connect("fired", _on_weapon_fired)
	if not _has_network_manager():
		push_warning("[net-sync] NetworkManager autoload missing — sync disabled")
		set_process(false)
		set_process_unhandled_input(false)
		return
	NetworkManager.damage_received.connect(_on_damage_received)
	NetworkManager.death_received.connect(_on_death_received)
	NetworkManager.respawn_received.connect(_on_respawn_received)


func _has_network_manager() -> bool:
	return get_node_or_null("/root/NetworkManager") != null


func _process(delta: float) -> void:
	if not _has_network_manager():
		return
	if not NetworkManager.is_online():
		return
	if _body == null:
		return
	_send_accumulator += delta
	var period: float = 1.0 / send_rate_hz
	if _send_accumulator < period:
		return
	_send_accumulator = 0.0
	_send_current_transform()


## Per-shot hook driven by WeaponController.fired. Carries the weapon enum
## int (PlayerAnimController.Weapon: AR=0, RPG=1) as its single param. The
## 30 Hz transform stream already keeps server position fresh, so don't
## piggy-back an extra transform here — it doubles the fire-burst packet
## rate and fills the WebSocket buffer faster than the server drains it.
func _on_weapon_fired(_weapon_enum: int) -> void:
	if not _has_network_manager() or not NetworkManager.is_online():
		return
	if _camera == null:
		return
	var origin: Vector3 = _camera.global_position
	var dir: Vector3 = -_camera.global_transform.basis.z
	var weapon_name: String = _weapon_string_from_enum(_weapon_enum)
	_fire_seq += 1
	NetworkManager.send_fire(weapon_name, origin, dir, _fire_seq)


# ---------------------------------------------------------------------------
# Animation forwarding
# ---------------------------------------------------------------------------

## PlayerAnimController.action_started → wire as anim_state. Fire is excluded
## because send_fire() already triggers the corresponding server broadcast.
func _on_anim_action_started(action: int, _anim_name: String) -> void:
	if not _has_network_manager() or not NetworkManager.is_online():
		return
	var weapon_name: String = _current_weapon_string()
	match action:
		_ACTION_RELOAD:
			NetworkManager.send_anim_state("reload", weapon_name)
		_ACTION_SELECT:
			NetworkManager.send_anim_state("weapon_select", weapon_name)
		_ACTION_FIRE:
			pass  # fire path handled by send_fire above
		_:
			pass


func _current_weapon_string() -> String:
	if _anim_controller == null:
		return weapon_id
	if not _anim_controller.has_method("get_current_weapon"):
		return weapon_id
	var idx: int = int(_anim_controller.call("get_current_weapon"))
	return _weapon_string_from_enum(idx)


func _weapon_string_from_enum(idx: int) -> String:
	if idx < 0 or idx >= _WEAPON_NAMES.size():
		return weapon_id
	return _WEAPON_NAMES[idx]


func _send_current_transform() -> void:
	if _body == null:
		return
	var yaw: float = _body.rotation.y
	var pitch: float = 0.0
	var move_state: String = ""
	if _player.has_method("get_aim_yaw"):
		yaw = _player.call("get_aim_yaw")
	if _player.has_method("get_aim_pitch"):
		pitch = _player.call("get_aim_pitch")
	if _player.has_method("get_move_state_string"):
		move_state = _player.call("get_move_state_string")
	NetworkManager.send_transform(_body.global_position, yaw, pitch, _body.velocity, move_state)


# ---------------------------------------------------------------------------
# Inbound — only react when payload concerns the local peer
# ---------------------------------------------------------------------------

func _on_damage_received(payload: Dictionary) -> void:
	var victim: int = int(payload.get("victim", -1))
	if victim != NetworkManager.local_peer_id:
		return
	var amount: int = int(payload.get("amount", 0))
	if _health != null and _health.has_method("take_damage"):
		_health.call("take_damage", amount, 0)


func _on_death_received(payload: Dictionary) -> void:
	var victim: int = int(payload.get("victim", -1))
	if victim != NetworkManager.local_peer_id:
		return
	if _player != null and _player.has_method("set_active"):
		_player.call("set_active", false)


func _on_respawn_received(payload: Dictionary) -> void:
	var pid: int = int(payload.get("peer_id", -1))
	if pid != NetworkManager.local_peer_id:
		return
	var pos_arr: Array = payload.get("pos", [0, 0, 0])
	if pos_arr.size() < 3:
		return
	var pos: Vector3 = Vector3(float(pos_arr[0]), float(pos_arr[1]), float(pos_arr[2]))
	if _player != null and _player.has_method("respawn_at"):
		_player.call("respawn_at", pos, 0.0)
