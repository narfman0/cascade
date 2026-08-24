extends Node
## Headless verification for Track HZ: gravity-well warning bands, computed
## point of no return, kill boundaries, and checkpoint restore.
##
## Run: godot --headless res://tests/hazard_test.tscn

var _failures: int = 0
var _world: Node3D
var _ship: RigidBody3D
var _system: SolarSystem
var _hazard: HazardMonitor


func _ready() -> void:
	_world = load("res://scenes/game_world.tscn").instantiate()
	add_child(_world)
	await get_tree().process_frame
	await get_tree().process_frame

	_ship = _world.get_node("Ship")
	_system = _world.get_node("SolarSystem")
	_hazard = _ship.get_node("HazardMonitor")

	_test_giant_shells()
	_test_no_return_arithmetic()
	await _test_warning_bands()
	await _test_checkpoint_discipline()
	await _test_jupiter_dive_and_restore()
	await _test_entry_burn()
	await _test_slow_descent_is_safe()

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


## Hold-teleport the ship somewhere, matched to a frame velocity.
func _park(where: Callable, vel: Callable) -> void:
	_ship.freeze = true
	for i in 4:
		_ship.global_position = where.call()
		await get_tree().physics_frame
	_ship.freeze = false
	_ship.global_position = where.call()
	_ship.linear_velocity = vel.call()
	_ship.angular_velocity = Vector3.ZERO


func _body_vel(body: CelestialBody) -> Vector3:
	var v: Array = body.velocity_at(SimClock.sim_time)
	return Vector3(float(v[0]), float(v[1]), float(v[2]))


func _test_giant_shells() -> void:
	print("\n== shells ==")
	var jupiter := _system.get_body(&"jupiter")
	var g: Vector3 = _system.gravity_at([
		jupiter.true_pos[0] + jupiter.def.radius * 1.1,
		jupiter.true_pos[1], jupiter.true_pos[2]])
	_check(absf(g.length() - 6.20 / (1.1 * 1.1)) < 0.05, "Jupiter pulls",
		"%.2f m/s² at 1.1R" % g.length())
	_check(_system.landable_body_at([
		jupiter.true_pos[0] + jupiter.def.radius * 1.1,
		jupiter.true_pos[1], jupiter.true_pos[2]]) == null,
		"…but is not landable")
	# Io orbits outside Jupiter's shell — parked moons must not fall.
	var io := _system.get_body(&"io")
	_check(io.def.orbit_radius > jupiter.def.radius * SolarSystem.GRAVITY_SHELL_TOP,
		"Io orbits outside the shell")
	var moon := _system.get_body(&"moon")
	_check(moon.def.orbit_radius > _system.get_body(&"earth").def.radius * SolarSystem.GRAVITY_SHELL_TOP,
		"the Moon orbits outside Earth's shell")


func _test_no_return_arithmetic() -> void:
	var jupiter := _system.get_body(&"jupiter")
	var r_nr: float = _hazard.no_return_radius(jupiter)
	var expect: float = jupiter.def.radius * sqrt(6.20 / 4.0)
	_check(absf(r_nr - expect) < 1.0, "Jupiter no-return radius is arithmetic",
		"%.0f m vs %.0f expected (1.245R)" % [r_nr, expect])
	var earth := _system.get_body(&"earth")
	_check(_hazard.no_return_radius(earth) == 0.0,
		"Earth is always escapable at full thrust")


func _test_warning_bands() -> void:
	print("\n== warning bands ==")
	var jupiter := _system.get_body(&"jupiter")
	# g = a_max - margin → r = R*sqrt(g0/(a_max - margin)): park at the radius
	# that produces each target margin and read the monitor.
	for target in [[1.0, HazardMonitor.Band.CAUTION, "caution"],
			[0.3, HazardMonitor.Band.WARNING, "warning"],
			[-0.5, HazardMonitor.Band.NO_RETURN, "no-return"]]:
		var margin: float = target[0]
		var g_want: float = 4.0 - margin
		var r: float = jupiter.def.radius * sqrt(6.20 / g_want)
		await _park(
			func() -> Vector3: return OriginShift.to_render(jupiter.true_pos) \
				+ Vector3(0, 1, 0).normalized() * r,
			func() -> Vector3: return _body_vel(jupiter))
		for i in 4:
			await get_tree().physics_frame
		_check(_hazard.band == target[1], "band %s at computed radius" % target[2],
			"margin %.2f" % _hazard.escape_margin)
	# Climb out: band clears.
	await _park(
		func() -> Vector3: return OriginShift.to_render(jupiter.true_pos) \
			+ Vector3(0, 1, 0) * jupiter.def.radius * 2.0,
		func() -> Vector3: return _body_vel(jupiter))
	for i in 4:
		await get_tree().physics_frame
	_check(_hazard.band == HazardMonitor.Band.CLEAR, "clear outside the shell")


