class_name PlanetSurface extends Node3D
## Progressive cube-sphere terrain for one celestial body.
##
## One quadtree per cube face; the "regimes" in docs/planet-renderer.md are just
## how much of it is resident. Root patches are built synchronously at setup so
## a body is never a hole in the sky; refinement is driven by a screen-space
## error metric and built on WorkerThreadPool tasks (arrays on the worker,
## ArrayMesh commit on the main thread — mesh upload is main-thread in Godot).
##
## Spin: CelestialBody drives `update_spin` with SimClock.sim_time every frame,
## so rotation is analytic like everything else on rails — never accumulated
## per-frame (accumulation breaks time compression). The proxy clamp drives
## `apply_scale_ratio`, which scales this node exactly as it scaled the old
## sphere mesh, so the angular-size trick keeps working unchanged.
##
## Skim collision: near the surface the analytic sphere collider lies — it
## walls the ship out of valleys and lets it through peaks. Inside skim range
## this node builds trimesh colliders for the resident patches around the ship,
## CelestialBody disables its sphere (it checks `skim_active`), and the ship
## gets CCD. All three reverse above the exit distance. Patches hang under a
## rail-driven Node3D, but a StaticBody3D is fine there — same pattern as the
## body's existing sphere collider (the docked-ship trap is about RigidBody3D).

signal textures_baked

## Subdivide a patch when its geometric error / camera distance exceeds this.
@export var subdivide_threshold: float = 0.004

## Merge back when the parent's error falls below threshold / hysteresis.
@export var merge_hysteresis: float = 1.5

## Subdivision decisions run at most this often (seconds) per body.
@export var eval_interval: float = 0.25

@export var max_depth: int = 7

## Patch/collision builds in flight per body. Approach streams, never hitches.
@export var max_in_flight: int = 4

## LRU cache budget of built patches.
# Measured, not estimated: a depth-5 settle over Earth holds ~230 leaves plus
# their ancestors, about 300 entries, and eviction cannot drop entries that are
# live or shallow. A cache smaller than the working set does not save memory, it
# just thrashes. 512 x 33^2 verts is still only ~18 MB.
@export var cache_capacity: int = 512

## Never evict patches at or above this depth — the coarse shell never rebuilds.
@export var cache_keep_depth: int = 2

## Skirt drop as a fraction of patch span.
@export var skirt_drop: float = 0.02

## Ship distance-to-surface thresholds for the collision swap. Hysteresis:
## the swap must not thrash while hovering at the boundary.
@export var skim_enter_distance: float = 500.0
@export var skim_exit_distance: float = 600.0

## Build trimesh colliders for resident patches within this range of the ship.
@export var skim_collider_range: float = 300.0

@export var bake_size: int = 512

var surface_res: BodySurface
var radius: float = 1000.0
var spin_period: float = 0.0
var spin_axis_tilt: float = 0.0

## Set by CelestialBody each frame. While proxied, only root patches stay
## resident and skim is impossible.
var body_is_proxy: bool = false

var skim_active: bool = false
var textures_ready: bool = false

var _material: ShaderMaterial
var _roots: Array = []
var _cache: Dictionary = {}
var _cache_tick: int = 0
var _building: Dictionary = {}
var _faces_pending: Dictionary = {}
var _in_flight: int = 0
var _task_ids: Array[int] = []
var _eval_accum: float = 0.0
var _spin_angle: float = 0.0
var _ratio: float = 1.0
var _skim_body: StaticBody3D = null
var _skim_ship: RigidBody3D = null
var _collider_nodes: Dictionary = {}


class QuadNode extends RefCounted:
	var face: int
	var depth: int
	var x: int
	var y: int
	var key: String
	var center: Vector3
	var mi: MeshInstance3D = null
	var children: Array = []


class CacheEntry extends RefCounted:
	var key: String
	var depth: int
	var arrays: Dictionary
	var mesh: ArrayMesh
	var tick: int = 0
	var refs: int = 0
	var faces: PackedVector3Array
	var has_faces: bool = false
	var shape: ConcavePolygonShape3D = null


