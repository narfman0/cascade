extends Node
## Renderer probe: one framed shot of Earth (atmosphere shell, clouds, terrain,
## sky) plus a report of what the driver actually gave us.
##
## Run:  xvfb-run -a godot --rendering-method mobile res://tests/capture_renderer_probe.tscn
## The Android and web exports do NOT use Forward+ — this is how we find out
## what the atmosphere looks like there without a phone in hand. Pass the label
## via CASCADE_PROBE so shots don't overwrite each other.

const OUT_DIR: String = "user://shots"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var label: String = OS.get_environment("CASCADE_PROBE")
	if label == "":
		label = "probe"

	var world: Node3D = load("res://scenes/game_world.tscn").instantiate()
	add_child(world)
	for i in 8:
		await get_tree().process_frame

	var ship: RigidBody3D = world.get_node("Ship")
	var system: SolarSystem = world.get_node("SolarSystem")
	var earth := system.get_body(&"earth")

	# Park on the sunlit limb at 1.6 R: the atmosphere shell, the cloud deck,
	# the terrain and the sky all in one frame — everything that could break.
	var sunward: Vector3 = (OriginShift.to_render(system.get_body(&"sun").true_pos)
		- OriginShift.to_render(earth.true_pos)).normalized()
	var dir: Vector3 = (sunward * 0.5 + Vector3(0, 0.3, 1)).normalized()
	ship.freeze = true
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		var where: Vector3 = OriginShift.to_render(earth.true_pos) + dir * (earth.def.radius * 1.6)
		ship.global_position = where
		ship.look_at(OriginShift.to_render(earth.true_pos), Vector3.UP)
		await get_tree().physics_frame
		if cam == null or cam.global_position.distance_to(where) < 40.0:
			break
	for i in 40:
		await get_tree().process_frame

	print("=== renderer probe: %s ===" % label)
	print("  rendering_method : %s" % ProjectSettings.get_setting(
		"rendering/renderer/rendering_method"))
	print("  video adapter    : %s" % RenderingServer.get_video_adapter_name())
	print("  api version      : %s" % RenderingServer.get_video_adapter_api_version())
	var surface := earth.planet_surface()
	print("  atmosphere shell : %s" % (surface.get_node_or_null("Atmosphere") != null))
	print("  fps (headless)   : %.1f" % Engine.get_frames_per_second())

	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/probe_%s.png" % [OUT_DIR, label]
	image.save_png(path)
	print("  wrote %s" % path)
	get_tree().quit()


## (The touch layout screenshots reuse this scene: run with CASCADE_TOUCH=1
## and the widgets render over the same framing.)
