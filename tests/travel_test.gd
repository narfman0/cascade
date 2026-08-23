extends Node
## Headless verification for the solar system and the transfer autopilot.
##
## Run: godot --headless res://tests/travel_test.tscn
##
## Real-time playback would take a quarter of an hour to cover every
## destination, so this drives the autopilot's integrator directly at a fixed
## simulation step instead of waiting on frames. That is the same code path a
## live transfer uses — only the clock source differs.

const SIM_STEP: float = 0.25
const MAX_STEPS: int = 400000

var _failures: int = 0


func _ready() -> void:
	var world: Node3D = load("res://scenes/game_world.tscn").instantiate()
	add_child(world)
	# Let _ready chains and the first body placement settle.
	await get_tree().process_frame
	await get_tree().process_frame

	var system: SolarSystem = world.get_node("SolarSystem")
	var ship: RigidBody3D = world.get_node("Ship")
	var autopilot: Autopilot = ship.get_node("Autopilot")

	_report_spawn(system, ship)
	_test_bodies(system)
	_test_sunlight(system)
	_test_transfers(system, ship, autopilot)

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


## --- Sunlight (Track SL1 + SL2) ------------------------------------------------

func _test_sunlight(system: SolarSystem) -> void:
	print("\n== sunlight ==")
	var sun := system.get_body(&"sun")
	var earth := system.get_body(&"earth")

	# SL2: the disc is the real 0.53 degrees from Earth orbit.
	var width_deg: float = rad_to_deg(
		2.0 * atan(sun.def.radius / earth.def.orbit_radius))
	_check(absf(width_deg - 0.53) < 0.06, "the sun is 0.53 degrees from Earth",
		"(%.2f deg)" % width_deg)

	# SL1 geometry: deep in Earth's shadow the sun is gone; on the sunny side
	# it is whole; a point grazing the disc's edge sits in the penumbra.
	var to_earth := Vector3(
		earth.true_pos[0] - sun.true_pos[0],
		earth.true_pos[1] - sun.true_pos[1],
		earth.true_pos[2] - sun.true_pos[2]).normalized()
	var umbra: Array = [
		earth.true_pos[0] + to_earth.x * earth.def.radius * 3.0,
		earth.true_pos[1] + to_earth.y * earth.def.radius * 3.0,
		earth.true_pos[2] + to_earth.z * earth.def.radius * 3.0,
	]
	_check(system.sun_visibility_at(umbra) < 0.05,
		"Earth's umbra swallows the sun",
		"(%.3f)" % system.sun_visibility_at(umbra))
	var sunny: Array = [
		earth.true_pos[0] - to_earth.x * earth.def.radius * 3.0,
		earth.true_pos[1] - to_earth.y * earth.def.radius * 3.0,
		earth.true_pos[2] - to_earth.z * earth.def.radius * 3.0,
	]
	_check(system.sun_visibility_at(sunny) > 0.999, "the sunny side sees it whole")
	# Slide sideways off the shadow axis until the disc is half uncovered.
	var side := to_earth.cross(Vector3.UP).normalized()
	var pen_vis: float = 0.0
	var found_partial := false
	for k in 40:
		var off: float = earth.def.radius * (0.9 + 0.01 * float(k))
		var probe: Array = [
			umbra[0] + side.x * off, umbra[1] + side.y * off, umbra[2] + side.z * off,
		]
		pen_vis = system.sun_visibility_at(probe)
		if pen_vis > 0.05 and pen_vis < 0.95:
			found_partial = true
			break
	_check(found_partial, "the penumbra is a gradient, not a switch",
		"(%.2f)" % pen_vis)

	# SL1 falloff: pure geometry, asserted through the pure formula.
	_check(is_equal_approx(
			SolarSystem.disc_occlusion(0.1, 0.2, 1.0), 0.0),
		"clear separation occludes nothing")
	_check(is_equal_approx(
			SolarSystem.disc_occlusion(0.1, 0.2, 0.05), 1.0),
		"full cover occludes everything")

	# SL3 sanity here too: vacuum sunlight is exactly white.
	_check(system.sun_filter_at(sunny).is_equal_approx(Vector3.ONE),
		"vacuum sunlight is white")


## --- Spawn -------------------------------------------------------------------

func _report_spawn(system: SolarSystem, ship: RigidBody3D) -> void:
	print("\n== spawn ==")
	var true_pos: Array = OriginShift.to_true(ship.global_position)
	var earth := system.get_body(&"earth")
	var altitude: float = OriginShift.dv_length(OriginShift.dv_sub(true_pos, earth.true_pos))
	print("  render pos      %s" % ship.global_position)
	print("  altitude        %.0f m from Earth centre" % altitude)
	print("  ship velocity   %.1f m/s absolute" % ship.linear_velocity.length())

	var ref := system.reference_body(true_pos)
	_check(ref == earth, "reference frame is Earth",
		"(got %s)" % (ref.nav_display_name() if ref else "none"))
	_check(absf(altitude - SolarSystemData.SPAWN_ALTITUDE) < 50.0,
		"spawn altitude matches SPAWN_ALTITUDE", "(%.0f m)" % altitude)
	# Station-keeping: the ship should start matched to Earth, not to the Sun.
	var rel: Vector3 = ship.linear_velocity - system.reference_velocity(true_pos)
	_check(rel.length() < 0.5, "spawn is station-keeping", "(%.3f m/s relative)" % rel.length())
	_check(ship.global_position.length() < OriginShift.SHIFT_THRESHOLD_METERS,
		"render space stays near the origin", "(%.0f m)" % ship.global_position.length())
	# The suit must not be a physics body nested under the ship — see
	# eva_controller.gd. If it is in the tree at spawn, that regression is back.
	var suit = ship.get("character")
	_check(suit != null and (suit as Node).get_parent() == null,
		"EVA suit is stowed out of the tree while aboard")


