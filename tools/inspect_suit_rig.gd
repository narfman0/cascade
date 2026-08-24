extends SceneTree
## One-shot: print the suit scene's node layout, skeleton, and track paths.
## Run: godot --headless -s res://tools/inspect_suit_rig.gd

func _init() -> void:
	var scene: PackedScene = load(
		"res://assets/meshes/POLYGON_Scifi_Space_SourceFiles_v2/SourceFiles/Characters/SK_Chr_BR_EVA_Suit_01.gltf")
	var inst := scene.instantiate()
	_dump(inst, 0)
	var player := inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player:
		for lib_name in player.get_animation_library_list():
			var lib := player.get_animation_library(lib_name)
			for anim_name in lib.get_animation_list():
				var anim := lib.get_animation(anim_name)
				print("clip '%s/%s' len %.2f tracks %d" % [lib_name, anim_name, anim.length, anim.get_track_count()])
				for i in mini(anim.get_track_count(), 4):
					print("   track %d type %d path %s" % [i, anim.track_get_type(i), anim.track_get_path(i)])
	var skel := inst.find_child("Skeleton3D", true, false) as Skeleton3D
	if skel:
		print("skeleton '%s' bones %d, motion_scale %.3f" % [skel.name, skel.get_bone_count(), skel.motion_scale])
		print("  bone0 %s rest origin %s" % [skel.get_bone_name(0), skel.get_bone_rest(0).origin])
	inst.free()
	quit()


func _dump(node: Node, depth: int) -> void:
	print("%s%s (%s)" % ["  ".repeat(depth), node.name, node.get_class()])
	if depth < 3:
		for child in node.get_children():
			_dump(child, depth + 1)
