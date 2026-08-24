extends Node
class_name Autopilot
## Destination autopilot: flight assist with somewhere to be.
##
## The player picks a body at the nav console; this flies a brachistochrone
## transfer to it — accelerate toward the target, flip at the midpoint, decelerate
## into a standoff park matched to the body's orbital velocity. Because a real
## constant-acceleration transfer across even a compressed solar system takes
## tens of minutes, the clock is compressed so the trip costs the player well
## under five minutes of actual sitting-there time. That bound is a guarantee,
## not a hope: see `_plan_warp`.
##
## Two design decisions worth knowing before changing anything here:
##
## 1. **The transfer is analytic, not physical.** The ship is frozen and its
##    true-space position is integrated in 64-bit here, then written to render
##    space each frame. Running a live physics burn under 20x time compression
##    would mean 300-metre physics steps — every collision check would tunnel and
##    the integration error would compound. Bodies are on analytic rails for the
##    same reason, so compressing time stays exact.
##
## 2. **Guidance is closed-loop, not a precomputed path.** Destinations move
##    while you travel. Each step re-aims at where the body is *now* and brakes
##    against how far is left, which converges on arrival without ever solving a
##    rendezvous polynomial. The plan computed at engage time is only used to
##    pick a warp factor and show an ETA.
##
## The cruise drive is deliberately not the manual main engine. 20 m/s² would make
## precision debris work impossible to fly by hand; the ship computer gets a
## high-impulse drive it alone can throttle, and the pilot keeps the 4 m/s² main.

enum Phase { IDLE, TRANSFER, ARRIVING }

## Cruise-drive acceleration, m/s². Autopilot only — see the note above.
@export var cruise_accel: float = 20.0

## Speed ceiling, m/s. Keeps the midpoint flip legible and bounds the step size.
@export var max_cruise_speed: float = 8000.0

## What a transfer should cost the player, in real seconds. Warp is chosen to
## hit this; short hops that already fit run uncompressed.
@export var target_real_seconds: float = 45.0

## Hard ceiling on real time for any transfer, in seconds. The user-facing
## promise: nothing takes longer than this.
@export var max_real_seconds: float = 300.0

## Below this much simulation time, don't bother compressing.
@export var min_warp_sim_seconds: float = 30.0

## Arrival tolerances: metres from the standoff point, and m/s relative.
@export var arrival_distance_tolerance: float = 60.0
@export var arrival_speed_tolerance: float = 6.0

## Attitude slew rate under autopilot control, radians per simulation second.
@export var attitude_slew_rate: float = 0.6

## Fuel per m/s of delta-v spent by the cruise drive.
@export var cruise_fuel_per_dv: float = 0.4

signal engaged(target_name: String, eta_real: float)
signal progress(fraction: float, eta_real: float, distance: float)
signal arrived(target_name: String)
signal cancelled(reason: String)

var phase: Phase = Phase.IDLE
var target: NavTarget = null

var _ship: RigidBody3D
var _system: SolarSystem

# Transfer state, all 64-bit true space.
var _pos: Array = [0.0, 0.0, 0.0]
var _vel_rel: Array = [0.0, 0.0, 0.0]   # velocity relative to the target body
var _total_distance: float = 0.0
var _planned_sim_seconds: float = 0.0
var _elapsed_sim: float = 0.0
var _dv_spent: float = 0.0


func _ready() -> void:
	_ship = get_parent() as RigidBody3D
	if _ship == null:
		push_error("Autopilot must be a child of the ship RigidBody3D.")


func setup(system: SolarSystem) -> void:
	_system = system


## --- Engage / cancel ---------------------------------------------------------

func can_engage() -> bool:
	# Docked means physically attached to a port — the station undocks you, the
	# autopilot does not tear you off it.
	return (
		phase == Phase.IDLE and _ship != null and _system != null
		and not GameState.docked and not GameState.landed
	)


