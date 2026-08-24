class_name HazardMonitor extends Node
## Gravity-well hazard: warning, failure, restart (Track HZ).
##
## Two beats. A WARNING while the well is still winnable — escape margin is
## the ship's best acceleration minus local gravity, and the point of no
## return is computed arithmetic (r where g(r) = a_max), never authored.
## And a FAILURE when the hull crosses a kill boundary — the atmosphere
## interface at excessive speed on a landable body, the cloud deck of a gas
## giant, the Sun's corona — followed by a restart from the last safe-state
## checkpoint, restored through the autopilot's release pattern.
##
## The tone rule: the warning is INFORMATIVE, never a klaxon. Every failure
## was preceded by the warning beat, and the physics were winnable at
## CAUTION. Dying is possible; dying unfairly is not.
##
## AudioManager hooks: note_event on each band change and at hull loss —
## no audio assets yet, the M2 convention.

enum Band { CLEAR, CAUTION, WARNING, NO_RETURN }

## Margin thresholds, m/s² of spare acceleration against local gravity.
const CAUTION_MARGIN: float = 1.5
const WARNING_MARGIN: float = 0.5

## Entry interface speed on atmosphere-bearing landable bodies: slower than
## this through the atmosphere shell is a descent, faster is an entry burn.
## Landings cross at ~1.5 m/s; orbital velocity here is ~130 m/s.
const ENTRY_BURN_SPEED: float = 80.0

## Kill radius for bodies with no solid surface, in radii: the cloud deck.
const CLOUD_DECK: float = 1.05
## The Sun burns from farther out.
const CORONA: float = 1.5

## Seconds between checkpoint attempts, and the stability window required.
const CHECKPOINT_INTERVAL: float = 5.0
const SAFE_SPEED: float = 5.0

signal band_changed(band: int, body_name: String, margin: float)
signal hull_lost(reason: String)
signal restored

var band: int = Band.CLEAR
var band_body: CelestialBody = null
var escape_margin: float = INF
## True while the loss presentation runs; flight input stands down.
var failing: bool = false

var _ship: RigidBody3D
var _system: SolarSystem = null
var _cp_timer: float = 0.0
# Checkpoint: reference-relative, so the restore lands beside the body
# wherever its rails have carried it since. Empty until the first save.
var _cp: Dictionary = {}


func _ready() -> void:
	_ship = get_parent() as RigidBody3D


func setup(system: SolarSystem) -> void:
	_system = system


func _physics_process(delta: float) -> void:
	if _ship == null or _system == null or failing:
		return
	var true_pos: Array = OriginShift.to_true(_ship.global_position)
	var body := _system.shell_body_at(true_pos)
	_update_band(body)
	if body != null and _check_kill(body):
		return
	_maybe_checkpoint(delta, body)


## --- Warning beat -------------------------------------------------------------

func _update_band(body: CelestialBody) -> void:
	var new_band: int = Band.CLEAR
	escape_margin = INF
	band_body = body
	if body != null:
		var r: float = _radial_distance(body)
		var g: float = body.def.surface_gravity \
			* (body.def.radius * body.def.radius) / maxf(r * r, 1.0)
		escape_margin = _max_accel() - g
		if escape_margin <= 0.0:
			new_band = Band.NO_RETURN
		elif escape_margin < WARNING_MARGIN:
			new_band = Band.WARNING
		elif escape_margin < CAUTION_MARGIN:
			new_band = Band.CAUTION
	if new_band != band:
		band = new_band
		band_changed.emit(band, body.nav_display_name() if body else "", escape_margin)
		AudioManager.note_event(&"hazard_band_%d" % band)


## Best acceleration the ship can currently muster, fuel folded in. The main
## engine is the escape engine (belly jets carry its budget inside shells).
func _max_accel() -> float:
	if float(_ship.get("fuel_remaining")) <= 0.0:
		return 0.0
	return float(_ship.get("thrust_main")) / _ship.mass


## Radius below which escape from `body` is arithmetically impossible for the
## current ship — g(r) = a_max, solved for r. INF spare means 0.
func no_return_radius(body: CelestialBody) -> float:
	var a: float = _max_accel()
	if a <= 0.0:
		return body.def.radius * SolarSystem.GRAVITY_SHELL_TOP
	var g0: float = body.def.surface_gravity
	if g0 <= a:
		return 0.0
	return body.def.radius * sqrt(g0 / a)


## --- Failure beat -------------------------------------------------------------

func _check_kill(body: CelestialBody) -> bool:
	# The landed/docked hull is parked, not falling.
	if GameState.landed or GameState.docked:
		return false
	var r: float = _radial_distance(body)
	var radius: float = body.def.radius
	if not body.def.has_solid_surface:
		var deck: float = CORONA if body.def.id == &"sun" else CLOUD_DECK
		if r < radius * deck:
			_fail("lost in the %s of %s" % [
				"corona" if body.def.id == &"sun" else "cloud deck",
				body.nav_display_name()])
			return true
		return false
	if body.def.atmosphere != null:
		var interface: float = radius * (1.0 + body.def.atmosphere.height_fraction)
		if r < interface:
			var v_rel: float = (_ship.linear_velocity
				- LandingComputer.surface_point_velocity(body, _ship.global_position)).length()
			if v_rel > ENTRY_BURN_SPEED:
				_fail("atmospheric entry burn at %s" % body.nav_display_name())
				return true
	return false


