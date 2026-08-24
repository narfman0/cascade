extends Node
## Headless verification for Track LD3/LD4: gravity shells and the landed state.
##
## Run: godot --headless res://tests/landing_test.tscn
##
## Gates (docs/tasks.md Track LD):
## - field values: inverse-square inside the shell, faded to zero at the top
## - every arrival standoff sits outside every shell
## - the suit's thrust-to-weight facts: hovers on the Moon, not on Earth
## - flight assist holds altitude inside a shell (gravity feed-forward)
## - autopilot refuses to engage from inside a shell
## - scripted descent → landed state on Earth; co-rotation with the spinning
##   surface under warp (origin shifts fire during this and must not move the
##   ship relative to the ground)
## - takeoff hands off the moving ground's velocity, no teleport frame

var _failures: int = 0
var _world: Node3D
var _ship: RigidBody3D
var _system: SolarSystem
var _landing: LandingComputer
var _earth: CelestialBody


func _ready() -> void:
	_world = load("res://scenes/game_world.tscn").instantiate()
	add_child(_world)
	await get_tree().process_frame
	await get_tree().process_frame

	_ship = _world.get_node("Ship")
	_system = _world.get_node("SolarSystem")
	_landing = _ship.get_node("LandingComputer")
	_earth = _system.get_body(&"earth")

	_test_field_values()
	_test_standoffs_clear_shells()
	_test_suit_twr_facts()
	await _test_fa_holds_altitude()
	await _test_autopilot_refusal()
	await _test_descent_and_landing()
	await _test_corotation_under_warp()
	await _test_takeoff()

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


func _g_at(body: CelestialBody, radii: float) -> float:
	return _system.gravity_at([
		body.true_pos[0] + body.def.radius * radii,
		body.true_pos[1], body.true_pos[2]]).length()


func _test_field_values() -> void:
	print("\n== gravity field ==")
	var g_surface: float = _g_at(_earth, 1.0)
	_check(absf(g_surface - 2.45) < 0.01, "Earth surface gravity", "%.2f m/s²" % g_surface)
	var g_12: float = _g_at(_earth, 1.2)
	_check(absf(g_12 - 2.45 / 1.44) < 0.02, "inverse-square at 1.2R", "%.2f m/s²" % g_12)
	_check(_g_at(_earth, 1.6) == 0.0, "zero above the shell (1.6R)")
	_check(_g_at(_earth, 1.45) < g_12 / 1.3, "fade band thins the top of the shell")
	var moon := _system.get_body(&"moon")
	_check(absf(_g_at(moon, 1.0) - 0.40) < 0.01, "Moon surface gravity",
		"%.2f m/s²" % _g_at(moon, 1.0))
	var jupiter := _system.get_body(&"jupiter")
	_check(_g_at(jupiter, 1.1) == 0.0, "gas giants have no shell")
	# The direction points at the body, not away.
	var g_vec: Vector3 = _system.gravity_at([
		_earth.true_pos[0] + _earth.def.radius, _earth.true_pos[1], _earth.true_pos[2]])
	_check(g_vec.x < 0.0, "gravity points down")


func _test_standoffs_clear_shells() -> void:
	var all_clear := true
	var worst: String = ""
	for body in _system.bodies:
		if body.def.surface_gravity <= 0.0:
			continue
		if body.arrival_standoff() <= body.def.radius * SolarSystem.GRAVITY_SHELL_TOP:
			all_clear = false
			worst = String(body.def.id)
	_check(all_clear, "every arrival standoff sits outside its shell", worst)


func _test_suit_twr_facts() -> void:
	var suit: RigidBody3D = _ship.get("character")
	var accel: float = float(suit.get("thrust_translation")) / suit.mass
	_check(accel < 2.45, "suit cannot hover on Earth",
		"%.2f m/s² thrust vs 2.45" % accel)
	_check(accel > 0.40, "suit flies freely on the Moon",
		"%.2f m/s² thrust vs 0.40" % accel)


