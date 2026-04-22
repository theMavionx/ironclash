class_name TracerPool
extends Node3D

## Object pool for AR tracer MeshInstance3D nodes — eliminates per-shot heap
## allocation of mesh nodes, Tweens, and Callable lambdas that previously fired
## at ~10 Hz during sustained AR fire.
##
## SETUP (add to player.tscn):
##   1. Add a Node3D child to the Player root node. Name it "TracerPool".
##      Set its script to this file (tracer_pool.gd).
##   2. In WeaponController's Inspector, point tracer_pool_path to "TracerPool"
##      (relative to WeaponController's parent — the Player root).
##   3. Call WeaponController._ready() wiring will invoke:
##         tracer_pool.setup(_tracer_quad_mesh, _tracer_shader_material,
##                           _tracer_mesh, _tracer_material, _tracer_shader_ready)
##      via PlayerFireVFX.set_pools(). This MUST happen after PlayerFireVFX
##      has called prewarm() / _ensure_textures_loaded() so the shared
##      mesh + material statics are populated.
##
## POOL EXHAUSTION: when all entries are active, the oldest entry is recycled
## (its previous flight is abandoned mid-air). The bullet damage was already
## dealt at spawn time, so the visual miss is cosmetically acceptable.

# ---------------------------------------------------------------------------
# Tuning (all @export so no hardcoded values — per gameplay-code.md)
# ---------------------------------------------------------------------------

@export_group("Pool")
## Number of pre-allocated tracer mesh entries. At 10 Hz and max 0.35s life
## there are at most 4 simultaneously active tracers; 32 gives 8× headroom.
@export var pool_size: int = 32

@export_group("Tracer Timing")
## World-units per second the tracer travels. 80 m/s is arcade-readable;
## real bullet (700+ m/s) would be invisible on screen at gameplay ranges.
@export var bullet_speed: float = 80.0
## Minimum travel time regardless of distance (prevents instant-vanish on
## point-blank shots).
@export var min_travel_time: float = 0.02
## Maximum travel time cap so long-range shots still feel snappy.
@export var max_travel_time: float = 0.35

# ---------------------------------------------------------------------------
# Entry state — parallel typed arrays, no per-entry dict allocation.
# Index i owns: _entries[i], _active[i], _start_pos[i], _end_pos[i],
#               _travel_time[i], _elapsed[i], _use_shader[i].
# ---------------------------------------------------------------------------

var _entries: Array[MeshInstance3D] = []
var _active: PackedByteArray          ## bool stored as byte — 0 = idle, 1 = active
var _start_pos: PackedVector3Array
var _end_pos: PackedVector3Array
var _travel_time: PackedFloat32Array
var _elapsed: PackedFloat32Array
var _use_shader: PackedByteArray

## Shared mesh + material references — set once in setup(), never changed.
## Two pipelines coexist so both shader and fallback paths work from the pool.
var _quad_mesh: QuadMesh = null
var _quad_mat: ShaderMaterial = null
var _cyl_mesh: CylinderMesh = null
var _cyl_mat: StandardMaterial3D = null
var _shader_ready: bool = false

## Oldest-entry cursor for recycle-on-exhaustion (round-robin across active).
var _oldest_index: int = 0

## How many entries are currently active. Drives set_process on/off.
var _active_count: int = 0


func _ready() -> void:
	set_process(false)
	_active = PackedByteArray()
	_active.resize(pool_size)
	_start_pos = PackedVector3Array()
	_start_pos.resize(pool_size)
	_end_pos = PackedVector3Array()
	_end_pos.resize(pool_size)
	_travel_time = PackedFloat32Array()
	_travel_time.resize(pool_size)
	_elapsed = PackedFloat32Array()
	_elapsed.resize(pool_size)
	_use_shader = PackedByteArray()
	_use_shader.resize(pool_size)

	# Pre-allocate all MeshInstance3D nodes. Mesh + material are assigned in
	# setup() after the caller has loaded shared resources. Nodes are hidden
	# at rest.
	_entries.resize(pool_size)
	for i: int in pool_size:
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.visible = false
		add_child(mi)
		_entries[i] = mi
		_active[i] = 0
		_elapsed[i] = 0.0
		_travel_time[i] = 0.0
		_use_shader[i] = 0


