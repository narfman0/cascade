extends Node
## Headless verification for Track LD7: asteroids sized for the ship.
##
## Run: godot --headless res://tests/minor_body_test.tscn

var _failures: int = 0
var _world: Node3D
var _ship: RigidBody3D
var _system: SolarSystem


func _ready() -> void:
	_world = load("res://scenes/game_world.tscn").instantiate()
	add_child(_world)
	await get_tree().process_frame
	await get_tree().process_frame

	_ship = _world.get_node("Ship")
	_system = _world.get_node("SolarSystem")

	_test_class_and_envelope()
	await _test_rcs_hover()
	await _test_autoland_on_minor_body()
	await _test_corotation_on_tumbler()
	await _test_eva_microgravity()

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


func _body_vel(body: CelestialBody) -> Vector3:
	var v: Array = body.velocity_at(SimClock.sim_time)
	return Vector3(float(v[0]), float(v[1]), float(v[2]))


func _stage(body: CelestialBody, radii: float, dir: Vector3) -> void:
	_ship.freeze = true
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		var where: Vector3 = OriginShift.to_render(body.true_pos) + dir * (body.def.radius * radii)
		_ship.global_position = where
		var up: Vector3 = dir
		var fwd: Vector3 = up.cross(Vector3.RIGHT).normalized()
		_ship.global_basis = Basis(fwd.cross(up).normalized(), up, -fwd).orthonormalized()
		await get_tree().physics_frame
		if cam == null or cam.global_position.distance_to(where) < 40.0:
			break
	# The camera carries WITH a teleport (steady-motion logic), so the arrive
	# check can pass on frame one — before OriginShift's next tick recentres
	# the world. Hold frozen until the origin actually lands here.
	var settle_deadline: int = Time.get_ticks_msec() + 10000
	while _ship.global_position.length() > CelestialBody.MAX_RENDER_DISTANCE \
			and Time.get_ticks_msec() < settle_deadline:
		_ship.global_position = OriginShift.to_render(body.true_pos) \
			+ dir * (body.def.radius * radii)
		await get_tree().physics_frame
	for i in 3:
		_ship.global_position = OriginShift.to_render(body.true_pos) \
			+ dir * (body.def.radius * radii)
		await get_tree().physics_frame
	_ship.freeze = false
	_ship.linear_velocity = _body_vel(body)
	_ship.angular_velocity = Vector3.ZERO


func _autoland_busy(autoland: AutolandComputer) -> bool:
	return autoland.active or not GameState.landed


func _test_class_and_envelope() -> void:
	print("\n== class and envelope ==")
	var count: int = 0
	for id in [&"kamooalewa", &"eros", &"toutatis"]:
		var body := _system.get_body(id)
		if body == null:
			_check(false, "%s exists" % id)
			continue
		count += 1
		_check(body is MinorBody, "%s is a MinorBody" % id)
		# The design line: gravity inside the RCS envelope, so the belly-jet
		# promotion (threshold 1.0 m/s²) never triggers.
		_check(body.def.surface_gravity <= 0.3 and body.def.surface_gravity > 0.0,
			"%s gravity inside the RCS envelope" % id,
			"%.2f m/s²" % body.def.surface_gravity)
		_check(body.arrival_standoff() > body.def.radius * SolarSystem.GRAVITY_SHELL_TOP,
			"%s standoff clears its shell" % id)
		_check(_system.landable_body_at([
			body.true_pos[0] + body.def.radius * 1.1,
			body.true_pos[1], body.true_pos[2]]) == body,
			"%s is landable" % id)
	_check(count == 3, "three minor bodies seeded")
	# Trimesh collision, not the sphere.
	var eros := _system.get_body(&"eros")
	var col := eros.get_node("Surface").get_child(0) as CollisionShape3D
	_check(col.shape is ConcavePolygonShape3D, "collision is the displaced trimesh")


## FA hover on RCS alone: the vertical axis stays RCS-limited (no belly
## promotion under 1.0 m/s²) and still holds station in Eros's 0.3 well.
func _test_rcs_hover() -> void:
	print("\n== hover on RCS ==")
	var eros := _system.get_body(&"eros")
	await _stage(eros, 1.2, Vector3(0, 1, 0.2).normalized())
	GameState.flight_assist_enabled = true
	for i in 120:
		await get_tree().physics_frame
	var v_rel: float = (_ship.linear_velocity - _ship.call("reference_velocity")).length()
	_check(v_rel < 0.2, "flight assist hovers on lateral thrusters",
		"drift %.3f m/s in a %.2f well" % [v_rel, 0.3 / (1.2 * 1.2)])


func _test_autoland_on_minor_body() -> void:
	print("\n== autoland onto Eros ==")
	var eros := _system.get_body(&"eros")
	var autoland := _ship.get_node("AutolandComputer") as AutolandComputer
	await _stage(eros, 1.35, Vector3(0, 1, 0.2).normalized())
	_check(autoland.can_engage(), "autoland can engage in a minor shell")
	autoland.engage()
	var lc := _ship.get_node("LandingComputer") as LandingComputer
	var deadline: int = Time.get_ticks_msec() + 240000
	var tick: int = 0
	# Wait for AUTOLAND to stand down, not just the landed flag: releasing in
	# the gap between LD4's capture and autoland's next tick leaves autoland
	# flying a ghost mission (found the hard way — it re-enabled FA mid-way
	# through a later test).
	while _autoland_busy(autoland) and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		tick += 1
		if tick > 14000:
			break
	_check(GameState.landed, "touchdown captured")
	_check(lc.landed_body == eros, "landed on Eros")
	_check(_ship.get_parent() == eros, "landed hull parented under the asteroid")
	lc.release()
	for i in 5:
		await get_tree().physics_frame


