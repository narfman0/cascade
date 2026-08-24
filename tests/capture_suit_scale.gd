extends Node
## One shot: the EVA suit floating beside the hull, both in frame — the
## proportion check for the 1.8x ship rescale (OR1 follow-up).

func _ready() -> void:
	var world: Node3D = load("res://scenes/game_world.tscn").instantiate()
	add_child(world)
	for _i in 8:
		await get_tree().process_frame
	var ship: RigidBody3D = world.get_node("Ship")
	ship.freeze = true
	var suit: RigidBody3D = ship.get("character")
	if suit.get_parent() == null:
		world.add_child(suit)
	suit.freeze = true
	var cs := suit.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if cs:
		cs.disabled = true
	# The suit's gltf is internally consistent (joints AND binds both in
	# centimetres, vertices metres): untouched, it renders at 1.73 m. Play
	# the bundled clip for a natural pose — its tracks share the cm space.
	for ap in suit.find_children("*", "AnimationPlayer", true, false):
		var anims: PackedStringArray = (ap as AnimationPlayer).get_animation_list()
		if anims.size() > 0:
			(ap as AnimationPlayer).play(anims[0])
	# CLEAR OF THE DEBRIS FIELD: spawn is inside the prop field, and every
	# jagged rock at close range photobombs as a "giant suit limb".
	ship.global_position += Vector3(0, 30000, 0)
	# Beside the hull, between camera and ship, upright in ship frame.
	for _i in 30:
		suit.global_transform = Transform3D(
			ship.global_basis, ship.to_global(Vector3(5.6, 0.0, 0.0)))
		await get_tree().physics_frame
	for _i in 30:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png("user://shots/suit_vs_ship.png")
	print("  wrote suit_vs_ship")
	get_tree().quit()