func engage(destination: NavTarget) -> bool:
	if not can_engage() or destination == null:
		return false
	# Inside a gravity shell the analytic transfer's frozen-hull assumption is
	# a lie — the well owns you until you climb out of it, by hand (LD3).
	if _system.landable_body_at(OriginShift.to_true(_ship.global_position)) != null:
		cancelled.emit("in gravity well — climb above the shell first")
		return false
	target = destination
	_pos = OriginShift.to_true(_ship.global_position)
	# Start from the ship's current velocity, expressed relative to the target.
	var tv: Array = target.velocity_at(SimClock.sim_time)
	_vel_rel = [
		float(_ship.linear_velocity.x) - tv[0],
		float(_ship.linear_velocity.y) - tv[1],
		float(_ship.linear_velocity.z) - tv[2],
	]
	_elapsed_sim = 0.0
	_dv_spent = 0.0

	var plan := _plan()
	_total_distance = plan.distance
	_planned_sim_seconds = plan.sim_seconds
	SimClock.warp = _plan_warp(plan.sim_seconds)

	# Hand the ship over: frozen, no collisions, no pilot input.
	_ship.freeze = true
	_ship.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	_ship.collision_mask = 0
	GameState.autopilot_active = true
	phase = Phase.TRANSFER

	engaged.emit(target.nav_display_name(), SimClock.real_span(plan.sim_seconds))
	return true


func cancel(reason: String = "pilot override") -> void:
	if phase == Phase.IDLE:
		return
	_release_to_physics()
	var was := target
	phase = Phase.IDLE
	target = null
	cancelled.emit(reason)
	if was:
		AudioManager.note_event(&"autopilot_cancelled")


func _release_to_physics() -> void:
	SimClock.reset_warp()
	# Re-centre the origin on where we ended up, then hand back exact state.
	OriginShift.shift_to(_pos)
	_ship.global_position = OriginShift.to_render(_pos)
	_ship.freeze = false
	_ship.collision_mask = 15
	# Hand back the exact state we arrived with, including the body's orbital
	# velocity — so "parked next to Europa" stays parked.
	var world_vel: Array = _vel_rel.duplicate()
	if target:
		world_vel = OriginShift.dv_add(world_vel, target.velocity_at(SimClock.sim_time))
	_ship.linear_velocity = Vector3(
		float(world_vel[0]), float(world_vel[1]), float(world_vel[2])
	)
	_ship.angular_velocity = Vector3.ZERO
	GameState.autopilot_active = false
	GameState.flight_assist_enabled = true


## --- Planning ----------------------------------------------------------------

class TransferPlan extends RefCounted:
	var distance: float = 0.0
	var sim_seconds: float = 0.0


## Estimate distance and duration, accounting for the target moving while we
## travel. Three iterations is plenty: the correction shrinks fast.
func _plan() -> TransferPlan:
	var plan := TransferPlan.new()
	var t_flight: float = 0.0
	for _i in 3:
		var arrive_at: float = SimClock.sim_time + t_flight
		var aim: Array = _aim_point(target, arrive_at, _pos)
		var to_aim: Array = OriginShift.dv_sub(aim, _pos)
		plan.distance = OriginShift.dv_length(to_aim)
		t_flight = _brachistochrone_time(plan.distance, OriginShift.dv_length(_vel_rel))
	plan.sim_seconds = t_flight
	return plan


## Time to cover `distance` from speed `v0`, accelerating then braking to rest.
## Peak speed satisfies 2*v_peak² - v0² = 2*a*d; total time is (2*v_peak - v0)/a.
func _brachistochrone_time(distance: float, v0: float) -> float:
	var a: float = maxf(cruise_accel, 0.001)
	var v_peak: float = sqrt(maxf((2.0 * a * distance + v0 * v0) * 0.5, 0.0))
	v_peak = minf(v_peak, max_cruise_speed)
	return maxf((2.0 * v_peak - v0) / a, 0.0)


## Warp factor that lands the trip on `target_real_seconds`, never exceeding the
## promised `max_real_seconds` and never compressing trivially short hops.
func _plan_warp(sim_seconds: float) -> float:
	if sim_seconds <= min_warp_sim_seconds:
		return 1.0
	var wanted: float = sim_seconds / maxf(target_real_seconds, 1.0)
	# The floor is what the hard cap demands; the ceiling is the clock's limit.
	var required: float = sim_seconds / maxf(max_real_seconds, 1.0)
	return clampf(maxf(wanted, required), 1.0, SimClock.MAX_WARP)


