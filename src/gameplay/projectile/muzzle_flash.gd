class_name MuzzleFlash
extends Sprite3D

## Minimal 5-star muzzle flash using the first 3 frames of the sprite sheet.

@export var frame_count: int = 3
@export var frame_path_format: String = "res://assets/models/tank/FootageCrate-5_Star_Muzzle_Flash_Front/FootageCrate-5_Star_Muzzle_Flash_Front-%05d.png"
@export var frame_duration: float = 0.04
@export var world_pixel_size: float = 0.0009

var _frames: Array[Texture2D] = []
var _current_frame: int = 0
var _timer: float = 0.0


func _ready() -> void:
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	shaded = false
	alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	pixel_size = world_pixel_size
	for i in range(1, frame_count + 1):
		var path: String = frame_path_format % i
		var tex: Texture2D = load(path) as Texture2D
		if tex:
			_frames.append(tex)
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
