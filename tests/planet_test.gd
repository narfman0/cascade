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
	_test_authored_maps()
	_test_patch_determinism()
	_test_seam_agreement()
	_test_spin_is_analytic()
	_test_site_orientation()
	await _test_site_streaming()
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


## --- PR3: authored maps -------------------------------------------------------

## The committed maps are the milestone. This checks three things at once, all of
## which have failed in obvious ways before: that Godot's importer did not
## VRAM-compress the 16-bit split-channel height encoding into garbage, that the
## raster is oriented in the game's equirect convention, and that it is real
## Earth rather than something plausible-looking. A wrong orientation or a broken
## decode both show up as a land fraction nowhere near 0.29.
func _test_authored_maps() -> void:
	print("\n== authored maps ==")
	var earth := _system.get_body(&"earth")
	var surface: BodySurface = earth.def.surface
	_check(surface.authored_height != null, "Earth has an authored height map")
	_check(surface.authored_albedo != null, "Earth has an authored albedo map")
	_check(surface.night_emissive != null, "Earth has an authored night-lights map")
	_check(surface.has_authored_height(),
		"the height map decoded to usable CPU pixels")
	_check(is_equal_approx(surface.sea_level, 0.0),
		"sea level is the map's datum, not a tuned constant",
		"(%.3f)" % surface.sea_level)

	var sampler := surface.make_sampler()
	# Area-weighted land fraction over a coarse grid. Real Earth is 0.292.
	var land: float = 0.0
	var total: float = 0.0
	for iy in 90:
		var lat: float = (float(iy) + 0.5) / 90.0 * PI - PI / 2.0
		var weight: float = cos(lat)
		for ix in 180:
			var lon: float = (float(ix) + 0.5) / 180.0 * TAU - PI
			var dir := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
			total += weight
			if not sampler.is_sea(dir):
				land += weight
	var fraction: float = land / total
	_check(absf(fraction - 0.292) < 0.03, "land covers the right share of the globe",
		"(%.3f vs 0.292)" % fraction)

	# Orientation, spot-checked where getting it wrong is unmistakable.
	_check(sampler.is_sea(_dir(0.0, -150.0)), "the mid-Pacific is ocean")
	_check(sampler.is_sea(_dir(30.0, -40.0)), "the mid-Atlantic is ocean")
	_check(not sampler.is_sea(_dir(23.0, 10.0)), "the Sahara is land")
	_check(not sampler.is_sea(_dir(28.0, 87.0)), "the Himalaya is land")
	_check(sampler.height_normalized(_dir(28.0, 87.0)) > 0.6,
		"the Himalaya is the high ground",
		"(%.2f)" % sampler.height_normalized(_dir(28.0, 87.0)))
	_check(not sampler.is_sea(_dir(40.75, -73.98)),
		"New York sits on land, not in its own harbour")


func _dir(lat_deg: float, lon_deg: float) -> Vector3:
	var lat: float = deg_to_rad(lat_deg)
	var lon: float = deg_to_rad(lon_deg)
	return Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))


## --- PR3: detail sites --------------------------------------------------------

## The anchor frame, checked as geometry rather than by eye: it must sit on the
## surface, stand up along the local normal, and turn with the body. A site whose
## frame is mirrored or whose up-axis is wrong builds a city lying on its side.
func _test_site_orientation() -> void:
	print("\n== site anchor ==")
	var earth := _system.get_body(&"earth")
	var surface := earth.planet_surface()
	var site: DetailSite = earth.def.surface.sites[0]
	_check(site.id == &"nyc", "Earth carries the New York site")
	_check(site.scene != null, "the site has a scene to stream")
	_check(site.height_inset != null, "the site has a height inset")

	surface.update_spin(0.0)
	var xf: Transform3D = surface.site_transform(&"nyc")
	var centre: Vector3 = surface.global_position
	var out: Vector3 = (xf.origin - centre).normalized()
	_check(absf((xf.origin - centre).length() - earth.def.radius) < earth.def.radius * 0.05,
		"the anchor sits on the surface",
		"(%.1f m vs r=%.0f)" % [(xf.origin - centre).length(), earth.def.radius])
	_check(xf.basis.y.normalized().dot(out) > 0.999,
		"local +Y is the outward normal (the scene is authored flat)")
	_check(absf(xf.basis.x.dot(xf.basis.y)) < 0.001
			and absf(xf.basis.z.dot(xf.basis.y)) < 0.001,
		"the tangent frame is orthogonal")
	_check(xf.basis.x.cross(xf.basis.y).dot(xf.basis.z) > 0.999,
		"the tangent frame is right-handed (a mirrored site mirrors its city)")

	# The anchor is a child of the surface node, so spin carries it. Half a
	# rotation must put it on the far side of the spin axis.
	var axis := Vector3(
		0.0, cos(earth.def.spin_axis_tilt), sin(earth.def.spin_axis_tilt)).normalized()
	surface.update_spin(earth.def.spin_period * 0.5)
	var half: Vector3 = surface.site_transform(&"nyc").origin - centre
	var expected: Vector3 = out.rotated(axis, PI) * (xf.origin - centre).length()
	_check((half - expected).length() < 1.0,
		"half a spin period puts the site antipodal about the spin axis",
		"(%.2f m off)" % (half - expected).length())
	surface.update_spin(0.0)