## What a transfer to `body` would cost, without engaging. The nav console shows
## this so the player chooses a destination knowing the price in time.
## Returns { distance, sim_seconds, real_seconds, warp }.
func estimate_transfer(body: NavTarget) -> Dictionary:
	if body == null or _ship == null:
		return {"distance": 0.0, "sim_seconds": 0.0, "real_seconds": 0.0, "warp": 1.0}
	var from_pos: Array = OriginShift.to_true(_ship.global_position)
	var t_flight: float = 0.0
	var distance: float = 0.0
	for _i in 3:
		var aim: Array = _aim_point(body, SimClock.sim_time + t_flight, from_pos)
		distance = OriginShift.dv_length(OriginShift.dv_sub(aim, from_pos))
		t_flight = _brachistochrone_time(distance, 0.0)
	var warp: float = _plan_warp(t_flight)
	return {
		"distance": distance,
		"sim_seconds": t_flight,
		"real_seconds": t_flight / maxf(warp, 0.0001),
		"warp": warp,
	}


## Standoff point: on the near side of the body, so we arrive facing it rather
## than through it.
func _aim_point(body: NavTarget, at_sim_time: float, from_pos: Array) -> Array:
	var body_pos: Array = body.position_at(at_sim_time)
	var outward: Array = OriginShift.dv_normalized(OriginShift.dv_sub(from_pos, body_pos))
	if OriginShift.dv_length(outward) < 0.5:
		outward = [0.0, 1.0, 0.0]
	return OriginShift.dv_add(body_pos, OriginShift.dv_scaled(outward, body.arrival_standoff()))


## --- Transfer loop -----------------------------------------------------------

func _process(delta: float) -> void:
	if phase != Phase.TRANSFER or target == null:
		return
	var dt_sim: float = delta * SimClock.warp
	if dt_sim <= 0.0:
		return
	_elapsed_sim += dt_sim
	_step(dt_sim)


func _step(dt_sim: float) -> void:
	var now: float = SimClock.sim_time
	var target_vel: Array = target.velocity_at(now)
	var aim: Array = _aim_point(target, now, _pos)
	var to_aim: Array = OriginShift.dv_sub(aim, _pos)
	var distance: float = OriginShift.dv_length(to_aim)
	var speed_rel: float = OriginShift.dv_length(_vel_rel)

	if distance <= arrival_distance_tolerance and speed_rel <= arrival_speed_tolerance:
		_complete()
		return

	# Desired relative velocity: straight at the aim point, fast as we can still
	# brake from. sqrt(2*a*d) is the speed whose full-deceleration stopping
	# distance is exactly d — track it and arrival falls out for free.
	var a: float = cruise_accel
	var brake_speed: float = sqrt(2.0 * a * maxf(distance, 0.0))
	var cruise_speed: float = minf(brake_speed, max_cruise_speed)
	var dir: Array = OriginShift.dv_normalized(to_aim)
	var desired: Array = OriginShift.dv_scaled(dir, cruise_speed)

	# Accelerate toward the desired velocity, capped by what the drive can do.
	var dv: Array = OriginShift.dv_sub(desired, _vel_rel)
	var dv_len: float = OriginShift.dv_length(dv)
	var dv_budget: float = a * dt_sim
	if dv_len > dv_budget and dv_len > 1e-9:
		dv = OriginShift.dv_scaled(dv, dv_budget / dv_len)
		dv_len = dv_budget
	_vel_rel = OriginShift.dv_add(_vel_rel, dv)
	_dv_spent += dv_len

	# Gravity shells (LD3): the same field the live ship feels. Standoffs sit
	# outside every shell so this is normally zero; a route that skims one gets
	# the honest tug, and the closed-loop guidance absorbs it.
	var g: Vector3 = _system.gravity_at(_pos)
	if g != Vector3.ZERO:
		_vel_rel = OriginShift.dv_add(_vel_rel, [
			g.x * dt_sim, g.y * dt_sim, g.z * dt_sim])

	# Integrate true position with the target's motion folded back in.
	var world_vel: Array = OriginShift.dv_add(_vel_rel, target_vel)
	_pos = OriginShift.dv_add(_pos, OriginShift.dv_scaled(world_vel, dt_sim))

	_consume_cruise_fuel(dv_len)
	_write_render_state(dv, dt_sim)
	_emit_progress(distance)


