extends Node

## Client-only networking. Connects to the Node.js authoritative server via
## a plain `WebSocketPeer` + JSON wire protocol. Godot is purely a renderer
## here — no MultiplayerAPI, no @rpc, no MultiplayerSynchronizer.
##
## Implements: docs/architecture/adr-0005-node-authoritative-server.md
## Wire protocol: shared/protocol.ts
##
## Public surface (signals):
##   connected_to_server(peer_id, team)
##   disconnected_from_server()
##   connection_failed(reason)
##   snapshot_received(tick, server_t, players)
##   match_state_changed(state, red_score, blue_score, red_count, blue_count, time_remaining)
##   player_joined(peer_id, team)
##   player_left(peer_id)
##   damage_received(payload)
##   death_received(payload)
##   respawn_received(payload)
##   vfx_event(payload)
##   anim_event(payload)

signal connected_to_server(peer_id: int, team: String)
signal disconnected_from_server()
signal connection_failed(reason: String)
signal snapshot_received(tick: int, server_t: int, players: Array, vehicles: Array)
signal match_state_changed(state: String, red_score: int, blue_score: int, red_count: int, blue_count: int, time_remaining: float)
signal player_joined(peer_id: int, team: String)
signal player_left(peer_id: int)
signal damage_received(payload: Dictionary)
signal death_received(payload: Dictionary)
signal respawn_received(payload: Dictionary)
signal vfx_event(payload: Dictionary)
signal anim_event(payload: Dictionary)
## Round-trip latency in milliseconds, refreshed on every pong.
signal latency_updated(rtt_ms: int)
## Snapshots received in the last second; refreshed every ~1s on a moving window.
signal snapshot_rate_updated(snaps_per_sec: int)

const _WEB_BRIDGE_PATH: NodePath = ^"/root/WebBridge"
const _DEFAULT_CONFIG_PATH: String = "res://assets/data/network/default_network_config.tres"
const _CLIENT_VERSION: String = "0.1.0"
const _PROTOCOL_VERSION: String = "0.1.3"

var config: NetworkConfig = null
var local_peer_id: int = -1
var local_team: String = ""
var local_display_name: String = "Player"
var server_tick_hz: int = 30

var _socket: WebSocketPeer = null
var _state: int = WebSocketPeer.STATE_CLOSED
var _hello_sent: bool = false

# Ping/RTT bookkeeping. Ping every PING_INTERVAL_S; latency_updated fires
# whenever a pong rolls in. last_rtt_ms = -1 until the first pong arrives.
const _PING_INTERVAL_S: float = 1.0
var _ping_accumulator: float = 0.0
var last_rtt_ms: int = -1

# Snapshot-rate sliding window (1s).
var _snap_count_window: int = 0
var _snap_window_start_ms: int = 0
var last_snap_rate: int = 0


func _ready() -> void:
	config = _load_config()
	if has_node(_WEB_BRIDGE_PATH):
		var bridge: Node = get_node(_WEB_BRIDGE_PATH)
		if bridge.has_method("register_handler"):
			bridge.register_handler("ui_play", _on_ui_play)
	# Always-on poll. WebSocketPeer needs poll() every frame to drive its
	# internal state machine and surface incoming packets.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _load_config() -> NetworkConfig:
	if ResourceLoader.exists(_DEFAULT_CONFIG_PATH):
		var res: Resource = load(_DEFAULT_CONFIG_PATH)
		if res is NetworkConfig:
			return res
		push_warning("[net] config at %s is not a NetworkConfig — using defaults" % _DEFAULT_CONFIG_PATH)
	else:
		push_warning("[net] config %s missing — using script defaults" % _DEFAULT_CONFIG_PATH)
	return NetworkConfig.new()


# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------

func _on_ui_play(payload: Dictionary) -> void:
	local_display_name = _sanitize_display_name(String(payload.get("display_name", local_display_name)))
	connect_to_server()


