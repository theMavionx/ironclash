class_name WebShaderBillboardVFX
extends Node3D

## Lightweight browser VFX runner for shader billboards.
##
## WebGL2 can accept our ShaderMaterial while silently drawing particle nodes
## blank. This node keeps the shader path, but owns plain QuadMesh instances
## and animates them like particles from _process.

var _cards: Array[Dictionary] = []
@export var update_fps: float = 24.0

var _update_accumulator: float = 0.0


func _ready() -> void:
	set_process(true)


func stop_looping() -> void:
	for entry: Dictionary in _cards:
		entry["looping"] = false


func restart(looping: bool = true) -> void:
	_update_accumulator = 0.0
	for entry: Dictionary in _cards:
		entry["looping"] = looping
		var card: MeshInstance3D = entry["node"] as MeshInstance3D
		if card != null and is_instance_valid(card):
			card.visible = true
		_respawn(entry, randf() * float(entry["lifetime"]))
	set_process(true)


func hide_all() -> void:
	for entry: Dictionary in _cards:
		var card: MeshInstance3D = entry["node"] as MeshInstance3D
		if card != null and is_instance_valid(card):
			card.visible = false
	set_process(false)


func add_card(
	name: String,
	material: Material,
	base_size: Vector2,
	base_origin: Vector3,
	spawn_extents: Vector3,
	velocity_min: Vector3,
	velocity_max: Vector3,
	start_scale: float,
	end_scale: float,
	lifetime: float,
	looping: bool,
	alpha_peak: float,
	fade_in: float,
	fade_out: float,
	spin_speed_max: float = 0.0,
	start_age: float = -1.0,
	lock_upright: bool = false
) -> void:
	var quad: QuadMesh = QuadMesh.new()
	quad.size = base_size

	var card: MeshInstance3D = MeshInstance3D.new()
	card.name = name
	card.mesh = quad
	card.material_override = material.duplicate() if material != null else null
	card.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(card)

	var entry: Dictionary = {
		"node": card,
		"material": card.material_override,
		"base_origin": base_origin,
		"spawn_extents": spawn_extents,
		"velocity_min": velocity_min,
		"velocity_max": velocity_max,
		"start_scale": start_scale,
		"end_scale": end_scale,
		"lifetime": maxf(lifetime, 0.001),
		"looping": looping,
		"alpha_peak": alpha_peak,
		"fade_in": maxf(fade_in, 0.001),
		"fade_out": maxf(fade_out, 0.001),
		"spin_speed_max": spin_speed_max,
		"base_size": base_size,
		"lock_upright": lock_upright,
	}
	_cards.append(entry)
	_respawn(entry, start_age)


func add_card_with_velocity(
	name: String,
	material: Material,
	base_size: Vector2,
	local_origin: Vector3,
	velocity: Vector3,
	start_scale: float,
	end_scale: float,
	lifetime: float,
	looping: bool,
	alpha_peak: float,
	fade_in: float,
	fade_out: float,
	spin_speed_max: float = 0.0,
	start_age: float = -1.0,
	lock_upright: bool = false
) -> void:
	add_card(
		name,
		material,
		base_size,
		local_origin,
		Vector3.ZERO,
		velocity,
		velocity,
		start_scale,
		end_scale,
		lifetime,
		looping,
		alpha_peak,
		fade_in,
		fade_out,
		spin_speed_max,
		start_age,
		lock_upright
	)


