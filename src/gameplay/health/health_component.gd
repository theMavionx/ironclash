class_name HealthComponent
extends Node

## Vehicle health node — child of any CharacterBody3D vehicle.
## Holds HP, applies damage, emits destruction signals.
## Does NOT handle visuals or physics changes — vehicle controllers listen
## to [signal destroyed] and react in their own _on_destroyed() handler.
## Implements: design/gdd/combat-damage.md (pending)

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted whenever HP changes (including damage that does not kill).
signal health_changed(current_hp: int, max_hp_value: int)
## Emitted on every damage application that passes the destroyed-gate.
signal damaged(amount: int, source: int)
## Emitted exactly once when HP first reaches 0. [param by_source] is the
## DamageTypes.Source value of the killing blow.
signal destroyed(by_source: int)

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

## Maximum hit points. Set per-vehicle in the scene Inspector.
@export var max_hp: int = 100

# ---------------------------------------------------------------------------
# Private state
# ---------------------------------------------------------------------------

var _current_hp: int
var _is_destroyed: bool = false

# ---------------------------------------------------------------------------
# Built-in
# ---------------------------------------------------------------------------

func _ready() -> void:
	_current_hp = max_hp

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Apply damage from a projectile or kamikaze impact.
## Once HP reaches zero, further calls are ignored (destroyed-gate prevents
## double-firing destroyed signal from simultaneous hits).
func take_damage(amount: int, source: int) -> void:
	if _is_destroyed:
		return
	if amount <= 0:
		return
	var old_hp: int = _current_hp
	_current_hp = maxi(_current_hp - amount, 0)
	damaged.emit(amount, source)
	health_changed.emit(_current_hp, max_hp)
	if _current_hp == 0 and old_hp > 0:
		_is_destroyed = true
		destroyed.emit(source)


## True once HP has reached 0 at least once. Used by VehicleSwitcher
## to skip destroyed vehicles when cycling with E.
func is_destroyed() -> bool:
	return _is_destroyed


## Returns current HP (0..max_hp).
func get_current_hp() -> int:
	return _current_hp


## Restore full HP and clear the destroyed flag. Used by drone respawn.
func reset() -> void:
	_is_destroyed = false
	_current_hp = max_hp
	health_changed.emit(_current_hp, max_hp)
