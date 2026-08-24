extends Node
## Track FX screenshot harness — the engine seen doing its work.
##
## Run: xvfb-run -a godot res://tests/capture_fx_shots.tscn

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
	var earth := system.get_body(&"earth")
	GameState.flight_assist_enabled = false

	# Over Earth's night side, nose toward the dark limb: the third-person
	# camera hangs behind the stern, so the plume fires toward the lens with
	# the unlit planet as the backdrop.
	var sunward: Vector3 = (OriginShift.to_render(system.get_body(&"sun").true_pos)
		- OriginShift.to_render(earth.true_pos)).normalized()
	var night_dir: Vector3 = (-sunward + Vector3(0, 0.35, 0)).normalized()
	_ship.freeze = true
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		var where: Vector3 = OriginShift.to_render(earth.true_pos) \
			+ night_dir * (earth.def.radius + 2500.0)
		_ship.global_position = where
		_ship.look_at(OriginShift.to_render(earth.true_pos), Vector3.UP)
		await get_tree().physics_frame
		if cam == null or cam.global_position.distance_to(where) < 40.0:
			break
	_ship.freeze = false
	_ship.linear_velocity = LandingComputer.surface_point_velocity(earth, _ship.global_position)

	# 1. Main engine burn.
	Input.action_press("thrust_forward")
	for i in 45:
		await get_tree().physics_frame
		await get_tree().process_frame
	await _shot("17_engine_burn")
	Input.action_release("thrust_forward")

	# 2. RCS: yaw + strafe puffs, nose and flank thrusters alive.
	Input.action_press("thrust_right")
	Input.action_press("roll_left")
	for i in 30:
		await get_tree().physics_frame
		await get_tree().process_frame
	await _shot("18_rcs_puffs")
	Input.action_release("thrust_right")
	Input.action_release("roll_left")

	print("shots written to %s" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit()


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/%s.png" % [OUT_DIR, label]
	image.save_png(path)
	print("  wrote %s" % path)
