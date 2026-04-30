class_name MatchWarmupScene
extends Node3D

## Pre-match shader/pipeline prewarm + threaded scene loader.
##
## Configured as the project's [code]run/main_scene[/code]. It boots into an
## idle black staging scene while React downloads Godot immediately on site
## entry. The actual warmup starts only after React sends [code]ui_play[/code].
## Two jobs:
##   1. Background-load Main.tscn through ResourceLoader.load_threaded_request
##      so the player's main thread isn't blocked.
##   2. Instance every shader-bearing prefab in front of [member _camera] for
##      at least one frame so the Compatibility renderer (gl_compatibility,
##      OpenGL/WebGL2) compiles its pipelines BEFORE the first AK shot or tank
##      kill in real combat.
##
## Source for the technique: Godot docs — Reducing stutter from shader
## (pipeline) compilations.
##   https://docs.godotengine.org/en/stable/tutorials/performance/pipeline_compilations.html
##
## Quote: "preloading materials, shaders, and particles by displaying them for
## at least one frame in the view frustum when the level is loading."
##
## React overlays MatchLoadingOverlay on top of the canvas — it subscribes to
## [code]match_loading_progress[/code] events emitted from [method _emit_progress]
## and shows a progress bar. The 3D scene is intentionally minimal (black bg,
## one camera, one root for warmup actors) because the user is never meant to
## see it directly — it's the loading screen's render target.

@export var main_scene_path: String = "res://Main.tscn"
## Floor for time spent on the warmup screen even if Main.tscn loads instantly
## from cache. The Compatibility renderer needs at least one full frame per
## prefab to compile pipelines, and repeated shot probes need a little extra
## time so two visible frames land before the scene swap.
@export var min_hold_seconds: float = 8.0
## Hard ceiling — if Main.tscn doesn't finish loading after this, swap anyway
## and let the gameplay scene finish loading on its own. Prevents a soft hang
## if threaded loading deadlocks.
@export var max_hold_seconds: float = 18.0

## How far ahead of the camera the warmup root sits. Far enough that the
## whole probe spread remains in-frustum even on narrow browser canvases.
const _SPAWN_DISTANCE: float = 4.0

const _STAGE_LOADING: String = "loading_assets"
const _STAGE_COMPILING: String = "compiling_shaders"
const _STAGE_READY: String = "ready"

const _BLACKOUT_CANVAS_LAYER: int = 128
const _WARMUP_PROBE_LIFETIME: float = 8.0
const _WARMUP_SHOT_REPETITIONS: int = 10
const _WARMUP_PROJECTILE_REPETITIONS: int = 4
const _WARMUP_DESTRUCTION_REPETITIONS: int = 1
const _WARMUP_VEHICLE_FIRE_REPETITIONS: int = 3
const _WARMUP_DELAYED_SHOT_BURSTS: int = 2
const _WARMUP_SHOTS_PER_DELAYED_BURST: int = 2
const _WARMUP_FRAME_GAP: int = 1
const _MAIN_TANK_SCALE: float = 2.8
const _MAIN_HELICOPTER_SCALE: float = 3.2
const _MAIN_DRONE_SCALE: float = 1.0
const _VEHICLE_PROBE_Z: float = -34.0

@onready var _camera: Camera3D = $Camera3D
@onready var _warmup_root: Node3D = $WarmupRoot

var _elapsed: float = 0.0
var _switching: bool = false
var _last_emitted_progress: float = -1.0
var _last_emitted_stage: String = ""
## Wall-clock when warmup started, for end-of-warmup summary log.
var _start_msec: int = 0
## Last asset_progress value we logged — throttle log spam to changes ≥5 %.
var _last_logged_asset: float = -1.0
var _last_log_msec: int = 0
## Per-probe timing buckets — printed in the final summary so you can spot
## which prefab is the slowest to compile.
var _probe_timings: Dictionary = {}
var _probes_spawned: int = 0
var _probe_staging_complete: bool = false
var _pending_async_probes: int = 0
var _completed_async_probes: int = 0
var _async_probes_scheduled: int = 0
var _main_scene_resource: PackedScene = null
var _main_scene_load_done: bool = false
var _main_scene_load_failed: bool = false
var _camera_motion_enabled: bool = false
var _camera_base_transform: Transform3D = Transform3D.IDENTITY
var _started: bool = false
var _play_handler: Callable = Callable()
var _play_handler_registered: bool = false


func _ready() -> void:
	print("[warmup] _ready - waiting for ui_play (Godot %s)" % Engine.get_version_info()["string"])
	_install_blackout_cover()
	# Cursor visible while loading — pointer lock is captured by the player
	# controller after Main.tscn spawns.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_register_play_handler()
	if not _play_handler_registered:
		# Editor/native fallback: without the web bridge there is no React PLAY
		# button, so start automatically to keep local smoke tests usable.
		call_deferred("_start_warmup")


func _register_play_handler() -> void:
	var bridge: Node = get_node_or_null(^"/root/WebBridge")
	if bridge == null or not bridge.has_method("register_handler"):
		return
	if bridge.has_method("is_available") and not bool(bridge.call("is_available")):
		return
	_play_handler = Callable(self, "_on_ui_play")
	bridge.call("register_handler", "ui_play", _play_handler)
	_play_handler_registered = true
	if bridge.has_method("send_event"):
		bridge.call("send_event", "warmup_ready_for_play", {})


func _exit_tree() -> void:
	if not _play_handler_registered:
		return
	var bridge: Node = get_node_or_null(^"/root/WebBridge")
	if bridge != null and bridge.has_method("unregister_handler"):
		bridge.call("unregister_handler", "ui_play", _play_handler)
	_play_handler_registered = false


func _on_ui_play(_payload: Dictionary = {}) -> void:
	_start_warmup()


func _start_warmup() -> void:
	if _started:
		return
	_started = true
	_elapsed = 0.0
	_switching = false
	_last_emitted_progress = -1.0
	_last_emitted_stage = ""
	_last_logged_asset = -1.0
	_last_log_msec = 0
	_probe_timings.clear()
	_probes_spawned = 0
	_probe_staging_complete = false
	_pending_async_probes = 0
	_completed_async_probes = 0
	_async_probes_scheduled = 0
	_main_scene_resource = null
	_main_scene_load_done = false
	_main_scene_load_failed = false
	_start_msec = Time.get_ticks_msec()
	print("[warmup] ui_play - gl_compatibility prewarm start")
	_emit_progress(0.02, _STAGE_LOADING)
	# Kick off the websocket handshake in parallel with asset loading. The
	# warmup scene is the user's first concrete contact with the engine (no
	# more in-engine menu) so it must self-start networking. has_method guards
	# protect editor smoke tests where the autoload isn't present.
	_start_network_connection()
	print("[warmup] Main.tscn will be loaded synchronously inside warmup overlay")
	# Spawn next frame so the camera transform is already current.
	call_deferred("_spawn_warmup_actors")