## --- Bodies ------------------------------------------------------------------

func _test_bodies(system: SolarSystem) -> void:
	print("\n== bodies ==")
	_check(system.bodies.size() >= 15, "system populated",
		"(%d bodies)" % system.bodies.size())

	# Moons must follow their planets: a moon's distance from its parent should
	# stay constant at its orbit radius no matter how far the clock advances.
	var moon := system.get_body(&"moon")
	var earth := system.get_body(&"earth")
	var radius_0: float = OriginShift.dv_length(
		OriginShift.dv_sub(moon.position_at(0.0), earth.position_at(0.0))
	)
	var worst: float = 0.0
	for i in 200:
		var t: float = float(i) * 137.0
		var d: float = OriginShift.dv_length(
			OriginShift.dv_sub(moon.position_at(t), earth.position_at(t))
		)
		worst = maxf(worst, absf(d - radius_0))
	_check(worst < 1.0, "Moon holds its orbit radius around Earth",
		"(max error %.3f m)" % worst)

	# Analytic velocity must match the position derivative, or the autopilot's
	# rendezvous will aim at the wrong place.
	var t0: float = 5000.0
	var dt: float = 0.01
	var p0: Array = system.get_body(&"europa").position_at(t0)
	var p1: Array = system.get_body(&"europa").position_at(t0 + dt)
	var numeric: Array = OriginShift.dv_scaled(OriginShift.dv_sub(p1, p0), 1.0 / dt)
	var analytic: Array = system.get_body(&"europa").velocity_at(t0)
	var err: float = OriginShift.dv_length(OriginShift.dv_sub(numeric, analytic))
	_check(err < 0.5, "Europa velocity matches position derivative",
		"(error %.4f m/s)" % err)


## --- Transfers ---------------------------------------------------------------

func _test_transfers(system: SolarSystem, ship: RigidBody3D, autopilot: Autopilot) -> void:
	print("\n== transfers ==")
	print("  %-14s %12s %12s %10s %8s" % ["target", "distance", "sim time", "real", "warp"])
	var worst_real: float = 0.0

	for body in system.destinations():
		var result := _fly_to(body, ship, autopilot)
		if result.is_empty():
			_failures += 1
			print("  FAIL  %s did not converge" % body.nav_display_name())
			continue
		worst_real = maxf(worst_real, result["real_seconds"])
		print("  %-14s %12s %12s %10s %8.1fx" % [
			body.nav_display_name(),
			"%.0f km" % (result["distance"] / 1000.0),
			_clock(result["sim_seconds"]),
			_clock(result["real_seconds"]),
			result["warp"],
		])

	print("")
	_check(worst_real <= autopilot.max_real_seconds,
		"every destination inside the %.0fs promise" % autopilot.max_real_seconds,
		"(worst %s)" % _clock(worst_real))


## Engage, then run the integrator until arrival. Returns {} if it never lands.
func _fly_to(body: NavTarget, ship: RigidBody3D, autopilot: Autopilot) -> Dictionary:
	if not autopilot.engage(body):
		return {}
	var warp: float = SimClock.warp
	var sim_elapsed: float = 0.0
	var steps: int = 0
	while autopilot.phase == Autopilot.Phase.TRANSFER and steps < MAX_STEPS:
		SimClock.sim_time += SIM_STEP
		autopilot._step(SIM_STEP)
		sim_elapsed += SIM_STEP
		steps += 1
	if autopilot.phase != Autopilot.Phase.IDLE:
		autopilot.cancel("test timeout")
		return {}

	# Arrival sanity: parked at the standoff distance, matched to the body.
	var true_pos: Array = OriginShift.to_true(ship.global_position)
	var distance: float = OriginShift.dv_length(
		OriginShift.dv_sub(true_pos, body.position_at(SimClock.sim_time))
	)
	var standoff: float = body.arrival_standoff()
	var park_error: float = absf(distance - standoff)
	if park_error > maxf(standoff * 0.25, autopilot.arrival_distance_tolerance * 2.0):
		_failures += 1
		print("  FAIL  %s parked %.0f m off standoff (%.0f m)" % [
			body.nav_display_name(), park_error, standoff])

	var body_vel: Array = body.velocity_at(SimClock.sim_time)
	var rel := Vector3(
		ship.linear_velocity.x - float(body_vel[0]),
		ship.linear_velocity.y - float(body_vel[1]),
		ship.linear_velocity.z - float(body_vel[2])
	)
	if rel.length() > autopilot.arrival_speed_tolerance * 2.0:
		_failures += 1
		print("  FAIL  %s arrival not velocity-matched (%.1f m/s)" % [
			body.nav_display_name(), rel.length()])

	return {
		"distance": autopilot._total_distance,
		"sim_seconds": sim_elapsed,
		"real_seconds": sim_elapsed / maxf(warp, 0.0001),
		"warp": warp,
	}


static func _clock(seconds: float) -> String:
	var s: int = int(maxf(seconds, 0.0))
	return "%d:%02d" % [s / 60, s % 60]
