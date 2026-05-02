class_name MuzzleFlash
extends Sprite3D

## Shared muzzle flash sprite. Tank and rifle fire both use the same texture so
## the Web export doesn't carry two near-identical 1080p flash PNGs.

@export var frame_count: int = 1
@export var frame_path_format: String = "res://assets/textures/muzzle_flash/ak_muzzle_flash.png"
@export var frame_duration: float = 0.16
@export var world_pixel_size: float = 0.0009

var _frames: Array[Texture2D] = []
var _current_frame: int = 0
var _timer: float = 0.0
var _pool_owner: Node = null
var _pool_active: bool = true
## Set true while the deferred 2-frame pipeline-compile prewarm is in flight.
## Cleared by play_at()/deactivate_for_pool() so a real shot acquired during
## the warmup window cancels the pending self-deactivate.
var _pool_warmup_pending: bool = false

## Optional bone follow — when set, the flash glues to a Skeleton3D bone for
## its full lifetime so it stays on the muzzle tip even as the player keeps
## rotating the turret after pulling the trigger. Without this the flash
## spawns at fire-time world position and "slides off" the moving barrel.
var _follow_skeleton: Skeleton3D = null
var _follow_bone_idx: int = -1
var _follow_local_offset: Vector3 = Vector3.ZERO

static var _cached_frames: Array[Texture2D] = []
static var _cached_frame_count: int = 0
static var _cached_frame_path_format: String = ""


func _ready() -> void:
	_configure_sprite()
	_ensure_frames()
	if _frames.is_empty():
		push_warning("MuzzleFlash: no frames loaded")
		_finish()
		return
	texture = _frames[0]
	if _pool_owner != null:
		# Why: WebGL/Compatibility renderer compiles the billboard+ALPHA_CUT+
		# no_depth_test sprite pipeline on first DRAW. Calling deactivate_for_pool()
		# in the same frame as add_child hides the sprite before any draw call is
		# submitted -> first real shot in match stalls the frame while the pipeline
		# compiles inline. Hold visible for two frames, then deactivate.
		_pool_active = true
		_pool_warmup_pending = true
		visible = true
		set_process(false)
		call_deferred("_finish_pool_warmup_render")
	else:
		set_process(true)


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
	if _follow_skeleton != null and is_instance_valid(_follow_skeleton) and _follow_bone_idx >= 0:
		var bone_world: Transform3D = _follow_skeleton.global_transform * _follow_skeleton.get_bone_global_pose(_follow_bone_idx)
		global_position = bone_world * _follow_local_offset
	_timer += delta
	if _timer < frame_duration:
		return
	_timer = 0.0
	_current_frame += 1
	if _current_frame >= _frames.size():
		_finish()
		return
	texture = _frames[_current_frame]


## Make this flash glue itself to a Skeleton3D bone for its full lifetime.
## The flash position is recomputed each render frame from the bone's current
## global pose, so the flash stays on the muzzle even if the player keeps
## yawing/pitching the turret after firing.
func set_follow_target(skeleton: Skeleton3D, bone_idx: int, local_offset: Vector3) -> void:
	_follow_skeleton = skeleton
	_follow_bone_idx = bone_idx
	_follow_local_offset = local_offset


func set_pool_owner(pool_owner: Node) -> void:
	_pool_owner = pool_owner


func is_pool_idle() -> bool:
	return _pool_owner != null and not _pool_active


func play_at(world_transform: Transform3D) -> void:
	if _frames.is_empty():
		_ensure_frames()
	if _frames.is_empty():
		return
	# Cancel any pending pool-warmup deactivate so a real shot acquired mid
	# prewarm window stays visible.
	_pool_warmup_pending = false
	# Reset bone follow — caller can re-set after play_at if it wants the
	# flash to glue to a bone. Pool reuses the same instance, so stale follow
	# state from a previous shot must be cleared.
	_follow_skeleton = null
	_follow_bone_idx = -1
	global_transform = world_transform
	_current_frame = 0
	_timer = 0.0
	texture = _frames[0]
	visible = true
	_pool_active = true
	set_process(true)


func deactivate_for_pool() -> void:
	_pool_warmup_pending = false
	_pool_active = false
	visible = false
	_current_frame = 0
	_timer = 0.0
	_follow_skeleton = null
	_follow_bone_idx = -1
	if not _frames.is_empty():
		texture = _frames[0]
	set_process(false)


func _configure_sprite() -> void:
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	shaded = false
	alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	no_depth_test = true
	pixel_size = world_pixel_size


func _ensure_frames() -> void:
	if _cached_frames.is_empty() or _cached_frame_count != frame_count or _cached_frame_path_format != frame_path_format:
		_cached_frames.clear()
		_cached_frame_count = frame_count
		_cached_frame_path_format = frame_path_format
		for i: int in range(1, frame_count + 1):
			var frame_path: String = frame_path_format
			if frame_path_format.contains("%"):
				frame_path = frame_path_format % i
			var tex: Texture2D = load(frame_path) as Texture2D
			if tex != null:
				_cached_frames.append(tex)
			else:
				var frame_index: int = i - 1
				var t: float = 1.0 - (float(frame_index) / maxf(float(frame_count), 1.0))
				_cached_frames.append(_build_flash_texture(t))
	_frames = _cached_frames.duplicate()


func _finish() -> void:
	if _pool_owner != null and is_instance_valid(_pool_owner) and _pool_owner.has_method("release_muzzle_flash"):
		_pool_owner.call("release_muzzle_flash", self)
		return
	queue_free()


func _build_flash_texture(strength: float, size: int = 96) -> Texture2D:
	var image: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center: float = float(size - 1) * 0.5
	for y: int in range(size):
		for x: int in range(size):
			var uv: Vector2 = Vector2((float(x) - center) / center, (float(y) - center) / center)
			var r: float = uv.length()
			var core: float = clampf(1.0 - r * lerpf(1.8, 2.7, 1.0 - strength), 0.0, 1.0)
			var horizontal: float = clampf(1.0 - absf(uv.y) * 13.0 - absf(uv.x) * 0.70, 0.0, 1.0)
			var vertical: float = clampf(1.0 - absf(uv.x) * 13.0 - absf(uv.y) * 0.70, 0.0, 1.0)
			var diag_a: float = clampf(1.0 - absf(uv.x - uv.y) * 10.0 - r * 0.92, 0.0, 1.0)
			var diag_b: float = clampf(1.0 - absf(uv.x + uv.y) * 10.0 - r * 0.92, 0.0, 1.0)
			var star: float = maxf(maxf(horizontal, vertical), maxf(diag_a, diag_b))
			var alpha: float = clampf(maxf(core, star) * strength * (1.0 - smoothstep(0.82, 1.0, r)), 0.0, 1.0)
			var heat: float = clampf(core * 1.5 + star * 0.75, 0.0, 1.0)
			image.set_pixel(x, y, Color(1.0, lerpf(0.46, 0.95, heat), lerpf(0.08, 0.52, core), alpha))
	return ImageTexture.create_from_image(image)