func connect_to_server(url_override: String = "") -> void:
	if _socket != null:
		var existing_state: int = _socket.get_ready_state()
		if existing_state == WebSocketPeer.STATE_OPEN or existing_state == WebSocketPeer.STATE_CONNECTING:
			return
		_socket.close()
		_socket = null
	var url: String = _resolve_client_url(url_override)
	_socket = WebSocketPeer.new()
	# Default 64 KB is too small — when the menu→Main scene transition stalls
	# `_process` for a few hundred ms, snapshot bursts pile up and `write_packet`
	# in packet_buffer.h spams "Buffer payload full!". Bump to 1 MB on both
	# sides to absorb spikes; max_queued_packets covers count pressure.
	_socket.inbound_buffer_size = 1024 * 1024
	_socket.outbound_buffer_size = 1024 * 1024
	_socket.max_queued_packets = 4096
	var err: int = _socket.connect_to_url(url)
	if err != OK:
		push_error("[net] connect_to_url(%s) failed: %d" % [url, err])
		_socket = null
		connection_failed.emit("connect_to_url err %d" % err)
		_send_bridge_event("network_connection_failed", {"reason": "connect_to_url", "code": err})
		return
	_hello_sent = false
	_state = WebSocketPeer.STATE_CONNECTING
	print("[net] dialing %s ..." % url)


func _resolve_client_url(url_override: String = "") -> String:
	if url_override != "":
		return url_override
	var configured_url: String = config.client_url.strip_edges()
	if OS.has_feature("web") and _is_local_client_url(configured_url):
		var browser_url: String = _browser_ws_url()
		if browser_url != "":
			return browser_url
	return configured_url


func _is_local_client_url(url: String) -> bool:
	var lowered: String = url.to_lower()
	return lowered.begins_with("ws://127.0.0.1") or lowered.begins_with("ws://localhost")


func _browser_ws_url() -> String:
	var host_name: String = str(JavaScriptBridge.eval("window.location.hostname", true))
	if host_name == "" or host_name == "localhost" or host_name == "127.0.0.1":
		return ""
	var host: String = str(JavaScriptBridge.eval("window.location.host", true))
	if host == "":
		return ""
	var page_protocol: String = str(JavaScriptBridge.eval("window.location.protocol", true))
	var ws_scheme: String = "wss" if page_protocol == "https:" else "ws"
	return "%s://%s/ws" % [ws_scheme, host]


func disconnect_from_server() -> void:
	if _socket == null:
		return
	_socket.close()


# ---------------------------------------------------------------------------
# Frame loop
# ---------------------------------------------------------------------------

func _process(dt: float) -> void:
	if _socket == null:
		return
	_socket.poll()
	var current_state: int = _socket.get_ready_state()
	if current_state != _state:
		_on_state_changed(_state, current_state)
		_state = current_state
	if current_state == WebSocketPeer.STATE_OPEN:
		while _socket.get_available_packet_count() > 0:
			var raw: PackedByteArray = _socket.get_packet()
			_handle_raw(raw)
		_tick_ping(dt)
		_tick_snapshot_rate()


func _tick_ping(dt: float) -> void:
	_ping_accumulator += dt
	if _ping_accumulator < _PING_INTERVAL_S:
		return
	_ping_accumulator = 0.0
	send_ping()


func _tick_snapshot_rate() -> void:
	var now: int = Time.get_ticks_msec()
	if _snap_window_start_ms == 0:
		_snap_window_start_ms = now
		return
	if now - _snap_window_start_ms < 1000:
		return
	last_snap_rate = _snap_count_window
	snapshot_rate_updated.emit(last_snap_rate)
	_snap_count_window = 0
	_snap_window_start_ms = now


func _on_state_changed(prev: int, current: int) -> void:
	if current == WebSocketPeer.STATE_OPEN and not _hello_sent:
		send_message({
			"t": "hello",
			"client_version": _CLIENT_VERSION,
			"protocol_version": _PROTOCOL_VERSION,
			"display_name": local_display_name,
		})
		_hello_sent = true
	elif current == WebSocketPeer.STATE_CLOSED:
		var reason: String = _socket.get_close_reason() if _socket != null else "unknown"
		var code: int = _socket.get_close_code() if _socket != null else -1
		if prev == WebSocketPeer.STATE_OPEN:
			print("[net] disconnected (code=%d reason=%s)" % [code, reason])
			disconnected_from_server.emit()
			_send_bridge_event("network_disconnected", {"code": code, "reason": reason})
		else:
			print("[net] connection failed (code=%d reason=%s)" % [code, reason])
			connection_failed.emit(reason)
			_send_bridge_event("network_connection_failed", {"code": code, "reason": reason})
		local_peer_id = -1
		local_team = ""
		_socket = null
		_hello_sent = false


# ---------------------------------------------------------------------------
# Outgoing
# ---------------------------------------------------------------------------

