class_name CombatPoolHub
extends Node3D

## Scene-level pool for combat objects that used to be allocated on shot.
## Keep this as a node in Main.tscn so pooled projectiles live in world space
## and can be reused by local controllers and network replication alike.

const GROUP_NAME: StringName = &"combat_pool_hub"
const PROJECTILE_RPG: StringName = &"rpg"

@export var tank_shell_scene: PackedScene = preload("res://scenes/projectile/tank_shell.tscn")
@export var rpg_rocket_scene: PackedScene = preload("res://scenes/projectile/rpg_rocket.tscn")
@export var shell_impact_scene: PackedScene = preload("res://scenes/projectile/shell_impact.tscn")
@export var muzzle_flash_scene: PackedScene = preload("res://scenes/projectile/muzzle_flash.tscn")

@export_range(0, 128, 1) var tank_shell_pool_size: int = 12
@export_range(0, 64, 1) var rpg_pool_size: int = 8
@export_range(0, 128, 1) var impact_pool_size: int = 8
@export_range(0, 64, 1) var muzzle_flash_pool_size: int = 8

var _tank_shell_pool: Array[Node3D] = []
var _rpg_pool: Array[Node3D] = []
var _impact_pool: Array[ShellImpact] = []
var _muzzle_flash_pool: Array[MuzzleFlash] = []
var _tank_shell_cursor: int = 0
var _rpg_cursor: int = 0
var _impact_cursor: int = 0
var _muzzle_flash_cursor: int = 0


static func find_for(context: Node) -> CombatPoolHub:
	if context == null or context.get_tree() == null:
		return null
	for node: Node in context.get_tree().get_nodes_in_group(GROUP_NAME):
		var hub: CombatPoolHub = node as CombatPoolHub
		if hub != null and is_instance_valid(hub):
			return hub
	return null


func _enter_tree() -> void:
	add_to_group(GROUP_NAME)


func _ready() -> void:
	if not _tank_shell_pool.is_empty() or not _rpg_pool.is_empty() or not _impact_pool.is_empty() or not _muzzle_flash_pool.is_empty():
		return
	_build_projectile_pool(tank_shell_scene, tank_shell_pool_size, _tank_shell_pool)
	# Browser builds already warm RPG shaders; keep this path on legacy spawn
	# because the exported RPG scene can report as not pool-ready in Web runtime.
	if not OS.has_feature("web"):
		_build_projectile_pool(rpg_rocket_scene, rpg_pool_size, _rpg_pool)
	_build_impact_pool()
	_build_muzzle_flash_pool()


func spawn_projectile(
	projectile_kind: StringName,
	origin: Vector3,
	aim_dir: Vector3,
	source: int,
	damage: int,
	shooter: CollisionObject3D,
	projectile_id: String = "",
	apply_local: bool = true,
	lifetime_override: float = -1.0
) -> Node3D:
	var shell: Node3D = _acquire_projectile(projectile_kind)
	if shell == null:
		return null
	if shell.has_method("activate_from_pool"):
		shell.call(
			"activate_from_pool",
			source,
			damage,
			shooter,
			projectile_id,
			apply_local,
			origin,
			aim_dir,
			lifetime_override
		)
	return shell


func release_projectile(shell: Node3D) -> void:
	if shell == null or not is_instance_valid(shell):
		return
	if shell.has_method("deactivate_for_pool"):
		shell.call("deactivate_for_pool")


func spawn_impact(hit_point: Vector3, hit_normal: Vector3, fallback_scene: PackedScene = null) -> ShellImpact:
	var impact: ShellImpact = _acquire_impact(fallback_scene)
	if impact == null:
		return null
	impact.play_at(hit_point, hit_normal)
	return impact


func release_impact(impact: ShellImpact) -> void:
	if impact == null or not is_instance_valid(impact):
		return
	impact.deactivate_for_pool()


func spawn_world_muzzle_flash(world_transform: Transform3D, fallback_scene: PackedScene = null) -> MuzzleFlash:
	var flash: MuzzleFlash = _acquire_muzzle_flash(fallback_scene)
	if flash == null:
		return null
	flash.play_at(world_transform)
	return flash


func release_muzzle_flash(flash: MuzzleFlash) -> void:
	if flash == null or not is_instance_valid(flash):
		return
	flash.deactivate_for_pool()


