class_name ShellImpact
extends Node3D

## Shell impact VFX. Flash (GPUParticles3D, brief) + Volumetric smoke (FogVolume).
## The smoke uses a custom fog shader with 3D noise (reactive-smoke approach).
## The smoke node self-frees via its own tween when fade completes, so we just
## need to free THIS node once the smoke would be gone.

@export var total_lifetime: float = 4.0

@onready var _flash: GPUParticles3D = $Flash

var _timer: float = 0.0


func _ready() -> void:
	_flash.restart()
	# Smoke is a FogVolume with smoke_volume.gd already tween-animating itself.


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= total_lifetime:
		queue_free()
