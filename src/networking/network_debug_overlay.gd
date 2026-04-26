extends CanvasLayer

## Dev-only on-screen network telemetry. Toggle with F3.
## Live values:
##   - Connection state (connecting / open / closed)
##   - Local peer_id + team
##   - Last server tick + snapshot rate
##   - RTT (ping) in ms
##   - Player roster (peer_id, team, hp, alive)
##   - Vehicle roster (id, driver_peer_id, hp, alive)
##
## NEVER ship this with a release build — it leaks every peer's HP on screen,
## so wrap visibility in a debug flag at packaging time.

const _TOGGLE_ACTION_KEY: int = KEY_F3

var _label: RichTextLabel = null
var _last_tick: int = 0
var _last_server_t: int = 0
var _player_count: int = 0
var _vehicles_state: Array = []
var _players_state: Array = []
var _connection_state: String = "init"


func _ready() -> void:
	layer = 100  # above HUD
	_build_ui()
	if not _has_network_manager():
		_label.text = "[no NetworkManager autoload]"
		return
	NetworkManager.connected_to_server.connect(_on_connected)
	NetworkManager.disconnected_from_server.connect(_on_disconnected)
	NetworkManager.connection_failed.connect(_on_failed)
	NetworkManager.snapshot_received.connect(_on_snapshot)
	NetworkManager.latency_updated.connect(_on_latency)
	NetworkManager.snapshot_rate_updated.connect(_on_snap_rate)
	visible = true


func _has_network_manager() -> bool:
	return get_node_or_null("/root/NetworkManager") != null


func _build_ui() -> void:
	var panel: PanelContainer = PanelContainer.new()
	panel.position = Vector2(8, 8)
	# Custom semi-opaque background so the label is readable over any scene.
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	sb.set_corner_radius_all(2)
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)
	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.custom_minimum_size = Vector2(420, 0)
	_label.add_theme_font_size_override("normal_font_size", 12)
	_label.add_theme_color_override("default_color", Color(1, 1, 1, 0.95))
	panel.add_child(_label)


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k: InputEventKey = event
		if k.pressed and not k.echo and k.keycode == _TOGGLE_ACTION_KEY:
			visible = not visible


func _on_connected(peer_id: int, team: String) -> void:
	_connection_state = "open peer=%d team=%s" % [peer_id, team]
	_redraw()


func _on_disconnected() -> void:
	_connection_state = "closed"
	_redraw()


func _on_failed(reason: String) -> void:
	_connection_state = "failed: " + reason
	_redraw()


func _on_snapshot(tick: int, server_t: int, players: Array, vehicles: Array) -> void:
	_last_tick = tick
	_last_server_t = server_t
	_players_state = players
	_vehicles_state = vehicles
	_player_count = players.size()
	# Don't redraw on every snapshot (30 Hz) — would burn cycles. We refresh
	# from a slower _process loop so the overlay stays cheap.


func _on_latency(_rtt: int) -> void:
	_redraw()


func _on_snap_rate(_rate: int) -> void:
	_redraw()


func _process(_dt: float) -> void:
	if visible:
		_redraw()


func _redraw() -> void:
	if _label == null or not visible:
		return
	var lines: PackedStringArray = []
	lines.append("[b]NET DEBUG[/b]   F3 to toggle")
	if not _has_network_manager():
		lines.append("[no NetworkManager]")
		_label.text = "\n".join(lines)
		return
	var rtt: int = NetworkManager.last_rtt_ms
	var snap_rate: int = NetworkManager.last_snap_rate
	var url: String = NetworkManager.config.client_url if NetworkManager.config != null else "?"
	var rtt_color: String = "lime" if rtt < 80 else ("yellow" if rtt < 160 else "tomato")
	var rate_color: String = "lime" if snap_rate >= 25 else ("yellow" if snap_rate >= 15 else "tomato")
	lines.append("link  : %s" % _connection_state)
	lines.append("url   : %s" % url)
	lines.append("rtt   : [color=%s]%s[/color]" % [rtt_color, ("%d ms" % rtt) if rtt >= 0 else "—"])
	lines.append("snap  : [color=%s]%d/s[/color]   tick=%d" % [rate_color, snap_rate, _last_tick])
	lines.append("peers : %d" % _player_count)
	for raw in _players_state:
		if not (raw is Dictionary):
			continue
		var p: Dictionary = raw
		var pid: int = int(p.get("id", -1))
		var team: String = String(p.get("team", ""))
		var hp: int = int(p.get("hp", 0))
		var max_hp: int = int(p.get("max_hp", 100))
		var alive: bool = bool(p.get("alive", true))
		var weapon: String = String(p.get("weapon", ""))
		var marker: String = "*" if pid == NetworkManager.local_peer_id else " "
		var alive_tag: String = "" if alive else "[color=tomato] DEAD[/color]"
		lines.append("  %s P%d %-5s %s %d/%d%s" % [marker, pid, team, weapon, hp, max_hp, alive_tag])
	if _vehicles_state.size() > 0:
		lines.append("vehicles:")
		for raw in _vehicles_state:
			if not (raw is Dictionary):
				continue
			var v: Dictionary = raw
			var id_: String = String(v.get("id", ""))
			var driver: int = int(v.get("driver_peer_id", -1))
			var hp: int = int(v.get("hp", 0))
			var max_hp: int = int(v.get("max_hp", 100))
			var alive: bool = bool(v.get("alive", true))
			var driver_str: String = ("P%d" % driver) if driver >= 0 else "—"
			var alive_tag: String = "" if alive else "[color=tomato] WRECK[/color]"
			lines.append("  %-10s drv=%-4s %d/%d%s" % [id_, driver_str, hp, max_hp, alive_tag])
	_label.text = "\n".join(lines)