## In at 3 km, out at 4 km, and — the point of the gap — nothing happens in
## between. Parking on the boundary is a normal thing for a player to do; a site
## that streams on the same threshold it streams off would instantiate and free a
## hundred buildings every evaluation tick.
func _test_site_streaming() -> void:
	print("\n== site streaming ==")
	var earth := _system.get_body(&"earth")
	var surface := earth.planet_surface()

	await _settle_over_site(earth, 6000.0)
	_check(not surface.site_resident(&"nyc"), "site is out at 6 km")

	await _settle_over_site(earth, 2500.0)
	_check(surface.site_resident(&"nyc"), "site streams in inside 3 km")
	var anchor := surface.get_node_or_null("Site_nyc")
	_check(anchor != null and anchor.get_child_count() > 0,
		"the site scene is instantiated under the anchor")
	if anchor != null:
		var city := anchor.get_child(0)
		var built: int = int(city.call("building_count")) if city.has_method(
			"building_count") else 0
		_check(built > 40, "the diorama placed a skyline", "(%d buildings)" % built)
		_check(city.find_children("*", "PhysicsBody3D", true, false).is_empty(),
			"the site scene carries no physics bodies")

	# Hysteresis, both ways. From inside, 3.5 km must NOT release; from outside,
	# 3.5 km must NOT acquire. Same distance, two different answers — that is
	# what "no thrash at the boundary" means.
	await _settle_over_site(earth, 3500.0)
	_check(surface.site_resident(&"nyc"),
		"3.5 km does not release a site that is already in")

	await _settle_over_site(earth, 4500.0)
	_check(not surface.site_resident(&"nyc"), "site streams out past 4 km")
	_check(surface.get_node_or_null("Site_nyc") == null
			or not is_instance_valid(surface.get_node_or_null("Site_nyc")),
		"the anchor is released with it")

	await _settle_over_site(earth, 3500.0)
	_check(not surface.site_resident(&"nyc"),
		"3.5 km does not acquire a site that is already out")

	# And the pinned refinement follows the site rather than the camera.
	await _settle_over_site(earth, 2500.0)
	var stats: Dictionary = surface.stats()
	_check(int(stats["max_depth"]) >= surface.site_min_depth,
		"a resident site pins its patches to site_min_depth",
		"(%d ≥ %d)" % [stats["max_depth"], surface.site_min_depth])
	await _settle_over_site(earth, 6000.0)
	_check(not surface.site_resident(&"nyc"), "site released on climb-out")


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
	# Hold until the camera has caught up, not for a fixed number of frames: the
	# rig smooths on a half-life against the process delta, and headless process
	# frames are sub-millisecond, so four frames move it a couple of metres out of
	# a several-kilometre jump. The error metric is a *camera* metric, so a
	# lagging rig reports a far shallower tree than the distance actually asks for.
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		var where: Vector3 = OriginShift.to_render(body.true_pos) + dir * distance
		_ship.global_position = where
		await get_tree().physics_frame
		if cam == null or cam.global_position.distance_to(where) < 20.0:
			break
	return await _settle_surface(surface)


## Park the ship `distance` metres from the New York site, looking down at it, and
## let the surface settle. Distance is measured to the *site*, not to the body's
## centre, because that is what the streamer's thresholds are measured against.
## The site is re-read every hold frame: the planet is spinning underneath.
func _settle_over_site(body: CelestialBody, distance: float) -> Dictionary:
	var surface := body.planet_surface()
	_ship.freeze = true
	# Wait for the *camera* to arrive, not just the ship. The rig follows on a
	# 0.12 s half-life against the process delta, and headless process frames are
	# sub-millisecond, so a fixed number of hold frames leaves it hundreds of
	# metres short — long enough to read a stale streaming decision, and a site
	# pins its own patch depth so the leaf count settles even while the camera is
	# still moving.
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		var xf: Transform3D = surface.site_transform(&"nyc")
		var out: Vector3 = (xf.origin - surface.global_position).normalized()
		_ship.global_position = xf.origin + out * distance
		# Up is the site's local north: `out` is the negative of the look
		# direction and would make look_at degenerate.
		_ship.look_at(xf.origin, xf.basis.z)
		await get_tree().physics_frame
		if cam == null:
			break
		if absf((cam.global_position - xf.origin).length() - distance) < 20.0:
			break
	return await _settle_surface(surface)


## Settle until refinement *stops changing*, not until the first quiet moment.
## A split only commits once all four children have been built, so the queue
## empties between rounds and `is_quiescent()` goes true partway down the tree —
## waiting on it alone reports a far shallower surface than the metric asks for.
##
## Bounded by wall clock, not by a frame count. Headless frames are far faster
## than the worker pool, so a frame budget that looks generous can expire in well
## under a second and report a surface that simply has not been built yet.
func _settle_surface(surface: PlanetSurface) -> Dictionary:
	var previous := {}
	var stable_rounds: int = 0
	var deadline: int = Time.get_ticks_msec() + 30000
	while stable_rounds < 3 and Time.get_ticks_msec() < deadline:
		surface.force_evaluate()
		await get_tree().process_frame
		if not surface.is_quiescent():
			stable_rounds = 0
			continue
		var now: Dictionary = surface.stats()
		if previous.size() > 0 and now["leaves"] == previous["leaves"] \
				and now["max_depth"] == previous["max_depth"] \
				and now["sites"] == previous["sites"]:
			stable_rounds += 1
		else:
			stable_rounds = 0
		previous = now
	await get_tree().physics_frame
	await get_tree().physics_frame
	return surface.stats()
