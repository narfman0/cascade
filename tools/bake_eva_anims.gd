extends SceneTree
## Track AN baker: retarget Base-Locomotion clips onto the EVA suit rig and
## save them as res://assets/anims/eva_locomotion.res (an AnimationLibrary).
##
## Run: godot --headless -s res://tools/bake_eva_anims.gd
##
## Why a baker and not a name-swap: the two Synty generations share a body
## plan but NOT rest rotations (verified: Pelvis rest [-0.70,-0.12,-0.12,0.70]
## vs Hips [-0.03,0.01,0.00,1.00]) — renaming tracks explodes the pose. Both
## rigs DO rest in a world-space T-pose, so per-bone world orientation deltas
## transfer cleanly:
##     D(t)      = W_src(t) * inv(W_src_rest)        (world, per bone)
##     W_tgt(t)  = D(t) * W_tgt_rest
##     local(t)  = inv(W_parent_tgt(t)) * W_tgt(t)
## computed in the INSTANCED scenes' world space, because each rig's skeleton
## space is axis-rotated differently by its cook (the suit's hips rest at
## local -Z; the pack's at +Y). Hips also get a position track: world delta
## scaled by the rigs' hip-height ratio, so the run bob survives the size
## difference. Unmapped bones (fingers, eyes) keep the suit's rest.

const SUIT := "res://assets/meshes/POLYGON_Scifi_Space_SourceFiles_v2/SourceFiles/Characters/SK_Chr_BR_EVA_Suit_01.gltf"
const REFERENCE := "res://assets/meshes/ANIMATION_Base_Locomotion_SourceFiles_v3/SourceFiles/Character/PolygonSyntyCharacter.glb"
const PACK := "res://assets/meshes/ANIMATION_Base_Locomotion_SourceFiles_v3/SourceFiles/Animations/Polygon/Masculine"
const OUT := "res://assets/anims/eva_locomotion.res"
const FPS := 30.0

## clip name -> [source file, loops]
const CLIPS := {
	"idle": ["Idle/A_Idle_Standing_Masc.glb", true],
	"walk": ["Locomotion/Walk/A_Walk_F_Masc.glb", true],
	"run": ["Locomotion/Run/A_Run_F_Masc.glb", true],
	"jump": ["InAir/A_Jump_Idle_Masc.glb", false],
	"fall": ["InAir/A_InAir_FallShort_Masc.glb", true],
	"land_soft": ["InAir/A_Land_IdleSoft_Masc.glb", false],
	"land_medium": ["InAir/A_Land_IdleMedium_Masc.glb", false],
	"land_hard": ["InAir/A_Land_IdleHard_Masc.glb", false],
}

## suit bone -> pack bone. Fingers/eyes stay at suit rest (gloves anyway).
const MAP := {
	"Pelvis": "Hips",
	"spine_01": "Spine_01", "spine_02": "Spine_02", "spine_03": "Spine_03",
	"neck_01": "Neck", "head": "Head",
	"clavicle_l": "Clavicle_L", "UpperArm_L": "Shoulder_L",
	"lowerarm_l": "Elbow_L", "Hand_L": "Hand_L",
	"clavicle_r": "Clavicle_R", "UpperArm_R": "Shoulder_R",
	"lowerarm_r": "Elbow_R", "Hand_R": "Hand_R",
	"Thigh_L": "UpperLeg_L", "calf_l": "LowerLeg_L", "Foot_L": "Ankle_L",
	"ball_l": "Ball_L", "toes_l": "Toes_L",
	"Thigh_R": "UpperLeg_R", "calf_r": "LowerLeg_R", "Foot_R": "Ankle_R",
	"ball_r": "Ball_R", "toes_r": "Toes_R",
}


var _ref_rest_world: Dictionary = {}


