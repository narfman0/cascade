extends Node
## Track HZ screenshot harness — the warning over Jupiter, and the loss.
##
## Run: xvfb-run -a godot res://tests/capture_hazard_shots.tscn

const OUT_DIR: String = "user://shots"

var _ship: RigidBody3D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var world: Node3D = load("res://scenes/game_world.tscn").instantiate()
	add_child(world)
	for i in 6:
		await get_tree().process_frame

	_ship = world.get_node("Ship")
	var system: SolarSystem = world.get_node("SolarSystem")
	var jupiter := system.get_body(&"jupiter")
	var hazard := _ship.get_node("HazardMonitor") as HazardMonitor
	GameState.flight_assist_enabled = false

	# 1. Deep in the warning band, Jupiter filling the sky below — sun-side
	# so the bands light. Margin 0.3 → r = R*sqrt(6.2/3.7).
	var sunward: Vector3 = (OriginShift.to_render(system.get_body(&"sun").true_pos)
		- OriginShift.to_render(jupiter.true_pos)).normalized()
	var r_warn: float = jupiter.def.radius * sqrt(6.20 / 3.7)
	_ship.freeze = true
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		var where: Vector3 = OriginShift.to_render(jupiter.true_pos) \
			+ (sunward + Vector3(0, 0.25, 0)).normalized() * r_warn
		_ship.global_position = where
		_ship.look_at(OriginShift.to_render(jupiter.true_pos), Vector3.UP)
		await get_tree().physics_frame
		if cam == null or cam.global_position.distance_to(where) < 40.0:
			break
	_ship.freeze = false
	var jv: Array = jupiter.velocity_at(SimClock.sim_time)
	_ship.linear_velocity = Vector3(float(jv[0]), float(jv[1]), float(jv[2]))
	for i in 30:
		await get_tree().process_frame
	await _shot("20_gravity_warning")

	# 2. The fall: cut thrust, let Jupiter take it, catch the overlay.
	var lost: Array = [false]
	hazard.hull_lost.connect(func(_r: String) -> void: lost[0] = true)
	_ship.freeze = true
	for i in 3:
		_ship.global_position = OriginShift.to_render(jupiter.true_pos) \
			+ (sunward + Vector3(0, 0.25, 0)).normalized() * (jupiter.def.radius * 1.06)
		await get_tree().physics_frame
	_ship.freeze = false
	_ship.linear_velocity = Vector3(float(jv[0]), float(jv[1]), float(jv[2]))
	var restored_flag: Array = [false]
	hazard.restored.connect(func() -> void: restored_flag[0] = true)
	deadline = Time.get_ticks_msec() + 10000
	while not lost[0] and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
	# Mid-presentation: overlay fading in (the beat is 2.5 s; llvmpipe renders
	# ~20 fps, so a dozen frames sits mid-fade).
	for i in 14:
		await get_tree().process_frame
	await _shot("21_hull_lost")
	# And the recovery: back at the checkpoint, live.
	deadline = Time.get_ticks_msec() + 10000
	while not restored_flag[0] and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
	for i in 40:
		await get_tree().process_frame
	await _shot("22_restored")

	print("shots written to %s" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit()


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/%s.png" % [OUT_DIR, label]
	image.save_png(path)
	print("  wrote %s" % path)
