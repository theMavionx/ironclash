class_name WeaponController
extends Node

## Player weapon state + input handler.
##
## Tracks current weapon (AR / RPG), ammo counts per weapon, and drives
## [PlayerAnimController] for fire / reload / select actions. Emits signals
## for the HUD — does not touch UI directly (per .claude/rules/gameplay-code.md).
##
## Input (raw keys — MVP; migrate to InputMap post-MVP):
##   1  → select AR     2  → select RPG
##   LMB (hold)         → fire AR (auto)
##   LMB (single click) → fire RPG (single-shot, auto-reloads after)
##   R                  → reload AR (manual; RPG has no manual reload)
##
## KNOWN TECH DEBT (per .claude/rules/gameplay-code.md): all tuning values are
## @export defaults rather than loaded from a Resource file. Matches the
## existing PlayerController convention — will refactor to a shared
## PlayerTuningResource post-MVP.

signal ammo_changed(weapon: int, current: int, maximum: int)
signal weapon_switched(weapon: int)
signal fired(weapon: int)

@export_group("AR (Kalash)")
@export var ar_mag_size: int = 30
## Minimum seconds between auto-fire triggers while LMB is held. 0.1 ≈ 600 RPM.
@export var ar_fire_interval_sec: float = 0.1
## Damage per AR bullet dealt to any HealthComponent the hitscan strikes.
@export var ar_damage: int = 10
## Hitscan max range (metres).
@export var ar_max_range: float = 500.0
## Seconds between LMB press and first bullet spawn. Gives the fire animation
## time to transition from low-ready pose to raised-firing pose — prevents
## bullets from visually spawning while the rifle is still at the hip.
@export var ar_raise_delay_sec: float = 0.3

@export_group("RPG")
@export var rpg_mag_size: int = 1
## Damage dealt to a HealthComponent on direct hit. One-shot anti-vehicle.
@export var rpg_damage: int = 200
## Hitscan/travel max range (metres). Shell auto-expires beyond this.
@export var rpg_max_range: float = 500.0
## Packed scene for the RPG rocket projectile. Preloaded by default so the
## rocket spawn works out-of-the-box without an Inspector step. Override in
## the Inspector to swap in a different rocket scene for testing.
@export var rpg_scene: PackedScene = preload("res://scenes/projectile/rpg_rocket.tscn")
## Node3D at the visual tip of the rocket on the RPG mesh — where the
## projectile spawns. Defaults to the rocketbullet bone in the player skeleton.
@export_node_path("Node3D") var rpg_muzzle_path: NodePath = \
		^"../Body/Visual/Player/Skeleton3D/rocketbullet"

@export_group("Paths")
@export_node_path("Node") var anim_controller_path: NodePath = ^"../PlayerAnimController"
## Camera used as the hitscan origin. Ray travels along camera forward for
## crosshair-accurate aim (classic FPS pattern).
@export_node_path("Camera3D") var camera_path: NodePath = ^"../CameraPivot/SpringArm3D/CameraRig/Camera3D"
## Node3D at the visual muzzle tip of the rifle — where the flash and tracer
## visually originate. Parented to the AK47 BoneAttachment3D so it follows
## the rifle's actual pose (including the aim-look modifier's spine bend).
## Drag to fine-tune offset along the barrel in the Inspector.
@export_node_path("Node3D") var muzzle_path: NodePath = ^"../Body/Visual/Player/Skeleton3D/ak47/Muzzle"
## PhysicsBody3D to exclude from the hitscan (usually the player's own body).
@export_node_path("CollisionObject3D") var shooter_path: NodePath = ^"../Body"
## TracerPool Node3D — child of the Player root. See tracer_pool.gd for setup.
## Leave blank to fall back to the legacy per-shot allocating path (+ warning).
@export_node_path("Node3D") var tracer_pool_path: NodePath = ^"../TracerPool"
## MuzzleFlashPool — child of the muzzle node. See muzzle_flash_pool.gd for setup.
## Leave blank to fall back to the legacy per-shot allocating path (+ warning).
@export_node_path("Node3D") var flash_pool_path: NodePath = ^"../Body/Visual/Player/Skeleton3D/ak47/Muzzle/MuzzleFlashPool"

