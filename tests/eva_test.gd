extends Node
## Headless verification for EVA: the exit/board lifecycle and suit physics.
##
## Run: godot --headless res://tests/eva_test.tscn
##
## This covers the five M2 gate items that are assertions rather than judgement
## calls (docs/tasks.md). The two it cannot cover — whether flight-assist-off is
## "challenging but controllable" and whether the camera handoff *feels* seamless
## — need a human at a keyboard.
##
## Worth knowing why this file exists at all: the EVA controller was written
## before the solar system work and had never been executed, and its exit/board
## lifecycle was then rewritten to stow the suit out of the scene tree (a
## RigidBody3D cannot be nested under another RigidBody3D — see
## eva_controller.gd). That made it the least-exercised code in the project.

var _failures: int = 0
var _world: Node3D
var _ship: RigidBody3D
var _suit: RigidBody3D


func _ready() -> void:
	_world = load("res://scenes/game_world.tscn").instantiate()
	add_child(_world)
	await get_tree().process_frame
	await get_tree().process_frame

	_ship = _world.get_node("Ship")
	_suit = _ship.get("character") as RigidBody3D

	_test_stowed_at_spawn()
	await _test_exit_from_drifting_ship()
	await _test_momentum_conservation()
	await _test_camera_handoff()
	await _test_board()
	await _test_exit_from_rotating_ship()
	_test_fuel_thresholds()

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


## Put the suit back aboard between cases.
func _reset() -> void:
	if not _suit.call("is_stowed"):
		_suit.call("stow")
	GameState.input_mode = GameState.InputMode.SHIP_FLIGHT
	_ship.freeze = false
	_ship.linear_velocity = Vector3.ZERO
	_ship.angular_velocity = Vector3.ZERO
	await get_tree().physics_frame


## --- Cases -------------------------------------------------------------------

func _test_stowed_at_spawn() -> void:
	print("\n== stowed while aboard ==")
	_check(_suit != null, "ship holds a suit reference")
	if _suit == null:
		return
	_check(_suit.call("is_stowed"), "suit is out of the scene tree")
	_check(_suit.freeze, "suit is frozen")
	var shape := _suit.get_node_or_null("CollisionShape3D") as CollisionShape3D
	_check(shape != null and shape.disabled, "suit collision is disabled")
	# The nesting bug this guards against showed up as the ship's own transform
	# being dragged 16 km per frame.
	_check(_ship.global_position.length() < 100.0,
		"ship transform is sane", "(%.1f m from render origin)" % _ship.global_position.length())


func _test_exit_from_drifting_ship() -> void:
	print("\n== exit from a drifting ship ==")
	await _reset()
	var drift := Vector3(0.0, 0.0, -5.0)
	_ship.linear_velocity = drift
	await get_tree().physics_frame

	var ship_velocity_before: Vector3 = _ship.linear_velocity
	_suit.call("request_exit")
	await get_tree().physics_frame

	_check(not _suit.call("is_stowed"), "suit entered the scene tree")
	_check(not _suit.freeze, "suit is unfrozen")
	_check(GameState.input_mode == GameState.InputMode.EVA, "input mode switched to EVA")

	# Co-moving: relative velocity at the moment of exit should be nil.
	var relative: Vector3 = _suit.linear_velocity - ship_velocity_before
	_check(relative.length() < 0.5, "suit exits co-moving with the ship",
		"(%.3f m/s relative)" % relative.length())

	# And the ship keeps its momentum — undocking must not brake it.
	_check(absf(_ship.linear_velocity.length() - drift.length()) < 0.5,
		"ship keeps coasting after the suit leaves",
		"(%.2f m/s)" % _ship.linear_velocity.length())

	# The hatch must be clear of the hull, or the physics engine depenetrates the
	# suit out of the ship at speed.
	var separation: float = (_suit.global_position - _ship.global_position).length()
	_check(separation > 2.0, "suit spawns clear of the hull",
		"(%.2f m from ship centre)" % separation)