## Park inside the shell, matched to Earth's frame, FA on, hands off: the
## gravity feed-forward must hold the sag to near nothing.
func _test_fa_holds_altitude() -> void:
	print("\n== inside the shell ==")
	# Upright, like a pilot holding a hover: the belly jets carry the vertical
	# axis, so gravity must sit on local Y. Lying flat puts it on the 15 kN
	# RCS axis and the ship honestly sinks — attitude matters inside a shell.
	var up_dir := Vector3(0, 1, 0.2).normalized()
	_ship.freeze = true
	for i in 3:
		_ship.global_position = OriginShift.to_render(_earth.true_pos) \
			+ up_dir * (_earth.def.radius * 1.2)
		var fwd: Vector3 = up_dir.cross(Vector3.RIGHT).normalized()
		_ship.global_basis = Basis(fwd.cross(up_dir).normalized(), up_dir, -fwd).orthonormalized()
		await get_tree().physics_frame
	_ship.freeze = false
	var frame_v: Array = _earth.velocity_at(SimClock.sim_time)
	_ship.linear_velocity = Vector3(float(frame_v[0]), float(frame_v[1]), float(frame_v[2]))
	_ship.angular_velocity = Vector3.ZERO
	GameState.flight_assist_enabled = true
	for i in 120:
		await get_tree().physics_frame
	var rel_v: Vector3 = _ship.linear_velocity - _ship.call("reference_velocity")
	var g_here: Vector3 = _system.gravity_at(OriginShift.to_true(_ship.global_position))
	var down_dir: Vector3 = g_here.normalized()
	_check(rel_v.length() < 0.2, "flight assist hovers (gravity feed-forward)",
		"drift %.3f m/s (down %.3f, lateral %.3f; |g| %.2f)" % [
			rel_v.length(), rel_v.dot(down_dir),
			(rel_v - down_dir * rel_v.dot(down_dir)).length(), g_here.length()])


func _test_autopilot_refusal() -> void:
	var autopilot := _ship.get_node("Autopilot") as Autopilot
	var moon := _system.get_body(&"moon")
	var ok: bool = autopilot.engage(moon)
	_check(not ok and not GameState.autopilot_active,
		"autopilot refuses to engage inside a shell")


## Fly a controlled 1.5 m/s descent to the ground, upright; the landing
## computer must capture on contact.
func _test_descent_and_landing() -> void:
	print("\n== touchdown ==")
	var surface := _earth.planet_surface()
	var dir := Vector3(0, 1, 0.2).normalized()
	# Settle low enough for skim colliders, high enough not to spawn intersecting
	# terrain (relief reaches ~2% of radius = 40 m).
	_ship.freeze = true
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		var where: Vector3 = OriginShift.to_render(_earth.true_pos) + dir * (_earth.def.radius + 80.0)
		_ship.global_position = where
		# Upright: ship +Y along local up.
		var up: Vector3 = dir
		var fwd: Vector3 = up.cross(Vector3.RIGHT).normalized()
		_ship.global_basis = Basis(fwd.cross(up).normalized(), up, -fwd).orthonormalized()
		await get_tree().physics_frame
		surface.force_evaluate()
		if surface.skim_active and (cam == null or cam.global_position.distance_to(where) < 30.0):
			break
	_check(surface.skim_active, "skim colliders resident for descent")
	# Let the ship-footprint pin converge to max depth before descending —
	# splits are worker-built, and the whole point is that they finish HERE,
	# not under the hull.
	for i in 240:
		surface.force_evaluate()
		await get_tree().process_frame
	_ship.freeze = false
	GameState.flight_assist_enabled = false
	# Scripted descent: hold 1.5 m/s straight down relative to the ground until
	# the capture fires. The override stops the moment we're landed.
	# GDScript lambdas capture locals by value; mutate through an array cell.
	var landed_fired: Array = [false]
	_landing.landed.connect(func(_n: String) -> void: landed_fired[0] = true)
	# Transition-earlier gate: once below 60 m the ground under the hull must
	# never move again — no LOD swap may change the surface beneath a landing.
	var ground_r_min: float = INF
	var ground_r_max: float = -INF
	var ray_tick: int = 0
	deadline = Time.get_ticks_msec() + 150000
	while not GameState.landed and Time.get_ticks_msec() < deadline:
		# Down is re-derived every frame: the planet turns and the ship rides it in.
		var down: Vector3 = (OriginShift.to_render(_earth.true_pos) - _ship.global_position).normalized()
		var ground_v: Vector3 = LandingComputer.surface_point_velocity(_earth, _ship.global_position)
		_ship.linear_velocity = ground_v + down * 1.5
		_ship.angular_velocity = Vector3.ZERO
		await get_tree().physics_frame
		ray_tick += 1
		var centre: Vector3 = OriginShift.to_render(_earth.true_pos)
		var alt_now: float = (_ship.global_position - centre).length() - _earth.def.radius
		if alt_now < 60.0 and ray_tick % 10 == 0:
			var q := PhysicsRayQueryParameters3D.create(
				_ship.global_position, _ship.global_position + down * 200.0)
			q.exclude = [_ship.get_rid()]
			var hit: Dictionary = _ship.get_world_3d().direct_space_state.intersect_ray(q)
			if not hit.is_empty():
				var r_hit: float = (hit.position - centre).length()
				ground_r_min = minf(ground_r_min, r_hit)
				ground_r_max = maxf(ground_r_max, r_hit)
	_check(GameState.landed and landed_fired[0], "touchdown captures the landed state")
	var ground_spread: float = ground_r_max - ground_r_min
	_check(ground_r_min < INF and ground_spread < 0.3,
		"ground never moves under the final approach",
		"height spread %.3f m below 60 m altitude" % ground_spread)
	_check(_landing.landed_body == _earth, "landed on Earth")
	var parent_ok: bool = _ship.get_parent() == _earth.planet_surface()
	_check(parent_ok, "landed hull parented under the spinning surface")
	_check(not _ship.is_in_group(OriginShift.SHIFTABLE_GROUP),
		"landed hull left the shiftable group")
	# The capture reparents the hull, and a reparent passes through
	# _exit_tree — which used to free the stowed suit (EVA dead after any
	# docking or landing). Guard the regression.
	var suit: RigidBody3D = _ship.get("character")
	_check(suit != null and is_instance_valid(suit),
		"stowed suit survives the landing reparent")
	# And EVA exit on the ground must enter the WORLD: the landed ship's own
	# parent is the rail-driven surface, and a live body added there drifts
	# kilometres in frames (the write-back fight).
	if suit != null:
		suit.call("request_exit")
		suit.freeze = true
		_check(suit.get_parent() != null and suit.get_parent() != _earth.planet_surface(),
			"EVA exit while landed enters the world, not the rail-driven surface")
		GameState.input_mode = GameState.InputMode.SHIP_FLIGHT
		suit.call("stow")