var _anim_ctrl: PlayerAnimController
var _camera: Camera3D
var _muzzle: Node3D
var _rpg_muzzle: Node3D
var _shooter: CollisionObject3D
## Cached scene root — read once in _ready() so _spawn_ar_fire_vfx never calls
## get_tree().current_scene (which is a tree walk) on the hot fire path.
var _world_root: Node = null
## Seconds since LMB was first pressed for a fire burst. -1 = no active burst.
## Keeps counting even AFTER LMB release so a single click still fires once
## when the raise delay completes (no-trigger-no-shot bug fix).
var _ar_fire_held_time: float = -1.0
## Previous-frame LMB state — used to detect rising edge (click start).
var _ar_lmb_was_pressed: bool = false
var _current_weapon: int = PlayerAnimController.Weapon.AR
var _ar_ammo: int = 30
var _rpg_ammo: int = 1
## True while a select / reload / RPG-fire sequence is locking input.
## AR fire does NOT set this (auto-fire must keep working while AR_Burst loops).
var _is_busy: bool = false
var _time_since_last_fire: float = 999.0
var _cached_visual_rocket_source: MeshInstance3D = null


func _ready() -> void:
	_anim_ctrl = get_node_or_null(anim_controller_path) as PlayerAnimController
	if _anim_ctrl == null:
		push_warning("WeaponController: PlayerAnimController not found at %s" % anim_controller_path)
		return
	_camera = get_node_or_null(camera_path) as Camera3D
	_muzzle = get_node_or_null(muzzle_path) as Node3D
	_shooter = get_node_or_null(shooter_path) as CollisionObject3D
	_rpg_muzzle = get_node_or_null(rpg_muzzle_path) as Node3D
	if _camera == null:
		push_warning("WeaponController: camera_path unset — AR tracer will not fire")
	if _muzzle == null:
		push_warning("WeaponController: muzzle_path unset — flash/tracer fall back to camera position")
	if _rpg_muzzle == null:
		push_warning("WeaponController: rpg_muzzle_path not found at '%s' — RPG will spawn at camera origin" % rpg_muzzle_path)

	# Cache scene root once — avoids a tree walk on every shot in _spawn_ar_fire_vfx.
	_world_root = get_tree().current_scene

	# Wire VFX pools. prewarm() must have run first (called from player._ready)
	# so the shared mesh/material statics are populated before setup() runs.
	var tracer_pool: TracerPool = get_node_or_null(tracer_pool_path) as TracerPool
	var flash_pool: MuzzleFlashPool = get_node_or_null(flash_pool_path) as MuzzleFlashPool
	if tracer_pool == null:
		var pool_parent: Node = get_parent()
		if pool_parent != null:
			tracer_pool = TracerPool.new()
			tracer_pool.name = "TracerPool"
			pool_parent.add_child(tracer_pool)
			push_warning("WeaponController: tracer_pool_path not found at '%s' — created runtime TracerPool" % tracer_pool_path)
		else:
			push_warning("WeaponController: tracer_pool_path not found at '%s' — tracer pool disabled, using legacy allocation" % tracer_pool_path)
	if flash_pool == null and _muzzle != null:
		flash_pool = MuzzleFlashPool.new()
		flash_pool.name = "MuzzleFlashPool"
		_muzzle.add_child(flash_pool)
		push_warning("WeaponController: flash_pool_path not found at '%s' — created runtime MuzzleFlashPool" % flash_pool_path)
	elif flash_pool == null:
		push_warning("WeaponController: flash_pool_path not found at '%s' — flash pool disabled, using legacy allocation" % flash_pool_path)
	PlayerFireVFX.set_pools(tracer_pool, flash_pool)

	_ar_ammo = ar_mag_size
	_rpg_ammo = rpg_mag_size
	_anim_ctrl.set_weapon(_current_weapon)
	_anim_ctrl.action_finished.connect(_on_action_finished)
	# Broadcast initial state so HUD can paint first frame without guessing.
	weapon_switched.emit(_current_weapon)
	_emit_current_ammo()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func get_current_weapon() -> int:
	return _current_weapon

