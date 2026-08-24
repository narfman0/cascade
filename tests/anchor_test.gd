extends Node
## Headless verification for Track LD1/LD2: rocks, sleep/wake, and latching.
##
## Run: godot --headless res://tests/anchor_test.tscn
##
## Gates (docs/tasks.md Track LD):
## - rocks spawn and a sleeping rock tracks its field anchor under warp
## - a woken rock co-moves with the field (< 0.1 m/s error) and keeps tumbling
## - latch succeeds under the speed threshold and refuses over it
## - a latched ship+rock couple tows under thrust with combined-mass dynamics
## - release is impulse-clean
## - a jointed suit rides a tumbling rock

var _failures: int = 0
var _world: Node3D
var _ship: RigidBody3D
var _field: RockField
var _latch: LatchComputer


func _ready() -> void:
	_world = load("res://scenes/game_world.tscn").instantiate()
	add_child(_world)
	await get_tree().process_frame
	await get_tree().process_frame

	_ship = _world.get_node("Ship")
	_field = _world.get_node("RockField")
	_latch = _ship.get_node("LatchComputer")

	_test_spawn()
	await _test_sleeping_tracks_anchor_under_warp()
	await _test_wake_handoff()
	await _test_latch_refusal_when_fast()
	await _test_latch_and_tow()
	await _test_release_clean()
	await _test_suit_rides_tumbling_rock()

	print("")
	if _failures == 0:
		print("PASS — all checks green")
	else:
		print("FAIL — %d check(s) failed" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _check(ok: bool, label: String, detail: String = "") -> void:
	if ok:
		print("  ok    %s %s" % [label, detail])
	else:
		_failures += 1
		print("  FAIL  %s %s" % [label, detail])


## Park the frozen ship and settle physics — the hold-settle-rehold discipline
## from the other suites, with one addition this suite forces: `where` is a
## Callable re-evaluated every held frame. A fixed render-space position goes
## stale the moment an origin shift fires mid-hold (teleporting the ship 20 km
## triggers one), and the world the field rides is itself moving at 131 m/s.
func _park_ship_at(where: Callable, vel: Callable) -> void:
	_ship.freeze = true
	for i in 4:
		_ship.global_position = where.call()
		await get_tree().physics_frame
	_ship.freeze = false
	_ship.global_position = where.call()
	_ship.linear_velocity = vel.call()
	_ship.angular_velocity = Vector3.ZERO


func _test_spawn() -> void:
	_check(_field.rocks.size() == _field.rock_count,
		"rock count", "%d spawned" % _field.rocks.size())
	# Rocks inside the wake radius of the spawn point wake immediately — that
	# is the feature. Everything farther must still be asleep.
	var ok := true
	for rock in _field.rocks:
		var near: bool = _ship.global_position.distance_to(rock.global_position) < _field.wake_radius
		if rock.asleep == near:
			ok = false
	_check(ok, "asleep exactly beyond the wake radius")


func _test_sleeping_tracks_anchor_under_warp() -> void:
	# Ship is far from the field at spawn? No — spawn is 600 m from the field
	# centre, inside nothing (wake radius is 500 from each ROCK). Move the ship
	# well away so no rock wakes during the warp.
	await _park_ship_at(
		func() -> Vector3: return _field.global_position + Vector3(0, 20000, 0),
		func() -> Vector3: return _field.frame_velocity())
	var rock: SpaceRock = _field.rocks[0]
	for i in 5:
		await get_tree().process_frame
	_check(rock.asleep, "rock re-sleeps when abandoned")
	var local_before: Vector3 = _field.to_local(rock.global_position)
	SimClock.warp = 50.0
	for i in 60:
		await get_tree().process_frame
	SimClock.reset_warp()
	var local_after: Vector3 = _field.to_local(rock.global_position)
	_check(local_before.distance_to(local_after) < 0.5,
		"sleeping rock rides the rails under warp",
		"local drift %.3f m" % local_before.distance_to(local_after))


func _test_wake_handoff() -> void:
	var rock: SpaceRock = _field.rocks[0]
	# Approach: park the ship right by the rock, matched to the field's frame.
	await _park_ship_at(
		func() -> Vector3: return rock.global_position + Vector3(30, 0, 0),
		func() -> Vector3: return _field.frame_velocity())
	for i in 5:
		await get_tree().process_frame
	_check(not rock.asleep, "rock wakes on approach")
	var rel: float = (rock.linear_velocity - _field.frame_velocity()).length()
	_check(rel < 0.1, "wake velocity handoff", "%.3f m/s relative to field" % rel)
	_check(rock.angular_velocity.length() > 0.01, "tumble persists",
		"|w| %.3f rad/s" % rock.angular_velocity.length())
	# Momentum conservation awake: velocity relative to the frame stays put.
	var v0: Vector3 = rock.linear_velocity
	for i in 60:
		await get_tree().physics_frame
	_check((rock.linear_velocity - v0).length() < 0.05,
		"woken rock coasts (no phantom forces)")


func _test_latch_refusal_when_fast() -> void:
	var rock: SpaceRock = _field.rocks[0]
	await _park_ship_at(
		func() -> Vector3: return rock.global_position + Vector3(20, 0, 0),
		func() -> Vector3: return rock.linear_velocity + Vector3(-3.0, 0, 0))
	# Drive at the rock at 3 m/s — contact happens over the threshold.
	var saw_ready := false
	for i in 240:
		await get_tree().physics_frame
		if _latch.ready_rock != null:
			saw_ready = true
		if _ship.get_colliding_bodies().has(rock):
			break
	_check(not saw_ready and _latch.latched_rock == null,
		"latch refuses over speed threshold")
	GameState.flight_assist_enabled = true


func _test_latch_and_tow() -> void:
	var rock: SpaceRock = _field.rocks[0]
	# Rest gently against the rock, matched to its velocity.
	await _park_ship_at(
		func() -> Vector3: return rock.global_position + Vector3(0, 0, 12),
		func() -> Vector3: return rock.linear_velocity)
	GameState.flight_assist_enabled = false
	# Nudge into contact. Closing from outside the hull's 6.5 m half-length
	# at 0.6 m/s takes ~10 s of sim — give it room.
	_ship.linear_velocity = rock.linear_velocity + Vector3(0, 0, -0.6)
	var touched := false
	for i in 1500:
		await get_tree().physics_frame
		if _latch.ready_rock == rock:
			touched = true
			break
	_check(touched, "latch-ready on gentle contact")
	_latch.latch_to(rock)
	_check(_latch.latched_rock == rock, "latched")
	for i in 10:
		await get_tree().physics_frame

	# Tow: the ROCK must accelerate — total momentum gains F·t with or without
	# a joint, so the honest gate is the rock's own velocity change matching
	# the coupled pair's F/(m1+m2), not the free ship's F/m1.
	var force: float = 15000.0
	var combined_mass: float = _ship.mass + rock.mass
	var rock_v0: Vector3 = rock.linear_velocity
	var ticks: int = 60
	for i in ticks:
		_ship.apply_central_force(Vector3(force, 0, 0))
		await get_tree().physics_frame
	var dt: float = ticks / 60.0
	var got: float = (rock.linear_velocity - rock_v0).x
	var expect: float = force / combined_mass * dt
	_check(absf(got - expect) < expect * 0.2,
		"tow drags the rock at combined-mass acceleration",
		"rock dv %.3f expected %.3f (rock %.0f kg)" % [got, expect, rock.mass])
	_check((rock.linear_velocity - _ship.linear_velocity).length() < 1.0,
		"rock moves with the ship while latched")


func _test_release_clean() -> void:
	var rock: SpaceRock = _latch.latched_rock
	if rock == null:
		_check(false, "release precondition (still latched)")
		return
	# Let the pair settle, then release: relative velocity must stay near zero.
	for i in 30:
		await get_tree().physics_frame
	var rel_before: Vector3 = _ship.linear_velocity - rock.linear_velocity
	_latch.unlatch()
	for i in 10:
		await get_tree().physics_frame
	var rel_after: Vector3 = _ship.linear_velocity - rock.linear_velocity
	_check((rel_after - rel_before).length() < 0.2,
		"release is impulse-clean",
		"rel dv %.3f m/s" % (rel_after - rel_before).length())


func _test_suit_rides_tumbling_rock() -> void:
	var suit: RigidBody3D = _ship.get("character")
	var rock: SpaceRock = _field.rocks[0]
	# The wake check watches the TRACKED ship, not the suit — make sure the
	# rock is live before jointing to it (a joint to a body outside the
	# physics space holds nothing).
	if rock.asleep:
		rock.wake(_world, _field.frame_velocity())
	# Give the rock a definite tumble and park the suit at its skin.
	rock.angular_velocity = Vector3(0.0, 0.6, 0.0)
	suit.call("request_exit")
	await get_tree().physics_frame
	suit.freeze = true
	for i in 3:
		# Close to the skin: angular momentum is conserved when the clamp
		# couples the pair, and a 150 kg suit parked far out is a flywheel
		# that eats the spin (I scales with r²) — park at 3 m, not 8.
		suit.global_position = rock.global_position + Vector3(3, 0, 0)
		await get_tree().physics_frame
	suit.freeze = false
	suit.linear_velocity = rock.linear_velocity
	suit.angular_velocity = Vector3.ZERO
	var joint := LatchComputer.make_lock_joint(suit, rock)
	suit.set("clamped_rock", rock)
	suit.set("_rock_joint", joint)
	# Half a second of tumble: the suit's position in the rock's local frame
	# must hold while its world position swings around the rock.
	var local0: Vector3 = rock.to_local(suit.global_position)
	var world0: Vector3 = suit.global_position - rock.global_position
	for i in 120:
		await get_tree().physics_frame
	var local1: Vector3 = rock.to_local(suit.global_position)
	var world1: Vector3 = suit.global_position - rock.global_position
	_check(local0.distance_to(local1) < 1.0,
		"jointed suit rides the tumble", "local drift %.3f m" % local0.distance_to(local1))
	_check(world0.angle_to(world1) > 0.05,
		"…and the ride is real rotation", "swung %.2f rad" % world0.angle_to(world1))
	suit.call("release_rock")
	GameState.input_mode = GameState.InputMode.SHIP_FLIGHT
	suit.call("stow")
