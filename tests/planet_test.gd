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
	_test_cloud_climatology()
	_test_height_tiles()
	_test_real_sky()
	await _test_sea_mask()
	_test_patch_determinism()
	_test_seam_agreement()
	_test_geomorph_targets()
	_test_spin_is_analytic()
	_test_site_orientation()
	await _test_site_streaming()
	await _test_canaveral()
	await _test_approach_refinement()
	await _test_tile_streaming()
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
## Real cloud climatology: the deck must sit where Earth's weather actually
## is. A random-noise deck over the Sahara is exactly what this replaces.
func _test_cloud_climatology() -> void:
	print("\n== cloud climatology ==")
	var earth := _system.get_body(&"earth")
	_check(earth.def.cloud_map != null, "Earth carries a cloud-fraction map")
	var cloud_mat: ShaderMaterial = \
		earth.planet_surface().cloud_layer().material_override
	_check(cloud_mat.get_shader_parameter("has_coverage_map") == true,
		"the deck shader is anchored to the map")
	var img: Image = (earth.def.cloud_map as Texture2D).get_image()
	if img.is_compressed():
		img.decompress()
	var sahara := _region_mean(img, 23.0, 10.0)
	var atlantic := _region_mean(img, 55.0, -30.0)
	var itcz := _region_mean(img, 2.0, 20.0)
	_check(sahara < 0.1, "the Sahara is clear", "(%.3f)" % sahara)
	_check(atlantic > 0.2 and itcz > 0.2,
		"storm track and ITCZ are cloudy",
		"(atlantic %.3f, itcz %.3f)" % [atlantic, itcz])

	# Cloud shadows: the surface darkens itself under the same field the deck
	# draws — both parameterized from configure_clouds, and only there.
	var surf_mat: ShaderMaterial = earth.planet_surface().material()
	_check(surf_mat.get_shader_parameter("cloud_shadows") == true
			and surf_mat.get_shader_parameter("cloud_has_map") == true
			and is_equal_approx(
				surf_mat.get_shader_parameter("cloud_coverage"),
				earth.def.cloud_coverage),
		"the ground shadows itself under the deck's own field")
	var moon_mat: ShaderMaterial = _system.get_body(&"moon").planet_surface().material()
	_check(moon_mat.get_shader_parameter("cloud_shadows") == null,
		"airless bodies cast no cloud shadows")


func _region_mean(img: Image, lat_deg: float, lon_deg: float) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var cx := int((lon_deg + 180.0) / 360.0 * float(w))
	var cy := int((90.0 - lat_deg) / 180.0 * float(h))
	var sum := 0.0
	var count := 0
	for dy in range(-16, 17):
		for dx in range(-16, 17):
			var x := clampi(cx + dx, 0, w - 1)
			var y := clampi(cy + dy, 0, h - 1)
			sum += img.get_pixel(x, y).r
			count += 1
	return sum / float(count)


## Fidelity tier: L1 eager, L2 streamed by proximity, and the pyramid must
## actually be consulted, agree with the global layer at the coastline, and
## resolve relief the 2k map cannot.
func _test_height_tiles() -> void:
	print("\n== height tiles ==")
	var earth := _system.get_body(&"earth")
	var ps := earth.planet_surface()
	var surface: BodySurface = ps.surface_res
	_check(surface.tile_count() == 8, "L1 floor is resident at boot",
		"(%d tiles)" % surface.tile_count())
	_check(surface.l2_available_count() >= 24, "L2 set is available to stream",
		"(%d tiles)" % surface.l2_available_count())

	# Continuity across a tile boundary (L1 tiles meet at lon 0): stepping an
	# epsilon across it must not step the terrain.
	var tiled := surface.make_sampler()
	var west := tiled.height_normalized(_dir(46.0, -0.005))
	var east := tiled.height_normalized(_dir(46.0, 0.005))
	_check(absf(west - east) < 0.02, "no step across a tile boundary",
		"(gap %.5f)" % absf(west - east))

	# The coastline datum survives the layer switch: mid-ocean stays sea,
	# the Sahara stays land, through the tiled sampler.
	_check(tiled.is_sea(_dir(0.0, -150.0)) and tiled.is_sea(_dir(30.0, -40.0)),
		"oceans are still oceans through the tiles")
	_check(not tiled.is_sea(_dir(23.0, 10.0)), "the Sahara is still land")