func _install_blackout_cover() -> void:
	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = "WarmupBlackoutLayer"
	layer.layer = _BLACKOUT_CANVAS_LAYER
	add_child(layer)

	var cover: ColorRect = ColorRect.new()
	cover.name = "WarmupBlackout"
	cover.color = Color.BLACK
	cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cover.anchor_right = 1.0
	cover.anchor_bottom = 1.0
	cover.offset_left = 0.0
	cover.offset_top = 0.0
	cover.offset_right = 0.0
	cover.offset_bottom = 0.0
	layer.add_child(cover)


func _start_network_connection() -> void:
	var nm: Node = get_node_or_null(^"/root/NetworkManager")
	if nm == null:
		push_warning("[warmup] NetworkManager autoload missing — match cannot connect")
		return
	if not nm.has_method("connect_to_server"):
		push_warning("[warmup] NetworkManager exists but lacks connect_to_server() — abort")
		return
	print("[warmup] kicking off NetworkManager.connect_to_server()")
	nm.call("connect_to_server")


func _process(_delta: float) -> void:
	if not _started:
		return
	_elapsed = float(Time.get_ticks_msec() - _start_msec) / 1000.0
	_update_camera_motion_probe()
	if _switching:
		return
	var status: int = _main_load_status()
	var asset_progress: float = 1.0 if _main_scene_load_done else 0.0
	if not _main_scene_load_done and not _main_scene_load_failed:
		asset_progress = clampf(_elapsed / maxf(min_hold_seconds, 0.001), 0.0, 0.5)
	# Two-band progress mapping so the bar always feels alive:
	#   0 → 70 %: tracks asset_progress while Main.tscn is being parsed.
	#             Single-threaded web export means this often jumps from 0 to
	#             ~70 % in one frame after the load_threaded_request unblocks.
	#   70 → 95 %: time-based crawl over min_hold_seconds — gives the user a
	#             visible animation instead of "0 then 95 % stuck" while the
	#             warmup probes finish their final-frame compiles.
	#   100 %: emitted by _switch_to_main right before scene swap.
	var time_floor: float = clampf(_elapsed / min_hold_seconds, 0.0, 1.0)
	var blended: float
	if asset_progress < 0.999:
		# Web ResourceLoader progress is often silent until the scene is almost
		# ready. Keep the UI moving with a capped time floor while still honoring
		# real asset progress when the browser gives it to us.
		var asset_band: float = clampf(asset_progress * 0.7, 0.0, 0.7)
		var loading_crawl: float = clampf(0.02 + (time_floor * 0.58), 0.02, 0.60)
		blended = clampf(maxf(asset_band, loading_crawl), 0.02, 0.65)
	else:
		var probes_ready_for_swap: bool = _probe_staging_complete and _pending_async_probes <= 0
		var compile_cap: float = 0.95 if probes_ready_for_swap else 0.90
		blended = clampf(0.7 + (time_floor * (compile_cap - 0.7)), 0.7, compile_cap)
	var stage: String = _STAGE_COMPILING if asset_progress >= 0.999 else _STAGE_LOADING
	_emit_progress(blended, stage)
	_log_tick_throttled(status, asset_progress, blended, stage)

	var assets_ready: bool = (status == ResourceLoader.THREAD_LOAD_LOADED)
	var probes_ready: bool = _probe_staging_complete and _pending_async_probes <= 0
	var hold_satisfied: bool = _elapsed >= min_hold_seconds and probes_ready
	var force_switch: bool = _elapsed >= max_hold_seconds
	if ((assets_ready or _main_scene_load_failed) and hold_satisfied) or force_switch:
		if force_switch and not assets_ready and not _main_scene_load_failed:
			push_warning("[warmup] FORCED SWITCH after %.2fs — Main.tscn still %s (asset_progress=%.2f). Game may hitch on first frame." % [_elapsed, _status_label(status), asset_progress])
		elif force_switch and not probes_ready:
			push_warning("[warmup] FORCED SWITCH after %.2fs - warmup probes still pending=%d staged=%s. Game may hitch on first combat VFX." % [_elapsed, _pending_async_probes, str(_probe_staging_complete)])
		else:
			print("[warmup] ready to switch: elapsed=%.2fs asset=100%% status=LOADED" % _elapsed)
		_switch_to_main()


## Print a tick line whenever asset progress jumps ≥5 % or every 500 ms,
## whichever comes first. Keeps the console useful without flooding it.
func _log_tick_throttled(status: int, asset_progress: float, blended: float, stage: String) -> void:
	var now: int = Time.get_ticks_msec()
	var asset_jumped: bool = absf(asset_progress - _last_logged_asset) >= 0.05
	var time_elapsed: bool = (now - _last_log_msec) >= 500
	if not asset_jumped and not time_elapsed:
		return
	_last_logged_asset = asset_progress
	_last_log_msec = now
	print("[warmup] tick t=%.2fs asset=%3d%% blended=%3d%% stage=%s status=%s probes=%d async=%d/%d pending=%d staged=%s" % [
		_elapsed,
		int(asset_progress * 100.0),
		int(blended * 100.0),
		stage,
		_status_label(status),
		_probes_spawned,
		_completed_async_probes,
		_async_probes_scheduled,
		_pending_async_probes,
		str(_probe_staging_complete),
	])


func _status_label(status: int) -> String:
	match status:
		ResourceLoader.THREAD_LOAD_INVALID_RESOURCE: return "INVALID"
		ResourceLoader.THREAD_LOAD_IN_PROGRESS: return "IN_PROGRESS"
		ResourceLoader.THREAD_LOAD_FAILED: return "FAILED"
		ResourceLoader.THREAD_LOAD_LOADED: return "LOADED"
		_: return "?"


func _main_load_status() -> int:
	if _main_scene_load_done:
		return ResourceLoader.THREAD_LOAD_LOADED
	if _main_scene_load_failed:
		return ResourceLoader.THREAD_LOAD_FAILED
	return ResourceLoader.THREAD_LOAD_IN_PROGRESS


