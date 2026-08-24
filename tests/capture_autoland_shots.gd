extends Node
## Track AL screenshot — the computer flying the descent, belly jets lit.
##
## Run: xvfb-run -a godot res://tests/capture_autoland_shots.tscn

const OUT_DIR: String = "user://shots"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var world: Node3D = load("res://scenes/game_world.tscn").instantiate()
	add_child(world)
	for i in 6:
		await get_tree().process_frame

	var ship: RigidBody3D = world.get_node("Ship")
	var system: SolarSystem = world.get_node("SolarSystem")
	var moon := system.get_body(&"moon")
	var autoland := ship.get_node("AutolandComputer") as AutolandComputer
	var surface = moon.planet_surface()

	# Sun-side staging so the descent is lit.
	var sunward: Vector3 = (OriginShift.to_render(system.get_body(&"sun").true_pos)
		- OriginShift.to_render(moon.true_pos)).normalized()
	var dir: Vector3 = (sunward + Vector3(0, 0.3, 0)).normalized()
	ship.freeze = true
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 25000
	while Time.get_ticks_msec() < deadline:
		var where: Vector3 = OriginShift.to_render(moon.true_pos) + dir * (moon.def.radius * 1.3)
		ship.global_position = where
		var fwd: Vector3 = dir.cross(Vector3.RIGHT).normalized()
		ship.global_basis = Basis(fwd.cross(dir).normalized(), dir, -fwd).orthonormalized()
		await get_tree().physics_frame
		surface.force_evaluate()
		if cam == null or cam.global_position.distance_to(where) < 40.0:
			break
	ship.freeze = false
	var mv: Array = moon.velocity_at(SimClock.sim_time)
	ship.linear_velocity = Vector3(float(mv[0]), float(mv[1]), float(mv[2]))
	autoland.engage()

	# Ride down until low over the ground, then take the frame: AUTOLAND line
	# up, belly plume firing against the surface.
	deadline = Time.get_ticks_msec() + 240000
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var alt: float = (ship.global_position
			- OriginShift.to_render(moon.true_pos)).length() - moon.def.radius
		if alt < 120.0 or GameState.landed:
			break
	for i in 10:
		await get_tree().process_frame
	await _shot("23_autoland")
	get_tree().quit()


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/%s.png" % [OUT_DIR, label]
	image.save_png(path)
	print("  wrote %s" % path)