func _test_momentum_conservation() -> void:
	print("\n== suit momentum ==")
	# Flight assist off: the point is that velocity persists with no input.
	GameState.flight_assist_enabled = false
	_suit.linear_velocity = Vector3(3.0, -1.0, 2.0)
	_suit.angular_velocity = Vector3(0.2, 0.0, -0.1)
	var v0: Vector3 = _suit.linear_velocity
	var w0: Vector3 = _suit.angular_velocity
	for _i in 120:
		await get_tree().physics_frame
	_check((_suit.linear_velocity - v0).length() < 0.01,
		"linear velocity unchanged over 120 ticks",
		"(drift %.5f m/s)" % (_suit.linear_velocity - v0).length())
	_check((_suit.angular_velocity - w0).length() < 0.01,
		"angular velocity unchanged (tumble persists)",
		"(drift %.5f rad/s)" % (_suit.angular_velocity - w0).length())
	GameState.flight_assist_enabled = true


func _test_camera_handoff() -> void:
	print("\n== camera handoff ==")
	var eva_camera := _suit.get_node_or_null("CameraRig/Camera3D") as Camera3D
	var ship_camera := _ship.get_node_or_null("CameraRig/Camera3D") as Camera3D
	_check(eva_camera != null and ship_camera != null, "both camera rigs exist")
	if eva_camera == null or ship_camera == null:
		return
	# Mode is EVA at this point in the run.
	_check(eva_camera.current, "EVA camera is current on EVA")
	_check(not ship_camera.current, "ship camera released on EVA")
	_check(eva_camera.is_inside_tree(), "EVA camera is in the tree")


func _test_board() -> void:
	print("\n== boarding ==")
	# Park the suit inside the cargo bay so the Area3D registers the overlap.
	#
	# The suit has to be *held* there rather than teleported once: the ship is
	# station-keeping at Earth's orbital velocity, so it covers ~2 m of render
	# space per physics tick, and the cargo bay is only 1.5 m of half-extent. A
	# single teleport leaves the suit outside the volume within one frame. Flying
	# in under thrust is the human half of this gate item; what is asserted here
	# is that overlap is detected and the transition is clean.
	GameState.flight_assist_enabled = false
	var bay := _ship.get_node("CargoBay") as Area3D
	_suit.freeze = true
	_suit.angular_velocity = Vector3.ZERO
	var detected := false
	for _i in 20:
		_suit.global_position = bay.global_position
		await get_tree().physics_frame
		if _suit.call("can_board"):
			detected = true
			break

	_check(detected, "cargo bay overlap detected",
		"(%.2f m from bay centre, %d body(s) in volume)" % [
			(_suit.global_position - bay.global_position).length(),
			bay.get_overlapping_bodies().size(),
		])

	var hull_velocity_before: Vector3 = _ship.linear_velocity
	_suit.call("request_board")
	await get_tree().physics_frame

	_check(_suit.call("is_stowed"), "suit stowed again after boarding")
	_check(GameState.input_mode == GameState.InputMode.SHIP_FLIGHT,
		"input mode returned to ship flight")
	var ship_camera := _ship.get_node_or_null("CameraRig/Camera3D") as Camera3D
	_check(ship_camera != null and ship_camera.current, "ship camera is current again")
	# Boarding must not leave a stray impulse on the hull — measured as a change,
	# since the ship is still carrying drift from an earlier case.
	var hull_kick: float = (_ship.linear_velocity - hull_velocity_before).length()
	_check(hull_kick < 0.5, "boarding imparts no impulse to the hull",
		"(%.4f m/s change)" % hull_kick)
	GameState.flight_assist_enabled = true


