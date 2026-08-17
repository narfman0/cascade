extends Node
## Screenshot harness for review. Loads the world and captures a few framings.
##
## Run: xvfb-run -a godot res://tests/capture_shots.tscn
## Writes PNGs to user:// (printed on exit) — used to eyeball lighting and the
## solar system without a display attached.

const OUT_DIR: String = "user://shots"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var world: Node3D = load("res://scenes/game_world.tscn").instantiate()
	add_child(world)
	await _settle(6)

	var ship: RigidBody3D = world.get_node("Ship")
	var autopilot: Autopilot = ship.get_node("Autopilot")
	var system: SolarSystem = world.get_node("SolarSystem")

	await _shot("01_low_earth_orbit")

	# Look back at Earth so the terminator and the lit limb are in frame.
	var earth := system.get_body(&"earth")
	_aim_ship_at(ship, OriginShift.to_render(earth.true_pos))
	await _settle(40)
	await _shot("02_earth_limb", ship, earth)

	# Sunward: the star should read as a bright disc, not a white screen.
	var sun := system.get_body(&"sun")
	_aim_ship_at(ship, OriginShift.to_render(sun.true_pos))
	await _settle(40)
	await _shot("03_sunward", ship, sun)

	# Mid-transfer, under time compression.
	autopilot.engage(system.get_body(&"jupiter"))
	await _settle(90)
	await _shot("04_transfer_cruise")
	print("  cruise status: %s" % autopilot.status_line())

	# Let it run to arrival, then look at the destination.
	var guard: int = 0
	while autopilot.phase != Autopilot.Phase.IDLE and guard < 4000:
		await get_tree().process_frame
		guard += 1
	var jupiter := system.get_body(&"jupiter")
	_aim_ship_at(ship, OriginShift.to_render(jupiter.true_pos))
	await _settle(40)
	await _shot("05_jupiter_arrival", ship, jupiter)
	print("  parked %.0f m from Jupiter centre (standoff %.0f m)" % [
		OriginShift.dv_length(OriginShift.dv_sub(
			OriginShift.to_true(ship.global_position), jupiter.true_pos)),
		jupiter.arrival_standoff()])

	print("shots written to %s" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit()


func _aim_ship_at(ship: Node3D, target: Vector3) -> void:
	var dir: Vector3 = target - ship.global_position
	if dir.length() < 1.0:
		return
	# The physics server owns a live RigidBody3D's transform and reverts writes
	# from script, so freeze before aiming. (The autopilot freezes for the same
	# reason.) This is a harness-only concern.
	var body := ship as RigidBody3D
	if body:
		body.freeze = true
	var up := Vector3.UP
	if absf(dir.normalized().dot(up)) > 0.99:
		up = Vector3.RIGHT
	ship.look_at(target, up)


func _settle(frames: int) -> void:
	for _i in frames:
		await get_tree().process_frame


func _shot(label: String, ship: Node3D = null, subject: CelestialBody = null) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/%s.png" % [OUT_DIR, label]
	image.save_png(path)
	var note := ""
	if ship and subject:
		var cam: Camera3D = ship.get_node("CameraRig/Camera3D")
		var to_subject: Vector3 = subject.position - cam.global_position
		var forward: Vector3 = -cam.global_basis.z
		var radius: float = (subject.get_node("Mesh") as MeshInstance3D).scale.x
		note = "  [%s: %.1f° wide, %.0f° off-axis]" % [
			subject.nav_display_name(),
			rad_to_deg(2.0 * atan(radius / maxf(to_subject.length(), 0.001))),
			rad_to_deg(forward.angle_to(to_subject.normalized())),
		]
	print("  wrote %s%s" % [path, note])
