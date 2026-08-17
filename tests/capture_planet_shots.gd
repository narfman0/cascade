extends Node
## PR1/PR2 gate screenshots: do the surfaces actually read?
##
## Run: xvfb-run -a godot res://tests/capture_planet_shots.tscn
##
## Uses a harness-owned review camera rather than the gameplay rig: the shots
## want a planet centred and framed, which is not where a camera parked behind
## the ship happens to point. The ship is frozen and posed so the surface's error
## metric (which reads the active camera) refines toward what is being framed.

const OUT_DIR: String = "user://shots"

var _system: SolarSystem
var _ship: RigidBody3D
var _cam: Camera3D


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

	_cam = Camera3D.new()
	_cam.fov = 55.0
	_cam.near = 0.5
	_cam.far = 200000.0
	add_child(_cam)
	_cam.current = true

	var earth := _system.get_body(&"earth")

	# 1. Full disc, sunlit — continents and sea, or the relief is not working.
	await _frame_body(earth, 3.4, 0.0)
	await _shot("14_earth_disc")

	# 2. The terminator: city lights must fade in across dusk, not switch on.
	await _frame_body(earth, 2.6, 0.82)
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

	print("shots written to %s" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit()


## Park the ship (which drives refinement) and the camera at `radii` times the
## body's radius, rotated `sun_offset` radians around it — 0 is fully sunlit,
## ~0.8 puts the terminator across the disc.
func _frame_body(body: CelestialBody, radii: float, sun_offset: float) -> void:
	var centre: Vector3 = OriginShift.to_render(body.true_pos)
	var to_sun: Vector3 = (OriginShift.to_render(_system.get_body(&"sun").true_pos)
		- centre).normalized()
	var axis: Vector3 = to_sun.cross(Vector3.UP)
	if axis.length() < 0.1:
		axis = to_sun.cross(Vector3.RIGHT)
	var dir: Vector3 = to_sun.rotated(axis.normalized(), sun_offset)
	var where: Vector3 = centre + dir * (body.def.radius * radii)

	_ship.freeze = true
	for _i in 3:
		_ship.global_position = where
		await get_tree().physics_frame
	_cam.global_position = where
	_cam.look_at(centre, Vector3.UP)
	await _settle(body)


## Just above the surface, looking along it: the low-skim framing.
func _skim_frame(body: CelestialBody) -> void:
	var centre: Vector3 = OriginShift.to_render(body.true_pos)
	var to_sun: Vector3 = (OriginShift.to_render(_system.get_body(&"sun").true_pos)
		- centre).normalized()
	var up: Vector3 = to_sun
	var along: Vector3 = up.cross(Vector3.UP).normalized()
	var where: Vector3 = centre + up * (body.def.radius + 140.0)
	_ship.freeze = true
	for _i in 3:
		_ship.global_position = where
		await get_tree().physics_frame
	_cam.global_position = where
	# Look along the surface with a slight downward tilt, so terrain fills the
	# lower frame and the limb sits high.
	_cam.look_at(where + along * 400.0 - up * 90.0, up)
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
	var previous := {}
	var stable: int = 0
	var guard: int = 0
	while stable < 3 and guard < 300:
		surface.force_evaluate()
		await get_tree().process_frame
		guard += 1
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