func get_current_ammo() -> int:
	return _ar_ammo if _current_weapon == PlayerAnimController.Weapon.AR else _rpg_ammo

func get_current_mag_size() -> int:
	return ar_mag_size if _current_weapon == PlayerAnimController.Weapon.AR else rpg_mag_size

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	_time_since_last_fire += delta
	if not _accept_mouse_fire_input():
		_ar_fire_held_time = -1.0
		_ar_lmb_was_pressed = false
		return
	# AR fire: rising-edge starts the raise timer, which keeps ticking until
	# the shot fires (even if LMB was released in the meantime — single-click
	# still fires once the raise animation completes).
	var lmb_now: bool = _current_weapon == PlayerAnimController.Weapon.AR \
			and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var rising_edge: bool = lmb_now and not _ar_lmb_was_pressed
	if rising_edge:
		# Only START the raise timer if it isn't already running. Resetting it
		# on every click broke rapid single-clicks: clicking faster than
		# ar_raise_delay_sec (0.3 s) kept re-zeroing the timer, so no shot
		# ever fired. With this guard, consecutive clicks respect the first
		# click's raise animation and the first shot fires cleanly; subsequent
		# shots gate on _time_since_last_fire (ar_fire_interval_sec) as usual.
		if _ar_fire_held_time < 0.0:
			_ar_fire_held_time = 0.0
			if not _is_busy and _ar_ammo > 0 and _anim_ctrl != null:
				_anim_ctrl.play_fire()
	# Tick the timer if a burst is in progress (started by rising edge),
	# regardless of whether LMB is still held.
	if _ar_fire_held_time >= 0.0:
		_ar_fire_held_time += delta
		_try_fire()
		# Burst ends when raise-delay has elapsed AND LMB is no longer held.
		# (If LMB is still held, we stay in auto-fire mode.)
		if _ar_fire_held_time >= ar_raise_delay_sec and not lmb_now:
			_ar_fire_held_time = -1.0
	_ar_lmb_was_pressed = lmb_now


func _unhandled_input(event: InputEvent) -> void:
	if not _accept_mouse_fire_input():
		return
	if event is InputEventKey:
		var key_ev := event as InputEventKey
		if key_ev.pressed and not key_ev.echo:
			match key_ev.keycode:
				KEY_1: _switch_weapon(PlayerAnimController.Weapon.AR)
				KEY_2: _switch_weapon(PlayerAnimController.Weapon.RPG)
				KEY_R: _try_reload()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		# RPG fires on the press edge only (no auto). AR handled in _process.
		if mb.pressed \
				and mb.button_index == MOUSE_BUTTON_LEFT \
				and _current_weapon == PlayerAnimController.Weapon.RPG:
			_try_fire()

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

func _switch_weapon(w: int) -> void:
	if _is_busy:
		return
	if _current_weapon == w:
		return
	_current_weapon = w
	# Reset fire cooldown so the first shot after switching respects the new
	# weapon's fire interval (prevents instant fire if select anim is short).
	_time_since_last_fire = 0.0
	_is_busy = true
	_anim_ctrl.play_select(w)
	weapon_switched.emit(w)
	_emit_current_ammo()


func _try_fire() -> void:
	if _is_busy:
		return
	if _time_since_last_fire < ar_fire_interval_sec:
		return
	if _current_weapon == PlayerAnimController.Weapon.AR:
		if _ar_ammo <= 0:
			return  # Empty mag — dry-fire SFX hook would go here.
		# Wait for the weapon-raise animation to finish before the first
		# bullet of a burst. Subsequent shots auto-fire because
		# _ar_fire_held_time keeps growing while LMB stays held.
		if _ar_fire_held_time < ar_raise_delay_sec:
			return
		_ar_ammo -= 1
		_time_since_last_fire = 0.0
		_anim_ctrl.play_fire()
		_spawn_ar_fire_vfx()
		fired.emit(_current_weapon)
		_emit_current_ammo()
	else:
		if _rpg_ammo <= 0:
			return
		_rpg_ammo -= 1
		_time_since_last_fire = 0.0
		# RPG locks input until the auto-reload chain finishes in
		# _on_action_finished. AR does not lock — auto-fire must keep flowing.
		_is_busy = true
		_anim_ctrl.play_fire()
		_spawn_rpg_projectile()
		fired.emit(_current_weapon)
		_emit_current_ammo()