func _build_projectile_pool(scene: PackedScene, count: int, pool: Array[Node3D]) -> void:
	if scene == null:
		return
	for i: int in range(maxi(count, 0)):
		var shell: Node3D = scene.instantiate() as Node3D
		if shell == null or not shell.has_method("activate_from_pool"):
			push_warning("CombatPoolHub: projectile scene is not pool-ready: %s" % scene.resource_path)
			if shell != null:
				shell.queue_free()
			return
		if shell.has_method("set_pool_owner"):
			shell.call("set_pool_owner", self)
		add_child(shell)
		if shell.has_method("deactivate_for_pool"):
			shell.call("deactivate_for_pool")
		pool.append(shell)


func _build_impact_pool() -> void:
	if shell_impact_scene == null:
		return
	for i: int in range(maxi(impact_pool_size, 0)):
		var impact: ShellImpact = shell_impact_scene.instantiate() as ShellImpact
		if impact == null:
			push_warning("CombatPoolHub: impact scene root is not ShellImpact")
			return
		impact.set_pool_owner(self)
		add_child(impact)
		impact.deactivate_for_pool()
		_impact_pool.append(impact)


func _build_muzzle_flash_pool() -> void:
	if muzzle_flash_scene == null:
		return
	for i: int in range(maxi(muzzle_flash_pool_size, 0)):
		var flash: MuzzleFlash = muzzle_flash_scene.instantiate() as MuzzleFlash
		if flash == null:
			push_warning("CombatPoolHub: muzzle flash scene root is not MuzzleFlash")
			return
		flash.set_pool_owner(self)
		add_child(flash)
		flash.deactivate_for_pool()
		_muzzle_flash_pool.append(flash)


func _acquire_projectile(projectile_kind: StringName) -> Node3D:
	if projectile_kind == PROJECTILE_RPG:
		var rpg_idle: Node3D = _find_idle_projectile(_rpg_pool)
		if rpg_idle != null:
			return rpg_idle
		return _recycle_rpg()
	var shell_idle: Node3D = _find_idle_projectile(_tank_shell_pool)
	if shell_idle != null:
		return shell_idle
	return _recycle_tank_shell()


func _find_idle_projectile(pool: Array[Node3D]) -> Node3D:
	for shell: Node3D in pool:
		if shell != null and is_instance_valid(shell) and shell.has_method("is_pool_idle") and bool(shell.call("is_pool_idle")):
			return shell
	return null


func _recycle_tank_shell() -> Node3D:
	if _tank_shell_pool.is_empty():
		return null
	var shell: Node3D = _tank_shell_pool[_tank_shell_cursor % _tank_shell_pool.size()]
	_tank_shell_cursor = (_tank_shell_cursor + 1) % _tank_shell_pool.size()
	return shell


func _acquire_impact(fallback_scene: PackedScene) -> ShellImpact:
	for impact: ShellImpact in _impact_pool:
		if impact != null and is_instance_valid(impact) and impact.is_pool_idle():
			return impact
	if not _impact_pool.is_empty():
		var recycled: ShellImpact = _impact_pool[_impact_cursor % _impact_pool.size()]
		_impact_cursor = (_impact_cursor + 1) % _impact_pool.size()
		return recycled
	var scene: PackedScene = fallback_scene if fallback_scene != null else shell_impact_scene
	if scene == null:
		return null
	var impact: ShellImpact = scene.instantiate() as ShellImpact
	if impact == null:
		return null
	impact.set_pool_owner(self)
	add_child(impact)
	impact.deactivate_for_pool()
	_impact_pool.append(impact)
	return impact


func _recycle_rpg() -> Node3D:
	if _rpg_pool.is_empty():
		return null
	var shell: Node3D = _rpg_pool[_rpg_cursor % _rpg_pool.size()]
	_rpg_cursor = (_rpg_cursor + 1) % _rpg_pool.size()
	return shell


func _acquire_muzzle_flash(fallback_scene: PackedScene) -> MuzzleFlash:
	for flash: MuzzleFlash in _muzzle_flash_pool:
		if flash != null and is_instance_valid(flash) and flash.is_pool_idle():
			return flash
	if not _muzzle_flash_pool.is_empty():
		var recycled: MuzzleFlash = _muzzle_flash_pool[_muzzle_flash_cursor % _muzzle_flash_pool.size()]
		_muzzle_flash_cursor = (_muzzle_flash_cursor + 1) % _muzzle_flash_pool.size()
		return recycled
	var scene: PackedScene = fallback_scene if fallback_scene != null else muzzle_flash_scene
	if scene == null:
		return null
	var flash: MuzzleFlash = scene.instantiate() as MuzzleFlash
	if flash == null:
		return null
	flash.set_pool_owner(self)
	add_child(flash)
	flash.deactivate_for_pool()
	_muzzle_flash_pool.append(flash)
	return flash