func _spawn_warmup_actors() -> void:
	if not is_instance_valid(_camera) or not is_instance_valid(_warmup_root):
		push_warning("[warmup] camera or warmup root missing — skipping prewarm")
		return
	var cam_xform: Transform3D = _camera.global_transform
	var origin: Vector3 = cam_xform.origin + (-cam_xform.basis.z) * _SPAWN_DISTANCE
	_warmup_root.global_transform = Transform3D(Basis.IDENTITY, origin)
	_camera_base_transform = _camera.transform
	_camera_motion_enabled = true
	print("[warmup] spawn_warmup_actors — camera=%v root=%v" % [cam_xform.origin, origin])

	# Round 1 — VFX statics. PlayerFireVFX.prewarm internally loads textures,
	# builds the tracer mesh + materials, and creates a short visible draw.
	var t: int = Time.get_ticks_msec()
	PlayerFireVFX.prewarm(_warmup_root)
	_record_probe_time("PlayerFireVFX.prewarm", Time.get_ticks_msec() - t)
	await _yield_warmup_frames()
	_spawn_canvas_shader_probe()
	await _yield_warmup_frames()
	_spawn_camera_motion_probe()
	await _yield_warmup_frames()

	# Round 2 — actual frame draws of every per-shot pipeline. Each helper
	# spawns the same primitive that runtime gameplay would, so the
	# Compatibility renderer compiles the matching pipeline here instead of
	# during a live firefight.
	_spawn_player_shot_probe()
	await _yield_warmup_frames()
	await _wait_for_main_load_before_scene_probes()
	await _yield_warmup_frames()
	await _spawn_vehicle_fire_probes()
	await _yield_warmup_frames()
	_spawn_charred_probe()
	await _yield_warmup_frames()
	_spawn_smoke_fire_probe()
	await _yield_warmup_frames()
	_spawn_explosion_probe()
	await _yield_warmup_frames()
	_spawn_static_debris_probe()
	await _yield_warmup_frames()
	await _spawn_projectile_scene_probes()
	await _yield_warmup_frames()
	await _wait_for_async_probes("projectile/fire delayed probes", 3.0)
	_probe_staging_complete = true
	print("[warmup] all %d probes staged in %d ms (async scheduled=%d pending=%d)" % [_probes_spawned, Time.get_ticks_msec() - _start_msec, _async_probes_scheduled, _pending_async_probes])


func _yield_warmup_frames(frames: int = _WARMUP_FRAME_GAP) -> void:
	for _i: int in range(maxi(frames, 1)):
		await get_tree().process_frame


func _wait_for_main_load_before_scene_probes(_max_wait_seconds: float = 6.0) -> void:
	if _main_scene_load_done or _main_scene_load_failed:
		return
	await _yield_warmup_frames()
	var t: int = Time.get_ticks_msec()
	print("[warmup] loading %s synchronously before scene probes" % main_scene_path)
	var resource: Resource = ResourceLoader.load(main_scene_path)
	if resource is PackedScene:
		_main_scene_resource = resource as PackedScene
		_main_scene_load_done = true
		print("[warmup] synchronous Main load done in %d ms" % (Time.get_ticks_msec() - t))
	else:
		_main_scene_load_failed = true
		push_warning("[warmup] synchronous Main load failed in %d ms; will fall back to change_scene_to_file" % (Time.get_ticks_msec() - t))


## Compile each vehicle type's STATIC materials by briefly instantiating its
## scene. We deliberately do NOT trigger the controller's `_on_destroyed`
## handler — calling it during warmup turned out to leak destruction state
## into the live Main.tscn vehicles (cook-off cooled the wrong tank's turret
## pose, charred overlays bled across instances, etc.). Material compilation
## happens just from _ready running through `_setup_tread_materials` and
## populating MeshInstance3D nodes inside the camera frustum.
##
## The skeleton-aware spawn_turret_debris pipeline is prewarmed separately
## via [_spawn_turret_debris_synthetic_probe] using a dummy skeleton, so the
## first real tank cook-off doesn't compile that path inline.
func _spawn_vehicle_destruction_probes() -> void:
	_spawn_turret_debris_synthetic_probe()
	await _yield_warmup_frames()
	_spawn_real_tank_debris_probe()


func _spawn_actual_vehicle_destruction_probes() -> void:
	var t: int = Time.get_ticks_msec()
	var cases: Array[Dictionary] = [
		{
			"label": "tank actual destruction",
			"path": "res://scenes/tank/tank.tscn",
			"pos": Vector3(8.0, -2.2, _VEHICLE_PROBE_Z - 8.0),
			"scale": _MAIN_TANK_SCALE,
			"props": {
				"turret_path": NodePath("Model/Armature/Skeleton3D/TankBody_001"),
				"barrel_path": NodePath("Model/Armature/Skeleton3D/TankBody_002"),
			},
		},
		{
			"label": "helicopter actual destruction",
			"path": "res://scenes/helicopter/helicopter.tscn",
			"pos": Vector3(-8.0, -2.0, _VEHICLE_PROBE_Z - 8.0),
			"scale": _MAIN_HELICOPTER_SCALE,
			"props": {},
		},
		{
			"label": "drone actual destruction",
			"path": "res://scenes/drone/drone.tscn",
			"pos": Vector3(0.0, -1.2, _VEHICLE_PROBE_Z - 4.0),
			"scale": _MAIN_DRONE_SCALE,
			"props": {},
		},
	]
	for repeat_index: int in range(_WARMUP_DESTRUCTION_REPETITIONS):
		for data: Dictionary in cases:
			var scene_path: String = String(data["path"])
			if not ResourceLoader.exists(scene_path):
				push_warning("[warmup] actual destruction scene missing: %s" % scene_path)
				continue
			var packed: PackedScene = load(scene_path) as PackedScene
			if packed == null:
				push_warning("[warmup] failed to load actual destruction scene: %s" % scene_path)
				continue
			var inst: Node = packed.instantiate()
			var props: Dictionary = data["props"]
			for key: Variant in props.keys():
				inst.set(String(key), props[key])
			_warmup_root.add_child(inst)
			if inst is Node3D:
				var n: Node3D = inst as Node3D
				var repeat_offset: Vector3 = Vector3(
					0.22 * float(repeat_index),
					0.04 * float(repeat_index % 2),
					-0.18 * float(repeat_index)
				)
				var base_pos: Vector3 = data["pos"]
				n.position = base_pos + repeat_offset
				var s: float = float(data["scale"])
				n.scale = Vector3(s, s, s)
			var label: String = "%s #%d" % [String(data["label"]), repeat_index + 1]
			_schedule_async_probe(
				0.20 + 0.12 * float(repeat_index),
				Callable(self, "_run_actual_vehicle_destruction_probe").bind(inst, label),
				label
			)
			_schedule_free(inst, _WARMUP_PROBE_LIFETIME * 2.0)
			await _yield_warmup_frames()
	_record_probe_time("actual vehicle destruction flows x%d" % _WARMUP_DESTRUCTION_REPETITIONS, Time.get_ticks_msec() - t)


func _run_actual_vehicle_destruction_probe(inst: Node, label: String) -> void:
	if inst == null or not is_instance_valid(inst):
		return
	if inst.has_method("apply_network_destroyed"):
		inst.call("apply_network_destroyed")
	elif inst.has_method("_on_destroyed"):
		inst.call("_on_destroyed", DamageTypes.Source.TANK_SHELL)
	elif inst is Node3D:
		var n: Node3D = inst as Node3D
		DestructionVFX.spawn_explosion(get_tree().current_scene, n.global_position + Vector3(0.0, 0.4, 0.0))
		DestructionVFX.apply_charred(n)
		DestructionVFX.spawn_smoke_fire(n, 0.5, true, _WARMUP_PROBE_LIFETIME)
	_hide_null_mesh_instances(inst)
	print("[warmup]   actual destruction probe ran: %s" % label)


