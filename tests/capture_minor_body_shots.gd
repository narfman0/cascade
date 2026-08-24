extends Node
## Track LD7 screenshot — landed on an asteroid the ship was sized for.
##
## Run: xvfb-run -a godot res://tests/capture_minor_body_shots.tscn

const OUT_DIR: String = "user://shots"

var _ship: RigidBody3D
var _system: SolarSystem


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var world: Node3D = load("res://scenes/game_world.tscn").instantiate()
	add_child(world)
	for i in 6:
		await get_tree().process_frame

	_ship = world.get_node("Ship")
	_system = world.get_node("SolarSystem")
	var eros := _system.get_body(&"eros")
	var autoland := _ship.get_node("AutolandComputer") as AutolandComputer

	# Sun-side staging, then let autoland fly the whole thing.
	var sunward: Vector3 = (OriginShift.to_render(_system.get_body(&"sun").true_pos)
		- OriginShift.to_render(eros.true_pos)).normalized()
	var dir: Vector3 = (sunward + Vector3(0, 0.35, 0)).normalized()
	_ship.freeze = true
	var deadline: int = Time.get_ticks_msec() + 20000
	var cam := get_viewport().get_camera_3d()
	while Time.get_ticks_msec() < deadline:
		var where: Vector3 = OriginShift.to_render(eros.true_pos) + dir * (eros.def.radius * 1.35)
		_ship.global_position = where
		var fwd: Vector3 = dir.cross(Vector3.RIGHT).normalized()
		_ship.global_basis = Basis(fwd.cross(dir).normalized(), dir, -fwd).orthonormalized()
		await get_tree().physics_frame
		if _ship.global_position.length() < CelestialBody.MAX_RENDER_DISTANCE \
				and (cam == null or cam.global_position.distance_to(where) < 40.0):
			break
	for i in 3:
		_ship.global_position = OriginShift.to_render(eros.true_pos) \
			+ dir * (eros.def.radius * 1.35)
		await get_tree().physics_frame
	_ship.freeze = false
	var ev: Array = eros.velocity_at(SimClock.sim_time)
	_ship.linear_velocity = Vector3(float(ev[0]), float(ev[1]), float(ev[2]))
	autoland.engage()

	deadline = Time.get_ticks_msec() + 300000
	while not GameState.landed and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
	for i in 40:
		await get_tree().process_frame
	await _shot("24_landed_asteroid")
	get_tree().quit()


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/%s.png" % [OUT_DIR, label]
	image.save_png(path)
	print("  wrote %s" % path)
