extends Node
## Track LD screenshot harness — rocks, latching, descent, and landings.
##
## Run: xvfb-run -a godot res://tests/capture_landing_shots.tscn
##
## The landed shots are REAL landings — the scripted-descent path from
## landing_test, through the actual capture — not posed lookalikes: the point
## of the evidence is that the landed state renders from inside the game loop.

const OUT_DIR: String = "user://shots"

var _world: Node3D
var _ship: RigidBody3D
var _system: SolarSystem
var _landing: LandingComputer
var _sunward: Vector3 = Vector3.RIGHT


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_world = load("res://scenes/game_world.tscn").instantiate()
	add_child(_world)
	await _settle(6)

	_ship = _world.get_node("Ship")
	_system = _world.get_node("SolarSystem")
	_landing = _ship.get_node("LandingComputer")
	var earth := _system.get_body(&"earth")
	_sunward = (OriginShift.to_render(_system.get_body(&"sun").true_pos)
		- _ship.global_position).normalized()
	GameState.flight_assist_enabled = false
	# CASCADE_SHOT=earth|moon|rocks reruns a single section while iterating.
	var only: String = OS.get_environment("CASCADE_SHOT")

	if only == "" or only == "rocks":
		await _rocks_shots(earth)
	if only == "" or only == "earth":
		await _earth_shots(earth)
	if only == "" or only == "moon":
		await _moon_shot()

	print("shots written to %s" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit()


func _rocks_shots(earth: CelestialBody) -> void:
	# 1. The rock field, Earth behind — parked on the sun side looking through.
	var field := _world.get_node("RockField") as RockField
	var toward_earth: Vector3 = (
		OriginShift.to_render(earth.true_pos) - field.global_position).normalized()
	# From inside the field, sunward edge, looking through the rocks at Earth.
	await _pose_ship(
		field.global_position + _sunward * 60.0 - toward_earth * 40.0,
		field.global_position + toward_earth * 600.0)
	await _settle(40)
	await _shot("11_rock_field")

	# 2. Latched: nose against the biggest nearby rock, clamped.
	var rock: SpaceRock = null
	for r in field.rocks:
		if rock == null or r.mass > rock.mass:
			rock = r
	if rock.asleep:
		rock.wake(_world, field.frame_velocity())
	rock.angular_velocity = Vector3.ZERO
	rock.linear_velocity = field.frame_velocity()
	await _pose_ship(
		rock.global_position + _sunward * 14.0,
		rock.global_position)
	_ship.freeze = false
	_ship.linear_velocity = rock.linear_velocity
	var latch := _ship.get_node("LatchComputer") as LatchComputer
	latch.latch_to(rock)
	await _settle(30)
	await _shot("12_latched_to_rock")
	latch.unlatch()


func _earth_shots(earth: CelestialBody) -> void:
	# 3. On the way down: inside Earth's shell, ground filling the view — aimed
	# at a continent interior (the first take landed in the ocean: the planet
	# spins ~18 degrees during a descent, so the aim compensates for drift and
	# the site is ring-checked for land 0.15 rad around).
	var site_dir: Vector3 = _pick_site_dir(earth)
	await _pose_ship(
		OriginShift.to_render(earth.true_pos) + site_dir * (earth.def.radius + 900.0),
		OriginShift.to_render(earth.true_pos) + site_dir * earth.def.radius * 0.5)
	await _settle(60)
	await _shot("13_descent")

	# 4. Landed on Earth — flown in through the real capture, warped to
	# mid-morning, then shot from the EVA suit boot-clamped beside it.
	var ok: bool = await _land_on(earth, site_dir)
	print("  earth landing captured: %s" % ok)
	_level_landed_hull(earth)
	await _warp_to_morning(earth)
	await _suit_groundside_shot(earth, "14_landed_earth")
	_landing.release()
	await _settle(5)


func _moon_shot() -> void:
	# 5. Landed on the Moon, same staging.
	var moon := _system.get_body(&"moon")
	var ok: bool = await _land_on(moon, _pick_site_dir(moon))
	print("  moon landing captured: %s" % ok)
	_level_landed_hull(moon)
	await _warp_to_morning(moon)
	await _suit_groundside_shot(moon, "15_landed_moon")
	# 6. And jump (LD6): a lunar leap is metres high and seconds long — catch
	# it on the way up, ship and ground falling away below.
	var suit: RigidBody3D = _ship.get("character")
	suit.call("request_exit")
	suit.freeze = true
	for i in 8:
		var up2: Vector3 = (_ship.global_position
			- OriginShift.to_render(moon.true_pos)).normalized()
		suit.global_position = _ship.global_position \
			+ (OriginShift.to_render(_system.get_body(&"sun").true_pos)
			- _ship.global_position).normalized().slide(up2).normalized() * 10.0 + up2 * 0.5
		suit.global_basis = Basis.looking_at(
			(_ship.global_position + up2 * 1.5 - suit.global_position).normalized(), up2)
		PhysicsServer3D.body_set_state(
			suit.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, suit.global_transform)
		await get_tree().physics_frame
	suit.call("enter_walk_on", moon)
	await _wait_grounded(suit)
	# 6b. Mid-run first (Track AN): W held, catch the stride.
	Input.action_press("thrust_forward")
	for i in 70:
		await get_tree().physics_frame
	await _shot("19_moon_run")
	Input.action_release("thrust_forward")
	for i in 30:
		await get_tree().physics_frame
	Input.action_press("thrust_up")
	for i in 8:
		await get_tree().physics_frame
	Input.action_release("thrust_up")
	# Ride up for ~1.5 s of the leap, then take the frame.
	for i in 90:
		await get_tree().physics_frame
	await _shot("16_moon_jump")
	GameState.input_mode = GameState.InputMode.SHIP_FLIGHT
	suit.call("stow")


## A landed hull captures nose-to-sky, which hangs the trailing third-person
## camera underground behind it (backface soup) or staring into the sunward
## in-scatter (white-out). The tree owns a landed transform, so level the nose
## to the horizon pointing away from the sun: camera above ground, light
## behind it, terrain and horizon in frame.
func _level_landed_hull(body: CelestialBody) -> void:
	var up: Vector3 = (_ship.global_position
		- OriginShift.to_render(body.true_pos)).normalized()
	var body_sun: Vector3 = (OriginShift.to_render(_system.get_body(&"sun").true_pos)
		- _ship.global_position).normalized()
	var level: Vector3 = (-body_sun - up * (-body_sun).dot(up)).normalized()
	_ship.global_basis = Basis.looking_at(level, up)
	_ship.global_position += up * 1.5


## Jump the clock to when the sun stands high over the landed site — solved
## analytically (positions are closed-form in sim_time; the landed hull rides
## the spin through the tree, so time of day is just a number). A live warp
## search raced frame pacing and missed its window; this cannot miss.
func _warp_to_morning(body: CelestialBody) -> void:
	var sun := _system.get_body(&"sun")
	var surface := body.planet_surface()
	var site_local: Vector3 = surface.to_local(_ship.global_position).normalized()
	var axis := Vector3(
		0.0, cos(body.def.spin_axis_tilt), sin(body.def.spin_axis_tilt)).normalized()
	var best_t: float = SimClock.sim_time
	var best_err: float = INF
	var t: float = SimClock.sim_time
	while t < SimClock.sim_time + body.def.spin_period * 1.05:
		var n: Vector3 = Basis(axis, fposmod(TAU * t / body.def.spin_period, TAU)) * site_local
		var bp: Array = body.position_at(t)
		var sp: Array = sun.position_at(t)
		var sd := Vector3(
			float(sp[0] - bp[0]), float(sp[1] - bp[1]), float(sp[2] - bp[2])).normalized()
		var err: float = absf(asin(clampf(n.dot(sd), -1.0, 1.0)) - deg_to_rad(62.0))
		if err < best_err:
			best_err = err
			best_t = t
		t += 5.0
	# Jump the clock, then re-centre the origin from TRUE space computed
	# analytically — never from render: the jump moves the body hundreds of
	# km along its orbit, the body goes proxy, the landed hull is dragged to
	# the 40 km proxy shell, and to_true() of that collapsed position locks
	# the garbage in (measured: origin 132 km off, whole scene proxied).
	var ship_local_un: Vector3 = surface.to_local(_ship.global_position)
	SimClock.sim_time = best_t
	var bp2: Array = body.position_at(best_t)
	var off: Vector3 = Basis(axis, fposmod(TAU * best_t / body.def.spin_period, TAU)) * ship_local_un
	OriginShift.shift_to([bp2[0] + off.x, bp2[1] + off.y, bp2[2] + off.z])
	await get_tree().process_frame
	await get_tree().process_frame
	var up_f: Vector3 = (_ship.global_position - OriginShift.to_render(body.true_pos)).normalized()
	var sd_f: Vector3 = (OriginShift.to_render(sun.true_pos) - _ship.global_position).normalized()
	print("  time jump: elev %.1f deg" % rad_to_deg(asin(clampf(up_f.dot(sd_f), -1.0, 1.0))))
	_level_landed_hull(body)


## The convincing frame: the EVA suit exits, boot-clamps to the ground a few
## metres off (the LD2 feature, and the only stable way to stand on a surface
## moving 131 m/s), and its own camera shoots the landed hull sitting on the
## terrain. Close range on purpose — the compressed atmosphere's ground
## visibility is ~30 m, so the ship camera's cruise offset fogs out on Earth.
func _suit_groundside_shot(body: CelestialBody, label: String) -> void:
	# Re-centre the origin on the landed hull first (the autopilot's own
	# release pattern): the hull rides its planet at ~131 m/s, so an origin
	# shift fires every ~76 s — and one landing inside the staging window
	# leaves shiftables translated while rail-driven nodes haven't recomputed
	# yet, which planted the suit 40 km off in a single racing frame.
	OriginShift.shift_to(OriginShift.to_true(_ship.global_position))
	var suit: RigidBody3D = _ship.get("character")
	suit.call("request_exit")
	# Freeze in the SAME frame: one physics step with the live suit at a hatch
	# that clips the relief and the solver throws it across the planet.
	suit.freeze = true
	print("  post-exit: sep %.1f" % (suit.global_position - _ship.global_position).length())
	var sun_render: Vector3 = OriginShift.to_render(_system.get_body(&"sun").true_pos)
	for i in 3:
		var up: Vector3 = (_ship.global_position
			- OriginShift.to_render(body.true_pos)).normalized()
		var sun_flat: Vector3 = (sun_render - _ship.global_position).normalized()
		sun_flat = (sun_flat - up * sun_flat.dot(up)).normalized()
		# 55 degrees off the sun line: light stays behind the camera but the
		# hull shows its flank instead of its stern.
		var stand_dir: Vector3 = sun_flat.rotated(up, deg_to_rad(55.0))
		var stand: Vector3 = _ship.global_position + stand_dir * 15.0 + up * 0.4
		suit.global_position = stand
		suit.global_basis = Basis.looking_at(
			(_ship.global_position + up * 1.0 - stand).normalized(), up)
		PhysicsServer3D.body_set_state(
			suit.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, suit.global_transform)
		await get_tree().physics_frame
	# Enter the walk (LD6): parented under the surface, feet settle onto the
	# terrain, and the staged facing seeds the walk's forward.
	suit.call("enter_walk_on", body)
	print("  staged: sep %.1f m (want ~15)" % (suit.global_position - _ship.global_position).length())
	await _wait_grounded(suit)
	await _settle(30)
	await _shot(label)
	GameState.input_mode = GameState.InputMode.SHIP_FLIGHT
	suit.call("stow")


## Freeze-hold the hull at `where` facing `target`, upright against the local
## vertical when near a body, until the rig camera has caught up.
func _pose_ship(where: Vector3, target: Vector3) -> void:
	_ship.freeze = true
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		_ship.global_position = where
		var fwd: Vector3 = (target - where).normalized()
		var up := Vector3.UP
		if absf(fwd.dot(up)) > 0.95:
			up = Vector3.RIGHT
		_ship.look_at(target, up)
		await get_tree().physics_frame
		if cam == null or cam.global_position.distance_to(where) < 40.0:
			break


## A descent aim that touches down somewhere PHOTOGENIC: scan surface-LOCAL
## directions, keep those whose whole 0.12 rad ring is dry (continent
## interior, so the spin drift during descent stays on land) AND flat (the
## relief is exaggerated; a hillside fills the whole frame with slope), and
## convert the best to a world aim compensated for ~100 s of rotation.
func _pick_site_dir(body: CelestialBody) -> Vector3:
	var surface := body.planet_surface()
	var sampler = surface.surface_res.make_sampler()
	var best: Vector3 = Vector3(0, 1, 0.2).normalized()
	var best_score: float = INF
	# Authored detail sites sabotage the scan twice over: their insets both
	# FLATTEN the terrain (winning the flatness score) and raise it above sea
	# level (passing the inland check) — which is how every Earth attempt
	# landed in New York harbor. Skip a wide cap around each site.
	var site_dirs: Array = []
	for state in surface._sites.values():
		site_dirs.append([state.dir, state.angular_radius * 4.0 + 0.2])
	# Only latitudes where local noon reaches 60 degrees — the morning warp
	# must be able to actually light the site (Moon tilt ~2deg rules out 40N).
	var tilt_deg: float = rad_to_deg(body.def.spin_axis_tilt)
	var lat_rows: Array = []
	for cand in [10, 25, 40, -15, -30]:
		if absf(float(cand) - tilt_deg) <= 30.0:
			lat_rows.append(cand)
	for lat_deg in lat_rows:
		for lon_step in 32:
			var lat: float = deg_to_rad(float(lat_deg))
			var lon: float = TAU * float(lon_step) / 32.0
			var local := Vector3(
				cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
			# Clearly inland, not just technically dry — a beach reads as
			# ocean in the albedo anyway.
			if sampler.height_normalized(local) < sampler.sea_level + 0.06:
				continue
			var near_site := false
			for sd in site_dirs:
				if local.angle_to(sd[0]) < sd[1]:
					near_site = true
					break
			if near_site:
				continue
			var h0: float = sampler.height(local)
			var side: Vector3 = local.cross(Vector3.UP).normalized() 				if absf(local.y) < 0.9 else Vector3.RIGHT
			var wet := false
			var relief: float = 0.0
			for k in 8:
				var ring: Vector3 = local.rotated(side, 0.12) 					.rotated(local, TAU * float(k) / 8.0).normalized()
				if sampler.is_sea(ring):
					wet = true
					break
				relief = maxf(relief, absf(sampler.height(ring) - h0))
			if wet:
				continue
			if relief < best_score:
				best_score = relief
				best = local
	return best


## The landing_test descent, packaged: aim at the surface-LOCAL site (the
## scan is deterministic in local space, so every run lands the same place),
## compensated for the spin the body will do while we fly down; settle into
## skim, ride down at 1.5 m/s until the landing computer captures. Retries
## once — a slow tile-stream can outlast the first descent deadline.
func _land_on(body: CelestialBody, local_site: Vector3) -> bool:
	var surface := body.planet_surface()
	if surface == null:
		return false
	var axis := Vector3(
		0.0, cos(body.def.spin_axis_tilt), sin(body.def.spin_axis_tilt)).normalized()
	for attempt in 2:
		var dir: Vector3 = (surface.global_transform.basis
			* local_site.rotated(axis, TAU * 100.0 / body.def.spin_period)).normalized()
		if await _descend(body, dir):
			return true
	return false


func _descend(body: CelestialBody, dir: Vector3) -> bool:
	var surface := body.planet_surface()
	_ship.freeze = true
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 25000
	while Time.get_ticks_msec() < deadline:
		var where: Vector3 = OriginShift.to_render(body.true_pos) + dir * (body.def.radius + 80.0)
		_ship.global_position = where
		var up: Vector3 = dir
		var fwd: Vector3 = up.cross(Vector3.RIGHT).normalized()
		_ship.global_basis = Basis(fwd.cross(up).normalized(), up, -fwd).orthonormalized()
		await get_tree().physics_frame
		surface.force_evaluate()
		if surface.skim_active and (cam == null or cam.global_position.distance_to(where) < 30.0):
			break
	_ship.freeze = false
	deadline = Time.get_ticks_msec() + 150000
	while not GameState.landed and Time.get_ticks_msec() < deadline:
		var down: Vector3 = (OriginShift.to_render(body.true_pos) - _ship.global_position).normalized()
		_ship.linear_velocity = LandingComputer.surface_point_velocity(
			body, _ship.global_position) + down * 1.5
		_ship.angular_velocity = Vector3.ZERO
		await get_tree().physics_frame
	return GameState.landed


## Lunar gravity settles slowly — never shoot a "standing" frame while the
## walk sim still says airborne (the fall clip reads as T-pose at distance).
func _wait_grounded(suit: RigidBody3D) -> void:
	var deadline: int = Time.get_ticks_msec() + 30000
	while bool(suit.get("_walk_airborne")) and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame


func _settle(frames: int) -> void:
	for _i in frames:
		await get_tree().process_frame


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/%s.png" % [OUT_DIR, label]
	image.save_png(path)
	print("  wrote %s" % path)