func _record_probe_time(name: String, msec: int) -> void:
	_probe_timings[name] = msec
	_probes_spawned += 1
	print("[warmup]   probe '%s' staged in %d ms" % [name, msec])


func _schedule_async_probe(delay_seconds: float, callback: Callable, label: String) -> void:
	_pending_async_probes += 1
	_async_probes_scheduled += 1
	var timer: SceneTreeTimer = get_tree().create_timer(delay_seconds)
	timer.timeout.connect(_run_async_probe.bind(callback, label))


func _run_async_probe(callback: Callable, label: String) -> void:
	if callback.is_valid():
		callback.call()
	_completed_async_probes += 1
	_pending_async_probes = maxi(_pending_async_probes - 1, 0)
	print("[warmup]   async probe '%s' complete (%d/%d, pending=%d)" % [
		label,
		_completed_async_probes,
		_async_probes_scheduled,
		_pending_async_probes,
	])


func _wait_for_async_probes(label: String, max_wait_seconds: float) -> void:
	var start_msec: int = Time.get_ticks_msec()
	while _pending_async_probes > 0 and not _switching:
		var waited: float = float(Time.get_ticks_msec() - start_msec) / 1000.0
		if waited >= max_wait_seconds:
			push_warning("[warmup] async barrier '%s' timed out with pending=%d" % [label, _pending_async_probes])
			return
		await get_tree().process_frame
	print("[warmup] async barrier '%s' clear" % label)


func _update_camera_motion_probe() -> void:
	if not _camera_motion_enabled or not is_instance_valid(_camera):
		return
	var yaw: float = sin(_elapsed * 2.1) * 0.12
	var pitch: float = sin(_elapsed * 1.55) * 0.055
	var offset: Vector3 = Vector3(
		sin(_elapsed * 1.35) * 0.18,
		sin(_elapsed * 1.10) * 0.055,
		cos(_elapsed * 1.20) * 0.14
	)
	var basis: Basis = _camera_base_transform.basis * Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	_camera.transform = Transform3D(basis, _camera_base_transform.origin + offset)


func _spawn_camera_motion_probe() -> void:
	var t: int = Time.get_ticks_msec()
	var root: Node3D = Node3D.new()
	root.name = "CameraMotionProbe"
	_warmup_root.add_child(root)
	for i: int in range(14):
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.name = "CameraProbeMesh%02d" % i
		var box: BoxMesh = BoxMesh.new()
		box.size = Vector3(
			0.18 + 0.04 * float(i % 3),
			0.12 + 0.05 * float(i % 4),
			0.18 + 0.03 * float((i + 1) % 3)
		)
		mi.mesh = box
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mat.albedo_color = Color(0.28 + 0.04 * float(i % 5), 0.31, 0.34, 1.0)
		mat.roughness = 0.82
		if i % 4 == 0:
			mat.emission_enabled = true
			mat.emission = Color(1.0, 0.45, 0.16)
			mat.emission_energy_multiplier = 1.8
		mi.material_override = mat
		root.add_child(mi)
		mi.position = Vector3(
			-1.2 + 0.4 * float(i % 7),
			-0.55 + 0.22 * float(i % 3),
			-0.8 - 0.18 * float(i / 7)
		)
		mi.rotation = Vector3(0.1 * float(i), 0.35 * float(i), 0.07 * float(i))
	_schedule_free(root, _WARMUP_PROBE_LIFETIME)
	_record_probe_time("camera motion + generic 3D render probe", Time.get_ticks_msec() - t)


func _spawn_player_shot_probe() -> void:
	# Exercise both local pooled shots and remote allocating shots. Runtime can
	# draw several AR rounds in the first half-second, so one probe is not
	# enough to warm the pool slots and fallback mesh path reliably.
	var t: int = Time.get_ticks_msec()
	var origin: Vector3 = _warmup_root.global_transform.origin
	var base_aim: Vector3 = -_camera.global_transform.basis.z

	var muzzle: Node3D = Node3D.new()
	muzzle.name = "WarmupMuzzle"
	_warmup_root.add_child(muzzle)
	muzzle.global_position = origin + Vector3(-0.25, 0.0, 0.0)

	var tracer_pool: TracerPool = TracerPool.new()
	tracer_pool.name = "WarmupTracerPool"
	_warmup_root.add_child(tracer_pool)
	var flash_pool: MuzzleFlashPool = MuzzleFlashPool.new()
	flash_pool.name = "WarmupMuzzleFlashPool"
	muzzle.add_child(flash_pool)
	PlayerFireVFX.set_pools(tracer_pool, flash_pool)

	for i: int in range(_WARMUP_SHOT_REPETITIONS):
		var ratio: float = float(i) / float(maxi(_WARMUP_SHOT_REPETITIONS - 1, 1))
		var side: float = lerpf(-0.36, 0.36, ratio)
		var aim: Vector3 = (base_aim + Vector3(side * 0.16, 0.04 * sin(float(i)), 0.0)).normalized()
		muzzle.global_position = origin + Vector3(-0.25 + side * 0.35, 0.05, 0.0)
		PlayerFireVFX.spawn_ar_shot(_warmup_root, muzzle, origin, aim, null, 0, 12.0)
		PlayerFireVFX.spawn_ar_visuals_from_world(
			_warmup_root,
			origin + Vector3(0.20 + side, -0.05, 0.0),
			origin,
			aim,
			12.0,
			null
		)

	for burst_index: int in range(_WARMUP_DELAYED_SHOT_BURSTS):
		_schedule_async_probe(
			0.18 + 0.12 * float(burst_index),
			Callable(self, "_run_player_shot_probe_burst").bind(muzzle, origin, base_aim, burst_index),
			"AR delayed burst #%d" % (burst_index + 1)
		)

	_schedule_free(muzzle, _WARMUP_PROBE_LIFETIME)
	_schedule_free(tracer_pool, _WARMUP_PROBE_LIFETIME)
	_record_probe_time("AR shots x%d (pooled + remote fallback)" % _WARMUP_SHOT_REPETITIONS, Time.get_ticks_msec() - t)


func _run_player_shot_probe_burst(muzzle: Node3D, origin: Vector3, base_aim: Vector3, burst_index: int) -> void:
	if muzzle == null or not is_instance_valid(muzzle) or not is_instance_valid(_warmup_root):
		return
	for shot_index: int in range(_WARMUP_SHOTS_PER_DELAYED_BURST):
		var i: int = burst_index * _WARMUP_SHOTS_PER_DELAYED_BURST + shot_index
		var phase: float = float(i) / float(maxi(_WARMUP_DELAYED_SHOT_BURSTS * _WARMUP_SHOTS_PER_DELAYED_BURST - 1, 1))
		var side: float = lerpf(-0.42, 0.42, phase)
		var aim: Vector3 = (base_aim + Vector3(side * 0.18, 0.05 * sin(float(i) * 0.73), 0.0)).normalized()
		muzzle.global_position = origin + Vector3(-0.28 + side * 0.38, 0.06, -0.02 * float(shot_index))
		PlayerFireVFX.spawn_ar_shot(_warmup_root, muzzle, origin, aim, null, 0, 12.0)
		PlayerFireVFX.spawn_ar_visuals_from_world(
			_warmup_root,
			origin + Vector3(0.24 + side, -0.04, 0.02 * float(shot_index)),
			origin,
			aim,
			12.0,
			null
		)


