class_name TankShell
extends Node3D

## Forward-moving raycast projectile. Used by both tank shells and helicopter
## missiles — the firer calls [method setup] to specify damage source/amount
## and to add a self-hit exception to the internal RayCast3D.
## On collision: applies damage to a HealthComponent if present, spawns impact
## VFX, and frees itself.
##
## Implements: design/gdd/combat/tank_shell.md

@export var speed: float = 60.0
@export var lifetime: float = 3.0

## PackedScene for the shell impact VFX.
@export var impact_scene: PackedScene = preload("res://scenes/projectile/shell_impact.tscn")

## Collision mask controlling which physics layers this shell tests against.
## Default layer 1 = world/terrain, layer 2 = vehicles. Adjust per-project.
@export_flags_3d_physics var collision_mask: int = 0b11

## Damage dealt to a HealthComponent on hit. Set via [method setup] by the firer.
@export var damage: int = 100
## Identifies the firing weapon for VFX/scoring branches.
@export var damage_source: int = DamageTypes.Source.TANK_SHELL

var _remaining_life: float
var _ray: RayCast3D
## Body to ignore on the first frame (the firing vehicle). Set via [method setup]
## BEFORE add_child so _ready can apply the exception when constructing the ray.
var _shooter: CollisionObject3D = null


## Configure damage source/amount and the firing vehicle to ignore for self-hit.
## MUST be called BEFORE add_child so _ready picks up the values when wiring
## the RayCast3D exception.
func setup(source: int, dmg: int, shooter: CollisionObject3D) -> void:
	damage_source = source
	damage = dmg
	_shooter = shooter


func _ready() -> void:
	_remaining_life = lifetime

	_ray = RayCast3D.new()
	add_child(_ray)
	# Cast slightly ahead each frame — length matches one frame of travel at max speed.
	# Using 1/30 s as a conservative frame floor so fast shells never tunnel.
	_ray.target_position = Vector3(0.0, 0.0, -(speed / 30.0))
	_ray.collision_mask = collision_mask
	_ray.enabled = true
	# Physics-level filter so the shell never hits the vehicle that fired it.
	if _shooter != null:
		_ray.add_exception(_shooter)


func _physics_process(delta: float) -> void:
	# Check collision BEFORE moving so the ray sweeps the path we are about to cover.
	if _ray.is_colliding():
		var collider: Node = _ray.get_collider() as Node
		_apply_damage_if_health(collider)
		_spawn_impact(_ray.get_collision_point(), _ray.get_collision_normal())
		queue_free()
		return

	translate(Vector3(0.0, 0.0, -speed * delta))
	_remaining_life -= delta
	if _remaining_life <= 0.0:
		queue_free()


func _apply_damage_if_health(collider: Node) -> void:
	if collider == null:
		return
	var health: HealthComponent = collider.get_node_or_null("HealthComponent") as HealthComponent
	if health != null:
		health.take_damage(damage, damage_source)


func _spawn_impact(hit_point: Vector3, hit_normal: Vector3) -> void:
	if impact_scene == null:
		return

	var impact: Node3D = impact_scene.instantiate() as Node3D
	if impact == null:
		push_error("TankShell: impact_scene did not instantiate as Node3D")
		return

	# Place in world space via the scene root so the VFX is not parented to the
	# shell (which will queue_free immediately).
	var world_root: Node = get_tree().current_scene
	world_root.add_child(impact)
	impact.global_position = hit_point

	# Orient so impact local +Y aligns with the surface normal. Using
	# Quaternion(from, to) handles edge cases (parallel vectors) correctly,
	# unlike the manual cross-product approach which produces a degenerate
	# basis when hit_normal is parallel to FORWARD or RIGHT.
	if hit_normal.length_squared() > 0.001:
		impact.global_transform.basis = Basis(Quaternion(Vector3.UP, hit_normal.normalized()))