func _init() -> void:
	var suit_scene: Node = (load(SUIT) as PackedScene).instantiate()
	var tgt: Skeleton3D = suit_scene.find_child("Skeleton3D", true, false)
	var tgt_rest_world: Dictionary = _world_rests(tgt)
	# The pack's clips rest in a deep A-pose (arm 52 degrees down); the suit
	# rests in a T-pose. Rest-relative transfer against the clip rig pins the
	# arms at T forever. The pack ships its reference character IN T-POSE
	# (verified: arm dir [+1.00,-0.09]) precisely for this: rotation deltas
	# are measured against the reference's rests instead, which speak the
	# same pose language as the suit's.
	var ref_scene: Node = (load(REFERENCE) as PackedScene).instantiate()
	var ref_skel: Skeleton3D = ref_scene.find_child("Skeleton3D", true, false)
	_ref_rest_world = _world_rests(ref_skel)
	ref_scene.free()

	var lib := AnimationLibrary.new()
	for clip_name in CLIPS:
		var anim := _bake(clip_name, tgt, tgt_rest_world)
		if anim != null:
			lib.add_animation(clip_name, anim)
			print("baked %-12s %5.2fs %3d tracks" % [clip_name, anim.length, anim.get_track_count()])
	DirAccess.make_dir_recursive_absolute("res://assets/anims")
	var err := ResourceSaver.save(lib, OUT)
	print("saved %s (%s)" % [OUT, error_string(err)])
	quit(0 if err == OK and lib.get_animation_list().size() == CLIPS.size() else 1)