func _spawn_vehicle_fire_probes() -> void:
	var t: int = Time.get_ticks_msec()
	_spawn_tank_fire_probe()
	await _yield_warmup_frames()
	_spawn_helicopter_fire_probe()
	_record_probe_time(
		"tank + helicopter controller fire x%d" % _WARMUP_VEHICLE_FIRE_REPETITIONS,
		Time.get_ticks_msec() - t
	)


func _spawn_tank_fire_probe() -> void:
	var path: String = "res://scenes/tank/tank.tscn"
	if not ResourceLoader.exists(path):
		push_warning("[warmup] tank fire scene missing: %s" % path)
		return
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		push_warning("[warmup] failed to load tank fire scene: %s" % path)
		return
	var tank: Node = packed.instantiate()
	tank.set("turret_path", NodePath("Model/Armature/Skeleton3D/TankBody_001"))
	tank.set("barrel_path", NodePath("Model/Armature/Skeleton3D/TankBody_002"))
	_warmup_root.add_child(tank)
	if tank is Node3D:
		var n: Node3D = tank as Node3D
		n.position = Vector3(8.0, -2.2, _VEHICLE_PROBE_Z + 8.0)
		n.scale = Vector3(_MAIN_TANK_SCALE, _MAIN_TANK_SCALE, _MAIN_TANK_SCALE)
	if tank.has_method("set_active"):
		tank.call("set_active", false)
	for i: int in range(_WARMUP_VEHICLE_FIRE_REPETITIONS):
		_schedule_async_probe(
			0.20 + 0.16 * float(i),
			Callable(self, "_run_tank_fire_probe").bind(tank),
			"tank fire #%d" % (i + 1)
		)
	_schedule_free(tank, _WARMUP_PROBE_LIFETIME * 2.0)


func _run_tank_fire_probe(tank: Node) -> void:
	if tank == null or not is_instance_valid(tank):
		return
	tank.set("_fire_timer", 0.0)
	if tank.has_method("_try_fire"):
		tank.call("_try_fire")


func _spawn_helicopter_fire_probe() -> void:
	var path: String = "res://scenes/helicopter/helicopter.tscn"
	if not ResourceLoader.exists(path):
		push_warning("[warmup] helicopter fire scene missing: %s" % path)
		return
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		push_warning("[warmup] failed to load helicopter fire scene: %s" % path)
		return
	var heli: Node = packed.instantiate()
	_warmup_root.add_child(heli)
	if heli is Node3D:
		var n: Node3D = heli as Node3D
		n.position = Vector3(-8.0, -2.0, _VEHICLE_PROBE_Z + 8.0)
		n.scale = Vector3(_MAIN_HELICOPTER_SCALE, _MAIN_HELICOPTER_SCALE, _MAIN_HELICOPTER_SCALE)
	if heli.has_method("set_active"):
		heli.call("set_active", false)
	for i: int in range(_WARMUP_VEHICLE_FIRE_REPETITIONS):
		_schedule_async_probe(
			0.20 + 0.16 * float(i),
			Callable(self, "_run_helicopter_fire_probe").bind(heli),
			"helicopter missile fire #%d" % (i + 1)
		)
	_schedule_free(heli, _WARMUP_PROBE_LIFETIME * 2.0)


func _run_helicopter_fire_probe(heli: Node) -> void:
	if heli == null or not is_instance_valid(heli):
		return
	heli.set("_missile_fire_timer", 0.0)
	heli.set("_is_reloading", false)
	if heli.has_method("_try_fire_missile"):
		heli.call("_try_fire_missile")


func _spawn_canvas_shader_probe() -> void:
	var t: int = Time.get_ticks_msec()
	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = "CanvasShaderWarmup"
	layer.layer = 99
	add_child(layer)

	var fpv_shader: Shader = load("res://src/gameplay/camera/fpv_post_process.gdshader") as Shader
	if fpv_shader != null:
		var mat: ShaderMaterial = ShaderMaterial.new()
		mat.shader = fpv_shader
		mat.set_shader_parameter("aberration_strength", 0.004)
		mat.set_shader_parameter("vignette_strength", 0.4)
		mat.set_shader_parameter("grain_strength", 0.12)
		mat.set_shader_parameter("desaturation", 0.35)
		mat.set_shader_parameter("warmth", 0.08)
		var fpv_rect: ColorRect = ColorRect.new()
		fpv_rect.name = "FPVPostProcessProbe"
		fpv_rect.anchor_right = 1.0
		fpv_rect.anchor_bottom = 1.0
		fpv_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fpv_rect.material = mat
		layer.add_child(fpv_rect)

	var hud_panel: Panel = Panel.new()
	hud_panel.name = "HUDPanelProbe"
	hud_panel.anchor_left = 0.5
	hud_panel.anchor_top = 0.5
	hud_panel.anchor_right = 0.5
	hud_panel.anchor_bottom = 0.5
	hud_panel.offset_left = -6.0
	hud_panel.offset_top = -6.0
	hud_panel.offset_right = 6.0
	hud_panel.offset_bottom = 6.0
	hud_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dot_style: StyleBoxFlat = StyleBoxFlat.new()
	dot_style.bg_color = Color(1.0, 1.0, 1.0, 0.95)
	dot_style.border_color = Color(0.0, 0.0, 0.0, 0.85)
	dot_style.set_border_width_all(1)
	dot_style.set_corner_radius_all(6)
	hud_panel.add_theme_stylebox_override("panel", dot_style)
	layer.add_child(hud_panel)

	var label: Label = Label.new()
	label.name = "AmmoLabelProbe"
	label.text = "AR  30 / 30"
	label.anchor_left = 1.0
	label.anchor_top = 1.0
	label.anchor_right = 1.0
	label.anchor_bottom = 1.0
	label.offset_left = -220.0
	label.offset_top = -80.0
	label.offset_right = -24.0
	label.offset_bottom = -24.0
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 32)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(label)

	var bar: ProgressBar = ProgressBar.new()
	bar.name = "StaminaBarProbe"
	bar.anchor_left = 0.5
	bar.anchor_top = 1.0
	bar.anchor_right = 0.5
	bar.anchor_bottom = 1.0
	bar.offset_left = -140.0
	bar.offset_top = -48.0
	bar.offset_right = 140.0
	bar.offset_bottom = -20.0
	bar.max_value = 100.0
	bar.value = 65.0
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bar_style: StyleBoxFlat = StyleBoxFlat.new()
	bar_style.bg_color = Color(0.0, 0.0, 0.0, 0.6)
	bar_style.border_color = Color(1.0, 1.0, 1.0, 0.8)
	bar_style.set_border_width_all(2)
	bar.add_theme_stylebox_override("background", bar_style)
	layer.add_child(bar)

	_schedule_free(layer, _WARMUP_PROBE_LIFETIME)
	_record_probe_time("Canvas HUD + FPV post shader", Time.get_ticks_msec() - t)