func setup(
	p_surface: BodySurface, p_radius: float, p_spin_period: float,
	p_spin_axis_tilt: float, p_base_color: Color, p_roughness: float
) -> void:
	surface_res = p_surface
	radius = p_radius
	spin_period = p_spin_period
	spin_axis_tilt = p_spin_axis_tilt
	surface_res.prepare()

	_material = ShaderMaterial.new()
	_material.shader = load("res://assets/shaders/planet_surface.gdshader")
	_material.set_shader_parameter("base_color", p_base_color)
	_material.set_shader_parameter("roughness_value", p_roughness)

	# Root shell, synchronous: bodies build during bootstrap, and a body must
	# never render as nothing while its first patches are in flight.
	for face in 6:
		var entry := _store_entry(
			PlanetPatchMesh.build_arrays(surface_res, radius, face, 0, 0, 0, skirt_drop), 0
		)
		var node := QuadNode.new()
		node.face = face
		node.depth = 0
		node.x = 0
		node.y = 0
		node.key = entry.key
		node.center = entry.arrays["center"]
		_attach_mesh(node, entry)
		_roots.append(node)

	_start_bake()


## --- Per-frame driving (called by CelestialBody.update_render) --------------

## Analytic spin from simulation time. Rotates this node only — never the
## collision sphere, never the CelestialBody — so orbital math is untouched.
func update_spin(t: float) -> void:
	if spin_period > 0.0:
		_spin_angle = fposmod(TAU * (t / spin_period), TAU)
	_recompose()


## The proxy clamp's scale, exactly as it scaled the old sphere mesh. Patch
## geometry is baked at metre scale, so the node scale is the ratio itself.
func apply_scale_ratio(ratio: float) -> void:
	_ratio = ratio
	_recompose()


func _recompose() -> void:
	var b := Basis.IDENTITY
	if spin_period > 0.0:
		var axis := Vector3(0.0, cos(spin_axis_tilt), sin(spin_axis_tilt)).normalized()
		b = Basis(axis, _spin_angle)
	transform = Transform3D(b.scaled(Vector3.ONE * _ratio), Vector3.ZERO)


## --- Refinement --------------------------------------------------------------

func _process(delta: float) -> void:
	_reap_tasks()
	_eval_accum += delta
	if _eval_accum >= eval_interval:
		_eval_accum = 0.0
		_evaluate()


## Test hook: run a subdivision pass now, ignoring the interval throttle.
func force_evaluate() -> void:
	_evaluate()


func _evaluate() -> void:
	if body_is_proxy:
		# Regime A: root patches only. The proxy scales them; the error metric
		# never runs against a scaled world.
		for root in _roots:
			_merge(root)
		_evict_overflow()
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cam_pos := cam.global_position
	var amp_m: float = radius * surface_res.amplitude
	for root in _roots:
		_update_node(root, cam_pos, amp_m)
	if skim_active:
		_refresh_colliders()
	_evict_overflow()


## Screen-space error: patch geometric error over camera distance. Geometric
## error halves per depth and is anchored to the relief amplitude, so smooth
## bodies (gas giants, amplitude 0) never subdivide at all — a sphere needs no
## more triangles, only its fancy albedo.
func _patch_error(node: QuadNode, cam_pos: Vector3, amp_m: float) -> float:
	var world_center: Vector3 = global_transform * node.center
	var dist: float = maxf(world_center.distance_to(cam_pos), 1.0)
	return (amp_m / float(1 << node.depth)) / dist


func _update_node(node: QuadNode, cam_pos: Vector3, amp_m: float) -> void:
	var err := _patch_error(node, cam_pos, amp_m)
	if node.children.is_empty():
		if err > subdivide_threshold and node.depth < max_depth:
			_try_split(node)
	elif err < subdivide_threshold / merge_hysteresis:
		_merge(node)
	else:
		for child in node.children:
			_update_node(child, cam_pos, amp_m)


## Split only once all four children are built: the parent stays visible until
## the swap, so approach never shows a hole — that is the no-pop rule.
func _try_split(node: QuadNode) -> void:
	var ready := true
	for ci in 4:
		var cx: int = node.x * 2 + (ci & 1)
		var cy: int = node.y * 2 + (ci >> 1)
		if not _cache.has(PlanetPatchMesh.patch_key(node.face, node.depth + 1, cx, cy)):
			ready = false
			_queue_build(node.face, node.depth + 1, cx, cy)
	if not ready:
		return
	for ci in 4:
		var child := QuadNode.new()
		child.face = node.face
		child.depth = node.depth + 1
		child.x = node.x * 2 + (ci & 1)
		child.y = node.y * 2 + (ci >> 1)
		child.key = PlanetPatchMesh.patch_key(child.face, child.depth, child.x, child.y)
		var entry: CacheEntry = _cache[child.key]
		child.center = entry.arrays["center"]
		_attach_mesh(child, entry)
		node.children.append(child)
	if node.mi:
		node.mi.visible = false