## Model-space transform of a skeleton node: composed by hand up to the scene
## root, because nothing here is in a SceneTree (global_transform would error).
func _model_xform(skel: Skeleton3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var node: Node = skel
	while node != null:
		if node is Node3D:
			xf = (node as Node3D).transform * xf
		node = node.get_parent()
	return xf


## World-space rest transform per bone name.
func _world_rests(skel: Skeleton3D) -> Dictionary:
	var base := _model_xform(skel)
	var out: Dictionary = {}
	for i in skel.get_bone_count():
		out[skel.get_bone_name(i)] = base * skel.get_bone_global_rest(i)
	return out


func _bake(clip_name: String, tgt: Skeleton3D, tgt_rest_world: Dictionary) -> Animation:
	var src_path: String = PACK + "/" + CLIPS[clip_name][0]
	if not ResourceLoader.exists(src_path):
		push_error("missing source clip: " + src_path)
		return null
	var src_scene: Node = (load(src_path) as PackedScene).instantiate()
	root.add_child(src_scene)  # the player needs a tree to seek in
	var src: Skeleton3D = src_scene.find_child("Skeleton3D", true, false)
	var src_base: Transform3D = _model_xform(src)
	var player: AnimationPlayer = src_scene.find_child("AnimationPlayer", true, false)
	var src_anim_name: String = player.get_animation_list()[0]
	var src_anim: Animation = player.get_animation(src_anim_name)
	var length: float = src_anim.length
	# The player is bypassed entirely: in this frameless -s environment even
	# play()+seek(update=true) never applied a pose (verified: eight rest-pose
	# clips, twice). Bone poses are set by hand from the track data instead —
	# synchronous, deterministic, no scene machinery to trust.
	var src_tracks: Array = []  # [type, bone_idx, track_idx]
	for ti in src_anim.get_track_count():
		var track_path := String(src_anim.track_get_path(ti))
		var bone_name := track_path.get_slice(":", 1)
		var bi := src.find_bone(bone_name)
		if bi >= 0:
			src_tracks.append([src_anim.track_get_type(ti), bi, ti])
	print("    [%s] %d/%d tracks matched; sample paths: %s" % [
		clip_name, src_tracks.size(), src_anim.get_track_count(),
		[String(src_anim.track_get_path(0)), String(src_anim.track_get_path(1))]])
	var src_rest_world: Dictionary = _world_rests(src)

	# Hip-height ratio scales the hips' world position delta onto the suit.
	var src_hips_h: float = absf((src_rest_world["Hips"] as Transform3D).origin.y)
	var tgt_hips_h: float = absf((tgt_rest_world["Pelvis"] as Transform3D).origin.y)
	var pos_scale: float = tgt_hips_h / maxf(src_hips_h, 1e-6)

	# Suit bones ordered parents-first, with per-bone parent index.
	var order: Array = []
	for i in tgt.get_bone_count():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		return _depth(tgt, a) < _depth(tgt, b))

	var anim := Animation.new()
	anim.length = length
	anim.loop_mode = Animation.LOOP_LINEAR if CLIPS[clip_name][1] else Animation.LOOP_NONE
	var tracks: Dictionary = {}  # suit bone name -> rotation track idx
	for bone_name in MAP:
		var ti := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(ti, NodePath("Root/Skeleton3D:%s" % bone_name))
		tracks[bone_name] = ti
	var pelvis_pos_track := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(pelvis_pos_track, NodePath("Root/Skeleton3D:Pelvis"))

	var steps: int = maxi(int(ceil(length * FPS)), 2)
	for step in steps + 1:
		var t: float = minf(step / FPS, length)
		src.reset_bone_poses()
		for entry in src_tracks:
			match entry[0]:
				Animation.TYPE_ROTATION_3D:
					src.set_bone_pose_rotation(entry[1], src_anim.rotation_track_interpolate(entry[2], t))
				Animation.TYPE_POSITION_3D:
					src.set_bone_pose_position(entry[1], src_anim.position_track_interpolate(entry[2], t))
				Animation.TYPE_SCALE_3D:
					src.set_bone_pose_scale(entry[1], src_anim.scale_track_interpolate(entry[2], t))
		# Source world transforms composed BY HAND from local poses:
		# get_bone_global_pose reads a cache that never refreshes outside
		# frame processing (verified: locals changed, globals froze).
		var src_world: Dictionary = {}
		var src_globals: Array = []
		src_globals.resize(src.get_bone_count())
		for i in src.get_bone_count():
			var local: Transform3D = src.get_bone_pose(i)
			var pi: int = src.get_bone_parent(i)
			var g: Transform3D = local if pi < 0 else (src_globals[pi] as Transform3D) * local
			src_globals[i] = g
			src_world[src.get_bone_name(i)] = src_base * g

		# Target world this frame: mapped bones via delta, unmapped ride rest
		# under their animated parents.
		var tgt_world: Dictionary = {}
		var tgt_local: Dictionary = {}
		for bi in order:
			var bone_name: String = tgt.get_bone_name(bi)
			var parent: int = tgt.get_bone_parent(bi)
			var parent_world: Transform3D = _model_xform(tgt)
			if parent >= 0:
				parent_world = tgt_world[tgt.get_bone_name(parent)]
			var w: Transform3D
			if MAP.has(bone_name) and src_world.has(MAP[bone_name]):
				var rest_w: Transform3D = tgt_rest_world[bone_name]
				var src_w: Transform3D = src_world[MAP[bone_name]]
				# Rotation delta vs the T-pose REFERENCE rest; position delta
				# vs the clip rig's own rest (right bob amplitude).
				var src_rw_rot: Basis = (_ref_rest_world.get(
					MAP[bone_name], src_rest_world[MAP[bone_name]]) as Transform3D).basis
				var src_rw_pos: Vector3 = (src_rest_world[MAP[bone_name]] as Transform3D).origin
				var delta: Basis = src_w.basis * src_rw_rot.inverse()
				w = Transform3D(delta * rest_w.basis, rest_w.origin)
				if bone_name == "Pelvis":
					w.origin = rest_w.origin + (src_w.origin - src_rw_pos) * pos_scale
			else:
				# Unmapped: local rest under the (possibly animated) parent.
				var rest_local := Transform3D(
					Basis(tgt.get_bone_rest(bi).basis.get_rotation_quaternion()),
					tgt.get_bone_rest(bi).origin)
				w = parent_world * rest_local
			tgt_world[bone_name] = w
			tgt_local[bone_name] = parent_world.affine_inverse() * w

		for bone_name in MAP:
			var q: Quaternion = (tgt_local[bone_name] as Transform3D).basis.get_rotation_quaternion().normalized()
			anim.rotation_track_insert_key(tracks[bone_name], t, q)
		anim.position_track_insert_key(
			pelvis_pos_track, t, (tgt_local["Pelvis"] as Transform3D).origin)

	src_scene.queue_free()
	return anim


func _depth(skel: Skeleton3D, bone: int) -> int:
	var d: int = 0
	var p: int = skel.get_bone_parent(bone)
	while p >= 0:
		d += 1
		p = skel.get_bone_parent(p)
	return d
