class_name NetworkTestController
extends CharacterBody3D

## Minimal local controller for the network demo scene. WASD + mouse, no
## weapons, no animations. Sends `transform` to the server at fixed rate so
## other clients can see this peer move via WorldReplicator.
##
## Implements: docs/architecture/adr-0005-node-authoritative-server.md
## Pairs with: scenes/debug/network_test.tscn

@export var move_speed: float = 8.0
@export var mouse_sensitivity: float = 0.002
@export var gravity: float = 9.8
@export var send_rate_hz: float = 30.0
@export var weapon_id: String = "ak"

@onready var _camera: Camera3D = $Camera3D

var _yaw: float = 0.0
var _pitch: float = 0.0
var _send_accumulator: float = 0.0


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		_yaw -= motion.relative.x * mouse_sensitivity
		_pitch = clamp(_pitch - motion.relative.y * mouse_sensitivity, -PI / 2.0 + 0.05, PI / 2.0 - 0.05)
		rotation.y = _yaw
		_camera.rotation.x = _pitch
	elif event is InputEventKey:
		var key: InputEventKey = event
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseButton:
		var btn: InputEventMouseButton = event
		if btn.pressed and btn.button_index == MOUSE_BUTTON_LEFT:
			_fire()


func _fire() -> void:
	if not _has_network_manager() or not NetworkManager.is_online():
		return
	var origin: Vector3 = _camera.global_position
	# Camera looks down its local -Z, so global -basis.z is the aim direction.
	var dir: Vector3 = -_camera.global_transform.basis.z
	NetworkManager.send_fire(weapon_id, origin, dir)


func _physics_process(delta: float) -> void:
	var input_vec: Vector2 = Vector2.ZERO
	if Input.is_action_pressed("move_forward"):
		input_vec.y -= 1.0
	if Input.is_action_pressed("move_back"):
		input_vec.y += 1.0
	if Input.is_action_pressed("move_left"):
		input_vec.x -= 1.0
	if Input.is_action_pressed("move_right"):
		input_vec.x += 1.0
	if input_vec.length() > 1.0:
		input_vec = input_vec.normalized()

	# Move on the XZ plane only — server speed-clamp will eventually enforce
	# this; for now it's a local invariant.
	var forward: Vector3 = -transform.basis.z
	var right: Vector3 = transform.basis.x
	var horizontal: Vector3 = (right * input_vec.x + forward * input_vec.y) * move_speed
	velocity.x = horizontal.x
	velocity.z = horizontal.z
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = max(velocity.y, 0.0)
	move_and_slide()

	_maybe_send_transform(delta)


func _maybe_send_transform(delta: float) -> void:
	_send_accumulator += delta
	var period: float = 1.0 / send_rate_hz
	if _send_accumulator < period:
		return
	_send_accumulator = 0.0
	if not _has_network_manager():
		return
	if not NetworkManager.is_online():
		return
	NetworkManager.send_transform(global_position, _yaw, _pitch, velocity)


func _has_network_manager() -> bool:
	return get_node_or_null("/root/NetworkManager") != null