func _merge(node: QuadNode) -> void:
	if node.children.is_empty():
		return
	for child in node.children:
		_merge(child)
		_free_leaf(child)
	node.children = []
	if node.mi:
		node.mi.visible = true


func _attach_mesh(node: QuadNode, entry: CacheEntry) -> void:
	_cache_tick += 1
	entry.tick = _cache_tick
	entry.refs += 1
	var mi := MeshInstance3D.new()
	mi.mesh = entry.mesh
	mi.position = node.center
	mi.material_override = _material
	mi.set_instance_shader_parameter(&"patch_center", node.center)
	add_child(mi)
	node.mi = mi


func _free_leaf(node: QuadNode) -> void:
	if node.mi:
		node.mi.queue_free()
		node.mi = null
	var entry: CacheEntry = _cache.get(node.key)
	if entry:
		entry.refs -= 1
	var cs: CollisionShape3D = _collider_nodes.get(node.key)
	if cs:
		cs.queue_free()
		_collider_nodes.erase(node.key)


## --- Build pipeline -----------------------------------------------------------

func _queue_build(face: int, depth: int, x: int, y: int) -> void:
	var key := PlanetPatchMesh.patch_key(face, depth, x, y)
	if _building.has(key) or _cache.has(key):
		return
	if _in_flight >= max_in_flight:
		return
	_building[key] = true
	_in_flight += 1
	var srf := surface_res
	var r := radius
	var sd := skirt_drop
	var commit: Callable = _commit_build
	_task_ids.append(WorkerThreadPool.add_task(func() -> void:
		var arrays := PlanetPatchMesh.build_arrays(srf, r, face, depth, x, y, sd)
		commit.call_deferred(arrays, depth)
	))


func _commit_build(arrays: Dictionary, depth: int) -> void:
	_in_flight -= 1
	_building.erase(arrays["key"])
	if not _cache.has(arrays["key"]):
		_store_entry(arrays, depth)


func _store_entry(arrays: Dictionary, depth: int) -> CacheEntry:
	var mesh_arrays: Array = []
	mesh_arrays.resize(Mesh.ARRAY_MAX)
	mesh_arrays[Mesh.ARRAY_VERTEX] = arrays["verts"]
	mesh_arrays[Mesh.ARRAY_NORMAL] = arrays["normals"]
	mesh_arrays[Mesh.ARRAY_INDEX] = arrays["indices"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh_arrays)
	var entry := CacheEntry.new()
	entry.key = arrays["key"]
	entry.depth = depth
	entry.arrays = arrays
	entry.mesh = mesh
	_cache_tick += 1
	entry.tick = _cache_tick
	_cache[entry.key] = entry
	return entry


func _evict_overflow() -> void:
	while _cache.size() > cache_capacity:
		var victim: CacheEntry = null
		for entry in _cache.values():
			if entry.depth <= cache_keep_depth or entry.refs > 0:
				continue
			if victim == null or entry.tick < victim.tick:
				victim = entry
		if victim == null:
			return
		_cache.erase(victim.key)


func _reap_tasks() -> void:
	var i := 0
	while i < _task_ids.size():
		if WorkerThreadPool.is_task_completed(_task_ids[i]):
			WorkerThreadPool.wait_for_task_completion(_task_ids[i])
			_task_ids.remove_at(i)
		else:
			i += 1


## --- Texture bake -------------------------------------------------------------

func _start_bake() -> void:
	var srf := surface_res
	var r := radius
	var size := bake_size
	var commit: Callable = _commit_bake
	_task_ids.append(WorkerThreadPool.add_task(func() -> void:
		var images := PlanetBake.bake(srf, r, size)
		commit.call_deferred(images)
	))


func _commit_bake(images: Dictionary) -> void:
	_material.set_shader_parameter(
		"albedo_tex", ImageTexture.create_from_image(images["albedo"]))
	_material.set_shader_parameter(
		"normal_tex", ImageTexture.create_from_image(images["normal"]))
	if surface_res.night_emissive != null:
		_material.set_shader_parameter("emissive_tex", surface_res.night_emissive)
		_material.set_shader_parameter("has_emissive", true)
	elif images["emissive"] != null:
		_material.set_shader_parameter(
			"emissive_tex", ImageTexture.create_from_image(images["emissive"]))
		_material.set_shader_parameter("has_emissive", true)
	_material.set_shader_parameter("textures_ok", true)
	textures_ready = true
	textures_baked.emit()