func _try_reload() -> void:
	if _is_busy:
		return
	# Only AR reloads via R — RPG reloads automatically after firing.
	if _current_weapon != PlayerAnimController.Weapon.AR:
		return
	if _ar_ammo >= ar_mag_size:
		return
	_is_busy = true
	_anim_ctrl.play_reload()


func _on_action_finished(action: int) -> void:
	match action:
		PlayerAnimController.Action.SELECT:
			_is_busy = false
		PlayerAnimController.Action.RELOAD:
			if _current_weapon == PlayerAnimController.Weapon.AR:
				_ar_ammo = ar_mag_size
			else:
				_rpg_ammo = rpg_mag_size
			_is_busy = false
			_emit_current_ammo()
		PlayerAnimController.Action.FIRE:
			# RPG: after each shot the mag is empty → chain into reload. Keep
			# _is_busy true across the chain so input stays locked.
			if _current_weapon == PlayerAnimController.Weapon.RPG and _rpg_ammo <= 0:
				_anim_ctrl.play_reload()
			else:
				_is_busy = false


func _emit_current_ammo() -> void:
	ammo_changed.emit(_current_weapon, get_current_ammo(), get_current_mag_size())


func _spawn_rpg_projectile() -> void:
	if rpg_scene == null:
		push_warning("WeaponController: rpg_scene is not set — no rocket will spawn")
		return
	if _camera == null:
		push_warning("WeaponController: camera not resolved — cannot aim RPG projectile")
		return

	var hub: CombatPoolHub = CombatPoolHub.find_for(self)
	var rocket: Node3D = null
	if hub == null:
		rocket = rpg_scene.instantiate() as Node3D
	if hub == null and rocket == null:
		push_error("WeaponController: rpg_scene root is not a TankShell — check rpg_rocket.tscn")
		return

	# Configure damage source and self-hit exclusion before adding to tree.
	if rocket != null:
		if rocket.has_method("setup"):
			rocket.call("setup", DamageTypes.Source.PLAYER_RPG, rpg_damage, _shooter)
	# Server is authoritative for damage when networked — local impact sends
	# a hit-claim, no local HP mutation. In solo mode the shell falls back to
	# its own apply_local_damage path (default true).
		if rocket.has_method("setup_network"):
			rocket.call("setup_network", "player_rpg", false)

	# Cap lifetime so the rocket auto-expires at max range without a hit.
	if rocket != null:
		var rocket_speed: float = float(rocket.get("speed")) if "speed" in rocket else 55.0
		rocket.set("lifetime", rpg_max_range / maxf(rocket_speed, 0.001))

	# Spawn at the physical muzzle when available, fall back to camera origin.
	# Using plain if/else rather than a ternary — Godot 4.3's type analyzer
	# emits a spurious "values not mutually compatible" warning on ternaries
	# whose branches access properties through a nullable receiver, even when
	# both sides clearly yield Vector3.
	var spawn_origin: Vector3
	if _rpg_muzzle != null:
		spawn_origin = _rpg_muzzle.global_position
	else:
		spawn_origin = _camera.global_position

	# Aim FROM the RPG muzzle TO the camera ray target. Plain camera-forward
	# makes an over-shoulder projectile fly parallel to the crosshair from the
	# side of the player, which reads like the rocket launching sideways.
	var aim_dir: Vector3 = _resolve_rpg_aim_dir(spawn_origin)

	if hub != null:
		rocket = hub.spawn_projectile(
			&"rpg",
			spawn_origin,
			aim_dir,
			DamageTypes.Source.PLAYER_RPG,
			rpg_damage,
			_shooter,
			"player_rpg",
			false
		)
		if rocket != null:
			var pooled_speed: float = float(rocket.get("speed")) if "speed" in rocket else 55.0
			if rocket.has_method("set_lifetime_remaining"):
				rocket.call("set_lifetime_remaining", rpg_max_range / maxf(pooled_speed, 0.001))
			else:
				rocket.set("lifetime", rpg_max_range / maxf(pooled_speed, 0.001))
		else:
			rocket = rpg_scene.instantiate() as Node3D
			if rocket != null:
				if rocket.has_method("setup"):
					rocket.call("setup", DamageTypes.Source.PLAYER_RPG, rpg_damage, _shooter)
				if rocket.has_method("setup_network"):
					rocket.call("setup_network", "player_rpg", false)
				var fallback_speed: float = float(rocket.get("speed")) if "speed" in rocket else 55.0
				rocket.set("lifetime", rpg_max_range / maxf(fallback_speed, 0.001))
				hub = null
	if rocket == null:
		return

	# Replace the placeholder grey CapsuleMesh with the actual rocketbullet
	# mesh from the launcher — the user mounts a visible rocket on the RPG
	# model and expects THAT mesh to fly out, not a generic capsule. Falls
	# back silently to the default capsule if the bone/mesh lookup fails so
	# we never spawn an invisible rocket.
	_apply_visual_rocket_mesh(rocket, aim_dir)

	if hub == null:
		_world_root.add_child(rocket)
		rocket.global_position = spawn_origin
		var up_ref: Vector3 = Vector3.UP
		if absf(aim_dir.dot(Vector3.UP)) > 0.95:
			up_ref = Vector3.FORWARD
		rocket.look_at(spawn_origin + aim_dir, up_ref)