func _fail(reason: String) -> void:
	failing = true
	AudioManager.note_event(&"hull_lost")
	hull_lost.emit(reason)
	# Presentation runs in the HUD off the signal; physics restore follows
	# after a short beat so the loss is legible.
	var timer := get_tree().create_timer(2.5)
	timer.timeout.connect(_restore)


## --- Checkpoint ---------------------------------------------------------------

func _maybe_checkpoint(delta: float, shell_body: CelestialBody) -> void:
	_cp_timer -= delta
	if _cp_timer > 0.0:
		return
	_cp_timer = CHECKPOINT_INTERVAL
	# Landed and docked are safe by construction.
	if GameState.landed or GameState.docked:
		_snapshot()
		return
	# Flying: stable, in open space (outside every shell), not warping,
	# autopilot idle, and slow against the local frame.
	if shell_body != null or GameState.autopilot_active or SimClock.warp > 1.01:
		return
	if _ship.freeze:
		return
	var v_rel: Vector3 = _ship.linear_velocity - _ship.call("reference_velocity")
	if v_rel.length() > SAFE_SPEED:
		return
	_snapshot()


func _snapshot() -> void:
	var true_pos: Array = OriginShift.to_true(_ship.global_position)
	var cp: Dictionary = {
		"fuel": float(_ship.get("fuel_remaining")),
		"landed": GameState.landed,
		"docked": GameState.docked,
	}
	# Reference-relative: the world keeps moving between loss and restore.
	var ref := _system.reference_body(true_pos)
	if ref != null:
		cp["ref_id"] = ref.nav_display_name()
		cp["ref"] = ref
		cp["offset"] = [
			true_pos[0] - ref.true_pos[0],
			true_pos[1] - ref.true_pos[1],
			true_pos[2] - ref.true_pos[2],
		]
		var rv: Array = ref.velocity_at(SimClock.sim_time)
		cp["vel_rel"] = _ship.linear_velocity - Vector3(
			float(rv[0]), float(rv[1]), float(rv[2]))
	else:
		cp["abs"] = true_pos
		cp["vel_rel"] = _ship.linear_velocity
	_cp = cp


func has_checkpoint() -> bool:
	return not _cp.is_empty()


func _restore() -> void:
	if _cp.is_empty():
		# No checkpoint yet (failure seconds after spawn): fall back to the
		# spawn placement by reloading the scene — blunt but correct.
		get_tree().reload_current_scene()
		return
	# Stand every ownership state down first.
	var autopilot := _ship.get_node_or_null("Autopilot") as Autopilot
	if autopilot and autopilot.phase != Autopilot.Phase.IDLE:
		autopilot.cancel("hull lost")
	if GameState.docked:
		var dc := _ship.get_node_or_null("DockingComputer") as DockingComputer
		if dc:
			dc.undock()
	if GameState.landed:
		var lc := _ship.get_node_or_null("LandingComputer") as LandingComputer
		if lc:
			lc.release()
	if GameState.input_mode == GameState.InputMode.EVA:
		# The mission resets as a whole: the suit comes home with the ship.
		var suit: Node = _ship.get("character")
		if suit and suit.has_method("stow"):
			if suit.get("clamped_rock") != null:
				suit.call("release_rock")
			GameState.input_mode = GameState.InputMode.SHIP_FLIGHT
			suit.call("stow")

	# Where the checkpoint is NOW: the reference body has moved on its rails.
	var target_true: Array
	var target_vel: Vector3
	if _cp.has("ref"):
		var ref = _cp["ref"]
		var off: Array = _cp["offset"]
		target_true = [
			ref.true_pos[0] + off[0], ref.true_pos[1] + off[1], ref.true_pos[2] + off[2]]
		var rv: Array = ref.velocity_at(SimClock.sim_time)
		target_vel = Vector3(float(rv[0]), float(rv[1]), float(rv[2])) + _cp["vel_rel"]
	else:
		target_true = _cp["abs"]
		target_vel = _cp["vel_rel"]

	# The autopilot release pattern: re-centre the origin, place, hand off.
	SimClock.reset_warp()
	OriginShift.shift_to(target_true)
	_ship.freeze = false
	_ship.global_position = OriginShift.to_render(target_true)
	_ship.linear_velocity = target_vel
	_ship.angular_velocity = Vector3.ZERO
	_ship.set("fuel_remaining", _cp["fuel"])
	_ship.emit_signal("fuel_changed", _cp["fuel"], _ship.get("fuel_capacity"))
	GameState.flight_assist_enabled = true
	_system.refresh()
	failing = false
	restored.emit()
	AudioManager.note_event(&"hazard_restored")


func _radial_distance(body: CelestialBody) -> float:
	var tp: Array = OriginShift.to_true(_ship.global_position)
	var dx: float = tp[0] - body.true_pos[0]
	var dy: float = tp[1] - body.true_pos[1]
	var dz: float = tp[2] - body.true_pos[2]
	return sqrt(dx * dx + dy * dy + dz * dz)
