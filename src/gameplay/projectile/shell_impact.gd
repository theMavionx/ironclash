class_name ShellImpact
extends Node3D

## Shell impact VFX. Flash (GPUParticles3D, brief) + smoke column (GPUParticles3D).
## The smoke uses the toon-posterized billboard shader at
## src/vfx/spatial_particles_smoke.gdshader — web-compatible (gl_compatibility)
## unlike the prior FogVolume implementation, which required Forward+.
## The smoke node self-frees via its own tween when fade completes, so we just
## need to free THIS node once the smoke would be gone.

@export var total_lifetime: float = 7.0

@onready var _flash: GPUParticles3D = $Flash

var _timer: float = 0.0


func _queue_free_instance(instance_id: int) -> void:
	var obj: Object = instance_from_id(instance_id)
	if obj is Node:
		(obj as Node).queue_free()


func _ready() -> void:
	if OS.has_feature("web"):
		_flash.emitting = false
		_spawn_web_flash()
		return
	_flash.restart()
	# Smoke is a GPUParticles3D with smoke_volume.gd already tween-animating itself.


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= total_lifetime:
		queue_free()


func _spawn_web_flash() -> void:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.albedo_color = Color(1.0, 0.62, 0.12, 0.85)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.42, 0.06)
	mat.emission_energy_multiplier = 8.0

	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = 0.42
	sphere.height = 0.84
	sphere.radial_segments = 12
	sphere.rings = 6
	sphere.material = mat

	var flash: MeshInstance3D = MeshInstance3D.new()
	flash.name = "WebImpactFlash"
	flash.mesh = sphere
	add_child(flash)
	get_tree().create_timer(0.12).timeout.connect(
		_queue_free_instance.bind(flash.get_instance_id())
	)