func _spawn_charred_probe() -> void:
	var t: int = Time.get_ticks_msec()
	var mi: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(0.18, 0.18, 0.18)
	mi.mesh = box
	_warmup_root.add_child(mi)
	mi.position = Vector3(-0.4, 0.0, 0.0)
	# Apply the charred ShaderMaterial overlay — same shader path the destroyed
	# tank/heli/drone use. One frame of rendering is enough.
	DestructionVFX.apply_charred(mi)
	_schedule_free(mi, _WARMUP_PROBE_LIFETIME)
	_record_probe_time("charred overlay shader", Time.get_ticks_msec() - t)


func _spawn_smoke_fire_probe() -> void:
	var t: int = Time.get_ticks_msec()
	for i: int in range(_WARMUP_SHOT_REPETITIONS):
		var probe: Node3D = Node3D.new()
		probe.name = "SmokeProbe%02d" % i
		_warmup_root.add_child(probe)
		probe.position = Vector3(0.35 + 0.22 * float(i), 0.0, 0.0)

		var body: MeshInstance3D = MeshInstance3D.new()
		body.name = "WarmupBurnBody"
		var box: BoxMesh = BoxMesh.new()
		box.size = Vector3(0.24, 0.18, 0.32)
		body.mesh = box
		probe.add_child(body)
		# Auto-frees after the lifetime; smoke shaders compile in the meantime.
		# The body mesh also exercises the visual smoke-origin path.
		DestructionVFX.spawn_smoke_fire(probe, 0.35, true, _WARMUP_PROBE_LIFETIME)
		_schedule_free(probe, _WARMUP_PROBE_LIFETIME)
	_record_probe_time("smoke x%d" % _WARMUP_SHOT_REPETITIONS, Time.get_ticks_msec() - t)


## Vehicle-explosion probe. Compiles the spark-burst circle-mask billboard
## material + HDR-tuned _make_spark_material + the OmniLight3D Tween used by
## the explosion flash. Without this, the first RPG hit on a tank froze the
## frame for hundreds of ms while sparks compiled inline.
func _spawn_explosion_probe() -> void:
	var t: int = Time.get_ticks_msec()
	# Offset slightly so the burst doesn't blow apart the smoke probe at the
	# same world point (cosmetic only; React loading overlay covers all of it).
	for i: int in range(_WARMUP_SHOT_REPETITIONS):
		var pos: Vector3 = _warmup_root.global_transform.origin + Vector3(-0.15 + 0.3 * float(i), 0.1, 0.2)
		DestructionVFX.spawn_explosion(_warmup_root, pos)
	_record_probe_time("vehicle explosion x%d" % _WARMUP_SHOT_REPETITIONS, Time.get_ticks_msec() - t)


## Generic debris-RigidBody3D probe. Drives _build_debris_body + _launch_debris
## + _make_fresh_mesh_copy + the post-spawn collision-mask reactivation timer.
## Same pipeline used by tank turret cook-off, heli rotor, heli tail boom, and
## any future static-mesh wreck — all share the debris RigidBody3D code path.
func _spawn_static_debris_probe() -> void:
	var t: int = Time.get_ticks_msec()
	for i: int in range(_WARMUP_SHOT_REPETITIONS):
		var src: MeshInstance3D = MeshInstance3D.new()
		var box: BoxMesh = BoxMesh.new()
		box.size = Vector3(0.2, 0.2, 0.2)
		src.mesh = box
		_warmup_root.add_child(src)
		src.global_position = _warmup_root.global_transform.origin + Vector3(-0.15 + 0.3 * float(i), -0.4, -0.3)
		# Short lifetime + tiny launch velocities — the fragment falls under
		# gravity inside the warmup frustum, freed before swap.
		DestructionVFX.spawn_static_mesh_debris(
			_warmup_root,
			src,
			src.global_transform,
			Vector3(0.2, 0.2, 0.2),
			5.0,    # mass
			1.0,    # upward_vel
			0.5,    # h_drift_max
			1.0,    # tumble_max
			_WARMUP_PROBE_LIFETIME,
		)
		_schedule_free(src, _WARMUP_PROBE_LIFETIME)
	_record_probe_time("debris RigidBody3D x%d" % _WARMUP_SHOT_REPETITIONS, Time.get_ticks_msec() - t)


func _spawn_projectile_scene_probes() -> void:
	# Briefly instance every projectile prefab so its materials + GPUParticles
	# pipelines compile. Position spread keeps them from colliding with each
	# other at spawn — collisions during warmup are fine, we just don't want
	# them to overlap visually in the React loading frame.
	var paths: Array[String] = [
		"res://scenes/projectile/tank_shell.tscn",
		"res://scenes/projectile/rpg_rocket.tscn",
		"res://scenes/projectile/shell_impact.tscn",
		"res://scenes/projectile/smoke_volume.tscn",
		"res://scenes/projectile/muzzle_flash.tscn",
	]
	var x: float = -0.6
	for p: String in paths:
		var t: int = Time.get_ticks_msec()
		if not ResourceLoader.exists(p):
			push_warning("[warmup] projectile scene missing: %s" % p)
			continue
		var packed: PackedScene = load(p) as PackedScene
		if packed == null:
			push_warning("[warmup] failed to load projectile scene: %s" % p)
			continue
		for i: int in range(_WARMUP_PROJECTILE_REPETITIONS):
			_stage_projectile_probe(packed, x, i, 0.0)
		x += 0.3
		_record_probe_time("%s x%d" % [p.get_file(), _WARMUP_PROJECTILE_REPETITIONS], Time.get_ticks_msec() - t)
		await _yield_warmup_frames()


func _stage_projectile_probe(packed: PackedScene, x: float, index: int, y: float) -> void:
	if packed == null or not is_instance_valid(_warmup_root):
		return
	var inst: Node = packed.instantiate()
	_warmup_root.add_child(inst)
	if inst is Node3D:
		(inst as Node3D).position = Vector3(x + 0.12 * float(index), -0.2 + y, -0.08 * float(index))
	_schedule_free(inst, _WARMUP_PROBE_LIFETIME)