func _process(delta: float) -> void:
	var step_delta: float = delta
	if update_fps > 0.0:
		_update_accumulator += delta
		var step: float = 1.0 / update_fps
		if _update_accumulator < step:
			return
		step_delta = _update_accumulator
		_update_accumulator = 0.0

	var camera: Camera3D = get_viewport().get_camera_3d()
	var live_cards: int = 0
	for entry: Dictionary in _cards:
		var card: MeshInstance3D = entry["node"] as MeshInstance3D
		if card == null or not is_instance_valid(card):
			continue

		entry["age"] = float(entry["age"]) + step_delta
		var lifetime: float = float(entry["lifetime"])
		if float(entry["age"]) >= lifetime:
			if bool(entry["looping"]):
				_respawn(entry)
			else:
				card.visible = false
				continue

		var age: float = float(entry["age"])
		var life: float = clampf(age / lifetime, 0.0, 1.0)
		var origin: Vector3 = entry["origin"]
		var velocity: Vector3 = entry["velocity"]
		var local_pos: Vector3 = origin + velocity * age
		local_pos.x += sin(age * 1.7 + float(entry["phase"])) * float(entry["sway"])
		local_pos.z += cos(age * 1.3 + float(entry["phase"]) * 0.7) * float(entry["sway"])
		card.position = local_pos

		var grow_t: float = smoothstep(0.0, 1.0, life)
		var scale_amount: float = lerpf(float(entry["start_scale"]), float(entry["end_scale"]), grow_t)
		var alpha: float = float(entry["alpha_peak"])
		alpha *= smoothstep(0.0, float(entry["fade_in"]), life)
		alpha *= 1.0 - smoothstep(1.0 - float(entry["fade_out"]), 1.0, life)
		_update_material(entry, life, alpha)
		_face_camera(card, camera, scale_amount, float(entry["roll"]) + age * float(entry["spin_speed"]))
		card.visible = alpha > 0.01
		live_cards += 1

	if live_cards == 0 and _cards.size() > 0:
		set_process(false)


func _respawn(entry: Dictionary, start_age: float = -1.0) -> void:
	var extents: Vector3 = entry["spawn_extents"]
	var base_origin: Vector3 = entry["base_origin"]
	entry["origin"] = base_origin + Vector3(
		randf_range(-extents.x, extents.x),
		randf_range(-extents.y, extents.y),
		randf_range(-extents.z, extents.z)
	)
	var vmin: Vector3 = entry["velocity_min"]
	var vmax: Vector3 = entry["velocity_max"]
	entry["velocity"] = Vector3(
		randf_range(vmin.x, vmax.x),
		randf_range(vmin.y, vmax.y),
		randf_range(vmin.z, vmax.z)
	)
	entry["age"] = start_age if start_age >= 0.0 else randf() * float(entry["lifetime"])
	if bool(entry["lock_upright"]):
		entry["roll"] = 0.0
		entry["spin_speed"] = 0.0
	else:
		entry["roll"] = randf() * TAU
		entry["spin_speed"] = randf_range(-float(entry["spin_speed_max"]), float(entry["spin_speed_max"]))
	entry["phase"] = randf() * TAU
	entry["sway"] = randf_range(0.0, 0.06)
	_update_material(entry, clampf(float(entry["age"]) / float(entry["lifetime"]), 0.0, 1.0), 0.0)


func _update_material(entry: Dictionary, life: float, alpha: float) -> void:
	var mat: ShaderMaterial = entry["material"] as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("alpha_multiplier", alpha)
	mat.set_shader_parameter("particle_life_override", life)
	if life <= 0.001:
		mat.set_shader_parameter("time_offset", randf() * 20.0)


func _face_camera(card: MeshInstance3D, camera: Camera3D, scale_amount: float, roll: float) -> void:
	if camera == null:
		card.scale = Vector3(scale_amount, scale_amount, scale_amount)
		return
	var pos: Vector3 = card.global_position
	var to_cam: Vector3 = camera.global_position - pos
	to_cam.y = 0.0
	if to_cam.length_squared() < 0.0001:
		to_cam = Vector3.FORWARD
	to_cam = to_cam.normalized()
	var up: Vector3 = Vector3.UP
	var right: Vector3 = up.cross(to_cam).normalized()
	var c: float = cos(roll)
	var s: float = sin(roll)
	var rolled_right: Vector3 = right * c + up * s
	var rolled_up: Vector3 = up * c - right * s
	card.global_transform = Transform3D(
		Basis(rolled_right * scale_amount, rolled_up * scale_amount, to_cam),
		pos
	)