func _test_corotation_on_tumbler() -> void:
	print("\n== the tumbler ==")
	var toutatis := _system.get_body(&"toutatis")
	# Land there via the scripted-descent path (fast and deterministic).
	await _stage(toutatis, 1.3, Vector3(0, 1, 0.2).normalized())
	GameState.flight_assist_enabled = false
	var deadline: int = Time.get_ticks_msec() + 120000
	while not GameState.landed and Time.get_ticks_msec() < deadline:
		var down: Vector3 = (OriginShift.to_render(toutatis.true_pos)
			- _ship.global_position).normalized()
		_ship.linear_velocity = LandingComputer.surface_point_velocity(
			toutatis, _ship.global_position) + down * 1.5
		_ship.angular_velocity = Vector3.ZERO
		# The tumbler turns beneath the descent — keep the belly on the ground
		# or the capture's tilt gate rightly refuses.
		var fwd: Vector3 = (-down).cross(Vector3.RIGHT).normalized()
		_ship.global_basis = Basis(fwd.cross(-down).normalized(), -down, -fwd).orthonormalized()
		await get_tree().physics_frame
	_check(GameState.landed, "landed on the tumbler")

	var local0: Vector3 = _ship.transform.origin
	var basis0: Basis = toutatis.global_basis
	var t0: float = SimClock.sim_time
	SimClock.warp = 30.0
	for i in 180:
		await get_tree().process_frame
	SimClock.reset_warp()
	var dt: float = SimClock.sim_time - t0
	_check(_ship.transform.origin.distance_to(local0) < 0.01,
		"landed pose holds in the tumbling frame",
		"%.4f m over %.0f sim-s" % [_ship.transform.origin.distance_to(local0), dt])
	var spun: float = basis0.get_rotation_quaternion().angle_to(
		toutatis.global_basis.get_rotation_quaternion())
	_check(spun > 0.3, "the asteroid actually tumbled underneath",
		"%.2f rad" % spun)
	var lc := _ship.get_node("LandingComputer") as LandingComputer
	lc.release()
	for i in 5:
		await get_tree().physics_frame


## Micro-g EVA: jump on Eros → apex v²/2g ≈ 8 m, a fifteen-second float.
func _test_eva_microgravity() -> void:
	print("\n== EVA under micro-g ==")
	var eros := _system.get_body(&"eros")
	# Land first so the exit is over ground.
	await _stage(eros, 1.25, Vector3(0, 1, 0.2).normalized())
	GameState.flight_assist_enabled = false
	var deadline: int = Time.get_ticks_msec() + 120000
	while not GameState.landed and Time.get_ticks_msec() < deadline:
		var down: Vector3 = (OriginShift.to_render(eros.true_pos)
			- _ship.global_position).normalized()
		_ship.linear_velocity = LandingComputer.surface_point_velocity(
			eros, _ship.global_position) + down * 1.5
		_ship.angular_velocity = Vector3.ZERO
		var fwd: Vector3 = (-down).cross(Vector3.RIGHT).normalized()
		_ship.global_basis = Basis(fwd.cross(-down).normalized(), -down, -fwd).orthonormalized()
		await get_tree().physics_frame
	_check(GameState.landed, "landed for the EVA")

	var suit: RigidBody3D = _ship.get("character")
	suit.call("request_exit")
	# EVA exits with FA on, and on a minor body the jetpack out-hovers the
	# well (2.0 vs 0.3 m/s²) — the suit hangs at the hatch until the pilot
	# chooses to descend. Cut FA, exactly as a player would.
	GameState.flight_assist_enabled = false
	deadline = Time.get_ticks_msec() + 30000
	var etick: int = 0
	while suit.get("clamped_body") == null and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		etick += 1
		if etick > 8000:
			break
	_check(suit.get("clamped_body") == eros, "walk entered on the asteroid")
	# Entry starts airborne (feet settle over the first frames) — a SPACE
	# press before boots-down is a jetpack blip, not a jump.
	deadline = Time.get_ticks_msec() + 30000
	while bool(suit.get("_walk_airborne")) and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
	for i in 10:
		await get_tree().physics_frame

	# Jump: near-8-metre apex under 0.3-ish local g.
	var surface: Node3D = suit.get_parent()
	var r0: float = surface.to_local(suit.global_position).length()
	var local_r: float = r0 / eros.def.radius
	var g: float = eros.def.surface_gravity / (local_r * local_r)
	var v0: float = float(suit.get("jump_speed"))
	Input.action_press("thrust_up")
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_release("thrust_up")
	var apex: float = 0.0
	deadline = Time.get_ticks_msec() + 120000
	var airborne_seen := false
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		apex = maxf(apex, surface.to_local(suit.global_position).length() - r0)
		if bool(suit.get("_walk_airborne")):
			airborne_seen = true
		elif airborne_seen:
			break
	var expect: float = v0 * v0 / (2.0 * g)
	_check(absf(apex - expect) < expect * 0.35, "jump apex matches v²/2g",
		"%.1f m vs %.1f expected" % [apex, expect])
	_check(suit.get("clamped_body") == eros, "floated back down to the ground")

	GameState.input_mode = GameState.InputMode.SHIP_FLIGHT
	suit.call("stow")
