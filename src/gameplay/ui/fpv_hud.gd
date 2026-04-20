class_name FPVHUD
extends CanvasLayer

## FPV drone HUD overlay. Displays altitude, RSSI, voltage, and armed state.
## Shows a red "DRONE OFFLINE" overlay while the drone is in its destroyed/
## respawning state — driven by the drone's HealthComponent.destroyed and the
## DroneController.respawned signals.
## Visibility is toggled by VehicleSwitcher; do NOT drive it from here.

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

## Path to the DroneController node — used to read altitude each frame and to
## connect destroyed/respawned signals.
@export_node_path var drone_path: NodePath

## Flicker frequency in Hz applied to the altitude label alpha.
@export var flicker_hz: float = 6.0
## Alpha range for the flicker effect (min alpha at trough, max at peak).
@export var flicker_alpha_min: float = 0.85
@export var flicker_alpha_max: float = 1.0

# ---------------------------------------------------------------------------
# Node references
# ---------------------------------------------------------------------------

@onready var _alt_label: Label = $Root/TopCenter/AltLabel
@onready var _rssi_label: Label = $Root/TopLeft/RSSILabel
@onready var _volt_label: Label = $Root/TopRight/VoltLabel
@onready var _armed_label: Label = $Root/BottomCenter/ArmedLabel
@onready var _offline_label: Label = $Root/OfflineLabel

# ---------------------------------------------------------------------------
# Private state
# ---------------------------------------------------------------------------

var _drone: Node3D = null
var _is_offline: bool = false

# ---------------------------------------------------------------------------
# Built-in
# ---------------------------------------------------------------------------

func _ready() -> void:
	_drone = get_node_or_null(drone_path) as Node3D
	if _drone == null:
		push_warning("FPVHUD: drone_path not set or not a Node3D (%s)" % drone_path)
		return
	# Connect drone signals so the HUD reflects destroyed/respawn state.
	if _drone.has_signal("respawned"):
		_drone.respawned.connect(_on_drone_respawned)
	var health: HealthComponent = _drone.get_node_or_null("HealthComponent") as HealthComponent
	if health != null:
		health.destroyed.connect(_on_drone_destroyed)


func _process(_delta: float) -> void:
	if not visible:
		return
	if _is_offline:
		# Don't update live data while offline — labels are blanked.
		return

	# Update altitude display.
	if _drone != null:
		var alt_m: float = maxf(_drone.global_position.y, 0.0)
		_alt_label.text = "AltH %d m" % int(alt_m)

	# Flicker: sinusoidal alpha modulation on altitude label.
	var t: float = Time.get_ticks_msec() * 0.001 * flicker_hz * TAU
	var alpha: float = lerpf(flicker_alpha_min, flicker_alpha_max, (sin(t) * 0.5) + 0.5)
	_alt_label.modulate.a = alpha


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Show or hide the HUD. Called by VehicleSwitcher.
func set_hud_visible(v: bool) -> void:
	visible = v


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

func _on_drone_destroyed(_by_source: int) -> void:
	_is_offline = true
	_offline_label.visible = true
	# Blank the live-data labels so it's obvious the link is down.
	_alt_label.text = "AltH --"
	_rssi_label.text = "RSSI --%"
	_volt_label.text = "--.-V [---]"
	_armed_label.text = "DISARMED"


func _on_drone_respawned() -> void:
	_is_offline = false
	_offline_label.visible = false
	# Restore default text — _process will update AltH each frame.
	_rssi_label.text = "RSSI 87%"
	_volt_label.text = "14.2V [===]"
	_armed_label.text = "ARMED"
