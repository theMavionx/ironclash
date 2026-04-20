extends OmniLight3D

## Pulses light_energy between [member min_energy] and [member max_energy] in
## a continuous loop. Attached to OmniLight3D nodes built by DestructionVFX.

@export var min_energy: float = 1.2
@export var max_energy: float = 2.8
@export var half_period_sec: float = 0.20

var _t_acc: float = 0.0


func _process(delta: float) -> void:
	# Sin-shaped oscillation between min and max — frame-rate independent.
	_t_acc += delta
	var phase: float = _t_acc / (half_period_sec * 2.0) * TAU
	light_energy = lerpf(min_energy, max_energy, (sin(phase) * 0.5) + 0.5)