func _resolve_rpg_aim_dir(spawn_origin: Vector3) -> Vector3:
	var cam_forward: Vector3 = -_camera.global_transform.basis.z
	var cam_pos: Vector3 = _camera.global_position
	var target_point: Vector3 = cam_pos + cam_forward * rpg_max_range
	var space: PhysicsDirectSpaceState3D = _camera.get_world_3d().direct_space_state
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(cam_pos, target_point)
	if _shooter != null and is_instance_valid(_shooter):
		query.exclude = [_shooter.get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	if not hit.is_empty():
		target_point = hit.get("position", target_point)
	var dir: Vector3 = target_point - spawn_origin
	if dir.length_squared() < 0.0001:
		return cam_forward
	return dir.normalized()


## Copy mesh + material + scale from the rocket the player saw mounted on
## the launcher onto the projectile's CoreMesh. The base RPG state shows
## [code]rocketbullet_low[/code] (low-poly, the always-visible variant in
## [weapon_anim_visibility._set_rpg_base]); [code]rocketbullet[/code] is the
## high-poly variant only on screen during the 17–61 frame window of the
## reload animation. Prefer the low-poly one, fall back to high-poly, fall
## back further to a sibling MeshInstance3D under whatever
## [member rpg_muzzle_path] resolves to. Any failure leaves the placeholder
## CapsuleMesh in place so we never spawn an invisible rocket.
func _apply_visual_rocket_mesh(rocket: Node, aim_dir: Vector3) -> void:
	if _rpg_muzzle == null:
		return
	var src_mi: MeshInstance3D = _resolve_visual_rocket_source()
	if src_mi == null or src_mi.mesh == null:
		return
	var core_mesh: MeshInstance3D = rocket.get_node_or_null("CoreMesh") as MeshInstance3D
	if core_mesh == null:
		return
	# Share the Mesh resource by reference — Godot's renderer is happy with
	# multiple MeshInstance3Ds pointing at one Mesh; the surface materials
	# embedded in the GLB carry over automatically.
	core_mesh.mesh = src_mi.mesh
	var mesh_forward_local: Vector3 = _signed_visual_rocket_forward_axis(src_mi, aim_dir)
	core_mesh.transform = Transform3D(
		Basis(Quaternion(mesh_forward_local, Vector3.FORWARD)),
		Vector3.ZERO
	)
	# material_override beats per-surface materials when present; copy it too
	# so any per-instance recolor on the launcher stays on the projectile.
	if src_mi.material_override != null:
		core_mesh.material_override = src_mi.material_override
	# Match the source rocket's effective world-space scale. The bone hierarchy
	# above it can apply non-trivial scale (skeleton bind-pose, model_node
	# scale, etc.), and an unscaled CoreMesh would render the rocket many
	# times larger or smaller than what the player saw on the launcher.
	var scale_v: Vector3 = src_mi.global_transform.basis.get_scale()
	scale_v = Vector3(absf(scale_v.x), absf(scale_v.y), absf(scale_v.z))
	if scale_v.x > 0.0 and scale_v.y > 0.0 and scale_v.z > 0.0:
		core_mesh.scale = scale_v


func _signed_visual_rocket_forward_axis(src_mi: MeshInstance3D, aim_dir: Vector3) -> Vector3:
	var axis: Vector3 = _dominant_mesh_axis(src_mi.mesh)
	var world_axis: Vector3 = src_mi.global_transform.basis * axis
	if world_axis.length_squared() > 0.0001 and world_axis.normalized().dot(aim_dir) < 0.0:
		axis = -axis
	return axis


func _dominant_mesh_axis(mesh: Mesh) -> Vector3:
	var size: Vector3 = mesh.get_aabb().size
	var sx: float = absf(size.x)
	var sy: float = absf(size.y)
	var sz: float = absf(size.z)
	if sx >= sy and sx >= sz:
		return Vector3.RIGHT
	if sy >= sx and sy >= sz:
		return Vector3.UP
	return Vector3.BACK


## Resolve which MeshInstance3D under the player skeleton represents the
## rocket the user currently sees mounted. The skeleton has two variants:
##
##   rocketbullet_low — visible in base RPG idle (default state)
##   rocketbullet     — visible only during reload frames 17–61
##
## The first to resolve to a MeshInstance3D wins. Both bones live as
## siblings under the skeleton, derivable from [member rpg_muzzle_path]'s
## parent — that lookup means the resolution still works if the user
## customises the muzzle path in the Inspector.
func _resolve_visual_rocket_source() -> MeshInstance3D:
	if _cached_visual_rocket_source != null and is_instance_valid(_cached_visual_rocket_source):
		return _cached_visual_rocket_source
	if _rpg_muzzle == null:
		return null
	var parent_skel: Node = _rpg_muzzle.get_parent()
	if parent_skel != null:
		var low: Node = parent_skel.get_node_or_null(^"rocketbullet_low")
		if low != null:
			var low_mi: MeshInstance3D = _resolve_first_mesh_instance(low)
			if low_mi != null and low_mi.mesh != null:
				_cached_visual_rocket_source = low_mi
				return low_mi
	# Fall back to the muzzle node itself (rocketbullet by default).
	_cached_visual_rocket_source = _resolve_first_mesh_instance(_rpg_muzzle)
	return _cached_visual_rocket_source


## Walk [param root] depth-first for the first MeshInstance3D descendant.
## Used by [_apply_visual_rocket_mesh] because the GLB import sometimes
## wraps the rocketbullet mesh inside a Node3D rather than exposing it as
## the bone-attached node directly.
func _resolve_first_mesh_instance(root: Node) -> MeshInstance3D:
	if root is MeshInstance3D:
		return root as MeshInstance3D
	for child: Node in root.get_children():
		var found: MeshInstance3D = _resolve_first_mesh_instance(child)
		if found != null:
			return found
	return null


func _spawn_ar_fire_vfx() -> void:
	if _camera == null:
		return
	var aim_origin: Vector3 = _camera.global_position
	var aim_dir: Vector3 = -_camera.global_transform.basis.z
	PlayerFireVFX.spawn_ar_shot(
		_world_root,  # cached in _ready() — avoids get_tree().current_scene on hot path
		_muzzle,      # parent the flash here so it moves rigidly with the rifle
		aim_origin,
		aim_dir,
		_shooter,
		ar_damage,
		ar_max_range,
	)


func _accept_mouse_fire_input() -> bool:
	# Web builds can fail Pointer Lock depending on browser/embed state. Do not
	# let that kill shooting; the React host already requires a user click and
	# focuses the canvas before the engine starts.
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or OS.has_feature("web")