## Briefly instance a vehicle scene so its static materials (tread shader,
## body PBR, glass, decals, etc.) compile at first draw. We do NOT trigger
## destruction here — that path mutates per-instance state in ways that
## previously bled into Main.tscn (e.g. cook-off hiding meshes, charred
## overlays applied at the wrong moment). Material compilation alone is
## enough to absorb the first-spawn frame cost in real gameplay.
##
## [param prop_overrides] sets exported properties (NodePath exports that
## Main.tscn customises per-instance) BEFORE add_child so the controller's
## _ready sees real values. Without this tank_controller would push errors
## for empty turret_path / barrel_path even though we never call cook-off.
func _spawn_vehicle_material_probe(
	label: String,
	scene_path: String,
	pos: Vector3,
	prop_overrides: Dictionary,
	visual_scale: float,
) -> void:
	var t: int = Time.get_ticks_msec()
	if not ResourceLoader.exists(scene_path):
		push_warning("[warmup] %s missing — skipping vehicle material prewarm" % scene_path)
		return
	var packed: PackedScene = load(scene_path) as PackedScene
	if packed == null:
		push_warning("[warmup] %s failed to load — skipping vehicle material prewarm" % scene_path)
		return
	var inst: Node = packed.instantiate()
	for key: Variant in prop_overrides.keys():
		inst.set(String(key), prop_overrides[key])
	_warmup_root.add_child(inst)
	if inst is Node3D:
		var n: Node3D = inst as Node3D
		n.position = pos
		n.scale = Vector3(visual_scale, visual_scale, visual_scale)
	if inst.has_method("set_active"):
		inst.call("set_active", false)
	_schedule_free(inst, _WARMUP_PROBE_LIFETIME)
	_record_probe_time(label, Time.get_ticks_msec() - t)


## Synthetic prewarm of [DestructionVFX.spawn_turret_debris]. Builds a tiny
## throwaway Skeleton3D + 2 skinned MeshInstance3D children from primitives
## (no GLB asset, no shared resources, no controller side effects), then
## drives spawn_turret_debris end-to-end with that dummy.
##
## This is the ONLY path that exercises [_clone_skeleton_bones] +
## [_copy_skinned_meshes_by_name] inside DestructionVFX. Without it the first
## real tank cook-off in match would compile both pipelines inline → ~80 ms
## stall on the kill frame.
##
## Self-contained: nothing references the dummy after spawn_turret_debris
## returns, so the React loading overlay never sees the wreck and Main.tscn
## doesn't inherit any state.
func _spawn_turret_debris_synthetic_probe() -> void:
	var t: int = Time.get_ticks_msec()
	# Container — sits inside the camera frustum so the resulting debris
	# RigidBody3D renders at least one frame and triggers pipeline compile.
	var dummy_root: Node3D = Node3D.new()
	dummy_root.name = "TurretDebrisProbe"
	_warmup_root.add_child(dummy_root)
	dummy_root.position = Vector3(0.0, 0.5, -0.2)
	dummy_root.scale = Vector3(0.08, 0.08, 0.08)

	# Synthetic 2-bone skeleton: turret + barrel, parented turret→barrel.
	var skel: Skeleton3D = Skeleton3D.new()
	skel.name = "DummySkeleton"
	dummy_root.add_child(skel)
	skel.add_bone("Turret")
	skel.set_bone_rest(0, Transform3D())
	skel.set_bone_pose_rotation(0, Quaternion.IDENTITY)
	skel.add_bone("Barrel")
	skel.set_bone_parent(1, 0)
	skel.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.5, 0.0)))
	skel.set_bone_pose_rotation(1, Quaternion.IDENTITY)

	# Two BoxMeshes parented under the skeleton — spawn_turret_debris's mesh
	# copy walks descendants of model_node looking for matching names. They
	# don't need real Skin resources to drive the pipeline compile.
	var turret_mesh: MeshInstance3D = MeshInstance3D.new()
	turret_mesh.name = "TurretMesh"
	var box_a: BoxMesh = BoxMesh.new()
	box_a.size = Vector3(0.2, 0.15, 0.3)
	turret_mesh.mesh = box_a
	skel.add_child(turret_mesh)

	var barrel_mesh: MeshInstance3D = MeshInstance3D.new()
	barrel_mesh.name = "BarrelMesh"
	var box_b: BoxMesh = BoxMesh.new()
	box_b.size = Vector3(0.06, 0.06, 0.4)
	barrel_mesh.mesh = box_b
	skel.add_child(barrel_mesh)

	DestructionVFX.spawn_turret_debris(
		_warmup_root,
		dummy_root,
		0,                                # turret_bone
		1,                                # barrel_bone
		Quaternion.IDENTITY,              # turret_pose
		Quaternion.IDENTITY,              # barrel_pose
		dummy_root.global_transform,      # spawn_world
		Transform3D(),                    # turret_bone_local
		PackedStringArray(["TurretMesh", "BarrelMesh"]),
		20.0,                             # mass
		1.5,                              # upward_velocity
		0.5,                              # horizontal_drift_max
		1.0,                              # tumble_velocity_max
		_WARMUP_PROBE_LIFETIME,           # self_destruct_after
	)
	_schedule_free(dummy_root, _WARMUP_PROBE_LIFETIME)
	_record_probe_time("turret_debris pipeline (synthetic skeleton)", Time.get_ticks_msec() - t)


## Realistic-skin variant of the turret_debris probe. Instances a real
## tank.tscn briefly and feeds its actual Skeleton3D + skinned MeshInstance3Ds
## (TankBody_001 / TankBody_002 with their GLB-baked Skin resources) into
## [DestructionVFX.spawn_turret_debris]. The synthetic probe above only
## compiles the NON-skinned shader path because BoxMeshes have no Skin
## resource — gameplay turret debris uses the SKINNED variant which the
## Compatibility renderer compiles separately. Without this realistic probe
## the first tank kill in match still stalls 50–150 ms while the skinned
## debris pipeline compiles inline.
##
## Critically we do NOT call tank._on_destroyed here — that path mutates the
## live tank instance (sets _is_destroyed, hides turret meshes, applies
## charred overlay) and previously leaked into Main.tscn vehicles. Instead
## we manually pull the skeleton refs from the deferred-captured tank and
## drive spawn_turret_debris directly. The source tank stays cosmetic and
## gets queue_freed at probe lifetime end.
func _spawn_real_tank_debris_probe() -> void:
	var t: int = Time.get_ticks_msec()
	var path: String = "res://scenes/tank/tank.tscn"
	if not ResourceLoader.exists(path):
		push_warning("[warmup] %s missing — skipping real-tank debris prewarm" % path)
		return
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		return
	var tank: Node = packed.instantiate()
	# NodePath overrides — Main.tscn customises these per-instance, default in
	# tank.tscn is empty. Setting them BEFORE add_child means the controller's
	# deferred-capture chain resolves the right meshes.
	tank.set("turret_path", NodePath("Model/Armature/Skeleton3D/TankBody_001"))
	tank.set("barrel_path", NodePath("Model/Armature/Skeleton3D/TankBody_002"))
	_warmup_root.add_child(tank)
	if tank is Node3D:
		var n: Node3D = tank as Node3D
		n.position = Vector3(8.0, -2.2, _VEHICLE_PROBE_Z - 16.0)
		n.scale = Vector3(_MAIN_TANK_SCALE, _MAIN_TANK_SCALE, _MAIN_TANK_SCALE)
	# Defer one frame so tank's call_deferred("_capture_turret_and_barrel")
	# from _ready has populated _skeleton / _turret_bone / _barrel_bone.
	_schedule_async_probe(
		0.05,
		Callable(self, "_run_real_tank_debris_probe").bind(tank),
		"real tank turret debris"
	)
	# Keep tank alive long enough for deferred capture + spawn_turret_debris,
	# then free it. The debris RigidBody3D it spawns has its own lifetime
	# (passed to spawn_turret_debris) so it cleans up independently.
	_schedule_free(tank, _WARMUP_PROBE_LIFETIME * 2.0)
	_record_probe_time("real-tank turret_debris (skinned variant)", Time.get_ticks_msec() - t)


