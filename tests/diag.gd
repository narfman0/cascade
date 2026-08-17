extends Node

func _ready() -> void:
	var world: Node3D = load("res://scenes/game_world.tscn").instantiate()
	add_child(world)
	for _i in 6:
		await get_tree().process_frame
	var system: SolarSystem = world.get_node("SolarSystem")
	var ship: RigidBody3D = world.get_node("Ship")
	var cam: Camera3D = ship.get_node("CameraRig/Camera3D")
	print("camera: current=%s pos=%s fov=%.1f  -Z=%s" % [cam.current, cam.global_position, cam.fov, -cam.global_basis.z])
	print("ship pos=%s" % ship.global_position)
	for body in system.bodies:
		var render_pos: Vector3 = body.position
		var dist: float = (render_pos - cam.global_position).length()
		var mesh: MeshInstance3D = body.get_node("Mesh")
		var eff_radius: float = mesh.scale.x
		var ang: float = rad_to_deg(2.0 * atan(eff_radius / maxf(dist, 0.001)))
		print("  %-10s render=%9.0f m  true=%9.0f m  mesh_scale=%8.1f  angular=%6.2f°  proxy=%s" % [
			body.def.display_name, render_pos.length(), body.true_distance, eff_radius, ang, body.is_proxy])
	get_tree().quit()