## Call once from WeaponController._ready() after PlayerFireVFX.prewarm() has
## populated the shared resource statics. Assigns mesh + material to every
## pool entry. If shader_ready is false the fallback cylinder pipeline is used.
##
## [param quad_mesh]     shared QuadMesh (shader pipeline)
## [param quad_mat]      shared ShaderMaterial (shader pipeline)
## [param cyl_mesh]      shared CylinderMesh (fallback pipeline)
## [param cyl_mat]       shared StandardMaterial3D (fallback pipeline)
## [param shader_ready]  true when the shader pipeline loaded successfully
func setup(
	quad_mesh: QuadMesh,
	quad_mat: ShaderMaterial,
	cyl_mesh: CylinderMesh,
	cyl_mat: StandardMaterial3D,
	shader_ready: bool,
) -> void:
	_quad_mesh = quad_mesh
	_quad_mat = quad_mat
	_cyl_mesh = cyl_mesh
	_cyl_mat = cyl_mat
	_shader_ready = shader_ready

	var use_shader_bit: int = 1 if shader_ready else 0
	var mesh: Mesh = quad_mesh if shader_ready else cyl_mesh
	var mat: Material = quad_mat if shader_ready else cyl_mat

	for i: int in pool_size:
		_entries[i].mesh = mesh
		_entries[i].material_override = mat
		_use_shader[i] = use_shader_bit


## Activate a tracer from [param from_pos] to [param to_pos].
## [param use_shader] must match the shader-readiness flag from PlayerFireVFX.
## If all entries are active the oldest one is recycled.
##
## Returns false if from_pos and to_pos are too close to bother (< 0.2 m).
func spawn(from_pos: Vector3, to_pos: Vector3, use_shader: bool) -> bool:
	var distance: float = from_pos.distance_to(to_pos)
	if distance < 0.2:
		return false

	var idx: int = _find_idle_or_recycle()
	var mi: MeshInstance3D = _entries[idx]

	# Switch mesh/material pipeline if shader availability differs from what
	# was baked in at setup() time (e.g. shader loaded mid-session).
	var want_shader_bit: int = 1 if use_shader else 0
	if _use_shader[idx] != want_shader_bit:
		_use_shader[idx] = want_shader_bit
		if use_shader and _quad_mesh != null and _quad_mat != null:
			mi.mesh = _quad_mesh
			mi.material_override = _quad_mat
		elif _cyl_mesh != null and _cyl_mat != null:
			mi.mesh = _cyl_mesh
			mi.material_override = _cyl_mat

	var travel: float = clampf(distance / bullet_speed, min_travel_time, max_travel_time)

	_start_pos[idx] = from_pos
	_end_pos[idx] = to_pos
	_travel_time[idx] = travel
	_elapsed[idx] = 0.0
	_active[idx] = 1

	# Orient the mesh. CylinderMesh length = local +Y; QuadMesh length = local +Y
	# after look_at + 90° rotate. Orientation along from→to convergence direction.
	var forward: Vector3 = (to_pos - from_pos).normalized()
	var up_ref: Vector3 = Vector3.UP
	if absf(forward.dot(Vector3.UP)) > 0.99:
		up_ref = Vector3.FORWARD

	# Pin start position BEFORE making the node visible so the first _process
	# tick finds it at muzzle_world rather than at origin (fixes first-frame
	# teleport bug that the old Tween .from() pin worked around).
	mi.global_position = from_pos
	mi.look_at(to_pos, up_ref)
	mi.rotate_object_local(Vector3.RIGHT, -PI / 2.0)
	mi.visible = true

	if _active_count == 0:
		set_process(true)
	_active_count += 1
	return true


## HOT PATH — no get_tree(), find_node, string ops, type checks, or allocations.
func _process(delta: float) -> void:
	for i: int in pool_size:
		if _active[i] == 0:
			continue
		_elapsed[i] += delta
		var t: float = _elapsed[i] / _travel_time[i]
		if t >= 1.0:
			_entries[i].global_position = _end_pos[i]
			_entries[i].visible = false
			_active[i] = 0
			_active_count -= 1
		else:
			_entries[i].global_position = _start_pos[i].lerp(_end_pos[i], t)

	if _active_count <= 0:
		_active_count = 0
		set_process(false)


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Returns an idle entry index. If none free, recycles the oldest active entry
## (advances the round-robin cursor across active indices).
func _find_idle_or_recycle() -> int:
	# Fast path: find first idle.
	for i: int in pool_size:
		if _active[i] == 0:
			return i

	# All busy — recycle oldest. _oldest_index is a round-robin cursor that
	# increments each time we must recycle, distributing the visual miss
	# across all pool entries rather than always yanking the same one.
	var idx: int = _oldest_index
	_oldest_index = (_oldest_index + 1) % pool_size
	# The recycled entry was active; decrement count before _activate re-increments.
	_active[idx] = 0
	_active_count -= 1
	return idx
