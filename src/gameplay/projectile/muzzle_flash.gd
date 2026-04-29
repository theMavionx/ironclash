class_name MuzzleFlash
extends Sprite3D

## Minimal 5-star muzzle flash using the first 3 frames of the sprite sheet.

@export var frame_count: int = 3
@export var frame_duration: float = 0.04
@export var world_pixel_size: float = 0.0009

var _frames: Array[Texture2D] = []
var _current_frame: int = 0
var _timer: float = 0.0

static var _cached_frames: Array[Texture2D] = []
static var _cached_frame_count: int = 0


func _ready() -> void:
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	shaded = false
	alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	pixel_size = world_pixel_size
	if _cached_frames.is_empty() or _cached_frame_count != frame_count:
		_cached_frames.clear()
		_cached_frame_count = frame_count
		for i: int in range(frame_count):
			var t: float = 1.0 - (float(i) / maxf(float(frame_count), 1.0))
			_cached_frames.append(_build_flash_texture(t))
	_frames = _cached_frames.duplicate()
	if _frames.is_empty():
		push_warning("MuzzleFlash: no frames loaded")
		queue_free()
		return
	texture = _frames[0]


func _process(delta: float) -> void:
	_timer += delta
	if _timer < frame_duration:
		return
	_timer = 0.0
	_current_frame += 1
	if _current_frame >= _frames.size():
		queue_free()
		return
	texture = _frames[_current_frame]


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
