extends Node
## Headless verification for Track AL: the computer flies the descent through
## the real physics and LD4's own capture.
##
## Run: godot --headless res://tests/autoland_test.tscn

var _failures: int = 0
var _world: Node3D
var _ship: RigidBody3D
var _system: SolarSystem
var _autoland: AutolandComputer


func _ready() -> void:
	_world = load("res://scenes/game_world.tscn").instantiate()
	add_child(_world)
	await get_tree().process_frame
	await get_tree().process_frame

	_ship = _world.get_node("Ship")
	_system = _world.get_node("SolarSystem")
	_autoland = _ship.get_node("AutolandComputer")

	_test_refusals()
	await _test_autoland(_system.get_body(&"moon"), "Moon")
	await _test_abort()
	await _test_autoland(_system.get_body(&"earth"), "Earth")

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


## Park inside the shell at `radii`, upright-ish, matched to the frame, and
## wait for the skim terrain (the ground the capture needs).
func _stage(body: CelestialBody, radii: float, dir: Vector3) -> void:
	var surface = body.planet_surface()
	_ship.freeze = true
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 25000
	while Time.get_ticks_msec() < deadline:
		var where: Vector3 = OriginShift.to_render(body.true_pos) + dir * (body.def.radius * radii)
		_ship.global_position = where
		var up: Vector3 = dir
		var fwd: Vector3 = up.cross(Vector3.RIGHT).normalized()
		_ship.global_basis = Basis(fwd.cross(up).normalized(), up, -fwd).orthonormalized()
		await get_tree().physics_frame
		if surface:
			surface.force_evaluate()
		if cam == null or cam.global_position.distance_to(where) < 40.0:
			break
	_ship.freeze = false
	_ship.linear_velocity = _body_vel(body)
	_ship.angular_velocity = Vector3.ZERO


func _test_refusals() -> void:
	print("\n== refusals ==")
	# At spawn: 2 R over Earth is outside the 1.5 R shell.
	_check(not _autoland.can_engage(), "refuses outside a gravity shell")


func _test_autoland(body: CelestialBody, label: String) -> void:
	print("\n== autoland %s ==" % label)
	var dir := Vector3(0, 1, 0.2).normalized()
	await _stage(body, 1.35, dir)
	_check(_autoland.can_engage(), "can engage inside the shell")
	_check(_autoland.engage(), "engaged")

	var down: Array = [false, ""]
	_autoland.touchdown.connect(func(n: String) -> void:
		down[0] = true
		down[1] = n
	, CONNECT_ONE_SHOT)
	# Descent from 1.35 R: hundreds of metres of braked profile. Generous
	# deadline; llvmpipe physics runs well under real time.
	var deadline: int = Time.get_ticks_msec() + 240000
	var max_tilt: float = 0.0
	var touchdown_speed: float = 0.0
	while not down[0] and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		if not GameState.landed and not _ship.freeze:
			var up: Vector3 = (_ship.global_position
				- body.global_position).normalized()
			var alt: float = (_ship.global_position - body.global_position).length() - body.def.radius
			if alt < 40.0:
				max_tilt = maxf(max_tilt, rad_to_deg(_ship.global_basis.y.angle_to(up)))
				touchdown_speed = (_ship.linear_velocity
					- LandingComputer.surface_point_velocity(body, _ship.global_position)).length()
	_check(down[0], "touchdown captured", down[1])
	_check(GameState.landed, "landed state set")
	_check(not _autoland.active, "autoland stands down after touchdown")
	_check(touchdown_speed < 2.0, "final approach under the capture limit",
		"%.2f m/s" % touchdown_speed)
	_check(max_tilt < 25.0, "upright through the last 40 m", "%.1f°" % max_tilt)

	# Clean up: lift off and climb clear for the next case.
	var lc := _ship.get_node("LandingComputer") as LandingComputer
	lc.release()
	await get_tree().physics_frame
	_ship.freeze = true
	await get_tree().physics_frame
	_ship.freeze = false


func _test_abort() -> void:
	print("\n== abort ==")
	var moon := _system.get_body(&"moon")
	await _stage(moon, 1.4, Vector3(0, 1, 0.2).normalized())
	_check(_autoland.engage(), "engaged for the abort case")
	for i in 30:
		await get_tree().physics_frame
	Input.action_press("thrust_forward")
	for i in 4:
		await get_tree().physics_frame
	Input.action_release("thrust_forward")
	_check(not _autoland.active, "stick input aborts")
	_check(GameState.flight_assist_enabled, "flight assist handed back")
	_check(not _ship.freeze and not GameState.landed, "ship live and unlanded")
