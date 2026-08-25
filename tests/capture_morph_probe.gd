extends Node
## Geomorph vertex-attribute probe (the phone's shattered-Earth bug).
##
## Run: CASCADE_PROBE=x xvfb-run -a godot --rendering-method gl_compatibility \
##        res://tests/capture_morph_probe.tscn
##
## Settled patches sit at morph_t = 1.0, where `mix(CUSTOM0.xyz, VERTEX, 1.0)`
## discards the parent position entirely — so a broken CUSTOM0 is INVISIBLE at
## rest and only appears while patches are mid-transition. That is why the
## first desktop probe looked clean and the phone did not.
##
## This forces every resident patch to morph_t = 0.5. Correct data renders a
## smooth surface (halfway to the parent's shape). Missing data collapses each
## patch toward its own centre — the starburst.

const OUT_DIR: String = "user://shots"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var label: String = OS.get_environment("CASCADE_PROBE")
	if label == "":
		label = "morph"

	var world: Node3D = load("res://scenes/game_world.tscn").instantiate()
	add_child(world)
	for i in 8:
		await get_tree().process_frame

	var ship: RigidBody3D = world.get_node("Ship")
	var system: SolarSystem = world.get_node("SolarSystem")
	var earth := system.get_body(&"earth")
	var surface := earth.planet_surface()

	# Close enough that the quadtree is deep and patches are big on screen.
	var sunward: Vector3 = (OriginShift.to_render(system.get_body(&"sun").true_pos)
		- OriginShift.to_render(earth.true_pos)).normalized()
	var dir: Vector3 = (sunward * 0.6 + Vector3(0, 0.4, 1)).normalized()
	# This is a RENDERING probe: stand the hazard monitor down, and hold the
	# hull at ground-matched velocity. Parking at 1.12 R doing 130 m/s is an
	# entry burn, and Track HZ rightly incinerated the first attempt.
	var hazard := ship.get_node_or_null("HazardMonitor")
	if hazard:
		hazard.set_physics_process(false)
	ship.freeze = true
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 25000
	while Time.get_ticks_msec() < deadline:
		var where: Vector3 = OriginShift.to_render(earth.true_pos) + dir * (earth.def.radius * 1.12)
		ship.global_position = where
		ship.look_at(OriginShift.to_render(earth.true_pos), Vector3.UP)
		ship.linear_velocity = LandingComputer.surface_point_velocity(
			earth, ship.global_position)
		await get_tree().physics_frame
		surface.force_evaluate()
		if cam == null or cam.global_position.distance_to(where) < 40.0:
			break
	# Trap #5: Earth keeps moving at 130 m/s under a frozen ship. Re-place it
	# every settle frame or the camera ends up INSIDE the planet — which is
	# what the first run of this probe actually photographed.
	for i in 30:
		ship.global_position = OriginShift.to_render(earth.true_pos) \
			+ dir * (earth.def.radius * 1.12)
		await get_tree().process_frame
		surface.force_evaluate()

	# Force the transition state the phone was caught in.
	var patched: int = _force_morph(surface, 0.5)
	for i in 10:
		await get_tree().process_frame

	print("=== morph probe: %s ===" % label)
	print("  patches forced to morph_t 0.5 : %d" % patched)
	print("  custom0 format (0=RGB8,4=RG_F,5=RGB_F,6=RGBA_F): %d" % _custom_format(surface))
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/morph_%s.png" % [OUT_DIR, label]
	image.save_png(path)
	print("  wrote %s" % path)
	get_tree().quit()


func _force_morph(surface: Node3D, value: float) -> int:
	var n: int = 0
	for mi in _mesh_instances(surface):
		mi.set_instance_shader_parameter("morph_t", value)
		n += 1
	return n


func _custom_format(surface: Node3D) -> int:
	for mi in _mesh_instances(surface):
		var mesh: ArrayMesh = mi.mesh as ArrayMesh
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var fmt: int = mesh.surface_get_format(0)
		return (fmt >> Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) & 0x7
	return -1


func _mesh_instances(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is MeshInstance3D:
			out.append(child)
		out.append_array(_mesh_instances(child))
	return out
