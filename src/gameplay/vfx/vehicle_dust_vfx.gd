class_name VehicleDustVFX
extends RefCounted

const _SMOKE_TEXTURE_PATH: String = "res://assets/textures/smoke_vfx/T_smoke_b7.png"

static var _dust_texture: Texture2D = null
static var _tread_material: Material = null
static var _rotor_material: Material = null


static func make_tread_dust() -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = "TreadDust"
	p.top_level = true
	p.amount = 26 if OS.has_feature("web") else 34
	p.lifetime = 0.72
	p.preprocess = 0.10
	p.explosiveness = 0.0
	p.randomness = 0.72
	p.fixed_fps = 24
	p.emitting = false
	p.local_coords = false
	p.draw_order = CPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.visibility_aabb = AABB(Vector3(-1.2, -0.35, -1.2), Vector3(2.4, 1.9, 2.4))
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(0.18, 0.035, 0.34)
	p.direction = Vector3(0.0, 1.0, 0.0)
	p.spread = 55.0
	p.initial_velocity_min = 0.18
	p.initial_velocity_max = 0.72
	p.gravity = Vector3(0.0, 0.10, 0.0)
	p.linear_accel_min = -0.24
	p.linear_accel_max = 0.02
	p.angle_min = -180.0
	p.angle_max = 180.0
	p.angular_velocity_min = -28.0
	p.angular_velocity_max = 28.0
	p.scale_amount_min = 0.16
	p.scale_amount_max = 0.34
	p.scale_amount_curve = _make_scale_curve(0.45, 0.95, 1.18)
	p.color_ramp = _make_dust_gradient(Color(0.46, 0.32, 0.18, 0.0), 0.34, 0.18)
	p.mesh = _make_dust_quad(Vector2(0.56, 0.48), true)
	return p


static func make_rotor_dust() -> CPUParticles3D:
	var p: CPUParticles3D = CPUParticles3D.new()
	p.name = "RotorWashDust"
	p.top_level = true
	p.amount = 44 if OS.has_feature("web") else 62
	p.lifetime = 0.92
	p.preprocess = 0.22
	p.explosiveness = 0.0
	p.randomness = 0.8
	p.fixed_fps = 24
	p.emitting = false
	p.local_coords = false
	p.draw_order = CPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.visibility_aabb = AABB(Vector3(-4.2, -0.45, -4.2), Vector3(8.4, 2.3, 8.4))
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 1.85
	p.direction = Vector3(0.0, 1.0, 0.0)
	p.spread = 82.0
	p.initial_velocity_min = 0.28
	p.initial_velocity_max = 1.20
	p.gravity = Vector3(0.0, 0.05, 0.0)
	p.radial_accel_min = 0.55
	p.radial_accel_max = 1.45
	p.linear_accel_min = -0.16
	p.linear_accel_max = 0.08
	p.angle_min = -180.0
	p.angle_max = 180.0
	p.angular_velocity_min = -34.0
	p.angular_velocity_max = 34.0
	p.scale_amount_min = 0.22
	p.scale_amount_max = 0.58
	p.scale_amount_curve = _make_scale_curve(0.35, 1.0, 1.35)
	p.color_ramp = _make_dust_gradient(Color(0.50, 0.36, 0.21, 0.0), 0.28, 0.13)
	p.mesh = _make_dust_quad(Vector2(0.78, 0.62), false)
	return p


static func _make_dust_quad(size: Vector2, tread: bool) -> QuadMesh:
	var quad: QuadMesh = QuadMesh.new()
	quad.size = size
	quad.material = _get_material(tread)
	return quad


static func _get_material(tread: bool) -> Material:
	if tread and _tread_material != null:
		return _tread_material
	if not tread and _rotor_material != null:
		return _rotor_material
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.render_priority = 9
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = false
	mat.disable_receive_shadows = true
	mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	var tex: Texture2D = _get_dust_texture()
	if tex != null:
		mat.albedo_texture = tex
	if tread:
		_tread_material = mat
	else:
		_rotor_material = mat
	return mat


static func _get_dust_texture() -> Texture2D:
	if _dust_texture != null:
		return _dust_texture
	_dust_texture = load(_SMOKE_TEXTURE_PATH) as Texture2D
	if _dust_texture == null:
		push_warning("VehicleDustVFX: dust texture missing at %s" % _SMOKE_TEXTURE_PATH)
	return _dust_texture


static func _make_scale_curve(start: float, mid: float, end: float) -> Curve:
	var curve: Curve = Curve.new()
	curve.add_point(Vector2(0.0, start))
	curve.add_point(Vector2(0.45, mid))
	curve.add_point(Vector2(1.0, end))
	return curve


static func _make_dust_gradient(base: Color, peak_alpha: float, tail_alpha: float) -> Gradient:
	var grad: Gradient = Gradient.new()
	grad.set_color(0, Color(base.r, base.g, base.b, 0.0))
	grad.set_offset(0, 0.0)
	grad.add_point(0.16, Color(base.r, base.g, base.b, peak_alpha))
	grad.add_point(0.58, Color(base.r * 0.88, base.g * 0.88, base.b * 0.88, tail_alpha))
	grad.add_point(1.0, Color(base.r, base.g, base.b, 0.0))
	return grad