func send_message(msg: Dictionary) -> void:
	if _socket == null or _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_socket.send_text(JSON.stringify(msg))


func send_transform(pos: Vector3, rot_y: float, aim_pitch: float, vel: Vector3, move_state: String = "") -> void:
	var msg: Dictionary = {
		"t": "transform",
		"pos": [pos.x, pos.y, pos.z],
		"rot_y": rot_y,
		"aim_pitch": aim_pitch,
		"vel": [vel.x, vel.y, vel.z],
		"client_t": Time.get_ticks_msec(),
	}
	if move_state != "":
		msg["move_state"] = move_state
	send_message(msg)


func send_fire(weapon: String, origin: Vector3, dir: Vector3, seq: int = 0) -> void:
	send_message({
		"t": "fire",
		"seq": seq,
		"weapon": weapon,
		"origin": [origin.x, origin.y, origin.z],
		"dir": [dir.x, dir.y, dir.z],
		"client_t": Time.get_ticks_msec(),
	})


func send_anim_state(state: String, weapon: String = "") -> void:
	var payload: Dictionary = {"t": "anim_state", "state": state}
	if weapon != "":
		payload["weapon"] = weapon
	send_message(payload)


func send_ping() -> void:
	send_message({"t": "ping", "client_t": Time.get_ticks_msec()})


func send_vehicle_enter(vehicle_id: String) -> void:
	send_message({"t": "vehicle_enter", "vehicle_id": vehicle_id})


func send_vehicle_exit() -> void:
	send_message({"t": "vehicle_exit"})


func send_vehicle_spawn_sync(
	vehicle_id: String,
	pos: Vector3,
	rot: Vector3,
	aim_yaw: float = NAN,
	aim_pitch: float = NAN
) -> void:
	var msg: Dictionary = {
		"t": "vehicle_spawn_sync",
		"vehicle_id": vehicle_id,
		"pos": [pos.x, pos.y, pos.z],
		"rot": [rot.x, rot.y, rot.z],
		"client_t": Time.get_ticks_msec(),
	}
	if not is_nan(aim_yaw):
		msg["aim_yaw"] = aim_yaw
	if not is_nan(aim_pitch):
		msg["aim_pitch"] = aim_pitch
	send_message(msg)


func send_vehicle_transform(
	vehicle_id: String,
	pos: Vector3,
	rot: Vector3,
	vel: Vector3,
	aim_yaw: float = NAN,
	aim_pitch: float = NAN
) -> void:
	var msg: Dictionary = {
		"t": "vehicle_transform",
		"vehicle_id": vehicle_id,
		"pos": [pos.x, pos.y, pos.z],
		"rot": [rot.x, rot.y, rot.z],
		"vel": [vel.x, vel.y, vel.z],
		"client_t": Time.get_ticks_msec(),
	}
	if not is_nan(aim_yaw):
		msg["aim_yaw"] = aim_yaw
	if not is_nan(aim_pitch):
		msg["aim_pitch"] = aim_pitch
	send_message(msg)


# ---------------------------------------------------------------------------
# Incoming
# ---------------------------------------------------------------------------