## Keep the origin on the ship so render space never leaves float32's comfort
## zone, then point the hull along the thrust vector — which makes the midpoint
## flip happen on its own, because that is where the thrust vector reverses.
func _write_render_state(thrust_dir: Array, dt_sim: float) -> void:
	OriginShift.shift_to(_pos)
	_ship.global_position = OriginShift.to_render(_pos)

	var dir := Vector3(float(thrust_dir[0]), float(thrust_dir[1]), float(thrust_dir[2]))
	if dir.length_squared() < 1e-12:
		return
	dir = dir.normalized()
	var up := Vector3.UP
	if absf(dir.dot(up)) > 0.999:
		up = Vector3.RIGHT
	var want := Basis.looking_at(dir, up)
	var slew: float = clampf(attitude_slew_rate * dt_sim, 0.0, 1.0)
	var q := Quaternion(_ship.global_basis.orthonormalized()).slerp(Quaternion(want), slew)
	_ship.global_basis = Basis(q.normalized())


func _consume_cruise_fuel(dv_len: float) -> void:
	if dv_len <= 0.0:
		return
	if _ship.has_method("spend_fuel"):
		_ship.spend_fuel(dv_len * cruise_fuel_per_dv)


func _emit_progress(distance: float) -> void:
	var fraction: float = 0.0
	if _total_distance > 1.0:
		fraction = clampf(1.0 - distance / _total_distance, 0.0, 1.0)
	var eta_sim: float = _brachistochrone_time(distance, OriginShift.dv_length(_vel_rel))
	progress.emit(fraction, SimClock.real_span(eta_sim), distance)


func _complete() -> void:
	var name_arrived: String = target.nav_display_name()
	_vel_rel = [0.0, 0.0, 0.0]
	_release_to_physics()
	phase = Phase.IDLE
	target = null
	arrived.emit(name_arrived)
	AudioManager.note_event(&"autopilot_arrived")


## --- Player override ---------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if phase == Phase.IDLE:
		return
	# Any hands-on-the-stick input drops the autopilot. Discoverable, and it
	# means a player never has to hunt for the disengage key.
	if event is InputEventMouseMotion:
		if (event as InputEventMouseMotion).relative.length() > 8.0:
			cancel("pilot override")
		return
	for action in [
		&"thrust_forward", &"thrust_back", &"thrust_left", &"thrust_right",
		&"thrust_up", &"thrust_down", &"roll_left", &"roll_right",
	]:
		if event.is_action_pressed(action):
			cancel("pilot override")
			return
	if event.is_action_pressed(&"engage_autopilot"):
		cancel("disengaged")


## --- Readouts ----------------------------------------------------------------

## Current cruise speed relative to the destination, m/s. The ship is frozen
## during a transfer, so its `linear_velocity` is stale — the HUD asks here.
func current_speed() -> float:
	if phase == Phase.IDLE:
		return 0.0
	return OriginShift.dv_length(_vel_rel)

func status_line() -> String:
	if phase == Phase.IDLE or target == null:
		return ""
	var distance: float = OriginShift.dv_length(
		OriginShift.dv_sub(_aim_point(target, SimClock.sim_time, _pos), _pos)
	)
	var eta: float = SimClock.real_span(
		_brachistochrone_time(distance, OriginShift.dv_length(_vel_rel))
	)
	return "AUTO → %s   %s   ETA %s   ×%.0f" % [
		target.nav_display_name(),
		_format_distance(distance),
		_format_clock(eta),
		SimClock.warp,
	]


static func _format_distance(metres: float) -> String:
	if metres >= 1000.0:
		return "%.1f km" % (metres / 1000.0)
	return "%.0f m" % metres


static func _format_clock(seconds: float) -> String:
	var s: int = int(maxf(seconds, 0.0))
	return "%d:%02d" % [s / 60, s % 60]