## Fly to the Himalaya: the covering L2 tile must stream in, sharpen the
## terrain beyond what the global map can express, and stream back out when
## the ship leaves. Everest at 28N 87E sits in L2 tile 5,1.
func _test_tile_streaming() -> void:
	print("\n== tile streaming ==")
	var earth := _system.get_body(&"earth")
	var ps := earth.planet_surface()
	var surface: BodySurface = ps.surface_res
	var everest := _dir(28.0, 87.0)

	# Park over the Himalaya (surface-local dir -> world via the spin).
	_ship.freeze = true
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		var world_dir: Vector3 = (ps.global_transform.basis * everest).normalized()
		var where: Vector3 = OriginShift.to_render(earth.true_pos) \
			+ world_dir * (earth.def.radius + 2500.0)
		_ship.global_position = where
		await get_tree().physics_frame
		if cam == null or cam.global_position.distance_to(where) < 30.0:
			break

	deadline = Time.get_ticks_msec() + 20000
	while not surface.is_tile_resident("2:5:1") and Time.get_ticks_msec() < deadline:
		ps.force_evaluate()
		await get_tree().process_frame
	_check(surface.is_tile_resident("2:5:1"),
		"the Himalaya's L2 tile streams in on approach",
		"(resident: %s)" % str(surface.resident_l2_keys()))

	# Sharper than the global map while resident: the highest probe near
	# Everest rises above what 2k averaging can keep.
	var solo := BodySurface.new()
	solo.authored_height = load("res://assets/planets/earth_height.png")
	solo.amplitude = surface.amplitude
	solo.sea_level = surface.sea_level
	solo.prepare(2000.0)
	var global_only := solo.make_sampler()
	var tiled := surface.make_sampler()
	var tiled_max := -2.0
	var solo_max := -2.0
	for dy in range(-6, 7):
		for dx in range(-6, 7):
			var dir := _dir(28.0 + float(dy) * 0.25, 87.0 + float(dx) * 0.25)
			tiled_max = maxf(tiled_max, tiled.height_normalized(dir))
			solo_max = maxf(solo_max, global_only.height_normalized(dir))
	_check(tiled_max > solo_max,
		"the streamed tile resolves the Himalaya sharper than the global map",
		"(tiled %.4f vs global %.4f)" % [tiled_max, solo_max])

	# Leave: fly to the antipode-ish far side; the tile must release.
	deadline = Time.get_ticks_msec() + 15000
	var away := _dir(-28.0, -93.0)
	while Time.get_ticks_msec() < deadline:
		var world_dir: Vector3 = (ps.global_transform.basis * away).normalized()
		var where: Vector3 = OriginShift.to_render(earth.true_pos) \
			+ world_dir * (earth.def.radius + 2500.0)
		_ship.global_position = where
		await get_tree().physics_frame
		if cam == null or cam.global_position.distance_to(where) < 30.0:
			break
	deadline = Time.get_ticks_msec() + 20000
	while surface.is_tile_resident("2:5:1") and Time.get_ticks_msec() < deadline:
		ps.force_evaluate()
		await get_tree().process_frame
	_check(not surface.is_tile_resident("2:5:1"),
		"the tile streams back out on departure")


## Track SL6: the sky is the real one. Polaris must sit over Earth's spin
## axis and Sirius must be where the catalog puts it — a broken RA/Dec
## transform or a flipped panorama fails here, not in a screenshot review.
func _test_real_sky() -> void:
	print("\n== the real sky ==")
	var tex := load("res://assets/sky/starmap.png") as Texture2D
	_check(tex != null, "the star map is cooked and imported")
	if tex == null:
		return
	var img: Image = tex.get_image()
	if img.is_compressed():
		img.decompress()

	var polaris := _sky_window_peak(img, 37.9546, 89.2641)
	_check(polaris > 0.15, "Polaris shines over the spin axis", "(%.2f)" % polaris)
	var sirius := _sky_window_peak(img, 101.287, -16.7161)
	_check(sirius > 0.5, "Sirius is the beacon it should be", "(%.2f)" % sirius)
	# And the anti-Polaris point is dark — a flipped map fails this.
	var south := _sky_window_peak(img, 37.9546 + 180.0, -89.2641)
	_check(south < polaris * 0.8, "the south celestial pole is dimmer than Polaris",
		"(%.2f)" % south)

	var mean := 0.0
	for k in 4096:
		var x := (k * 61) % img.get_width()
		var y := (k * 37) % img.get_height()
		mean += img.get_pixel(x, y).get_luminance()
	mean /= 4096.0
	_check(mean > 0.001 and mean < 0.06, "sky luminance stays in exposure range",
		"(mean %.4f)" % mean)

	# CHIRALITY: the sky must not be a mirror image (the bug that shipped the
	# first cook). Find the actual baked peaks for Betelgeuse, Rigel and
	# Sirius, take the signed volume of the FOUND directions, and compare its
	# sign against the real equatorial frame's (+0.126) pushed through the
	# proper rotation — which preserves sign. A mirrored map flips it.
	var found_b: Vector3 = _sky_window_find(img, 88.79, 7.41)["dir"]
	var found_r: Vector3 = _sky_window_find(img, 78.63, -8.20)["dir"]
	var found_s: Vector3 = _sky_window_find(img, 101.29, -16.72)["dir"]
	var chirality: float = found_b.dot(found_r.cross(found_s))
	var expected: float = _sky_dir(88.79, 7.41).dot(
		_sky_dir(78.63, -8.20).cross(_sky_dir(101.29, -16.72)))
	_check(chirality * expected > 0.0 and absf(expected - 0.1262) < 0.02,
		"Orion and Sirius wind the right way (no mirror-image sky)",
		"(found %+.4f, real %+.4f)" % [chirality, expected])