## Deferred follow-up for [_spawn_real_tank_debris_probe]. Reaches into the
## tank's controller state to extract the live skeleton + bone indices, then
## spawns a real-skinned turret debris body. Bails out silently if the tank
## was freed or its capture chain didn't populate (e.g. GLB structure changed
## and the bones can't be resolved).
func _run_real_tank_debris_probe(tank: Node) -> void:
	if tank == null or not is_instance_valid(tank):
		return
	var skel: Skeleton3D = tank.get("_skeleton") as Skeleton3D
	var turret_bone: int = int(tank.get("_turret_bone"))
	var barrel_bone: int = int(tank.get("_barrel_bone"))
	var model: Node3D = tank.get("_model") as Node3D
	if skel == null or turret_bone == -1 or barrel_bone == -1 or model == null:
		print("[warmup] real-tank debris probe: skeleton/bones unresolved — skipping (skel=%s turret=%d barrel=%d model=%s)" % [skel, turret_bone, barrel_bone, model])
		return
	var turret_pose: Quaternion = skel.get_bone_pose_rotation(turret_bone)
	var barrel_pose: Quaternion = skel.get_bone_pose_rotation(barrel_bone)
	var turret_bone_local: Transform3D = skel.get_bone_global_pose(turret_bone)
	var spawn_world: Transform3D = skel.global_transform * turret_bone_local
	var keep_names: PackedStringArray = PackedStringArray(["TankBody_001", "TankBody_002"])
	DestructionVFX.spawn_turret_debris(
		_warmup_root,
		model,
		turret_bone,
		barrel_bone,
		turret_pose,
		barrel_pose,
		spawn_world,
		turret_bone_local,
		keep_names,
		20.0,                            # mass
		1.0,                             # upward_velocity (gentle so it doesn't fly off-screen)
		0.5,                             # horizontal_drift_max
		1.0,                             # tumble_velocity_max
		_WARMUP_PROBE_LIFETIME,          # self_destruct_after
	)


func _spawn_grass_probe() -> void:
	# Grass GLB has its own custom material from gameready_grass_*.png — instance
	# once so its shader compiles before Terrain3D scatters dozens of clones.
	var t: int = Time.get_ticks_msec()
	var path: String = "res://Model/Grass/gameready_grass.glb"
	if not ResourceLoader.exists(path):
		print("[warmup] grass GLB missing at %s — skipped" % path)
		return
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		push_warning("[warmup] failed to load grass GLB at %s" % path)
		return
	var inst: Node = packed.instantiate()
	_warmup_root.add_child(inst)
	if inst is Node3D:
		var n: Node3D = inst as Node3D
		n.scale = Vector3(0.04, 0.04, 0.04)
		n.position = Vector3(0.0, -0.2, 0.0)
	_schedule_free(inst, _WARMUP_PROBE_LIFETIME)
	_record_probe_time("grass GLB", Time.get_ticks_msec() - t)


func _schedule_free(node: Node, after_seconds: float) -> void:
	# Bind by instance id instead of a node Callable. Warmup probes can be freed
	# as a subtree before their individual timers fire during scene transition.
	var t: SceneTreeTimer = get_tree().create_timer(after_seconds)
	t.timeout.connect(_queue_free_instance.bind(node.get_instance_id()))


func _queue_free_instance(instance_id: int) -> void:
	var obj: Object = instance_from_id(instance_id)
	if obj is Node:
		(obj as Node).queue_free()


func _hide_null_mesh_instances(root: Node) -> void:
	if root is MeshInstance3D:
		var mi: MeshInstance3D = root as MeshInstance3D
		if mi.mesh == null:
			mi.visible = false
	for child: Node in root.get_children():
		_hide_null_mesh_instances(child)


func _switch_to_main() -> void:
	if _switching:
		return
	_switching = true
	_emit_progress(1.0, _STAGE_READY)
	var total_msec: int = Time.get_ticks_msec() - _start_msec
	print("[warmup] ===== summary (total %.2fs, %d probes, async %d/%d) =====" % [
		total_msec / 1000.0,
		_probes_spawned,
		_completed_async_probes,
		_async_probes_scheduled,
	])
	var keys: Array = _probe_timings.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool:
		return int(_probe_timings[a]) > int(_probe_timings[b]))
	for k: Variant in keys:
		print("[warmup]   %5d ms  %s" % [int(_probe_timings[k]), k])
	print("[warmup] ============================================")
	PlayerFireVFX.set_pools(null, null)
	if _main_scene_resource is PackedScene:
		print("[warmup] swapping to %s (PackedScene)" % main_scene_path)
		# Defer one frame so the final progress event reaches React before the
		# scene swap clears the WebBridge handler list.
		call_deferred("_change_to_packed", _main_scene_resource)
	else:
		push_warning("[warmup] threaded load did not yield PackedScene — falling back to change_scene_to_file")
		call_deferred("_change_to_file_fallback")


func _change_to_packed(packed: PackedScene) -> void:
	get_tree().change_scene_to_packed(packed)


func _change_to_file_fallback() -> void:
	get_tree().change_scene_to_file(main_scene_path)


func _emit_progress(progress: float, stage: String) -> void:
	var clamped: float = clampf(progress, 0.0, 1.0)
	# Throttle: emit only when progress moves >=1 % or stage changes. Stops the
	# WebBridge from flooding the JS bridge with ~60 events/sec.
	var stage_changed: bool = stage != _last_emitted_stage
	var progress_jumped: bool = absf(clamped - _last_emitted_progress) >= 0.01
	if not stage_changed and not progress_jumped:
		return
	_last_emitted_progress = clamped
	_last_emitted_stage = stage
	var bridge: Node = get_node_or_null(^"/root/WebBridge")
	if bridge != null and bridge.has_method("send_event"):
		bridge.send_event("match_loading_progress", {
			"progress": clamped,
			"stage": stage,
		})