## Warp time forward: the ship's pose in the surface frame must hold exactly
## while the world turns underneath — and Earth co-moves ~130 m/s, so origin
## shifts fire during this and must not smear the ship off the ground.
func _test_corotation_under_warp() -> void:
	if not GameState.landed:
		_check(false, "co-rotation precondition (not landed)")
		return
	var local0: Transform3D = _ship.transform
	var radial0: float = (_ship.global_position
		- OriginShift.to_render(_earth.true_pos)).length()
	var t0: float = SimClock.sim_time
	SimClock.warp = 60.0
	for i in 240:
		await get_tree().process_frame
	SimClock.reset_warp()
	var dt: float = SimClock.sim_time - t0
	var local1: Transform3D = _ship.transform
	var drift: float = local0.origin.distance_to(local1.origin)
	_check(drift < 0.01, "landed pose holds in the surface frame",
		"%.4f m local drift over %.0f sim-s" % [drift, dt])
	var radial1: float = (_ship.global_position
		- OriginShift.to_render(_earth.true_pos)).length()
	_check(absf(radial1 - radial0) < 1.0, "still standing on the ground",
		"radial delta %.2f m" % absf(radial1 - radial0))
	var spun: float = TAU * dt / _earth.def.spin_period
	_check(spun > 0.05, "the planet actually turned underneath",
		"%.3f rad of spin" % spun)


func _test_takeoff() -> void:
	print("\n== takeoff ==")
	var pos_before: Vector3 = _ship.global_position
	_landing.release()
	await get_tree().physics_frame
	_check(not GameState.landed, "released the landed state")
	_check(_ship.is_in_group(OriginShift.SHIFTABLE_GROUP), "hull rejoined the shiftable group")
	var jump: float = _ship.global_position.distance_to(pos_before)
	_check(jump < 5.0, "no teleport frame on release", "%.2f m" % jump)
	var ground_v: Vector3 = LandingComputer.surface_point_velocity(_earth, _ship.global_position)
	var rel: float = (_ship.linear_velocity - ground_v).length()
	_check(absf(rel - _landing.push_off_speed) < 0.1,
		"lift-off hands off ground velocity plus the push-off kick", "%.3f m/s" % rel)
	# Climb: thrust up must actually gain altitude against gravity (TWR > 1).
	GameState.flight_assist_enabled = false
	var up: Vector3 = (_ship.global_position - OriginShift.to_render(_earth.true_pos)).normalized()
	var alt0: float = (_ship.global_position - OriginShift.to_render(_earth.true_pos)).length()
	for i in 120:
		# The belly jets carry takeoff — main-engine budget on the vertical axis.
		up = (_ship.global_position - OriginShift.to_render(_earth.true_pos)).normalized()
		_ship.apply_central_force(up * _ship.get("thrust_main") * 0.9)
		var v_before: Vector3 = _ship.linear_velocity
		await get_tree().physics_frame
		var dv: Vector3 = _ship.linear_velocity - v_before
		if dv.length() > 1.0:
			var names: Array = []
			for c in _ship.get_colliding_bodies():
				names.append(str(c.get_path()))
			print("    [KICK %3d] dv %+7.2f (%s) pos %s contacts %s" % [
				i, dv.length(), dv.normalized(), _ship.global_position, names])
	var alt1: float = (_ship.global_position - OriginShift.to_render(_earth.true_pos)).length()
	var v_up: float = (_ship.linear_velocity
		- LandingComputer.surface_point_velocity(_earth, _ship.global_position)).dot(up)
	_check(alt1 > alt0 + 1.0, "climbs out under thrust",
		"+%.1f m in 2 s (v_up %.2f, frozen=%s, contacts=%d)" % [
			alt1 - alt0, v_up, _ship.freeze, _ship.get_colliding_bodies().size()])
