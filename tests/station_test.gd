extends Node
## Headless verification for orbital stations — the SD1 gate.
##
## Run: godot --headless res://tests/station_test.tscn
##
## Covers: the station rides its analytic rail around Earth, the autopilot
## intercepts it through the NavTarget interface (a MOVING target — this
## exercises the interface plus the intercept math end to end), and the
## reference-frame rule resolves the station over its planet close in, which is
## the docking prerequisite. The transfer is driven through the autopilot's
## integrator at a fixed step, same pattern as travel_test; the flight-assist
## settle runs on live physics frames.

const SIM_STEP: float = 0.25
const MAX_STEPS: int = 400000

var _failures: int = 0


func _ready() -> void:
	var world: Node3D = load("res://scenes/game_world.tscn").instantiate()
	add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame

	var system: SolarSystem = world.get_node("SolarSystem")
	var ship: RigidBody3D = world.get_node("Ship")
	var autopilot: Autopilot = ship.get_node("Autopilot")
	var station: OrbitalStation = world.get_node("MeridianRelay")

	_test_registration(system, station)
	_test_orbit(system, station)
	_test_transfer(system, ship, autopilot, station)
	await _test_reference_frame(system, ship, station)

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


## --- Registration ------------------------------------------------------------

func _test_registration(system: SolarSystem, station: OrbitalStation) -> void:
	print("\n== registration ==")
	_check(station != null, "station instanced in GameWorld")
	_check(system.stations.has(station), "station registered with SolarSystem")
	_check(system.destinations().has(station), "station listed as a nav destination")
	_check(not station.is_in_group(OriginShift.SHIFTABLE_GROUP),
		"station is NOT in origin_shiftable (recomputed from true space)")
	_check(station.parent_body == system.get_body(&"earth"),
		"station's parent body resolved to Earth")


## --- Orbit -------------------------------------------------------------------

func _test_orbit(system: SolarSystem, station: OrbitalStation) -> void:
	print("\n== orbit ==")
	var earth := system.get_body(&"earth")

	# Same style as the Moon check: distance from the parent must stay at the
	# orbit radius no matter how far the clock advances.
	var radius_0: float = OriginShift.dv_length(
		OriginShift.dv_sub(station.position_at(0.0), earth.position_at(0.0))
	)
	var worst: float = 0.0
	for i in 200:
		var t: float = float(i) * 137.0
		var d: float = OriginShift.dv_length(
			OriginShift.dv_sub(station.position_at(t), earth.position_at(t))
		)
		worst = maxf(worst, absf(d - radius_0))
	_check(worst < 1.0, "station holds its orbit radius around Earth",
		"(radius %.0f m, max error %.3f m)" % [radius_0, worst])

	# Analytic velocity must match the position derivative, or the autopilot's
	# intercept aims wrong.
	var t0: float = 5000.0
	var dt: float = 0.01
	var p0: Array = station.position_at(t0)
	var p1: Array = station.position_at(t0 + dt)
	var numeric: Array = OriginShift.dv_scaled(OriginShift.dv_sub(p1, p0), 1.0 / dt)
	var analytic: Array = station.velocity_at(t0)
	var err: float = OriginShift.dv_length(OriginShift.dv_sub(numeric, analytic))
	_check(err < 0.5, "station velocity matches position derivative",
		"(error %.4f m/s)" % err)


## --- Transfer ----------------------------------------------------------------

func _test_transfer(
	system: SolarSystem, ship: RigidBody3D, autopilot: Autopilot, station: OrbitalStation
) -> void:
	print("\n== transfer ==")
	if not autopilot.engage(station):
		_check(false, "autopilot engages the station")
		return
	_check(true, "autopilot engages the station")

	var steps: int = 0
	while autopilot.phase == Autopilot.Phase.TRANSFER and steps < MAX_STEPS:
		SimClock.sim_time += SIM_STEP
		autopilot._step(SIM_STEP)
		steps += 1
	_check(autopilot.phase == Autopilot.Phase.IDLE, "transfer converges",
		"(%d steps)" % steps)
	if autopilot.phase != Autopilot.Phase.IDLE:
		autopilot.cancel("test timeout")
		return

	var true_pos: Array = OriginShift.to_true(ship.global_position)
	var distance: float = OriginShift.dv_length(
		OriginShift.dv_sub(true_pos, station.position_at(SimClock.sim_time))
	)
	var standoff: float = station.arrival_standoff()
	_check(absf(distance - standoff) <= autopilot.arrival_distance_tolerance * 2.0,
		"arrived at the standoff distance",
		"(%.0f m, standoff %.0f m)" % [distance, standoff])

	var sv: Array = station.velocity_at(SimClock.sim_time)
	var rel := Vector3(
		ship.linear_velocity.x - float(sv[0]),
		ship.linear_velocity.y - float(sv[1]),
		ship.linear_velocity.z - float(sv[2])
	)
	_check(rel.length() <= autopilot.arrival_speed_tolerance * 2.0,
		"arrival velocity-matched to the moving station",
		"(%.2f m/s relative)" % rel.length())


## --- Reference frame ---------------------------------------------------------

func _test_reference_frame(
	system: SolarSystem, ship: RigidBody3D, station: OrbitalStation
) -> void:
	print("\n== reference frame ==")
	# The transfer above was driven through the integrator without letting
	# frames run, so cached true positions are stale — give SolarSystem a frame
	# to refresh them before querying reference frames.
	await get_tree().process_frame
	await get_tree().process_frame
	# The transfer parked us at the standoff, well inside the 2 km influence.
	var true_pos: Array = OriginShift.to_true(ship.global_position)
	var ref := system.reference_body(true_pos)
	_check(ref == station, "reference frame at the standoff is the station",
		"(got %s)" % (ref.nav_display_name() if ref else "none"))

	# Flight assist should now hold station in the station's frame: from the
	# arrival residual (up to 6 m/s), releasing all input must settle to under
	# 0.5 m/s relative. Live physics, real assist forces.
	GameState.input_mode = GameState.InputMode.SHIP_FLIGHT
	GameState.flight_assist_enabled = true
	for _i in 600:
		await get_tree().physics_frame
	var rel: Vector3 = ship.linear_velocity - system.reference_velocity(
		OriginShift.to_true(ship.global_position)
	)
	_check(rel.length() < 0.5, "flight assist holds station in the station frame",
		"(%.3f m/s relative after settle)" % rel.length())
