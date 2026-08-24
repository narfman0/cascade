extends Node
## Earth from several angles and across time, plus the dark-side proof: five
## framings that together show phase, spin, terminator behaviour and the OR2
## eclipse working where the ship actually is. Logs sun visibility and light
## energy for the umbra shot so the screenshot carries its own numbers.
##
## Run: xvfb-run -a godot res://tests/capture_earth_series.tscn

const OUT_DIR: String = "user://shots"

var _system: SolarSystem
var _ship: RigidBody3D
var _earth: CelestialBody


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var world: Node3D = load("res://scenes/game_world.tscn").instantiate()
	add_child(world)
	for _i in 8:
		await get_tree().process_frame
	_system = world.get_node("SolarSystem")
	_ship = world.get_node("Ship")
	_earth = _system.get_body(&"earth")
	_ship.freeze = true
	GameState.flight_assist_enabled = false

	var surface := _earth.planet_surface()
	var deadline: int = Time.get_ticks_msec() + 60000
	while not (surface.textures_ready and surface.atmosphere_ready) \
			and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	# 1. The day side, nearly full.
	await _frame(2.8, 0.25)
	await _shot("earth_1_day")

	# 2. Half phase: the terminator down the middle.
	await _frame(2.6, 1.55)
	await _shot("earth_2_half")

	# 3. Night crescent: city lights carrying the dark side.
	await _frame(2.4, 2.3)
	await _shot("earth_3_crescent")

	# 4. Same half-phase framing, one third of a day later — the spin has
	#    carried different continents under the same terminator.
	SimClock.sim_time += _earth.def.spin_period / 3.0
	for _i in 4:
		await get_tree().physics_frame
	await _frame(2.6, 1.55)
	await _shot("earth_4_half_later")

	# 5. The dark-side proof: low over the night side, inside the umbra.
	#    The hull must go dark (eclipse follows the SHIP since OR2), the
	#    cities light the ground, and the sun is gone.
	await _frame(1.35, 2.75)
	print("  umbra check: sun_visibility %.3f, light energy %.3f" % [
		_system.sun_visibility,
		(_system.get_node("SunLight") as DirectionalLight3D).light_energy])
	await _shot("earth_5_umbra_low")

	print("shots written to %s" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit()


## Pose at `radii` from the centre, rotated `sun_offset` radians off the sun
## line (0 = full day, PI = behind the planet), looking at the disc. Held per
## frame (the body co-moves under the frozen ship), settled, re-held.
func _frame(radii: float, sun_offset: float) -> void:
	var resolve := func() -> Array:
		var centre: Vector3 = OriginShift.to_render(_earth.true_pos)
		var to_sun: Vector3 = (OriginShift.to_render(
			_system.get_body(&"sun").true_pos) - centre).normalized()
		var axis: Vector3 = to_sun.cross(Vector3.UP)
		if axis.length() < 0.1:
			axis = to_sun.cross(Vector3.RIGHT)
		var dir: Vector3 = to_sun.rotated(axis.normalized(), sun_offset)
		var where: Vector3 = centre + dir * (_earth.def.radius * radii)
		return [where + dir * 12.0, centre, Vector3.UP]
	await _hold(resolve)
	await _settle()
	await _hold(resolve)


func _hold(resolve: Callable) -> void:
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		var pose: Array = resolve.call()
		var up: Vector3 = pose[2]
		var dir: Vector3 = (pose[1] as Vector3) - (pose[0] as Vector3)
		if absf(dir.normalized().dot(up)) > 0.99:
			up = Vector3.RIGHT
		_ship.global_position = pose[0]
		_ship.look_at(pose[1], up)
		await get_tree().physics_frame
		if cam == null:
			break
		if cam.global_position.distance_to(_ship.to_global(_ship.get_node("CameraRig").third_person_offset)) < 1.0:
			break
	for _i in 20:
		await get_tree().process_frame


func _settle() -> void:
	var surface := _earth.planet_surface()
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


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	image.save_png("%s/%s.png" % [OUT_DIR, label])
	print("  wrote %s" % label)
