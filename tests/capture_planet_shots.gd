extends Node
## PR1/PR2 gate screenshots: do the surfaces actually read?
##
## Run: xvfb-run -a godot res://tests/capture_planet_shots.tscn
##
## Frames by posing the *ship* and letting the gameplay rig camera follow, rather
## than by adding a harness camera. A separately-added Camera3D does not reliably
## win `current` against the ship's rig here — that is what made the first pass of
## these shots (and the EVA portraits before them) render from behind the ship
## instead of from the intended framing. Posing the ship is also more honest: the
## shots then show what the player would actually see.

const OUT_DIR: String = "user://shots"

var _system: SolarSystem
var _ship: RigidBody3D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var world: Node3D = load("res://scenes/game_world.tscn").instantiate()
	add_child(world)
	for _i in 8:
		await get_tree().process_frame

	_system = world.get_node("SolarSystem")
	_ship = world.get_node("Ship")
	_ship.freeze = true
	GameState.flight_assist_enabled = false

	var earth := _system.get_body(&"earth")

	# 1. Full disc, sunlit — continents and sea, or the relief is not working.
	await _frame_body(earth, 3.4, 0.0)
	await _shot("14_earth_disc")

	# 2. The terminator: city lights must fade in across dusk, not switch on.
	await _frame_body(earth, 2.6, 1.75)
	await _shot("15_earth_terminator")

	# 3. Close relief — the quadtree's reason to exist.
	await _frame_body(earth, 1.35, 0.35)
	await _shot("16_earth_close")
	_report(earth)

	# 4. Moon relief, and 5. Jupiter banding on a body with zero amplitude.
	await _frame_body(_system.get_body(&"moon"), 3.0, 0.25)
	await _shot("17_moon_relief")
	await _frame_body(_system.get_body(&"jupiter"), 2.6, 0.2)
	await _shot("18_jupiter_bands")

	# 6. Continuous approach: five frames closing on Earth. Any visible pop
	#    between consecutive frames is the no-pop rule failing.
	var steps := [3.0, 2.2, 1.7, 1.35, 1.12]
	for i in steps.size():
		await _frame_body(earth, steps[i], 0.3)
		await _shot("19_approach_%d" % (i + 1))
	_report(earth)

	# 7. Skim: terrain filling the lower frame, seen from just above it.
	await _skim_frame(earth)
	await _shot("20_earth_skim")
	_report(earth)

	# --- PR3: the authored maps and the New York site -------------------------

	# 8. The disc again, but the point is the data: real coastlines, real ocean.
	await _frame_body(earth, 3.2, 0.15)
	await _shot("21_earth_real_disc")
	# 9. Black Marble city lights along a real terminator.
	await _frame_body(earth, 2.4, 2.05)
	await _shot("22_earth_real_night")
	# 10. The other two bodies with real data, as evidence they are real.
	await _frame_body(_system.get_body(&"moon"), 2.6, 0.3)
	await _shot("23_moon_lola")
	await _frame_body(_system.get_body(&"mars"), 2.6, 0.3)
	await _shot("24_mars_mola")

	# 11. THE MONEY SHOT: New York at night from ~2 km, terminator in frame.
	await _frame_site(earth, &"nyc", 2000.0, -0.18, 0.0, 26.0)
	await _shot("25_nyc_night_2km")
	_report(earth)
	# 12. Closer, so the street grid and the towers are legible.
	await _frame_site(earth, &"nyc", 1000.0, -0.22, 0.0, 26.0, 0.06)
	await _shot("26_nyc_night_close")
	# 13. The same diorama in daylight: buildings, coastline, no lights.
	await _frame_site(earth, &"nyc", 800.0, 0.55, 0.0, 26.0, 0.10)
	await _shot("27_nyc_day")

	# --- PR4: atmosphere and scattering ----------------------------------------

	await _await_atmo(earth)

	# 14. The limb arc: the iconic blue line against black, forward-lit.
	await _frame_body(earth, 1.6, 1.35)
	await _shot("28_earth_limb_arc")

	# 15. Sunset from low orbit: grazing the terminator, sun on the horizon.
	await _sunset_frame(earth)
	await _shot("29_sunset_low_orbit")

	# 16. THE COMPARISON: Earth's soft terminator beside the Moon's hard one —
	#     one frame, same sun. The airless body staying airless is a PR4 gate.
	await _terminator_pair(earth, _system.get_body(&"moon"))
	await _shot("30_terminator_soft_vs_hard")

	# 17-19. Per-body character: Mars butterscotch, Titan haze, Venus shroud.
	var mars := _system.get_body(&"mars")
	await _await_atmo(mars)
	await _frame_body(mars, 2.3, 1.85)
	await _shot("31_mars_terminator")
	var titan := _system.get_body(&"titan")
	await _await_atmo(titan)
	await _frame_body(titan, 2.4, 1.5)
	await _shot("32_titan_haze")
	var venus := _system.get_body(&"venus")
	await _await_atmo(venus)
	await _frame_body(venus, 2.5, 1.3)
	await _shot("33_venus_shroud")

	# 20. Aerial perspective on a low pass: distant terrain hazing out is what
	#     separates "has an atmosphere" from "has a blue ring".
	await _skim_low(earth)
	await _shot("34_skim_aerial")
	_report(earth)

	# --- PR5 sites: Cape Canaveral ---------------------------------------------

	# 21. The launch coast in daylight: the cape's hook, the rivers, the pads.
	#     Yawed like the NYC shots — the rig centres the ship, so an un-yawed
	#     aim hides the diorama exactly behind the hull.
	await _frame_site(earth, &"canaveral", 600.0, 0.55, 0.0, 22.0, 0.06)
	await _shot("35_canaveral_day")
	# 22. And at dusk: pad and port lights against the dark coast.
	await _frame_site(earth, &"canaveral", 900.0, -0.15, 0.0, 24.0, 0.16)
	await _shot("36_canaveral_dusk")
	_report(earth)

	print("shots written to %s" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit()


## Atmosphere LUTs bake on the worker pool; hold the shot until the shell is
## live, the same way the surface shots hold for textures_ready.
func _await_atmo(body: CelestialBody) -> void:
	var surface := body.planet_surface()
	if surface == null or surface.atmosphere == null:
		return
	var deadline: int = Time.get_ticks_msec() + 60000
	while not surface.atmosphere_ready and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


## Low above the terminator ring, looking toward the sun along the horizon —
## the sunset framing.
##
## Every low-altitude framing here re-centres after the settle, same as
## _frame_site and for the same reason: the body co-moves at ~131 m/s while
## the frozen ship does not (standing trap #5), so even a two-second settle
## leaves the camera hundreds of metres off a 70 m-altitude pose.
func _sunset_frame(body: CelestialBody) -> void:
	var resolve := func() -> Array:
		var centre: Vector3 = OriginShift.to_render(body.true_pos)
		var to_sun: Vector3 = (OriginShift.to_render(_system.get_body(&"sun").true_pos)
			- centre).normalized()
		var axis: Vector3 = to_sun.cross(Vector3.UP)
		if axis.length() < 0.1:
			axis = to_sun.cross(Vector3.RIGHT)
		axis = axis.normalized()
		# On the terminator ring, a touch into the day side, near the shell
		# top (~50 m on Earth) — this framing is also the camera-inside-the-
		# volume proof. The horizon dips ~15 deg at this altitude, so the aim
		# drops about that much to hold it in frame.
		var up_dir: Vector3 = to_sun.rotated(axis, 1.45)
		var where: Vector3 = centre + up_dir * (body.def.radius + 70.0)
		return [where, where + to_sun * 500.0 - up_dir * 126.0, up_dir]
	await _hold_pose(resolve)
	await _settle(body)
	await _hold_pose(resolve)


## Both discs in one frame, half-lit: Earth's twilight band against the Moon's
## razor terminator. The camera sits perpendicular to the sun so both bodies
## show the same phase.
func _terminator_pair(earth: CelestialBody, moon: CelestialBody) -> void:
	var resolve := func() -> Array:
		var ec: Vector3 = OriginShift.to_render(earth.true_pos)
		var mc: Vector3 = OriginShift.to_render(moon.true_pos)
		var to_sun: Vector3 = (OriginShift.to_render(_system.get_body(&"sun").true_pos)
			- ec).normalized()
		var em: Vector3 = mc - ec
		var em_dir: Vector3 = em.normalized()
		var perp: Vector3 = em_dir.cross(to_sun)
		if perp.length() < 0.1:
			perp = em_dir.cross(Vector3.UP)
		perp = perp.normalized()
		# Behind and beside the Moon, offset toward the sun so both discs show
		# their lit faces; the Moon's disc (~18 deg) rides beside Earth's
		# (~13 deg), close enough in size that the terminators read as a pair.
		var where: Vector3 = mc + em_dir * 2400.0 + perp * 1000.0 + to_sun * 1500.0
		var dir_e: Vector3 = (ec - where).normalized()
		var dir_m: Vector3 = (mc - where).normalized()
		var up_v: Vector3 = dir_m.cross(dir_e)
		if up_v.length() < 0.05:
			up_v = Vector3.UP
		return [where, where + (dir_e + dir_m).normalized() * 8000.0, up_v.normalized()]
	await _hold_pose(resolve)
	await _settle(earth)
	await _hold_pose(resolve)


## Lower than the skim framing and tilted further down: the haze gradient over
## distant terrain is the aerial-perspective evidence.
func _skim_low(body: CelestialBody) -> void:
	# The framing hangs off the sun direction, so which terrain sits under it
	# depends on where the spin happens to be — some runs came up over open
	# ocean and the aerial-perspective evidence was a featureless blue sheet.
	# Scan the day-side ring for land with the body's own height sampler and
	# pin the framing there instead of trusting luck.
	var sampler := body.def.surface.make_sampler()
	var surface := body.planet_surface()
	var resolve := func() -> Array:
		var centre: Vector3 = OriginShift.to_render(body.true_pos)
		var to_sun: Vector3 = (OriginShift.to_render(_system.get_body(&"sun").true_pos)
			- centre).normalized()
		var axis: Vector3 = to_sun.cross(Vector3.UP)
		if axis.length() < 0.1:
			axis = to_sun.cross(Vector3.RIGHT)
		# Rings of candidates spiralling out from the subsolar point — when the
		# sun sits over the mid-Pacific, the nearest land can be most of a
		# quadrant away and a single narrow ring finds nothing but water.
		var up: Vector3 = to_sun.rotated(axis.normalized(), 0.35)
		var found := false
		for ring in [0.35, 0.55, 0.75, 0.95]:
			if found:
				break
			var base: Vector3 = to_sun.rotated(axis.normalized(), ring)
			for k in 24:
				var cand: Vector3 = base.rotated(to_sun, TAU * float(k) / 24.0)
				var local: Vector3 = (
					surface.global_transform.basis.inverse() * cand).normalized()
				if sampler.height_normalized(local) > 0.02:
					up = cand
					found = true
					break
		var along: Vector3 = up.cross(Vector3.UP)
		if along.length() < 0.1:
			along = up.cross(Vector3.RIGHT)
		along = along.normalized()
		# 80 m up: the horizon dips ~16 deg, so the aim drops ~25 deg to put
		# hazing terrain across the lower frame.
		var where: Vector3 = centre + up * (body.def.radius + 80.0)
		return [where, where + along * 400.0 - up * 190.0, up]
	await _hold_pose(resolve)
	await _settle(body)
	await _hold_pose(resolve)


## Park the ship (which drives refinement) and the camera at `radii` times the
## body's radius, rotated `sun_offset` radians around it. 0 is fully sunlit,
## PI/2 is a half-lit disc, and ~2.0 rad gives a crescent with most of the night
## side in frame — which is where the city lights are.
func _frame_body(body: CelestialBody, radii: float, sun_offset: float) -> void:
	await _hold_pose(func() -> Array:
		var centre: Vector3 = OriginShift.to_render(body.true_pos)
		var to_sun: Vector3 = (OriginShift.to_render(_system.get_body(&"sun").true_pos)
			- centre).normalized()
		var axis: Vector3 = to_sun.cross(Vector3.UP)
		if axis.length() < 0.1:
			axis = to_sun.cross(Vector3.RIGHT)
		var dir: Vector3 = to_sun.rotated(axis.normalized(), sun_offset)
		var where: Vector3 = centre + dir * (body.def.radius * radii)
		# The rig sits behind the ship along its +Z, so back the ship off by the
		# rig offset to keep the framing distance honest, then aim it at the body.
		return [where + dir * 12.0, centre, Vector3.UP]
	)
	await _settle(body)


## Frame a detail site from `distance` metres, with the site's local sun elevation
## driven to `sun_elevation` (the dot of the local up with the sun direction).
##
## Spin is analytic from SimClock.sim_time, so "put New York just past the
## terminator" is a search over the clock rather than anything to pose by hand:
## step a full rotation, take the time whose elevation is closest, set the clock
## there. Negative elevations are night — -0.18 puts the terminator about 350 m
## away across the surface, close enough to sit in the same frame as the city.
func _frame_site(
	body: CelestialBody, id: StringName, distance: float, sun_elevation: float,
	tilt_deg: float = 0.0, yaw_deg: float = 28.0, back_frac: float = 0.28
) -> void:
	var surface := body.planet_surface()
	var site: DetailSite = null
	for candidate in body.def.surface.sites:
		if candidate != null and candidate.id == id:
			site = candidate
	if site == null or surface == null:
		return

	var period: float = body.def.spin_period
	var axis := Vector3(
		0.0, cos(body.def.spin_axis_tilt), sin(body.def.spin_axis_tilt)).normalized()
	var base_dir: Vector3 = site.direction()
	var best_t: float = SimClock.sim_time
	var best_err: float = 1e9
	for step in 720:
		var t: float = SimClock.sim_time + period * float(step) / 720.0
		var spun: Vector3 = base_dir.rotated(axis, fposmod(TAU * (t / period), TAU))
		var err: float = absf(spun.dot(_sun_direction(body, t)) - sun_elevation)
		if err < best_err:
			best_err = err
			best_t = t
	SimClock.sim_time = best_t
	for _i in 4:
		await get_tree().physics_frame

	# The warp just moved the body along its orbit — up to hundreds of km —
	# while the frozen ship stayed put. Past MAX_RENDER_DISTANCE the body goes
	# PROXY, and the hold below would chase a proxy-scaled site transform:
	# that was the nondeterministic orbit-framing bug in every site shot whose
	# elevation search reached far. Jump the ship with the body first; the
	# origin rebases, the body un-proxies, and the hold converges locally.
	var jump_centre: Vector3 = OriginShift.to_render(body.true_pos)
	var jump_dir: Vector3 = (surface.site_transform(id).origin - jump_centre)
	if jump_dir.length() < 1.0:
		jump_dir = Vector3.UP
	_ship.global_position = jump_centre \
		+ jump_dir.normalized() * (body.def.radius + distance)
	await get_tree().physics_frame

	var resolve := func() -> Array:
		var centre: Vector3 = OriginShift.to_render(body.true_pos)
		var xf: Transform3D = surface.site_transform(id)
		var out: Vector3 = (xf.origin - centre).normalized()
		var sun: Vector3 = _sun_direction(body, SimClock.sim_time)
		# Tangent component of the sun direction: which way the daylight lies.
		# Stand off on the night side of the site and look back across it toward
		# the day, so the lit city is in the foreground and the terminator behind.
		var sunward: Vector3 = (sun - out * out.dot(sun))
		if sunward.length() < 0.05:
			sunward = xf.basis.z
		sunward = sunward.normalized()
		# `back_frac` leans the standoff toward the night side so the terminator
		# and the limb come into frame; 0 is straight overhead, which is what a
		# shot that only has to show the diorama wants.
		var lean: float = sqrt(maxf(1.0 - back_frac * back_frac, 0.01))
		var where: Vector3 = (xf.origin + out * (distance * lean)
			- sunward * (distance * back_frac))
		where += (where - xf.origin).normalized() * 12.0
		# The rig draws the ship dead centre, so a camera pointed straight at the
		# site puts the city behind the hull. Yaw the aim so the diorama sits off
		# to one side: there is far more room horizontally (half-FOV ~54 deg at
		# 16:9) than vertically, where the horizon is only ~40 deg off nadir at
		# these altitudes and a big upward tilt overshoots the limb entirely.
		#
		# The offsets have to be built in the CAMERA's frame, not the planet's.
		# Near nadir the local up is almost parallel to the view direction, so
		# rotating the aim about it barely moves anything on screen — 26 deg of
		# azimuth came out as 11 deg of separation, still behind the hull.
		var view_dir: Vector3 = (xf.origin - where).normalized()
		var cam_up: Vector3 = out - view_dir * out.dot(view_dir)
		if cam_up.length() < 1e-3:
			cam_up = xf.basis.z
		cam_up = cam_up.normalized()
		var cam_right: Vector3 = view_dir.cross(cam_up).normalized()
		var aim: Vector3 = view_dir.rotated(cam_up, deg_to_rad(yaw_deg))
		var tilted: Vector3 = aim.rotated(cam_right, deg_to_rad(tilt_deg))
		# Positive tilt must raise the aim, dropping the site into the lower frame.
		if tilted.dot(cam_up) < aim.dot(cam_up):
			tilted = aim.rotated(cam_right, -deg_to_rad(tilt_deg))
		return [where, where + tilted * distance, out]

	await _hold_pose(resolve)
	await _settle(body)
	# Re-centre: the settle can take tens of seconds of wall clock, and the site
	# is moving at ~7 m/s under a spinning planet the whole time.
	await _hold_pose(resolve)


## Unit vector from a body toward the Sun at simulation time `t`. Render space
## and true space share axes, so this is usable directly against surface normals.
func _sun_direction(body: CelestialBody, t: float) -> Vector3:
	var bp: Array = body.position_at(t)
	var sp: Array = _system.get_body(&"sun").position_at(t)
	return Vector3(
		float(sp[0] - bp[0]), float(sp[1] - bp[1]), float(sp[2] - bp[2])).normalized()


## Just above the surface, looking along it: the low-skim framing.
func _skim_frame(body: CelestialBody) -> void:
	await _hold_pose(func() -> Array:
		var centre: Vector3 = OriginShift.to_render(body.true_pos)
		var to_sun: Vector3 = (OriginShift.to_render(_system.get_body(&"sun").true_pos)
			- centre).normalized()
		var up: Vector3 = to_sun
		var along: Vector3 = up.cross(Vector3.UP).normalized()
		var where: Vector3 = centre + up * (body.def.radius + 140.0)
		# Look along the surface with a slight downward tilt, so terrain fills the
		# lower frame and the limb sits high.
		return [where, where + along * 400.0 - up * 90.0, up]
	)
	await _settle(body)


## Let the quadtree finish refining for the current framing. A split commits only
## once all four children are built, so the build queue empties between rounds —
## settle until depth and leaf count stop changing, not on first quiescence.
func _settle(body: CelestialBody) -> void:
	var surface := body.planet_surface()
	if surface == null:
		for _i in 6:
			await get_tree().process_frame
		return
	# Wall clock, not frames: headless/xvfb frames outrun the worker pool, so a
	# frame budget expires long before the patches it is waiting on are built.
	var previous := {}
	var stable: int = 0
	var deadline: int = Time.get_ticks_msec() + 30000
	while stable < 3 and Time.get_ticks_msec() < deadline:
		surface.force_evaluate()
		await get_tree().process_frame
		if not surface.is_quiescent():
			stable = 0
			continue
		var now: Dictionary = surface.stats()
		if previous.size() > 0 and now["leaves"] == previous["leaves"] \
				and now["max_depth"] == previous["max_depth"]:
			stable += 1
		else:
			stable = 0
		previous = now


## Hold the ship at a pose across physics frames — a frozen kinematic body's
## transform only commits through a physics step — until the camera rig has
## caught up, then let a few more frames pass so the shot is not taken mid-lerp.
##
## `resolve` returns [where, look_target, up] and is called EVERY frame rather
## than once. Two things move underneath a fixed pose and both broke shots: the
## floating origin rebases the instant the ship is teleported more than 10 km
## (so a render-space position captured beforehand is stale by exactly the shift,
## which is how the Moon and Mars frames ended up pointing at empty space), and
## the planet keeps spinning, which walks a surface site out of frame during the
## refinement settle.
##
## The rig smooths on a 0.12 s half-life against the *process* delta, and under
## llvmpipe the process/physics frame relationship is nothing like the editor's,
## so convergence is tested against the rig's own target, not counted in frames.
func _hold_pose(resolve: Callable) -> void:
	_ship.freeze = true
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		var pose: Array = resolve.call()
		var where: Vector3 = pose[0]
		var look_target: Vector3 = pose[1]
		var up: Vector3 = pose[2]
		var dir: Vector3 = look_target - where
		if dir.length() < 1.0:
			return
		if absf(dir.normalized().dot(up)) > 0.99:
			up = Vector3.RIGHT
		_ship.global_position = where
		_ship.look_at(look_target, up)
		await get_tree().physics_frame
		if cam == null:
			break
		if cam.global_position.distance_to(_ship.to_global(Vector3(0.0, 3.0, 12.0))) < 1.0:
			break
	for _i in 20:
		await get_tree().process_frame


func _report(body: CelestialBody) -> void:
	var surface := body.planet_surface()
	if surface:
		print("  %s: %s  textures_ready=%s skim=%s" % [
			body.nav_display_name(), surface.stats(),
			surface.textures_ready, surface.skim_active])


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	image.save_png("%s/%s.png" % [OUT_DIR, label])
	print("  wrote %s" % label)
