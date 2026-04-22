class_name MuzzleFlashPool
extends Node3D

## Object pool for muzzle-flash Sprite3D nodes — eliminates per-shot allocation
## of Sprite3D, SceneTreeTimer, and Callable lambda that previously fired
## at ~10 Hz during sustained AR fire.
##
## DESIGN: Option B — pool lives as a DIRECT CHILD of the muzzle node.
## All Sprite3Ds are pre-parented here at creation time. Grab = set visible +
## reset local_position to zero. Release = set invisible. Zero reparenting per
## shot: no add_child / remove_child scene-tree churn at runtime.
##
## SETUP (add to player.tscn):
##   1. Locate the muzzle Node3D in your scene (the node pointed to by
##      WeaponController.muzzle_path, typically a child of the AK47 skeleton).
##   2. Add a Node3D child DIRECTLY UNDER that muzzle node. Name it
##      "MuzzleFlashPool". Set its script to this file (muzzle_flash_pool.gd).
##      Because it is a child of the muzzle, it inherits the rifle pose every
##      frame — the same guarantee the old per-shot parented Sprite3D had.
##   3. In WeaponController's Inspector, point flash_pool_path to the
##      MuzzleFlashPool node (e.g. "../Body/Visual/Player/Skeleton3D/ak47/Muzzle/MuzzleFlashPool").
##   4. PlayerFireVFX.set_pools() will call flash_pool.setup(texture) once from
##      WeaponController._ready() after textures are loaded.
##
## NOTE: Because this node is a child of the muzzle, it will follow the muzzle
## in world space. Each Sprite3D has local_position = Vector3.ZERO so it sits
## exactly at the muzzle tip, inheriting all parent transforms automatically.

# ---------------------------------------------------------------------------
# Tuning
# ---------------------------------------------------------------------------

@export_group("Pool")
## Number of pre-allocated flash Sprite3D entries. At 10 Hz the overlap window
## at 0.05s lifetime means at most 1 is ever active; 16 gives wide margin.
@export var pool_size: int = 16

@export_group("Flash Appearance")
## Seconds each flash frame is visible. Must match the old 0.05s behaviour.
@export var flash_lifetime: float = 0.05
## Pixel size passed to Sprite3D (world size of one pixel in metres).
## 0.00028 matches the original hand-tuned value.
@export var pixel_size: float = 0.00028

# ---------------------------------------------------------------------------
# Per-entry state — parallel arrays, zero dict allocation.
# ---------------------------------------------------------------------------

var _sprites: Array[Sprite3D] = []
var _active: PackedByteArray       ## 0 = idle, 1 = active
var _elapsed: PackedFloat32Array

## Shared texture assigned once in setup().
var _texture: Texture2D = null
var _is_setup: bool = false

## Number of currently active entries — drives set_process on/off.
var _active_count: int = 0


func _ready() -> void:
	set_process(false)

	_active = PackedByteArray()
	_active.resize(pool_size)
	_elapsed = PackedFloat32Array()
	_elapsed.resize(pool_size)
	_sprites.resize(pool_size)

	for i: int in pool_size:
		var sp: Sprite3D = Sprite3D.new()
		sp.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sp.shaded = false
		sp.pixel_size = pixel_size
		sp.visible = false
		sp.position = Vector3.ZERO  # local to muzzle node (this node's parent)
		add_child(sp)
		_sprites[i] = sp
		_active[i] = 0
		_elapsed[i] = 0.0


## Call once from WeaponController._ready() after PlayerFireVFX has loaded
## the flash texture. Sets the texture on every pool entry.
##
## [param texture] the loaded Texture2D for the muzzle flash sprite sheet.
func setup(texture: Texture2D) -> void:
	if texture == null:
		push_warning("MuzzleFlashPool.setup(): texture is null — flash pool will produce invisible sprites")
		return
	_texture = texture
	for i: int in pool_size:
		_sprites[i].texture = texture
	_is_setup = true


## Activate one flash entry. Safe to call before setup() completes — entry will
## be invisible (texture null) but won't crash.
## Random Z-rotation is applied per activation to vary successive flashes
## visually (matches the original random roll behaviour).
func activate_flash() -> void:
	var idx: int = _find_idle()
	if idx < 0:
		# All 16 slots busy at once (extremely unlikely at 0.05s lifetime + 10 Hz).
		# Silently skip — the shot already fired and damage was dealt.
		return

	var sp: Sprite3D = _sprites[idx]
	sp.position = Vector3.ZERO
	sp.rotation = Vector3(0.0, 0.0, randf() * TAU)
	sp.visible = true
	_active[idx] = 1
	_elapsed[idx] = 0.0

	if _active_count == 0:
		set_process(true)
	_active_count += 1


## HOT PATH — no get_tree(), string ops, allocations, or type checks.
func _process(delta: float) -> void:
	for i: int in pool_size:
		if _active[i] == 0:
			continue
		_elapsed[i] += delta
		if _elapsed[i] >= flash_lifetime:
			_sprites[i].visible = false
			_active[i] = 0
			_active_count -= 1

	if _active_count <= 0:
		_active_count = 0
		set_process(false)


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Returns the index of the first idle entry, or -1 if all are active.
func _find_idle() -> int:
	for i: int in pool_size:
		if _active[i] == 0:
			return i
	return -1