func _test_exit_from_rotating_ship() -> void:
	print("\n== exit from a rotating ship ==")
	await _reset()
	# Flight assist off: rotational assist saturates its torque clamp and nulls a
	# 0.4 rad/s spin within a tick or two, so with it on there is no spin left to
	# inherit by the time the hatch opens.
	GameState.flight_assist_enabled = false

	# Spin about an axis perpendicular to the hatch offset. The ship's spawn
	# attitude is arbitrary, so a fixed world axis can end up nearly parallel to
	# the offset — |omega x r| then collapses and the test measures almost nothing
	# whether the term is implemented or not.
	var exit_point := _ship.get_node("ExitPoint") as Marker3D
	var r: Vector3 = exit_point.global_position - _ship.global_position
	var axis: Vector3 = r.normalized().cross(Vector3.UP)
	if axis.length() < 0.1:
		axis = r.normalized().cross(Vector3.RIGHT)
	_ship.angular_velocity = axis.normalized() * 0.4
	await get_tree().physics_frame

	# Expected tangential contribution, computed independently of the controller.
	r = exit_point.global_position - _ship.global_position
	var expected_tangential: Vector3 = _ship.angular_velocity.cross(r)
	var ship_velocity: Vector3 = _ship.linear_velocity

	_suit.call("request_exit")
	await get_tree().physics_frame

	var actual: Vector3 = _suit.linear_velocity - ship_velocity
	var error: float = (actual - expected_tangential).length()
	_check(expected_tangential.length() > 0.5, "test spin produces a measurable tangent",
		"(%.2f m/s expected)" % expected_tangential.length())
	# Without the omega x r term, `actual` would be ~zero — this is the check that
	# catches leaving a rotating ship not flinging you.
	_check(error < 0.5, "suit inherits the tangential velocity of the hatch",
		"(expected %.2f m/s, error %.3f)" % [expected_tangential.length(), error])
	_check(_suit.angular_velocity.length() > 0.1, "suit inherits the ship's spin",
		"(%.2f rad/s)" % _suit.angular_velocity.length())


func _test_fuel_thresholds() -> void:
	print("\n== EVA fuel ==")
	var fuel = _suit.get("fuel")
	if fuel == null:
		_check(false, "suit has a fuel resource")
		return
	fuel.call("refill")

	var low := [0]
	var critical := [0]
	var depleted := [0]
	fuel.connect("low_fuel", func(): low[0] += 1)
	fuel.connect("critical_fuel", func(): critical[0] += 1)
	fuel.connect("depleted", func(): depleted[0] += 1)

	var pct_at_low := -1.0
	var pct_at_critical := -1.0
	# Bite size is chosen against the resource's own consumption_rate so the tank
	# empties in ~800 steps: fine enough to pin the thresholds to well under a
	# percent, coarse enough not to loop forever.
	var rate: float = fuel.get("consumption_rate")
	var bite: float = (fuel.get("capacity") * 0.00125) / maxf(rate, 1e-9)
	for _i in 2000:
		var before: float = fuel.call("percent")
		fuel.call("consume", bite, 1.0)
		if low[0] == 1 and pct_at_low < 0.0:
			pct_at_low = before
		if critical[0] == 1 and pct_at_critical < 0.0:
			pct_at_critical = before
		if fuel.get("remaining") <= 0.0:
			break

	_check(low[0] == 1, "low_fuel fired exactly once", "(%d)" % low[0])
	_check(critical[0] == 1, "critical_fuel fired exactly once", "(%d)" % critical[0])
	_check(depleted[0] == 1, "depleted fired exactly once", "(%d)" % depleted[0])
	_check(absf(pct_at_low - 20.0) < 1.0, "low_fuel fires at ~20%",
		"(%.1f%%)" % pct_at_low)
	_check(absf(pct_at_critical - 5.0) < 1.0, "critical_fuel fires at ~5%",
		"(%.1f%%)" % pct_at_critical)

	# Refill on boarding must rearm the warnings, or they only ever fire once
	# per session.
	fuel.call("refill")
	_check(fuel.call("percent") > 99.0, "refill tops the tank up")
	fuel.call("consume", bite, 2000.0)
	_check(low[0] == 2, "warnings rearm after a refill", "(low fired %d times)" % low[0])
