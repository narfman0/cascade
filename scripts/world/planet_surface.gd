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
## Detail sites: an authored place (NYC) streams its scene in inside
## `site_enter_distance` and out past `site_exit_distance`, so hovering at the
## boundary cannot thrash. The scene is authored flat and anchored to the sphere
## tangent here; because the anchor hangs under this node it turns with the spin
## for free. A resident site also pins its patches to `site_min_depth` — the
## error metric alone leaves ~12 m vertex spacing at the altitude a site is read
## from, and the inset has nothing that coarse to say.
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

## 8 since Track TF: L3 data is 0.77 m/texel, and depth 8 (0.38 m verts)
## keeps the mesh out-resolving the data 2:1 as it always has. The footprint
## pins bound how much of the tree ever reaches it.
@export var max_depth: int = 8

## Patch/collision builds in flight per body. Approach streams, never hitches.
@export var max_in_flight: int = 4

## LRU cache budget of built patches.
# Measured, not estimated, and raised twice for the same reason: eviction cannot
# drop entries that are live or shallow, so a cache smaller than the working set
# saves no memory and only thrashes. A depth-5 settle over Earth held ~300
# entries (512 was enough); pinning the patches under a resident detail site to
# depth 6 takes a 2.6 km settle to 429 leaves and 570 entries. 1024 x 33^2 verts
# is ~36 MB, which buys headroom for a second site without another measurement.
@export var cache_capacity: int = 1024

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

## Detail-site streaming distances, observer to site. Hysteresis: parking at the
## boundary must not thrash a scene in and out (design doc: in at 3 km, out at 4).
@export var site_enter_distance: float = 3000.0
@export var site_exit_distance: float = 4000.0

## L2 height-tile streaming margins, degrees from the observer's sub-body
## point to a tile's footprint. Enter is generous on purpose: a tile must be
## resident BEFORE the error metric builds depth-3+ patches over it, so no
## live deep patch is ever built against the wrong tile set. The enter/exit
## gap is the usual anti-thrash hysteresis.
@export var tile_enter_margin_deg: float = 14.0
@export var tile_exit_margin_deg: float = 28.0
## L3 (Track TF) is 4× the data per tile over a quarter the footprint: a
## tighter ring around the sub-observer point, same hysteresis idea.
@export var tile3_enter_margin_deg: float = 6.0
@export var tile3_exit_margin_deg: float = 12.0

## Cached patches at or above this depth are purged when their tile's
## residency changes — shallower ones sample coarser than the L1/L2
## difference can express and stay valid across the swap.
@export var tile_purge_depth: int = 3

## Patches overlapping a resident site refine to at least this depth regardless
## of the error metric. At Earth's radius that is a 49 m patch — 1.5 m vertex
## spacing — which is what makes a 512² inset over a 400 m footprint mean
## anything. The metric alone stops at depth 3 from 2 km up.
@export var site_min_depth: int = 6

## Equirect bake WIDTH (the map is 2:1). Only the normal map is baked for a body
## with authored albedo and night lights. 768 is a measured ceiling, not a taste:
## a bake costs ~2.7 us per texel in GDScript and fourteen bodies bake at once
## during bootstrap, so doubling it doubles how long every body stays flat.
@export var bake_size: int = 768

var surface_res: BodySurface
var radius: float = 1000.0
var spin_period: float = 0.0
var spin_axis_tilt: float = 0.0

## Atmosphere parameters, or null for an airless body (which then keeps the
## hard terminator and black limb — that look is load-bearing, see PR4).
var atmosphere: BodyAtmosphere = null

## True once both scattering LUTs are baked and the shell is live.
var atmosphere_ready: bool = false

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
var _in_flight: int = 0
var _task_ids: Array[int] = []
var _eval_accum: float = 0.0
var _spin_angle: float = 0.0
var _ratio: float = 1.0
var _skim_body: StaticBody3D = null
var _skim_ship: RigidBody3D = null
## A second footprint pin: the WALKING suit (set by eva_controller while its
## boots are on this body). Terrain under a walker converges to max depth just
## like under the ship, so ground steps stay centimetre-scale underfoot.
var walker_pin: Node3D = null
var _collider_nodes: Dictionary = {}
var _atmo_shell: MeshInstance3D = null
var _atmo_material: ShaderMaterial = null
var _cloud_layer: MeshInstance3D = null
var _tile_pending: Dictionary = {}

## Per-site runtime state, keyed by DetailSite.id.
var _sites: Dictionary = {}


class QuadNode extends RefCounted:
	var face: int
	var depth: int
	var x: int
	var y: int
	var key: String
	var center: Vector3
	var mi: MeshInstance3D = null
	var children: Array = []


class SiteState extends RefCounted:
	var site: DetailSite
	var dir: Vector3
	var local_pos: Vector3
	var basis: Basis
	var angular_radius: float
	var resident: bool = false
	var anchor: Node3D = null


class CacheEntry extends RefCounted:
	var key: String
	var depth: int
	var arrays: Dictionary
	var mesh: ArrayMesh
	var tick: int = 0
	var refs: int = 0
	var shape: ConcavePolygonShape3D = null


func setup(
	p_surface: BodySurface, p_radius: float, p_spin_period: float,
	p_spin_axis_tilt: float, p_base_color: Color, p_roughness: float,
	p_atmosphere: BodyAtmosphere = null, p_limb_darkening: float = 0.0
) -> void:
	surface_res = p_surface
	radius = p_radius
	spin_period = p_spin_period
	spin_axis_tilt = p_spin_axis_tilt
	atmosphere = p_atmosphere
	# Sites are metres on the sphere, so their angular extent needs the radius.
	surface_res.prepare(radius)
	# The terrain's physics body exists from birth: colliders mirror rendered
	# leaves at EVERY distance (the collision=visible rule), not just once a
	# ship has dipped into skim range. Roots attach their colliders during
	# this same setup call.
	_skim_body = StaticBody3D.new()
	_skim_body.name = "TerrainColliders"
	_skim_body.collision_layer = 8   # environment
	_skim_body.collision_mask = 0
	add_child(_skim_body)
	_build_site_states()

	_material = ShaderMaterial.new()
	_material.shader = load("res://assets/shaders/planet_surface.gdshader")
	_material.set_shader_parameter("base_color", p_base_color)
	_material.set_shader_parameter("roughness_value", p_roughness)
	if p_limb_darkening > 0.0:
		_material.set_shader_parameter("limb_darkening", p_limb_darkening)
	if atmosphere != null:
		# The twilight band is derived from the atmosphere's scale height and
		# drives the city-light gate, so lights and sky fade across the SAME
		# band at the terminator (PR4 requirement). Airless bodies keep the
		# shader's hard defaults.
		var gate: Vector2 = atmosphere.night_gate()
		_material.set_shader_parameter("night_gate_lo", gate.x)
		_material.set_shader_parameter("night_gate_hi", gate.y)
		_build_atmosphere_shell()
		_start_atmo_bake()

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
		# never runs against a scaled world. Nothing this far away is a site.
		_release_all_sites()
		for root in _roots:
			_merge(root)
		_evict_overflow()
		return
	var eye: Variant = _observer_position()
	if eye == null:
		return
	var cam_pos: Vector3 = eye
	_update_sites(cam_pos)
	_update_tile_streaming(cam_pos)
	var amp_m: float = radius * surface_res.amplitude
	for root in _roots:
		_update_node(root, cam_pos, amp_m)
	_evict_overflow()


## Whose eye drives refinement and site streaming. The viewport camera is the
## honest answer — it is what the error metric is a screen-space error *of* —
## with the tracked ship as the fallback for a frame before the rig exists.
func _observer_position() -> Variant:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		return cam.global_position
	var ship := OriginShift.tracked
	if ship != null and is_instance_valid(ship):
		return (ship as Node3D).global_position
	return null


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
	# Two pins: resident sites (their insets need the detail), and the skim
	# ship's footprint (LD4). The ship pin is the transition-EARLIER rule: the
	# terrain a hull might touch must be converged at max depth before the
	# hull enters the relief band — splits complete on approach out at skim
	# range, and merges wait until the hull leaves. Without it, the camera
	# receding on climb-out merges patches right under a hull five metres off
	# the deck, and the error-metric-driven splits chase the camera down
	# during descent. The swap guard (_swap_guarded) stays as a backstop, but
	# with this pin nothing should ever swap beneath a hull.
	var pinned := (node.depth < site_min_depth and _overlaps_resident_site(node)) \
		or (node.depth < max_depth and _overlaps_skim_ship(node))
	if node.children.is_empty():
		_update_morph(node, err, pinned)
		if (pinned or err > subdivide_threshold) and node.depth < max_depth:
			_try_split(node)
	elif not pinned and err < subdivide_threshold / merge_hysteresis:
		_merge(node)
	else:
		for child in node.children:
			_update_node(child, cam_pos, amp_m)


## Geomorph factor (PR5): 0 renders the patch as its parent's surface, 1 as
## its own. A patch splits into children when err reaches the threshold, so
## children arrive at err ~ threshold/2 — morph 0, identical to the parent
## they replace — and reach full detail by 0.75x threshold on approach. The
## merge hysteresis sits below the morph-0 point, so coarsening is a swap
## between two identical renderings too. Site-pinned patches skip morphing:
## their insets need the full-detail surface regardless of the error metric.
func _update_morph(node: QuadNode, err: float, pinned: bool) -> void:
	if node.mi == null or node.depth == 0:
		return
	var m: float = 1.0 if pinned \
		else clampf((err / subdivide_threshold - 0.5) * 4.0, 0.0, 1.0)
	node.mi.set_instance_shader_parameter(&"morph_t", m)


## Does this patch cover any part of a streamed-in site? Compared as angles on
## the unit sphere, so it is independent of spin and of the proxy scale.
## The spherical cap the skim ship's footprint pins to max depth. 150 m of
## ground radius keeps the hull well clear of any pinned/unpinned boundary.
func _overlaps_skim_ship(node: QuadNode) -> bool:
	if walker_pin != null and is_instance_valid(walker_pin):
		var dir_w: Vector3 = to_local(walker_pin.global_position).normalized()
		var reach_w: float = PlanetPatchMesh.span_m(radius, node.depth) * 0.75 / radius
		if dir_w.angle_to(node.center.normalized()) < 150.0 / radius + reach_w:
			return true
	if _skim_ship == null or not is_instance_valid(_skim_ship):
		return false
	# From 2.5 km of altitude, not skim range: at approach speeds the pin
	# needs tens of seconds of lead to finish its worker builds, so the
	# ground under an incoming ship is final geometry (mesh AND collider)
	# well before anything can touch it.
	if not skim_active:
		var alt: float = (_skim_ship.global_position - global_position).length() \
			- radius * _ratio
		if alt > 2500.0 or body_is_proxy:
			return false
	var local: Vector3 = to_local(_skim_ship.global_position)
	if local.length_squared() < 1e-6:
		return false
	var dir: Vector3 = node.center.normalized()
	var reach: float = PlanetPatchMesh.span_m(radius, node.depth) * 0.75 / radius
	return dir.angle_to(local.normalized()) < 150.0 / radius + reach


func _overlaps_resident_site(node: QuadNode) -> bool:
	if _sites.is_empty():
		return false
	var dir: Vector3 = node.center.normalized()
	# Half-diagonal of the patch, generously rounded up to a spherical cap.
	var reach: float = PlanetPatchMesh.span_m(radius, node.depth) * 0.75 / radius
	for state in _sites.values():
		if not state.resident:
			continue
		if dir.angle_to(state.dir) < state.angular_radius + reach:
			return true
	return false


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
	# The footprint swap guard (LD4): while a hull hugs the ground, never
	# change the colliders beneath it — a fresh trimesh materializing under
	# a live hull is a solver ejection. The mesh may still refine; the
	# collider set catches up once the hull is clear.
	if _swap_guarded(node):
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
	# Children now carry both render and collision for this square.
	_sync_collider(node, false)


func _merge(node: QuadNode) -> void:
	if node.children.is_empty():
		return
	if _swap_guarded(node):
		return
	# Re-arm the parent's collider BEFORE freeing the children's: at no
	# instant is this square of ground intangible.
	if node.mi:
		_sync_collider(node, true)
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
	# Vertices are body-local now, so the patch node sits at the body origin.
	mi.position = Vector3.ZERO
	mi.material_override = _material
	# A freshly attached patch renders as its parent did (morph 0) and morphs
	# in as the camera closes; roots have no parent level to morph from.
	mi.set_instance_shader_parameter(&"morph_t", 1.0 if node.depth == 0 else 0.0)
	add_child(mi)
	node.mi = mi
	_sync_collider(node, true)


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
	# High priority: patch geometry is the interactive path. WorkerThreadPool
	# caps *low* priority tasks at a fraction of its threads, and the one-off
	# texture bakes below are low priority and slow — leaving patch builds at the
	# default put them in a queue behind fourteen bodies' worth of baking, which
	# stalled refinement for seconds after bootstrap.
	_task_ids.append(WorkerThreadPool.add_task(func() -> void:
		var arrays := PlanetPatchMesh.build_arrays(srf, r, face, depth, x, y, sd)
		# Collision is built WITH the mesh, on the same worker: a patch's
		# collider exists the instant its mesh can render, so the visible
		# surface and the physical one can never diverge (the owner fell
		# through hills the sea-level sphere didn't know about).
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(PlanetPatchMesh.collision_faces(arrays))
		commit.call_deferred(arrays, depth, shape)
	, true))


func _commit_build(arrays: Dictionary, depth: int, shape: ConcavePolygonShape3D = null) -> void:
	_in_flight -= 1
	_building.erase(arrays["key"])
	if not _cache.has(arrays["key"]):
		_store_entry(arrays, depth, shape)


func _store_entry(arrays: Dictionary, depth: int, shape: ConcavePolygonShape3D = null) -> CacheEntry:
	var mesh_arrays: Array = []
	mesh_arrays.resize(Mesh.ARRAY_MAX)
	mesh_arrays[Mesh.ARRAY_VERTEX] = arrays["verts"]
	mesh_arrays[Mesh.ARRAY_NORMAL] = arrays["normals"]
	mesh_arrays[Mesh.ARRAY_INDEX] = arrays["indices"]
	# Geomorph targets ride along as custom attributes (PR5).
	mesh_arrays[Mesh.ARRAY_CUSTOM0] = arrays["parent_pos"]
	mesh_arrays[Mesh.ARRAY_CUSTOM1] = arrays["parent_nrm"]
	var flags: int = \
		(Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh_arrays, [], {}, flags)
	var entry := CacheEntry.new()
	entry.key = arrays["key"]
	entry.depth = depth
	entry.arrays = arrays
	entry.mesh = mesh
	if shape == null:
		# Synchronous path (roots at setup): build the shape here.
		shape = ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(PlanetPatchMesh.collision_faces(arrays))
	entry.shape = shape
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


## Drain outstanding worker tasks before this node goes away.
##
## Patch, bake and collision builds run on WorkerThreadPool and capture
## references into this node. Nothing awaited them at shutdown, so Godot blocked
## on the pool while the scene tore down: every headless suite printed its
## results and then hung at 0% CPU instead of exiting, which made the runs look
## like timeouts to anyone reading exit codes rather than logs.
func _exit_tree() -> void:
	for id in _task_ids:
		WorkerThreadPool.wait_for_task_completion(id)
	_task_ids.clear()


func _reap_tasks() -> void:
	var i := 0
	while i < _task_ids.size():
		if WorkerThreadPool.is_task_completed(_task_ids[i]):
			WorkerThreadPool.wait_for_task_completion(_task_ids[i])
			_task_ids.remove_at(i)
		else:
			i += 1


## --- Atmosphere shell (PR4) ----------------------------------------------------

## Back-face sphere at radius*(1+height_fraction), hanging under this node so
## it inherits both the proxy scale and (harmlessly — spheres are symmetric)
## the spin. Inheriting the scale IS the proxy contract: the shell can never
## detach from its planet at range because they scale through the same path.
func _build_atmosphere_shell() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 96
	sphere.rings = 48

	# Two passes on one mesh (Track SL4): extinction multiplies the scene by
	# per-channel transmittance, then its next_pass adds the in-scatter — the
	# composite is exact per channel, no scalar-alpha compromise. Both march
	# the same ray (atmosphere_common.gdshaderinc) with the same parameters.
	_atmo_material = ShaderMaterial.new()
	_atmo_material.shader = load("res://assets/shaders/atmosphere_extinction.gdshader")
	# Under any transparent local FX: the shell is the farthest haze there is.
	_atmo_material.render_priority = -15
	var inscatter := ShaderMaterial.new()
	inscatter.shader = load("res://assets/shaders/atmosphere.gdshader")
	_atmo_material.next_pass = inscatter
	for mat in [_atmo_material, inscatter]:
		mat.set_shader_parameter("height_fraction", atmosphere.height_fraction)
		mat.set_shader_parameter("rayleigh_scatter", atmosphere.rayleigh_coefficients)
		mat.set_shader_parameter("rayleigh_h", atmosphere.rayleigh_scale_height)
		mat.set_shader_parameter("mie_scatter", atmosphere.mie_coefficient)
		mat.set_shader_parameter("mie_absorb", atmosphere.mie_absorption)
		mat.set_shader_parameter("mie_h", atmosphere.mie_scale_height)
		mat.set_shader_parameter("mie_g", atmosphere.mie_g)
		mat.set_shader_parameter("ozone_absorb", atmosphere.ozone_absorption)
		mat.set_shader_parameter("ozone_center", atmosphere.ozone_center)
		mat.set_shader_parameter("ozone_width", atmosphere.ozone_width)
		mat.set_shader_parameter("sun_intensity", atmosphere.sun_intensity)

	_atmo_shell = MeshInstance3D.new()
	_atmo_shell.name = "AtmosphereShell"
	_atmo_shell.mesh = sphere
	_atmo_shell.material_override = _atmo_material
	_atmo_shell.scale = Vector3.ONE * (radius * (1.0 + atmosphere.height_fraction))
	_atmo_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The camera sits inside this mesh while skimming; give the culler margin
	# so grazing framings never drop the shell mid-flight.
	_atmo_shell.extra_cull_margin = radius * 0.1
	add_child(_atmo_shell)


## LUT bake on the worker pool, exactly the texture-bake pattern below: arrays
## on the worker, texture upload on the main thread, task id drained in
## _exit_tree. Until the commit lands the shell renders as nothing (luts_ok
## false), the same never-a-hole rule the surface bake follows.
func _start_atmo_bake() -> void:
	var atmo := atmosphere
	var commit: Callable = _commit_atmo_luts
	_task_ids.append(WorkerThreadPool.add_task(func() -> void:
		var t_lut := AtmosphereMath.bake_transmittance(atmo)
		var ms_lut := AtmosphereMath.bake_multi_scatter(atmo, t_lut)
		commit.call_deferred(t_lut, ms_lut)
	))


func _commit_atmo_luts(t_lut: Dictionary, ms_lut: Dictionary) -> void:
	if _atmo_material == null:
		return
	var t_tex := _lut_texture(t_lut)
	var ms_tex := _lut_texture(ms_lut)
	for mat in [_atmo_material, _atmo_material.next_pass as ShaderMaterial]:
		mat.set_shader_parameter("transmittance_lut", t_tex)
		mat.set_shader_parameter("ms_lut", ms_tex)
		mat.set_shader_parameter("luts_ok", true)
	atmosphere_ready = true


static func _lut_texture(lut: Dictionary) -> ImageTexture:
	var img := Image.create_from_data(
		lut["w"], lut["h"], false, Image.FORMAT_RGBF,
		(lut["data"] as PackedFloat32Array).to_byte_array())
	return ImageTexture.create_from_image(img)


## The shell node, or null for an airless body. Tests assert both ways.
func atmosphere_shell() -> MeshInstance3D:
	return _atmo_shell


## Build the translucent cloud deck (PR5). Called by CelestialBody after
## setup for bodies whose BodyDef asks for one; hangs under this node so spin
## and the proxy scale carry it exactly like the shell.
func configure_clouds(
	height_fraction: float, coverage: float, cloud_map: Texture2D = null
) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 96
	sphere.rings = 48

	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/cloud_layer.gdshader")
	mat.set_shader_parameter("coverage", coverage)
	if cloud_map != null:
		mat.set_shader_parameter("coverage_map", cloud_map)
		mat.set_shader_parameter("has_coverage_map", true)
	# Below the atmosphere shell (-15): haze composites over the clouds.
	mat.render_priority = -16

	# Cloud shadows: the surface darkens itself under the same field the deck
	# draws (cloud_field.gdshaderinc). Both materials are parameterized HERE,
	# from one set of values, so they can never disagree about the weather.
	_material.set_shader_parameter("cloud_shadows", true)
	_material.set_shader_parameter("cloud_coverage", coverage)
	_material.set_shader_parameter("cloud_height_fraction", height_fraction)
	if cloud_map != null:
		_material.set_shader_parameter("cloud_map", cloud_map)
		_material.set_shader_parameter("cloud_has_map", true)

	_cloud_layer = MeshInstance3D.new()
	_cloud_layer.name = "CloudLayer"
	_cloud_layer.mesh = sphere
	_cloud_layer.material_override = mat
	_cloud_layer.scale = Vector3.ONE * (radius * (1.0 + height_fraction))
	_cloud_layer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_cloud_layer)


func cloud_layer() -> MeshInstance3D:
	return _cloud_layer


## The shared surface material (tests inspect the night-gate uniforms).
func material() -> ShaderMaterial:
	return _material


## Per-body sun direction (Track SL5), world space, driven by SolarSystem
## every frame. One value feeds everything that shades this body: the surface
## lighting and night gate, the cloud shadows, and the atmosphere shell.
func set_sun_direction(dir: Vector3) -> void:
	_material.set_shader_parameter("body_sun_dir", dir)
	if _atmo_material != null:
		_atmo_material.set_shader_parameter("body_sun_dir", dir)
		var next: Material = _atmo_material.next_pass
		if next is ShaderMaterial:
			(next as ShaderMaterial).set_shader_parameter("body_sun_dir", dir)


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


## Authored rasters win over the bake wherever they exist: an equirect map that
## already is the surface is strictly better than a palette's guess at it, and
## PlanetBake skips producing what it would only be overwriting.
func _commit_bake(images: Dictionary) -> void:
	if surface_res.authored_albedo != null:
		_material.set_shader_parameter("albedo_tex", surface_res.authored_albedo)
		if surface_res.sea_level > -1.0:
			# Track SL7: the cooked albedo's alpha is the sea mask; only an
			# authored albedo on a body WITH a sea actually encodes it.
			_material.set_shader_parameter("has_sea_spec", true)
	else:
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


## --- Detail sites ---------------------------------------------------------------

func _build_site_states() -> void:
	var sampler := surface_res.make_sampler()
	for site in surface_res.sites:
		if site == null or site.id == &"":
			continue
		var state := SiteState.new()
		state.site = site
		state.dir = site.direction()
		# Sit the anchor on the terrain, sea clamp included, so a coastal site is
		# never left hanging over its own harbour.
		state.local_pos = state.dir * (radius * (1.0 + sampler.height(state.dir)))
		state.basis = Basis(site.east(), state.dir, site.north())
		state.angular_radius = site.angular_radius(radius)
		_sites[site.id] = state


## World position of a site right now — spin included, since the anchor rides
## this node's transform. Tests use it to check the tangent frame turns with the
## planet.
func site_transform(id: StringName) -> Transform3D:
	var state: SiteState = _sites.get(id)
	if state == null:
		return Transform3D.IDENTITY
	return global_transform * Transform3D(state.basis, state.local_pos)


func site_resident(id: StringName) -> bool:
	var state: SiteState = _sites.get(id)
	return state != null and state.resident


func resident_site_count() -> int:
	var n: int = 0
	for state in _sites.values():
		if state.resident:
			n += 1
	return n


## In under `site_enter_distance`, out over `site_exit_distance`, nothing in
## between — the whole point of the gap is that hovering on the boundary is a
## normal thing to do and must not cost a scene instantiation per tick.
func _update_sites(eye: Vector3) -> void:
	for state in _sites.values():
		var dist: float = (site_transform(state.site.id).origin - eye).length()
		if not state.resident and dist < site_enter_distance:
			_instance_site(state)
		elif state.resident and dist > site_exit_distance:
			_release_site(state)


func _instance_site(state: SiteState) -> void:
	state.resident = true
	var anchor := Node3D.new()
	anchor.name = "Site_%s" % state.site.id
	# Authored flat in local XZ with +Y up; this is the whole tangent-orientation
	# contract from the design doc, and it is why authoring a site is ordinary
	# scene work. The anchor is a child of this node, so spin carries it.
	anchor.transform = Transform3D(state.basis, state.local_pos)
	add_child(anchor)
	state.anchor = anchor
	if state.site.scene == null:
		return
	var inst := state.site.scene.instantiate()
	# Configure before entering the tree: a site scene builds itself from the
	# DetailSite, and building twice (once from _ready with defaults, once from
	# here) is pure waste.
	if inst.has_method("setup_site"):
		inst.call("setup_site", state.site, radius)
	# The site's lights must fade across the SAME derived twilight band as the
	# surface shader's night gate — one band for the sky, the map and the
	# diorama (the pre-PR4 hardcoded band drifted from the derived one).
	if atmosphere != null and inst.has_method("set_night_gate"):
		inst.call("set_night_gate", atmosphere.night_gate())
	anchor.add_child(inst)
	_detach_site_physics(inst)


## Site scenes are visual props. A physics body under this rail-driven node hits
## the frozen-kinematic write-back problem: the server rewrites the body's global
## transform one frame behind its moving parent and the local offset accumulates
## without bound. Taking it out of the physics space leaves the tree as the only
## owner of the transform — the same fix, and the same reason, as
## DockingComputer._capture step 3b.
func _detach_site_physics(root: Node) -> void:
	for node in root.find_children("*", "PhysicsBody3D", true, false):
		push_warning(
			"DetailSite scene contains a physics body (%s); detached from the physics space. Site scenes should be visual props only."
			% node.name)
		PhysicsServer3D.body_set_space((node as PhysicsBody3D).get_rid(), RID())


func _release_site(state: SiteState) -> void:
	state.resident = false
	if state.anchor != null and is_instance_valid(state.anchor):
		state.anchor.queue_free()
	state.anchor = null


func _release_all_sites() -> void:
	for state in _sites.values():
		if state.resident:
			_release_site(state)


## --- L2 height-tile streaming ---------------------------------------------------

## Stream the fine height tiles by observer proximity. Load I/O runs on the
## worker pool; the pixel decode and the residency swap happen on the main
## thread (Texture2D.get_image() is not thread-safe — same rule as prepare()).
## Correctness rests on two facts: samplers snapshot the tile dictionary by
## reference (a swap never changes a build in flight), and the enter margin is
## wide enough that a tile is resident before any depth-3+ patch is built over
## it — so a residency change only ever invalidates refs==0 CACHE entries,
## which _purge_stale_patches drops for the refine loop to rebuild.
func _update_tile_streaming(eye: Vector3) -> void:
	if surface_res.l2_available_count() == 0:
		return
	var dir_local: Vector3 = (global_transform.affine_inverse() * eye).normalized()
	for spec in [[2, tile_enter_margin_deg, tile_exit_margin_deg],
			[3, tile3_enter_margin_deg, tile3_exit_margin_deg]]:
		var level: int = spec[0]
		for key in surface_res.wanted_l2_keys(dir_local, spec[1], level):
			if surface_res.is_tile_resident(key) or _tile_pending.has(key):
				continue
			_queue_tile_load(key)
		var keep: Array = surface_res.wanted_l2_keys(dir_local, spec[2], level)
		for key in surface_res.resident_l2_keys(level):
			if not keep.has(key):
				surface_res.release_tile(key)
				_purge_stale_patches(String(key))


func _queue_tile_load(key: String) -> void:
	_tile_pending[key] = true
	var path: String = surface_res.l2_path(key)
	var commit: Callable = _commit_tile_load
	_task_ids.append(WorkerThreadPool.add_task(func() -> void:
		# ResourceLoader.load is thread-safe; it carries the file I/O and the
		# texture decompression, which is the part worth keeping off-frame.
		var tex := load(path) as Texture2D
		commit.call_deferred(key, tex)
	))


func _commit_tile_load(key: String, tex: Texture2D) -> void:
	_tile_pending.erase(key)
	if tex == null:
		push_warning("PlanetSurface: height tile failed to load: %s" % key)
		return
	var img: Image = tex.get_image()
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	surface_res.commit_tile(key, {
		"data": img.get_data(),
		"w": img.get_width(),
		"h": img.get_height(),
	})
	_purge_stale_patches(key)


## Drop cached deep patches overlapping a tile whose residency changed: they
## were built against the other tile set. Live leaves (refs > 0) are left
## alone by design — the streaming margins exist so none are deep enough to
## disagree visibly by the time residency changes under them.
func _purge_stale_patches(key: String) -> void:
	var rect: Array = BodySurface.tile_rect_deg(key)
	var stale: Array = []
	for cache_key in _cache:
		var entry: CacheEntry = _cache[cache_key]
		if entry.depth < tile_purge_depth or entry.refs > 0:
			continue
		var dir: Vector3 = (entry.arrays["center"] as Vector3).normalized()
		var lon := rad_to_deg(atan2(dir.z, dir.x))
		var lat := rad_to_deg(asin(clampf(dir.y, -1.0, 1.0)))
		# Patch half-span as slack, so patches straddling the rect edge purge.
		var slack := rad_to_deg(
			PlanetPatchMesh.span_m(radius, entry.depth) * 0.75 / radius)
		if lon >= rect[0] - slack and lon <= rect[1] + slack \
				and lat >= rect[2] - slack and lat <= rect[3] + slack:
			stale.append(cache_key)
	for cache_key in stale:
		_cache.erase(cache_key)


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


func _exit_skim() -> void:
	skim_active = false
	if _skim_ship != null and is_instance_valid(_skim_ship):
		_skim_ship.continuous_cd = false
	_skim_ship = null
	for key in _collider_nodes:
		_collider_nodes[key].queue_free()
	_collider_nodes.clear()


## Attach or remove the collider that mirrors a node's rendered mesh. The
## shape was built on the same worker as the mesh, so `want=true` can never
## be a frame early or late: what you see is what you hit, at every depth,
## planet-wide. The whole set is enabled/disabled by distance in one place
## (set_collision_active) via the StaticBody's layer.
func _sync_collider(node: QuadNode, want: bool) -> void:
	var have: CollisionShape3D = _collider_nodes.get(node.key)
	if want:
		if have != null:
			return
		var entry: CacheEntry = _cache.get(node.key)
		if entry == null or entry.shape == null:
			return
		var cs := CollisionShape3D.new()
		cs.shape = entry.shape
		cs.position = Vector3.ZERO  # faces are body-local
		_skim_body.add_child(cs)
		_collider_nodes[node.key] = cs
	elif have != null:
		have.queue_free()
		_collider_nodes.erase(node.key)


## The LD4 footprint guard, now guarding the SWAP itself: while the hull is
## inside the relief band and this square is under it, defer split/merge —
## the collider set beneath a live hull must not change (a fresh trimesh
## materializing there is a measured 68 m/s solver ejection). The refinement
## retries every evaluate pass and proceeds the moment the hull is clear.
func _swap_guarded(node: QuadNode) -> bool:
	if _skim_ship == null or not is_instance_valid(_skim_ship):
		return false
	var ship_pos := _skim_ship.global_position
	var alt: float = (ship_pos - global_position).length() - radius * _ratio
	if alt > radius * surface_res.amplitude + 80.0:
		return false
	var span: float = PlanetPatchMesh.span_m(radius, node.depth)
	var world_center: Vector3 = global_transform * node.center
	return world_center.distance_to(ship_pos) < span + 60.0


## Master switch, driven by CelestialBody by distance/proxy: layer 8 collides,
## layer 0 is inert. One flag instead of hundreds of per-shape toggles.
func set_collision_active(active: bool) -> void:
	if _skim_body:
		_skim_body.collision_layer = 8 if active else 0


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
		"sites": resident_site_count(),
	}


func is_quiescent() -> bool:
	return _in_flight == 0 and _building.is_empty()
