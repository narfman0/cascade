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

	# 3. On the way down: inside Earth's shell, ground filling the view. The
	# site sits near the terminator — a high sun at ground level whites the
	# whole frame out with in-scatter; a low one keeps the relief readable.
	var side: Vector3 = _sunward.cross(Vector3.UP).normalized()
	var site_dir: Vector3 = (_sunward * 0.35 + side + Vector3(0, 0.25, 0)).normalized()
	await _pose_ship(
		OriginShift.to_render(earth.true_pos) + site_dir * (earth.def.radius + 900.0),
		OriginShift.to_render(earth.true_pos) + site_dir * earth.def.radius * 0.5)
	await _settle(60)
	await _shot("13_descent")

	# 4. Landed on Earth — flown in through the real capture.
	var ok := await _land_on(earth, site_dir)
	print("  earth landing captured: %s" % ok)
	_level_landed_hull(earth)
	await _settle(60)
	await _shot("14_landed_earth")
	_landing.release()
	await _settle(5)

	# 5. Landed on the Moon.
	var moon := _system.get_body(&"moon")
	var moon_sun: Vector3 = (OriginShift.to_render(_system.get_body(&"sun").true_pos)
		- OriginShift.to_render(moon.true_pos)).normalized()
	var moon_dir: Vector3 = (moon_sun + Vector3(0, 0.3, 0)).normalized()
	ok = await _land_on(moon, moon_dir)
	print("  moon landing captured: %s" % ok)
	_level_landed_hull(moon)
	await _settle(60)
	await _shot("15_landed_moon")

	print("shots written to %s" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit()


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
	# Nose a touch above the horizon: terrain in the bottom of the frame, sky
	# and horizon above, instead of a screen full of ground.
	var fwd: Vector3 = (level + up * 0.35).normalized()
	_ship.global_basis = Basis.looking_at(fwd, up)
	_ship.global_position += up * 1.5
	# Pull the rig in close: Earth's compressed atmosphere scatters ~27x per
	# metre at ground level, and at the cruise offset (22 m) the hull fogs out.
	var rig := _ship.get_node("CameraRig")
	rig.set("third_person_offset", Vector3(0, 2.5, 9.0))


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


## The landing_test descent, packaged: settle into skim over `dir`, then ride
## down at 1.5 m/s until the landing computer captures. Returns success.
func _land_on(body: CelestialBody, dir: Vector3) -> bool:
	var surface := body.planet_surface()
	if surface == null:
		return false
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


func _settle(frames: int) -> void:
	for _i in frames:
		await get_tree().process_frame


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/%s.png" % [OUT_DIR, label]
	image.save_png(path)
	print("  wrote %s" % path)
