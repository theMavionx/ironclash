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


func _ready() -> void:
	_flash.restart()
	# Smoke is a GPUParticles3D with smoke_volume.gd already tween-animating itself.


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= total_lifetime:
		queue_free()