## --- Skim collision -----------------------------------------------------------

func _physics_process(_delta: float) -> void:
	_update_skim()


func _update_skim() -> void:
	var ship := OriginShift.tracked as RigidBody3D
	if ship == null or not is_instance_valid(ship) or body_is_proxy:
		if skim_active:
			_exit_skim()
		return
	var dist: float = (ship.global_position - global_position).length() - radius
	if not skim_active and dist < skim_enter_distance:
		_enter_skim(ship)
	elif skim_active and dist > skim_exit_distance:
		_exit_skim()


func _enter_skim(ship: RigidBody3D) -> void:
	skim_active = true
	_skim_ship = ship
	# 60 Hz physics and a fast pass over ~25 m patches will tunnel without CCD.
	ship.continuous_cd = true
	if _skim_body == null:
		_skim_body = StaticBody3D.new()
		_skim_body.name = "SkimTerrain"
		_skim_body.collision_layer = 8   # environment
		_skim_body.collision_mask = 0
		add_child(_skim_body)
	_refresh_colliders()


func _exit_skim() -> void:
	skim_active = false
	if _skim_ship != null and is_instance_valid(_skim_ship):
		_skim_ship.continuous_cd = false
	_skim_ship = null
	for key in _collider_nodes:
		_collider_nodes[key].queue_free()
	_collider_nodes.clear()


func _refresh_colliders() -> void:
	if _skim_ship == null or not is_instance_valid(_skim_ship):
		return
	var ship_pos := _skim_ship.global_position
	var wanted: Dictionary = {}
	var leaves: Array = []
	for root in _roots:
		_gather_leaves(root, leaves)
	for node in leaves:
		var world_center: Vector3 = global_transform * node.center
		var reach: float = skim_collider_range + PlanetPatchMesh.span_m(radius, node.depth)
		if world_center.distance_to(ship_pos) > reach:
			continue
		wanted[node.key] = true
		_ensure_collider(node)
	for key in _collider_nodes.keys():
		if not wanted.has(key):
			_collider_nodes[key].queue_free()
			_collider_nodes.erase(key)


func _ensure_collider(node: QuadNode) -> void:
	if _collider_nodes.has(node.key):
		return
	var entry: CacheEntry = _cache.get(node.key)
	if entry == null:
		return
	if entry.shape == null:
		if not entry.has_faces:
			_queue_faces(entry)
			return
		var shape := ConcavePolygonShape3D.new()
		# Both-sided: skimming must never depend on which side of a triangle a
		# CCD sweep happens to start from.
		shape.backface_collision = true
		shape.set_faces(entry.faces)
		entry.shape = shape
	var cs := CollisionShape3D.new()
	cs.shape = entry.shape
	cs.position = node.center
	_skim_body.add_child(cs)
	_collider_nodes[node.key] = cs


## Collision faces are extracted from the render arrays on the same worker
## tasks as everything else (design doc, "skimming is supported").
func _queue_faces(entry: CacheEntry) -> void:
	if _faces_pending.has(entry.key) or _in_flight >= max_in_flight:
		return
	_faces_pending[entry.key] = true
	_in_flight += 1
	var key := entry.key
	var arrays := entry.arrays
	var commit: Callable = _commit_faces
	_task_ids.append(WorkerThreadPool.add_task(func() -> void:
		var faces := PlanetPatchMesh.collision_faces(arrays)
		commit.call_deferred(key, faces)
	))


func _commit_faces(key: String, faces: PackedVector3Array) -> void:
	_in_flight -= 1
	_faces_pending.erase(key)
	var entry: CacheEntry = _cache.get(key)
	if entry:
		entry.faces = faces
		entry.has_faces = true


func _gather_leaves(node: QuadNode, out: Array) -> void:
	if node.children.is_empty():
		out.append(node)
		return
	for child in node.children:
		_gather_leaves(child, out)


## --- Introspection (tests, HUD debug) -----------------------------------------

func stats() -> Dictionary:
	var leaves: Array = []
	for root in _roots:
		_gather_leaves(root, leaves)
	var deepest: int = 0
	for node in leaves:
		deepest = maxi(deepest, node.depth)
	return {
		"leaves": leaves.size(),
		"max_depth": deepest,
		"cache": _cache.size(),
		"in_flight": _in_flight,
		"colliders": _collider_nodes.size(),
	}


func is_quiescent() -> bool:
	return _in_flight == 0 and _building.is_empty() and _faces_pending.is_empty()
