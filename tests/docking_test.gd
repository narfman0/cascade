extends Node
## Headless verification for docking — the SD2 gate.
##
## Run: godot --headless res://tests/docking_test.tscn
##
## The approaches are flown as live physics: the ship is posed frozen (a frozen
## kinematic body's transform only commits through physics steps, so poses are
## held across several physics frames), then released co-moving with the
## station plus a scripted drift. Flight assist is OFF for the approach cases —
## the capture gate is what is under test, not the assist.
##
## The origin-shift case is the trap-#3 regression test: a docked ship must
## NOT be in `origin_shiftable` (it inherits shifts through the port's tree),
## and being in both places showed up historically as the 16 km lurch bug.

var _failures: int = 0
var _world: Node3D
var _ship: RigidBody3D
var _dc: DockingComputer
var _station: OrbitalStation
var _port: DockingPort


func _ready() -> void:
	_world = load("res://scenes/game_world.tscn").instantiate()
	add_child(_world)
	await get_tree().process_frame
	await get_tree().process_frame

	_ship = _world.get_node("Ship")
	_dc = _ship.get_node("DockingComputer")
	_station = _world.get_node("MeridianRelay")
	_port = _station.get_node("DockingPort")

	await _test_hot_approach()
	await _test_misaligned_approach()
	await _test_clean_capture()
	await _test_origin_shift_while_docked()
	await _test_ride_the_rails()
	await _test_undock()

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


## --- Posing ------------------------------------------------------------------

## Hold the ship frozen at `out_m` along the port axis, nose toward the port,
## yawed off-axis by `angle_off_deg`, then release it co-moving with the
## station plus `drift_mps` straight down the approach axis. The pose is
## re-applied against the port's *current* transform each physics frame because
## the station moves ~2 m per frame on its rail.
func _pose_and_release(out_m: float, angle_off_deg: float, drift_mps: float) -> void:
	GameState.input_mode = GameState.InputMode.SHIP_FLIGHT
	GameState.flight_assist_enabled = false
	_ship.freeze = true
	for _i in 5:
		var axis: Vector3 = _port.axis_out()
		var pos: Vector3 = _port.global_position + axis * out_m
		var up := Vector3.UP
		if absf(axis.dot(up)) > 0.99:
			up = Vector3.RIGHT
		_ship.global_position = pos
		_ship.look_at(pos - axis, up)
		_ship.rotate(up, deg_to_rad(angle_off_deg))
		await get_tree().physics_frame
	_ship.linear_velocity = _port.station_velocity() - _port.axis_out() * drift_mps
	_ship.angular_velocity = Vector3.ZERO
	_ship.freeze = false


## --- Cases -------------------------------------------------------------------

func _test_hot_approach() -> void:
	print("\n== hot approach does not capture ==")
	await _pose_and_release(8.0, 0.0, 3.0)
	# 1 s at 3 m/s closes 3 of the 8 m — inside the volume the whole time, but
	# never slow enough, and never far enough in to touch the structure.
	var was_in_volume := false
	for _i in 60:
		await get_tree().physics_frame
		was_in_volume = was_in_volume or _dc.approach_port != null
	_check(was_in_volume, "ship transited the capture volume")
	_check(not GameState.docked, "no capture at 3.0 m/s",
		"(limit %.1f m/s)" % _port.capture_speed_max)


func _test_misaligned_approach() -> void:
	print("\n== misaligned approach does not capture ==")
	await _pose_and_release(6.0, 35.0, 0.5)
	var was_in_volume := false
	for _i in 120:
		await get_tree().physics_frame
		was_in_volume = was_in_volume or _dc.approach_port != null
	_check(was_in_volume, "ship sat in the capture volume")
	_check(not GameState.docked, "no capture at 35° off-axis",
		"(limit %.0f°)" % _port.capture_angle_max_deg)


func _test_clean_capture() -> void:
	print("\n== clean approach captures ==")
	await _pose_and_release(6.0, 0.0, 0.5)
	for _i in 240:
		await get_tree().physics_frame
		if GameState.docked:
			break
	_check(GameState.docked, "soft capture at 0.5 m/s, aligned")
	if not GameState.docked:
		return
	_check(_ship.freeze, "ship is frozen kinematic")
	_check(_ship.get_parent() == _port, "ship is parented under the port")
	_check(not _ship.is_in_group(OriginShift.SHIFTABLE_GROUP),
		"ship left the origin_shiftable group")
	_check(_dc.docked_port == _port, "computer reports the docked port")
	var fuel_frac: float = float(_ship.get("fuel_remaining")) / float(_ship.get("fuel_capacity"))
	_check(fuel_frac > 0.999, "fuel refilled by station services",
		"(%.1f%%)" % (fuel_frac * 100.0))


func _test_origin_shift_while_docked() -> void:
	print("\n== docked through an origin shift ==")
	if not GameState.docked:
		_check(false, "precondition: docked")
		return
	var local_before: Transform3D = _ship.transform
	OriginShift.shift_by(Vector3(20000, 0, 0))
	# Let the station recompute from true space and the auto-shift re-centre.
	for _i in 4:
		await get_tree().physics_frame
	var drift: float = (_ship.transform.origin - local_before.origin).length()
	_check(drift < 0.001, "ship stays exactly at the port through the shift",
		"(local drift %.6f m)" % drift)
	_check(GameState.docked and _ship.get_parent() == _port,
		"still docked after the shift")


func _test_ride_the_rails() -> void:
	print("\n== docked through 60 s of sim time ==")
	var local_before: Transform3D = _ship.transform
	SimClock.sim_time += 60.0
	for _i in 4:
		await get_tree().physics_frame
	var drift: float = (_ship.transform.origin - local_before.origin).length()
	_check(drift < 0.001, "no drift relative to the port",
		"(local drift %.6f m)" % drift)
	# The ship's true-space position must have moved with the station's rail.
	var ship_true: Array = OriginShift.to_true(_ship.global_position)
	var offset: float = OriginShift.dv_length(
		OriginShift.dv_sub(ship_true, _station.true_pos)
	)
	_check(offset < 100.0, "ship rides the station's orbit",
		"(%.1f m from station origin)" % offset)


func _test_undock() -> void:
	print("\n== undock ==")
	if not GameState.docked:
		_check(false, "precondition: docked")
		return
	var expected: Vector3 = _port.station_velocity() + _port.axis_out() * _dc.push_off_speed
	_dc.undock()
	_check(not GameState.docked, "docked flag cleared")
	_check(not _ship.freeze, "ship is live again")
	_check(_ship.get_parent() == _world, "ship reparented to the world")
	_check(_ship.is_in_group(OriginShift.SHIFTABLE_GROUP),
		"ship rejoined origin_shiftable")
	var vel_err: float = (_ship.linear_velocity - expected).length()
	_check(vel_err < 0.01, "departure velocity is station velocity plus push-off",
		"(error %.4f m/s)" % vel_err)
	_check(GameState.flight_assist_enabled, "flight assist on for the departure")
	# A few live frames: flight assist parks the ship just off the port; what
	# matters is that it is free, not that it keeps receding.
	for _i in 60:
		await get_tree().physics_frame
	_check(not GameState.docked, "no immediate re-capture after push-off")
	# The volume still sees the parked ship — proves the body rejoined the
	# physics space on undock (it leaves the space entirely while docked).
	_check(_dc.approach_port == _port, "port volume detects the free ship again")
