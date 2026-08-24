class_name AutolandComputer extends Node
## Autoland (Track AL): the computer flies the descent the landing gates
## prove out manually — the docking computer's philosophy (manual first,
## assisted second) in its second act.
##
## Jurisdiction: INSIDE a gravity shell over a landable body — exactly where
## the autopilot refuses, so the two hand off at 1.5 R with no overlap.
## It is an INPUT SOURCE, not a second landing state: it drives the real
## physics hull through forces (the fx signals light the belly jets for
## free), pitches upright against local up, kills lateral drift against the
## surface point below, descends on a braked profile, flares under the
## capture speed limit, and lets LD4's own capture fire. Site choice stays
## the pilot's: it lands where you are, straight down.
##
## Any stick input cancels — the autopilot's discoverable rule. Fuel-out
## mid-descent just cuts thrust; Track HZ owns what happens next.
##
## AudioManager hooks: note_event at engage/touchdown/abort — M2 convention.

## Fraction of the braking-limit speed the profile rides. Below 1.0 so the
## flare has authority in reserve.
const PROFILE_MARGIN: float = 0.7
## Descent speed floor and the flare target under the 2 m/s capture limit.
const V_MIN: float = 0.8
const FLARE_SPEED: float = 1.4
const FLARE_ALTITUDE: float = 25.0
## Lateral drift gain and the attitude gains.
const LATERAL_GAIN: float = 2.0
const UPRIGHT_GAIN: float = 60000.0
const UPRIGHT_DAMP: float = 90000.0

signal engaged_autoland(body_name: String)
signal touchdown(body_name: String)
signal aborted(reason: String)

var active: bool = false
var target_body: CelestialBody = null

var _ship: RigidBody3D
var _system: SolarSystem = null
var _landing: LandingComputer


func _ready() -> void:
	_ship = get_parent() as RigidBody3D
	_landing = get_parent().get_node_or_null("LandingComputer")


func setup(system: SolarSystem) -> void:
	_system = system


func can_engage() -> bool:
	if active or _ship == null or _system == null:
		return false
	if GameState.docked or GameState.landed or GameState.autopilot_active:
		return false
	return _system.landable_body_at(OriginShift.to_true(_ship.global_position)) != null


func engage() -> bool:
	if not can_engage():
		return false
	target_body = _system.landable_body_at(OriginShift.to_true(_ship.global_position))
	active = true
	GameState.flight_assist_enabled = false  # autoland owns the axes
	AudioManager.note_event(&"autoland_engaged")
	engaged_autoland.emit(target_body.nav_display_name())
	return true


func abort(reason: String = "pilot override") -> void:
	if not active:
		return
	active = false
	target_body = null
	GameState.flight_assist_enabled = true
	AudioManager.note_event(&"autoland_aborted")
	aborted.emit(reason)


func _unhandled_input(event: InputEvent) -> void:
	if GameState.input_mode != GameState.InputMode.SHIP_FLIGHT:
		return
	if event.is_action_pressed("engage_autoland"):
		if active:
			abort()
		elif can_engage():
			engage()


func _physics_process(_delta: float) -> void:
	if not active:
		return
	# Touchdown: LD4's capture fired underneath us — stand down, mission done.
	if GameState.landed:
		active = false
		GameState.flight_assist_enabled = true
		AudioManager.note_event(&"autoland_touchdown")
		touchdown.emit(target_body.nav_display_name() if target_body else "")
		target_body = null
		return
	# Any stick input cancels (translation or a mouse-torque burst is caught
	# by the controller before us, so watch the action strengths directly).
	for action in ["thrust_forward", "thrust_back", "thrust_left", "thrust_right",
			"thrust_up", "thrust_down"]:
		if Input.get_action_strength(action) > 0.1:
			abort()
			return
	if target_body == null or not is_instance_valid(target_body):
		abort("target lost")
		return
	# Climbed out of the shell (or never should have been here): stand down.
	if _system.landable_body_at(OriginShift.to_true(_ship.global_position)) != target_body:
		abort("left the gravity shell")
		return
	if float(_ship.get("fuel_remaining")) <= 0.0:
		abort("fuel exhausted")  # Track HZ owns the fall from here
		return
	_fly()


func _fly() -> void:
	var centre: Vector3 = target_body.global_position
	var up: Vector3 = (_ship.global_position - centre).normalized()
	var r: float = (_ship.global_position - centre).length()
	var radius: float = target_body.def.radius
	var alt: float = r - radius

	# Local gravity and available acceleration on the vertical axis (the
	# belly jets carry the main budget inside shells — LD3).
	var g: float = target_body.def.surface_gravity * (radius * radius) / (r * r)
	var a_up: float = float(_ship.get("thrust_main")) / _ship.mass
	var a_brake: float = maxf(a_up - g, 0.3)

	var ground_v: Vector3 = LandingComputer.surface_point_velocity(
		target_body, _ship.global_position)
	var v_rel: Vector3 = _ship.linear_velocity - ground_v
	var v_rad: float = v_rel.dot(up)
	var v_lat: Vector3 = v_rel - up * v_rad

	# Braked descent profile: fast high, flaring to a soft constant under the
	# capture limit for the last metres.
	var v_target: float = -clampf(
		sqrt(2.0 * a_brake * maxf(alt - FLARE_ALTITUDE * 0.4, 0.0)) * PROFILE_MARGIN,
		V_MIN, 60.0)
	if alt < FLARE_ALTITUDE:
		v_target = -FLARE_SPEED

	# Vertical: gravity feed-forward plus profile tracking.
	var a_cmd_up: float = g + (v_target - v_rad) * 1.2
	# Lateral: kill drift against the ground.
	var a_cmd_lat: Vector3 = -v_lat * LATERAL_GAIN
	var accel: Vector3 = up * a_cmd_up + a_cmd_lat
	var force: Vector3 = accel * _ship.mass
	# Respect the hardware: vertical axis has the main budget, lateral the RCS.
	var f_up: float = clampf(force.dot(up),
		-float(_ship.get("thrust_rcs")), float(_ship.get("thrust_main")))
	var f_lat: Vector3 = force - up * force.dot(up)
	var rcs: float = float(_ship.get("thrust_rcs"))
	if f_lat.length() > rcs:
		f_lat = f_lat.normalized() * rcs
	var total: Vector3 = up * f_up + f_lat
	_ship.apply_central_force(total)
	_ship.call("spend_fuel", total.length() * 1.0e-5 * get_physics_process_delta_time())
	# The FX signal: the pilot sees the machine fly (Track FX).
	var basis_t: Basis = _ship.global_basis.transposed()
	_ship.set("fx_thrust_local", basis_t * total)

	# Attitude: torque the belly toward the ground (ship +Y along local up),
	# critically damped, and null the spin the capture would refuse.
	var ship_up: Vector3 = _ship.global_basis.y
	var axis: Vector3 = ship_up.cross(up)
	var torque: Vector3 = axis * UPRIGHT_GAIN - _ship.angular_velocity * UPRIGHT_DAMP * 0.001
	_ship.apply_torque(torque)
	_ship.set("fx_torque_local", basis_t * torque)


## HUD line.
func status_line() -> String:
	if not active:
		return ""
	return "AUTOLAND — %s" % (target_body.nav_display_name() if target_body else "")