func _handle_raw(raw: PackedByteArray) -> void:
	var text: String = raw.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_warning("[net] non-object packet: %s" % text.substr(0, 80))
		return
	var msg: Dictionary = parsed
	var msg_type: String = String(msg.get("t", ""))
	match msg_type:
		"welcome":
			var server_proto: String = String(msg.get("protocol_version", ""))
			if server_proto != _PROTOCOL_VERSION:
				push_error("[net] protocol mismatch — client=%s server=%s — disconnecting" % [_PROTOCOL_VERSION, server_proto])
				_send_bridge_event("network_protocol_mismatch", {"client": _PROTOCOL_VERSION, "server": server_proto})
				disconnect_from_server()
				return
			local_peer_id = int(msg.get("peer_id", -1))
			local_team = String(msg.get("team", ""))
			local_display_name = _sanitize_display_name(String(msg.get("display_name", local_display_name)))
			server_tick_hz = int(msg.get("tick_hz", 30))
			print("[net] welcome peer_id=%d name=%s team=%s tick=%d Hz" % [local_peer_id, local_display_name, local_team, server_tick_hz])
			connected_to_server.emit(local_peer_id, local_team)
			_send_bridge_event("network_connected", {"peer_id": local_peer_id, "team": local_team, "display_name": local_display_name})
		"snapshot":
			var snap_tick: int = int(msg.get("tick", 0))
			var server_t: int = int(msg.get("server_t", 0))
			var snap_players: Array = msg.get("players", [])
			var snap_vehicles: Array = msg.get("vehicles", [])
			_snap_count_window += 1
			snapshot_received.emit(snap_tick, server_t, snap_players, snap_vehicles)
		"match_state":
			var ms: String = String(msg.get("state", "waiting"))
			var rs: int = int(msg.get("red_score", 0))
			var bs: int = int(msg.get("blue_score", 0))
			var rc: int = int(msg.get("red_count", 0))
			var bc: int = int(msg.get("blue_count", 0))
			var tr: float = float(msg.get("time_remaining", 0.0))
			match_state_changed.emit(ms, rs, bs, rc, bc, tr)
			get_tree().call_group("score_zones", "apply_server_match_state", msg)
			_send_bridge_event("match_state", msg)
		"player_joined":
			player_joined.emit(int(msg.get("peer_id", -1)), String(msg.get("team", "")))
		"player_left":
			player_left.emit(int(msg.get("peer_id", -1)))
		"damage":
			damage_received.emit(msg)
			# Forward to React HUD only for damage taken by the LOCAL peer.
			if int(msg.get("victim", -1)) == local_peer_id:
				_send_bridge_event("health_changed", {
					"hp": int(msg.get("new_hp", 0)),
					"max": 100,
					"source": String(msg.get("weapon", "")),
				})
			# Kill-feed: every damage event that drops a player to 0 is also a
			# kill. Broadcast to React for the kill feed regardless of victim.
			if int(msg.get("new_hp", 0)) == 0:
				_send_bridge_event("kill_feed", {
					"killer": int(msg.get("attacker", -1)),
					"killer_name": String(msg.get("attacker_name", "")),
					"killer_team": String(msg.get("attacker_team", "")),
					"victim": int(msg.get("victim", -1)),
					"victim_name": String(msg.get("victim_name", "")),
					"victim_team": String(msg.get("victim_team", "")),
					"weapon": String(msg.get("weapon", "")),
					"headshot": bool(msg.get("headshot", false)),
				})
		"death":
			death_received.emit(msg)
			if int(msg.get("victim", -1)) == local_peer_id:
				# Server tells us the respawn delay implicitly via the next
				# `respawn` packet; HUD locally counts down from now.
				_send_bridge_event("local_died", {
					"killer": int(msg.get("killer", -1)),
					"killer_name": String(msg.get("killer_name", "")),
					"killer_team": String(msg.get("killer_team", "")),
					"weapon": String(msg.get("weapon", "")),
				})
		"respawn":
			respawn_received.emit(msg)
			if int(msg.get("peer_id", -1)) == local_peer_id:
				_send_bridge_event("local_respawned", {})
		"vfx_event":
			vfx_event.emit(msg)
		"anim_event":
			anim_event.emit(msg)
		"kicked":
			print("[net] kicked: %s" % msg.get("reason", ""))
			_send_bridge_event("network_kicked", {"reason": msg.get("reason", "")})
		"pong":
			# Compute RTT from the client_t we echoed in the ping. Time.get_ticks_msec
			# rolls over at int32 max, which we won't hit during a session.
			var sent_t: int = int(msg.get("client_t", 0))
			var now_ms: int = Time.get_ticks_msec()
			last_rtt_ms = max(0, now_ms - sent_t)
			latency_updated.emit(last_rtt_ms)
		_:
			push_warning("[net] unknown message type: %s" % msg_type)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _send_bridge_event(event_name: String, payload: Dictionary) -> void:
	if not has_node(_WEB_BRIDGE_PATH):
		return
	var bridge: Node = get_node(_WEB_BRIDGE_PATH)
	if bridge.has_method("send_event"):
		bridge.send_event(event_name, payload)


func _sanitize_display_name(raw: String) -> String:
	var clean: String = raw.strip_edges()
	clean = clean.replace("\n", " ").replace("\r", " ").replace("\t", " ")
	clean = clean.replace("<", "").replace(">", "")
	while clean.contains("  "):
		clean = clean.replace("  ", " ")
	if clean.is_empty():
		return "Player"
	if clean.length() > 16:
		clean = clean.substr(0, 16)
	return clean


func is_online() -> bool:
	return _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN
