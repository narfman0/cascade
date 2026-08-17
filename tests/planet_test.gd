extends Node
## Headless verification for the progressive planet renderer (PR1 + PR2).
##
## Run: godot --headless res://tests/planet_test.tscn
##
## The PR2 gate from docs/tasks.md. Two of these checks are the ones worth having
## and are analytic rather than visual — seam agreement catches the classic
## quadtree crack without a single screenshot, and determinism is what makes the
## rest of the suite meaningful at all.
##
## Note on the software renderer: the test rig runs llvmpipe, so this asserts
## patch *counts* and geometry, never frame times.

const EPS: float = 0.001

var _failures: int = 0
var _world: Node3D
var _system: SolarSystem
var _ship: RigidBody3D


func _ready() -> void:
	_world = load("res://scenes/game_world.tscn").instantiate()
	add_child(_world)
	await get_tree().process_frame
	await get_tree().process_frame
	_system = _world.get_node("SolarSystem")
	_ship = _world.get_node("Ship")

	_test_surfaces_exist()
	_test_patch_determinism()
	_test_seam_agreement()
	_test_spin_is_analytic()
	await _test_approach_refinement()
	await _test_skim_collision()

	print("")
	if _failures == 0:
		print("PASS — all checks green")
	else:
		print("FAIL — %d check(s) failed" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _check(ok: bool, label: String, detail: String = "") -> void:
	if ok:
		print("  ok    %s %s" % [label, detail])
	else:
		_failures += 1
		print("  FAIL  %s %s" % [label, detail])


## --- PR1: surfaces -----------------------------------------------------------

func _test_surfaces_exist() -> void:
	print("\n== surfaces ==")
	var with_surface: int = 0
	for body in _system.bodies:
		if body.planet_surface() != null:
			with_surface += 1
	# Every body except the Sun, which keeps its emissive sphere.
	_check(with_surface == _system.bodies.size() - 1,
		"every body but the Sun has a surface",
		"(%d of %d)" % [with_surface, _system.bodies.size()])
	_check(_system.get_body(&"sun").planet_surface() == null,
		"the Sun kept its plain emissive sphere")

	var earth := _system.get_body(&"earth")
	_check(earth.def.surface.sea_level > -1.0, "Earth has a sea")
	_check(earth.def.surface.city_lights, "Earth has city lights")
	_check(_system.get_body(&"jupiter").def.surface.amplitude <= 0.0001,
		"Jupiter is smooth (banded albedo, no relief)")
	_check(_system.get_body(&"earth").def.spin_period > 0.0, "Earth spins")


## --- PR2: patch geometry -----------------------------------------------------

## Same patch id must produce bit-identical arrays. Everything else in this file
## leans on this: without it, seam and budget checks would be measuring noise.
func _test_patch_determinism() -> void:
	print("\n== determinism ==")
	var earth := _system.get_body(&"earth")
	var surface := earth.planet_surface()
	var a: Dictionary = _build(surface, 2, 3, 1, 2)
	var b: Dictionary = _build(surface, 2, 3, 1, 2)
	var va: PackedVector3Array = a["verts"]
	var vb: PackedVector3Array = b["verts"]
	_check(va.size() == vb.size() and va.size() > 0,
		"patch rebuild has the same vertex count", "(%d)" % va.size())
	var worst: float = 0.0
	for i in mini(va.size(), vb.size()):
		worst = maxf(worst, (va[i] - vb[i]).length())
	_check(worst == 0.0, "patch rebuild is bit-identical", "(max delta %.9f)" % worst)


## Adjacent same-depth patches must agree along their shared edge, or the surface
## shows cracks. Checked analytically on the height function via the patch
## builder, so no rendering is involved.
func _test_seam_agreement() -> void:
	print("\n== seams ==")
	var earth := _system.get_body(&"earth")
	var surface := earth.planet_surface()
	# Two horizontally adjacent patches on the same face and depth.
	var left: Dictionary = _build(surface, 0, 2, 1, 1)
	var right: Dictionary = _build(surface, 0, 2, 2, 1)
	var worst: float = _edge_gap(left, right)
	_check(worst < EPS, "adjacent patches share their edge exactly",
		"(max gap %.6f m)" % worst)

	# Cube-face closure. Rather than guess which patches border each other across
	# faces — the adjacency depends on the face_dir convention — assert the
	# property that matters: the six root patches' 24 corners must collapse onto
	# exactly the cube's 8 corners, each shared by 3 faces. If any face were
	# mis-parameterized or flipped, the shell would not close and the count would
	# not come out.
	var corners: Array[Vector3] = []
	for face in 6:
		var arrays: Dictionary = _build(surface, face, 0, 0, 0)
		for c in _patch_corners(arrays):
			corners.append(c)
	var clusters: Array[Vector3] = []
	var counts: Array[int] = []
	for c in corners:
		var found := false
		for i in clusters.size():
			if (clusters[i] - c).length() < 1.0:
				counts[i] += 1
				found = true
				break
		if not found:
			clusters.append(c)
			counts.append(1)
	var shared_by_three := true
	for n in counts:
		if n != 3:
			shared_by_three = false
	_check(clusters.size() == 8 and shared_by_three,
		"the six cube faces close into a shell",
		"(%d distinct corners, share counts %s)" % [clusters.size(), str(counts)])


## Spin must be a function of sim_time, never accumulated — otherwise time
## compression desynchronises the surface from the orbit.
func _test_spin_is_analytic() -> void:
	print("\n== spin ==")
	var earth := _system.get_body(&"earth")
	var surface := earth.planet_surface()
	var period: float = earth.def.spin_period

	surface.update_spin(0.0)
	var at_zero: Basis = surface.transform.basis
	surface.update_spin(period)
	var at_period: Basis = surface.transform.basis
	var drift: float = (at_zero.x - at_period.x).length()
	_check(drift < 0.01, "a full period returns to the same orientation",
		"(drift %.6f)" % drift)

	surface.update_spin(period * 0.5)
	var half: Basis = surface.transform.basis
	_check((half.x - at_zero.x).length() > 0.5, "half a period is a real rotation")

	# Order independence is the actual proof it is not accumulating.
	surface.update_spin(1234.5)
	var forward: Basis = surface.transform.basis
	surface.update_spin(0.0)
	surface.update_spin(1234.5)
	var again: Basis = surface.transform.basis
	_check((forward.x - again.x).length() < 0.0001,
		"same sim_time gives the same orientation regardless of history")


## --- PR2: refinement + budgets ----------------------------------------------

func _test_approach_refinement() -> void:
	print("\n== approach refinement ==")
	var earth := _system.get_body(&"earth")
	var surface := earth.planet_surface()

	var baseline: Dictionary = await _settle_at(earth, 30000.0)
	var mid: Dictionary = await _settle_at(earth, 6000.0)
	var close: Dictionary = await _settle_at(earth, 2600.0)

	print("    30 km: %s" % baseline)
	print("     6 km: %s" % mid)
	print("   2.6 km: %s" % close)

	_check(close["max_depth"] >= mid["max_depth"]
			and mid["max_depth"] >= baseline["max_depth"],
		"depth never decreases while closing",
		"(%d → %d → %d)" % [baseline["max_depth"], mid["max_depth"], close["max_depth"]])
	_check(close["max_depth"] > baseline["max_depth"],
		"approach actually refines the surface")
	_check(close["max_depth"] <= surface.max_depth,
		"depth respects the cap", "(%d ≤ %d)" % [close["max_depth"], surface.max_depth])
	_check(close["cache"] <= surface.cache_capacity,
		"cache stays within capacity", "(%d ≤ %d)" % [close["cache"], surface.cache_capacity])
	_check(int(close["in_flight"]) <= surface.max_in_flight,
		"in-flight builds stay within budget",
		"(%d ≤ %d)" % [close["in_flight"], surface.max_in_flight])

	# Receding must give the memory back, or streaming leaks over a session.
	var returned: Dictionary = await _settle_at(earth, 30000.0)
	_check(returned["leaves"] <= baseline["leaves"] * 1.5 + 6,
		"receding returns to baseline (no streaming leak)",
		"(%d leaves vs %d baseline)" % [returned["leaves"], baseline["leaves"]])


## --- PR2: skim collision ----------------------------------------------------

func _test_skim_collision() -> void:
	print("\n== skim collision ==")
	var earth := _system.get_body(&"earth")
	var surface := earth.planet_surface()

	# Near enough for the body's collision to be active at all (the pre-existing
	# rule is radius + COLLISION_ACTIVATION_MARGIN), but well outside skim range:
	# here the analytic sphere is the collision truth and no patch carries one.
	var above_skim: float = earth.def.radius + 6000.0
	await _settle_at(earth, above_skim)
	_check(not surface.skim_active, "skim inactive above skim range")
	_check(earth.sphere_collider_enabled(),
		"sphere collider carries collision outside skim range")
	_check(int(surface.stats()["colliders"]) == 0,
		"no patch colliders outside skim range")

	# Low: patch colliders take over and the sphere must stand down. Both halves
	# matter — a live sphere walls the ship out of valleys, and missing patch
	# colliders make the peaks intangible.
	await _settle_at(earth, earth.def.radius + 120.0)
	_check(surface.skim_active, "skim engages near the surface")
	_check(not earth.sphere_collider_enabled(),
		"sphere collider stands down in skim range")
	var stats: Dictionary = surface.stats()
	_check(int(stats["colliders"]) > 0, "patches carry colliders in skim range",
		"(%d)" % stats["colliders"])
	_check(_ship.continuous_cd, "ship CCD is on in skim range")

	# And the swap reverses on climb-out.
	await _settle_at(earth, above_skim)
	_check(not surface.skim_active, "skim disengages on climb-out")
	_check(earth.sphere_collider_enabled(), "sphere collider comes back")
	_check(int(surface.stats()["colliders"]) == 0, "patch colliders released")
	_check(not _ship.continuous_cd, "ship CCD is off again")


## --- Helpers ----------------------------------------------------------------

func _build(surface: PlanetSurface, face: int, depth: int, x: int, y: int) -> Dictionary:
	return PlanetPatchMesh.build_arrays(
		surface.surface_res, surface.radius, face, depth, x, y, surface.skirt_drop
	)


## Largest distance from each vertex on `a`'s +u edge to the nearest vertex on
## `b`'s -u edge. Skirt vertices are excluded — they are meant to hang below.
func _edge_gap(a: Dictionary, b: Dictionary) -> float:
	var av: PackedVector3Array = a["verts"]
	var bv: PackedVector3Array = b["verts"]
	var grid: int = PlanetPatchMesh.GRID
	var worst: float = 0.0
	for row in grid + 1:
		var ai: int = row * (grid + 1) + grid   # last column of a
		var bi: int = row * (grid + 1)          # first column of b
		if ai >= av.size() or bi >= bv.size():
			continue
		var pa: Vector3 = av[ai] + a["center"]
		var pb: Vector3 = bv[bi] + b["center"]
		worst = maxf(worst, (pa - pb).length())
	return worst


## The four grid corners of a patch, in body space.
func _patch_corners(arrays: Dictionary) -> Array[Vector3]:
	var v: PackedVector3Array = arrays["verts"]
	var centre: Vector3 = arrays["center"]
	var n: int = PlanetPatchMesh.GRID + 1
	var out: Array[Vector3] = []
	for idx in [0, n - 1, (n - 1) * n, n * n - 1]:
		if idx < v.size():
			out.append(v[idx] + centre)
	return out


## Park the ship `distance` metres from the body's centre and let the surface
## settle, then report stats. The ship is frozen: the physics server reverts
## transform writes on a live body (standing trap #2).
func _settle_at(body: CelestialBody, distance: float) -> Dictionary:
	var surface := body.planet_surface()
	_ship.freeze = true
	var dir := Vector3(0.0, 1.0, 0.2).normalized()
	for _i in 4:
		_ship.global_position = OriginShift.to_render(body.true_pos) + dir * distance
		await get_tree().physics_frame
	# Settle until refinement *stops changing*, not until the first quiet moment.
	# A split only commits once all four children have been built, so the queue
	# empties between rounds and `is_quiescent()` goes true partway down the
	# tree — waiting on it alone reports a far shallower surface than the metric
	# actually asks for.
	var previous := {}
	var stable_rounds: int = 0
	var guard: int = 0
	while stable_rounds < 3 and guard < 400:
		surface.force_evaluate()
		await get_tree().process_frame
		guard += 1
		if not surface.is_quiescent():
			stable_rounds = 0
			continue
		var now: Dictionary = surface.stats()
		if previous.size() > 0 and now["leaves"] == previous["leaves"] \
				and now["max_depth"] == previous["max_depth"]:
			stable_rounds += 1
		else:
			stable_rounds = 0
		previous = now
	await get_tree().physics_frame
	await get_tree().physics_frame
	return surface.stats()
