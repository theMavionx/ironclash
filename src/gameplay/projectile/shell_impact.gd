class_name ShellImpact
extends Node3D

## Shell impact VFX. Flash (GPUParticles3D, brief) + smoke column (GPUParticles3D).
## The smoke uses the toon-posterized billboard shader at
## src/vfx/spatial_particles_smoke.gdshader — web-compatible (gl_compatibility)
## unlike the prior FogVolume implementation, which required Forward+.
## Both flash and smoke can run as pooled instances to avoid first-hit
## allocation stalls in browser builds.

@export var total_lifetime: float = 7.0

@onready var _flash: GPUParticles3D = $Flash
@onready var _smoke: SmokeVolume = $Smoke as SmokeVolume

static var _web_flash_material: StandardMaterial3D = null
static var _web_flash_mesh: SphereMesh = null

var _timer: float = 0.0
var _pool_owner: Node = null
var _pool_active: bool = true
var _web_flash: MeshInstance3D = null
## True while the deferred 2-frame prewarm timer is still in flight. Cleared
## by play_at()/deactivate_for_pool() so a fallback-acquired impact during
## the warmup window does not get hidden mid-effect.
var _pool_warmup_pending: bool = false


func set_pool_owner(pool_owner: Node) -> void:
	_pool_owner = pool_owner
	_resolve_smoke()
	if _smoke != null:
		_smoke.set_pool_owner(self)


func is_pool_idle() -> bool:
	return _pool_owner != null and not _pool_active


func play_at(hit_point: Vector3, hit_normal: Vector3) -> void:
	# Cancel any pending pool-warmup deactivate so a real impact acquired
	# during the prewarm window stays visible through its effect.
	_pool_warmup_pending = false
	global_position = hit_point
	if hit_normal.length_squared() > 0.001:
		global_transform.basis = Basis(Quaternion(Vector3.UP, hit_normal.normalized()))
	_start_effect()


func deactivate_for_pool() -> void:
	_pool_warmup_pending = false
	_pool_active = false
	visible = false
	_timer = 0.0
	set_process(false)
	_hide_web_flash()
	if _flash != null:
		_flash.emitting = false
	if _smoke != null:
		_smoke.deactivate_for_pool()


func _ready() -> void:
	_resolve_smoke()
	if _pool_owner != null:
		if _smoke != null:
			_smoke.set_pool_owner(self)
		# Why: the additive BLEND_MODE_ADD + no_depth_test SphereMesh used for
		# the web flash compiles its pipeline only on first draw. Hiding the
		# pool entry immediately means the first real impact in match stalls
		# the frame on inline shader compile. Force a brief visible render
		# (web flash sphere on web, normal flash particles otherwise) for two
		# frames, then deactivate.
		_pool_active = true
		_pool_warmup_pending = true
		visible = true
		set_process(false)
		if OS.has_feature("web"):
			_show_web_flash()
		call_deferred("_finish_pool_warmup_render")
	else:
		_start_effect()


func _finish_pool_warmup_render() -> void:
	if not is_inside_tree() or not _pool_warmup_pending:
		return
	await get_tree().process_frame
	if not is_inside_tree() or not _pool_warmup_pending:
		return
	await get_tree().process_frame
	if not is_instance_valid(self) or not _pool_warmup_pending:
		return
	_pool_warmup_pending = false
	deactivate_for_pool()


func _process(delta: float) -> void:
	if _pool_owner != null and not _pool_active:
		return
	_timer += delta
	if OS.has_feature("web") and _web_flash != null and _web_flash.visible and _timer >= 0.12:
		_hide_web_flash()
	if _timer >= total_lifetime:
		_finish()


func _resolve_smoke() -> void:
	if _smoke != null and is_instance_valid(_smoke):
		return
	_smoke = get_node_or_null("Smoke") as SmokeVolume


func _start_effect() -> void:
	_timer = 0.0
	_pool_active = true
	visible = true
	set_process(true)
	if OS.has_feature("web"):
		if _flash != null:
			_flash.emitting = false
		_show_web_flash()
	else:
		if _flash != null:
			_flash.emitting = false
			_flash.restart()
	if _smoke != null:
		_smoke.play()


func _show_web_flash() -> void:
	if _web_flash == null or not is_instance_valid(_web_flash):
		_web_flash = MeshInstance3D.new()
		_web_flash.name = "WebImpactFlash"
		_web_flash.mesh = _get_web_flash_mesh()
		_web_flash.material_override = _get_web_flash_material()
		add_child(_web_flash)
	_web_flash.visible = true


func _hide_web_flash() -> void:
	if _web_flash != null and is_instance_valid(_web_flash):
		_web_flash.visible = false


func _finish() -> void:
	if _pool_owner != null and is_instance_valid(_pool_owner) and _pool_owner.has_method("release_impact"):
		_pool_owner.call("release_impact", self)
		return
	queue_free()


static func _get_web_flash_material() -> StandardMaterial3D:
	if _web_flash_material != null:
		return _web_flash_material
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.albedo_color = Color(1.0, 0.62, 0.12, 0.85)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.42, 0.06)
	mat.emission_energy_multiplier = 8.0
	_web_flash_material = mat
	return _web_flash_material


static func _get_web_flash_mesh() -> SphereMesh:
	if _web_flash_mesh != null:
		return _web_flash_mesh
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = 0.42
	sphere.height = 0.84
	sphere.radial_segments = 8
	sphere.rings = 4
	_web_flash_mesh = sphere
	return _web_flash_mesh