## Game-world direction of an RA/Dec position, through the SAME proper
## rotation the cook uses (z negated — the mirror-image trap; tilt 0.41).
func _sky_dir(ra_deg: float, dec_deg: float) -> Vector3:
	var ra := deg_to_rad(ra_deg)
	var dec := deg_to_rad(dec_deg)
	var x := cos(dec) * cos(ra)
	var y := sin(dec)
	var z := -cos(dec) * sin(ra)
	var tilt := 0.41
	return Vector3(x, y * cos(tilt) - z * sin(tilt), y * sin(tilt) + z * cos(tilt))


## Peak luminance (and its pixel) in a ~1 degree window around an RA/Dec
## position. Returns {"peak": float, "dir": Vector3 of the found pixel}.
func _sky_window_find(img: Image, ra_deg: float, dec_deg: float) -> Dictionary:
	var dir := _sky_dir(ra_deg, dec_deg)
	var u := 0.5 + atan2(dir.z, dir.x) / TAU
	var v := 0.5 - asin(clampf(dir.y, -1.0, 1.0)) / PI
	var cx := int(u * img.get_width())
	var cy := int(v * img.get_height())
	var reach := int(img.get_width() / 360.0) + 2
	var peak := 0.0
	var best_px := cx
	var best_py := cy
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var px := posmod(cx + dx, img.get_width())
			var py := clampi(cy + dy, 0, img.get_height() - 1)
			var lum := img.get_pixel(px, py).get_luminance()
			if lum > peak:
				peak = lum
				best_px = px
				best_py = py
	var lon := (float(best_px) + 0.5) / float(img.get_width()) * TAU - PI
	var lat := PI / 2.0 - (float(best_py) + 0.5) / float(img.get_height()) * PI
	return {"peak": peak,
		"dir": Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))}


func _sky_window_peak(img: Image, ra_deg: float, dec_deg: float) -> float:
	return _sky_window_find(img, ra_deg, dec_deg)["peak"]


## Track SL7: the albedo's alpha channel is the sea mask, cut by the same
## coastline rule as the height map — the two must agree on how much of the
## world is land.
func _test_sea_mask() -> void:
	print("\n== sea mask ==")
	# has_sea_spec lands with the texture-bake commit on the main thread.
	var earth_surface := _system.get_body(&"earth").planet_surface()
	var deadline: int = Time.get_ticks_msec() + 60000
	while not earth_surface.textures_ready and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var tex := load("res://assets/planets/earth_albedo.png") as Texture2D
	var img: Image = tex.get_image()
	if img.is_compressed():
		img.decompress()
	_check(img.get_format() == Image.FORMAT_RGBA8 or img.detect_alpha() != Image.ALPHA_NONE,
		"the cooked albedo carries an alpha channel")
	var land := 0.0
	var total := 0.0
	for iy in 128:
		var vv := (float(iy) + 0.5) / 128.0
		var weight := cos((vv - 0.5) * PI)
		for ix in 256:
			var px := int((float(ix) + 0.5) / 256.0 * img.get_width())
			var py := int(vv * img.get_height())
			total += weight
			if img.get_pixel(px, py).a > 0.5:
				land += weight
	var fraction := land / total
	_check(absf(fraction - 0.292) < 0.02,
		"the sea mask agrees with the real coastline", "(%.3f vs 0.292)" % fraction)
	var mat: ShaderMaterial = _system.get_body(&"earth").planet_surface().material()
	_check(mat.get_shader_parameter("has_sea_spec") == true,
		"Earth's surface material knows its sea is glossy")
	var moon_mat: ShaderMaterial = _system.get_body(&"moon").planet_surface().material()
	_check(moon_mat.get_shader_parameter("has_sea_spec") == null,
		"a sea-less body keeps flat roughness")