func _test_checkpoint_discipline() -> void:
	print("\n== checkpoint ==")
	var earth := _system.get_body(&"earth")
	# Park safe near the spawn frame and force a checkpoint window.
	await _park(
		func() -> Vector3: return OriginShift.to_render(earth.true_pos) \
			+ Vector3(-1, 0.32, 0.1).normalized() * (earth.def.radius * 2.0),
		func() -> Vector3: return _body_vel(earth))
	_hazard.set("_cp", {})
	_hazard.set("_cp_timer", 0.0)
	for i in 8:
		await get_tree().physics_frame
	_check(_hazard.has_checkpoint(), "safe flight checkpoints")

	# Inside a shell: the checkpoint must refuse.
	var jupiter := _system.get_body(&"jupiter")
	await _park(
		func() -> Vector3: return OriginShift.to_render(jupiter.true_pos) \
			+ Vector3(0, 1, 0) * jupiter.def.radius * 1.3,
		func() -> Vector3: return _body_vel(jupiter))
	_hazard.set("_cp", {})
	_hazard.set("_cp_timer", 0.0)
	for i in 8:
		await get_tree().physics_frame
	_check(not _hazard.has_checkpoint(), "no checkpoint inside a shell")


func _test_jupiter_dive_and_restore() -> void:
	print("\n== the dive ==")
	var earth := _system.get_body(&"earth")
	var jupiter := _system.get_body(&"jupiter")
	# Take a legitimate checkpoint parked in Earth frame.
	var safe_dir := Vector3(-1.0, 0.32, 0.1).normalized()
	await _park(
		func() -> Vector3: return OriginShift.to_render(earth.true_pos) \
			+ safe_dir * (earth.def.radius * 2.0),
		func() -> Vector3: return _body_vel(earth))
	_hazard.set("_cp", {})
	_hazard.set("_cp_timer", 0.0)
	for i in 8:
		await get_tree().physics_frame
	_check(_hazard.has_checkpoint(), "checkpoint taken before the dive")
	var fuel_at_cp: float = _ship.get("fuel_remaining")

	# Dive: drop the hull into the cloud deck.
	var lost: Array = [false, ""]
	_hazard.hull_lost.connect(func(reason: String) -> void:
		lost[0] = true
		lost[1] = reason)
	var restored_flag: Array = [false]
	_hazard.restored.connect(func() -> void: restored_flag[0] = true)
	await _park(
		func() -> Vector3: return OriginShift.to_render(jupiter.true_pos) \
			+ Vector3(0, 1, 0) * jupiter.def.radius * 1.02,
		func() -> Vector3: return _body_vel(jupiter))
	# Burn a little fuel mid-dive so the restore has something to restore.
	_ship.call("spend_fuel", 1000.0)
	var deadline: int = Time.get_ticks_msec() + 5000
	while not lost[0] and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
	_check(lost[0], "cloud deck kills", str(lost[1]))
	_check(_hazard.failing, "failure state holds during the beat")

	deadline = Time.get_ticks_msec() + 8000
	while not restored_flag[0] and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
	_check(restored_flag[0], "restore fires")
	# Back beside Earth, in its frame, with checkpoint fuel.
	var to_earth: float = (_ship.global_position
		- OriginShift.to_render(earth.true_pos)).length()
	_check(absf(to_earth - earth.def.radius * 2.0) < 50.0,
		"restored beside the reference body", "%.0f m from Earth centre" % to_earth)
	var v_rel: float = (_ship.linear_velocity - _body_vel(earth)).length()
	_check(v_rel < 6.0, "restored co-moving with the frame", "%.2f m/s" % v_rel)
	_check(absf(float(_ship.get("fuel_remaining")) - fuel_at_cp) < 1.0,
		"fuel restored to the checkpoint", "%.0f" % float(_ship.get("fuel_remaining")))
	_check(not _hazard.failing and not _ship.freeze, "ship handed back live")


func _test_entry_burn() -> void:
	print("\n== entry burn ==")
	var earth := _system.get_body(&"earth")
	var lost: Array = [false]
	var restored_flag: Array = [false]
	_hazard.hull_lost.connect(func(_r: String) -> void: lost[0] = true)
	_hazard.restored.connect(func() -> void: restored_flag[0] = true)
	# Inside the atmosphere interface at orbital-ish speed: burn.
	await _park(
		func() -> Vector3: return OriginShift.to_render(earth.true_pos) \
			+ Vector3(0, 1, 0.2).normalized() * (earth.def.radius * 1.01),
		func() -> Vector3: return _body_vel(earth) + Vector3(130, 0, 0))
	var deadline: int = Time.get_ticks_msec() + 5000
	while not lost[0] and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
	_check(lost[0], "hot entry burns")
	deadline = Time.get_ticks_msec() + 8000
	while not restored_flag[0] and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
	_check(restored_flag[0], "and restores")


func _test_slow_descent_is_safe() -> void:
	var earth := _system.get_body(&"earth")
	# The landing profile crosses the same interface at 1.5 m/s — no kill.
	await _park(
		func() -> Vector3: return OriginShift.to_render(earth.true_pos) \
			+ Vector3(0, 1, 0.2).normalized() * (earth.def.radius * 1.01),
		func() -> Vector3: return LandingComputer.surface_point_velocity(
			earth, _ship.global_position) + Vector3(0, -1.5, 0))
	var burned := false
	for i in 30:
		await get_tree().physics_frame
		if _hazard.failing:
			burned = true
	_check(not burned, "a landing descent through the atmosphere is safe")
