extends Node
## Headless verification for Track AN: the baked locomotion library exists,
## loads onto the suit's player, and the animator's clip tracks the walk
## state through a scripted idle → run → jump → fall → land sequence.
##
## Run: godot --headless res://tests/anim_test.tscn

var _failures: int = 0
var _world: Node3D
var _ship: RigidBody3D
var _suit: RigidBody3D
var _animator: EvaAnimator
var _system: SolarSystem


func _ready() -> void:
	_world = load("res://scenes/game_world.tscn").instantiate()
	add_child(_world)
	await get_tree().process_frame
	await get_tree().process_frame

	_ship = _world.get_node("Ship")
	_suit = _ship.get("character") as RigidBody3D
	_animator = _suit.get_node("../EvaAnimator") if _suit.has_node("../EvaAnimator") else null
	if _animator == null:
		_animator = _find_animator()
	_system = _world.get_node("SolarSystem")

	_test_library()
	await _test_state_sequence()

	print("")
	if _failures == 0:
		print("PASS — all checks green")
	else:
		print("FAIL — %d check(s) failed" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _find_animator() -> EvaAnimator:
	# The suit is stowed out of the tree at bootstrap; the animator node
	# travels with it as a child of Character.
	for child in _suit.get_children():
		if child is EvaAnimator:
			return child
	return null


func _check(ok: bool, label: String, detail: String = "") -> void:
	if ok:
		print("  ok    %s %s" % [label, detail])
	else:
		_failures += 1
		print("  FAIL  %s %s" % [label, detail])


func _test_library() -> void:
	print("\n== library ==")
	var lib := load("res://assets/anims/eva_locomotion.res") as AnimationLibrary
	_check(lib != null, "baked library loads")
	if lib == null:
		return
	var clips := lib.get_animation_list()
	_check(clips.size() == 8, "eight clips", str(clips))
	for clip_name in ["idle", "walk", "run", "jump", "fall", "land_soft", "land_medium", "land_hard"]:
		var anim := lib.get_animation(clip_name)
		if anim == null:
			_check(false, "clip %s present" % clip_name)
			continue
	var run := lib.get_animation("run")
	_check(run.get_track_count() >= 25, "run tracks", str(run.get_track_count()))
	_check(run.loop_mode == Animation.LOOP_LINEAR, "run loops")
	_check(lib.get_animation("land_hard").loop_mode == Animation.LOOP_NONE, "landings one-shot")
	# The retarget wrote real rotations, not identity: some track must swing.
	# Probe at quarter phase (half phase of a run cycle is left/right symmetric)
	# and take the max across all rotation tracks.
	var max_swing: float = 0.0
	for ti in run.get_track_count():
		if run.track_get_type(ti) != Animation.TYPE_ROTATION_3D:
			continue
		var q0: Quaternion = run.rotation_track_interpolate(ti, 0.0)
		var q1: Quaternion = run.rotation_track_interpolate(ti, run.length * 0.25)
		max_swing = maxf(max_swing, q0.angle_to(q1))
	_check(max_swing > 0.2, "keys actually animate", "max %.3f rad swing" % max_swing)

	_check(_animator != null, "animator on the suit")
	if _animator != null:
		var player: AnimationPlayer = _animator.get("_player")
		_check(player != null and player.has_animation("loco/run"),
			"library mounted on the suit's player")


func _test_state_sequence() -> void:
	print("\n== state tracking ==")
	if _animator == null:
		_check(false, "animator missing — sequence skipped")
		return
	var moon := _system.get_body(&"moon")
	# Stage the suit just above the REAL terrain, not a radius guess: since
	# collision mirrors the render planet-wide, a spot "1.02 R up" can be
	# metres inside a hill — and a live body staged inside the trimesh is
	# solver-ejected forever (the suite bounced in loco/fall until this).
	var sampler = moon.planet_surface().surface_res.make_sampler()
	_suit.call("request_exit")
	_suit.freeze = true
	var dir := Vector3(0, 1, 0.2).normalized()
	for i in 5:
		var local_dir: Vector3 = moon.planet_surface().to_local(
			OriginShift.to_render(moon.true_pos) + dir).normalized()
		var ground_r: float = moon.def.radius * (1.0 + sampler.height(local_dir))
		_suit.global_position = OriginShift.to_render(moon.true_pos) \
			+ dir * (ground_r + 2.5)
		PhysicsServer3D.body_set_state(
			_suit.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, _suit.global_transform)
		await get_tree().physics_frame
	_suit.call("enter_walk_on", moon)
	# The stage drops the suit from tens of metres up — at lunar gravity the
	# settle takes a while. Wait for boots-down before asserting.
	var settle_deadline: int = Time.get_ticks_msec() + 30000
	while bool(_suit.get("_walk_airborne")) and Time.get_ticks_msec() < settle_deadline:
		await get_tree().physics_frame
	# The arrival triggers a one-shot landing clip; idle follows once it ends.
	settle_deadline = Time.get_ticks_msec() + 5000
	while String(_animator.current_clip()) != "loco/idle" 			and Time.get_ticks_msec() < settle_deadline:
		await get_tree().physics_frame
	_check(String(_animator.current_clip()) == "loco/idle", "standing → idle",
		String(_animator.current_clip()))

	Input.action_press("thrust_forward")
	# Poll: coarse-terrain steps can flicker a stride through the fall state
	# while the walker pin's builds land — the gate is the MAPPING, so accept
	# run whenever it arrives inside the window.
	var run_deadline: int = Time.get_ticks_msec() + 10000
	while String(_animator.current_clip()) != "loco/run" \
			and Time.get_ticks_msec() < run_deadline:
		await get_tree().physics_frame
	_check(String(_animator.current_clip()) == "loco/run", "W held → run",
		String(_animator.current_clip()))
	# And the skeleton must actually MOVE — the clip reaching the player is
	# not the same as the tracks reaching the bones (path resolution).
	var skel := _suit.get_node("Suit").find_child("Skeleton3D", true, false) as Skeleton3D
	var thigh: int = skel.find_bone("Thigh_L")
	var q_a: Quaternion = skel.get_bone_pose_rotation(thigh)
	for i in 12:
		await get_tree().physics_frame
	var q_b: Quaternion = skel.get_bone_pose_rotation(thigh)
	var rest_q: Quaternion = skel.get_bone_rest(thigh).basis.get_rotation_quaternion()
	_check(q_a.angle_to(rest_q) > 0.05 or q_b.angle_to(rest_q) > 0.05,
		"bones leave the rest pose", "dev %.3f / %.3f rad" % [q_a.angle_to(rest_q), q_b.angle_to(rest_q)])
	_check(q_a.angle_to(q_b) > 0.02, "bones keep moving mid-run",
		"%.3f rad in 0.2 s" % q_a.angle_to(q_b))
	Input.action_release("thrust_forward")
	# Settle to a grounded stand before the jump.
	var stand_deadline: int = Time.get_ticks_msec() + 10000
	while (bool(_suit.get("_walk_airborne"))
			or String(_animator.current_clip()) != "loco/idle") \
			and Time.get_ticks_msec() < stand_deadline:
		await get_tree().physics_frame

	Input.action_press("thrust_up")
	for i in 6:
		await get_tree().physics_frame
	Input.action_release("thrust_up")
	_check(String(_animator.current_clip()) == "loco/jump", "lift → jump",
		String(_animator.current_clip()))
	# Moon jump: rise ~5.5 s — wait for the descending half.
	var saw_fall := false
	for i in 800:
		await get_tree().physics_frame
		if String(_animator.current_clip()) == "loco/fall":
			saw_fall = true
		if not bool(_suit.get("_walk_airborne")) and i > 20:
			break
	_check(saw_fall, "apex → fall")
	var clip_now := String(_animator.current_clip())
	_check(clip_now.begins_with("loco/land"), "touchdown → a landing clip", clip_now)
	for i in 120:
		await get_tree().physics_frame
	_check(String(_animator.current_clip()) == "loco/idle", "landing settles to idle",
		String(_animator.current_clip()))

	GameState.input_mode = GameState.InputMode.SHIP_FLIGHT
	_suit.call("stow")