## Geomorph targets (PR5): CUSTOM0/1 must carry the parent-level surface —
## even vertices coincide with parent vertices exactly, odd ones sit on the
## parent's linear interpolation. If either drifts, LOD transitions pop, which
## is precisely what geomorphing exists to remove.
func _test_geomorph_targets() -> void:
	print("\n== geomorph targets ==")
	var surface := _system.get_body(&"earth").planet_surface()
	var arrays: Dictionary = _build(surface, 0, 3, 2, 5)
	var verts: PackedVector3Array = arrays["verts"]
	var ppos: PackedFloat32Array = arrays["parent_pos"]
	_check(ppos.size() == verts.size() * 3,
		"parent targets cover every vertex, skirts included")

	var n: int = PlanetPatchMesh.GRID + 1
	var even_exact := true
	var odd_mid := true
	for j in range(0, n, 2):
		for i in range(0, n, 2):
			var idx: int = j * n + i
			var pv := Vector3(ppos[idx * 3], ppos[idx * 3 + 1], ppos[idx * 3 + 2])
			if (pv - verts[idx]).length() > 0.001:
				even_exact = false
	for j in range(0, n, 2):
		for i in range(1, n, 2):
			var idx: int = j * n + i
			var pv := Vector3(ppos[idx * 3], ppos[idx * 3 + 1], ppos[idx * 3 + 2])
			var mid: Vector3 = (verts[idx - 1] + verts[idx + 1]) * 0.5
			if (pv - mid).length() > 0.001:
				odd_mid = false
	_check(even_exact, "even vertices coincide with the parent's")
	_check(odd_mid, "odd vertices sit on the parent's edge midpoints")

	# Root patches have no coarser level: their target is themselves.
	var root: Dictionary = _build(surface, 0, 0, 0, 0)
	var rverts: PackedVector3Array = root["verts"]
	var rpos: PackedFloat32Array = root["parent_pos"]
	var self_target := true
	for k in rverts.size():
		var pv := Vector3(rpos[k * 3], rpos[k * 3 + 1], rpos[k * 3 + 2])
		if (pv - rverts[k]).length() > 0.001:
			self_target = false
	_check(self_target, "root patches morph to themselves")


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

## Cape Canaveral (PR5, owner-picked): the second site — real coastline inset,
## landmark props at the real installations, streaming like NYC's.
func _test_canaveral() -> void:
	print("\n== canaveral site ==")
	var earth := _system.get_body(&"earth")
	var surface := earth.planet_surface()
	var site: DetailSite = null
	for s in earth.def.surface.sites:
		if s.id == &"canaveral":
			site = s
	_check(site != null, "Earth carries the Cape Canaveral site")
	if site == null:
		return
	_check(site.height_inset != null and site.scene != null
			and site.night_emissive != null,
		"the site has an inset, a scene and a night plate")

	await _settle_over_site(earth, 2500.0, &"canaveral")
	_check(surface.site_resident(&"canaveral"), "the site streams in inside 3 km")
	var anchor := surface.get_node_or_null("Site_canaveral")
	_check(anchor != null and anchor.get_child_count() > 0,
		"the scene is instantiated under the anchor")
	if anchor != null:
		var cape := anchor.get_child(0)
		var built: int = int(cape.call("building_count")) if cape.has_method(
			"building_count") else 0
		_check(built >= 6, "the landmarks are placed", "(%d props)" % built)
		_check(cape.find_children("*", "PhysicsBody3D", true, false).is_empty(),
			"the site scene carries no physics bodies")

	await _settle_over_site(earth, 5000.0, &"canaveral")
	_check(not surface.site_resident(&"canaveral"), "and streams back out")


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
		if cam == null or cam.global_position.distance_to(where) < 30.0:
			break
	return await _settle_surface(surface)


## Park the ship `distance` metres from the New York site, looking down at it, and
## let the surface settle. Distance is measured to the *site*, not to the body's
## centre, because that is what the streamer's thresholds are measured against.
## The site is re-read every hold frame: the planet is spinning underneath.
func _settle_over_site(body: CelestialBody, distance: float, site_id: StringName = &"nyc") -> Dictionary:
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
		var xf: Transform3D = surface.site_transform(site_id)
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
