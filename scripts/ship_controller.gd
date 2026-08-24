extends RigidBody3D
## Ship controller — Newtonian 6DOF flight model.
##
## All force application in `_physics_process` so behavior is tick-rate
## independent. No velocity clamps, no drag: velocity persists exactly.

# --- Thrust (Newtons) ---
@export var thrust_main: float = 48000.0       # forward
@export var thrust_rcs: float = 15000.0        # lateral / vertical / reverse

# --- Rotation ---
@export var max_torque: float = 20000.0        # N·m per axis
@export var mouse_torque_sensitivity: float = 1500.0  # tuned so brisk sweep saturates clamp
@export var roll_torque_scale: float = 1.0

# --- Flight assist gains ---
# assist_gain defaults to mass * 2.0 in _ready; tunable via export for feel pass.
@export var assist_gain_override: float = -1.0
@export var assist_angular_gain: float = 40000.0

# --- Fuel ---
@export var fuel_capacity: float = 1_000_000.0
@export var fuel_consumption_per_newton_second: float = 1.0e-5
var fuel_remaining: float

signal fuel_changed(remaining: float, capacity: float)

# Mouse-look accumulator: collected in _input, consumed in _physics_process.
var _mouse_delta_accum: Vector2 = Vector2.ZERO
var _assist_gain: float = 0.0

## Set by GameWorld. Lets flight assist hold station relative to whatever body
## the ship is near, instead of relative to the Sun.
var system: SolarSystem = null

## Commanded thrust and torque this physics tick, ship-local, in N / N·m —
## the FX drive signal (Track FX). Written where forces are applied, so the
## flight-assist counter-burns show up too (they are real thruster firings);
## the autopilot writes its own cruise burn here while it owns the hull.
var fx_thrust_local: Vector3 = Vector3.ZERO
var fx_torque_local: Vector3 = Vector3.ZERO

## The EVA suit. Held here rather than in the tree while the player is aboard —
## see the note at the top of eva_controller.gd for why nesting it under this
## body is not an option. Never freed, so the reference stays valid.
var character: Node = null


func _ready() -> void:
	# Floating origin moves this node's render position; velocities are untouched.
	add_to_group(OriginShift.SHIFTABLE_GROUP)
	# Ensure Newtonian defaults regardless of scene overrides.
	linear_damp = 0.0
	angular_damp = 0.0
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	can_sleep = false
	# Touchdown capture and rock latching both read current contacts (LD2/LD4).
	contact_monitor = true
	max_contacts_reported = 8
	fuel_remaining = fuel_capacity
	_assist_gain = assist_gain_override if assist_gain_override > 0.0 else mass * 2.0
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	fuel_changed.emit(fuel_remaining, fuel_capacity)


func _unhandled_input(event: InputEvent) -> void:
	if GameState.autopilot_active:
		# The autopilot owns the ship; it handles its own override input.
		return
	if event is InputEventMouseMotion and GameState.input_mode == GameState.InputMode.SHIP_FLIGHT:
		_mouse_delta_accum += (event as InputEventMouseMotion).relative
	if event.is_action_pressed("toggle_flight_assist"):
		GameState.toggle_flight_assist()
	if event.is_action_pressed("interact") and GameState.input_mode == GameState.InputMode.SHIP_FLIGHT:
		# Interact priority while docked: undock beats EVA-exit.
		if GameState.docked:
			var dc := get_node_or_null("DockingComputer") as DockingComputer
			if dc:
				dc.undock()
		elif character and character.has_method("request_exit"):
			character.request_exit()
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	# Gravity applies whenever the hull is live in the space — including while
	# the pilot is outside on EVA: a ship parked inside a gravity shell falls,
	# which is the shell being honest, not a bug (LD3).
	var gravity := _gravity_accel()
	if gravity != Vector3.ZERO and not freeze:
		apply_central_force(gravity * mass)

	# Docked counts as hands-off: the hull is frozen at the port and thrust
	# would fight the freeze anyway. Landed likewise; LandingComputer owns the
	# takeoff input while the hull is glued to the ground.
	if (
		GameState.input_mode != GameState.InputMode.SHIP_FLIGHT
		or GameState.autopilot_active
		or GameState.docked
		or GameState.landed
	):
		_mouse_delta_accum = Vector2.ZERO
		# The autopilot owns the FX signal during a transfer; everything else
		# hands-off means engines cold.
		if not GameState.autopilot_active:
			fx_thrust_local = Vector3.ZERO
			fx_torque_local = Vector3.ZERO
		return

	# --- Local-space translation input as a per-axis command in [-1, 1] ---
	# Ship convention: -Z forward (Godot default), +X right, +Y up.
	var input_local := Vector3(
		Input.get_action_strength("thrust_right") - Input.get_action_strength("thrust_left"),
		Input.get_action_strength("thrust_up") - Input.get_action_strength("thrust_down"),
		Input.get_action_strength("thrust_back") - Input.get_action_strength("thrust_forward"),
	)

	# Per-axis max thrust (main for forward, rcs for everything else).
	var max_axis := Vector3(thrust_rcs, thrust_rcs, thrust_rcs)
	if input_local.z < 0.0:
		max_axis.z = thrust_main  # forward burn uses main engine
	# Belly landing jets (LD3): inside a gravity shell the vertical axis gets
	# the main-engine budget. 15 kN of RCS against a 12 t hull is 1.25 m/s² —
	# less than Earth's 2.45, so without this no upright hover, no braked
	# descent, and no landing exists at all. Deep-space RCS feel is untouched;
	# the jets light only where there is a surface to land on.
	# ...but only where the RCS genuinely cannot fight the well (LD7): on a
	# minor body (g ≤ 0.3) or the Moon (0.4) the 1.25 m/s² RCS hovers fine,
	# and landing stays the everyday lateral-thruster act it should be.
	if gravity.length() > 1.0:
		max_axis.y = thrust_main

	var thrust_local := Vector3(
		input_local.x * max_axis.x,
		input_local.y * max_axis.y,
		input_local.z * max_axis.z,
	)

	# --- Flight assist (translation) ---
	# For each axis with no player input, apply counter-force to null local
	# velocity — measured against the local reference frame, not the Sun. Parked
	# beside Europa you want to stay beside Europa, and Europa is moving.
	if GameState.flight_assist_enabled and fuel_remaining > 0.0:
		var v_local: Vector3 = global_basis.transposed() * (linear_velocity - reference_velocity())
		# Gravity feed-forward (LD3): inside a shell, holding station means
		# thrusting against the pull, not reacting to the sag it causes. The
		# per-axis clamp is what keeps this honest — a craft whose thrust can't
		# beat local gravity still falls (the suit on Earth, by design).
		var g_local: Vector3 = global_basis.transposed() * gravity
		for axis in 3:
			if is_zero_approx(input_local[axis]):
				var counter: float = -v_local[axis] * _assist_gain - g_local[axis] * mass
				counter = clampf(counter, -max_axis[axis], max_axis[axis])
				thrust_local[axis] += counter

	# --- Apply translation force in world space ---
	if fuel_remaining <= 0.0:
		thrust_local = Vector3.ZERO
	fx_thrust_local = thrust_local
	var thrust_world: Vector3 = global_basis * thrust_local
	if thrust_world != Vector3.ZERO:
		apply_central_force(thrust_world)
		_consume_fuel(thrust_world.length(), delta)

	# --- Rotation: mouse-driven torque, cleared every tick ---
	var mouse_delta := _mouse_delta_accum
	_mouse_delta_accum = Vector2.ZERO

	# Pitch from mouse.y (positive down = nose up? invert to feel right).
	# In local frame: +X torque = pitch up, +Y = yaw left, +Z = roll left.
	var roll_input: float = Input.get_action_strength("roll_left") - Input.get_action_strength("roll_right")
	var torque_local := Vector3(
		clampf(-mouse_delta.y * mouse_torque_sensitivity, -max_torque, max_torque),
		clampf(-mouse_delta.x * mouse_torque_sensitivity, -max_torque, max_torque),
		clampf(roll_input * max_torque * roll_torque_scale, -max_torque, max_torque),
	)

	var rotation_active := Vector3(
		absf(mouse_delta.y) > 0.0,
		absf(mouse_delta.x) > 0.0,
		absf(roll_input) > 0.0,
	)

	# --- Flight assist (rotation) ---
	if GameState.flight_assist_enabled and fuel_remaining > 0.0:
		var w_local: Vector3 = global_basis.transposed() * angular_velocity
		for axis in 3:
			if is_zero_approx(rotation_active[axis]):
				var counter: float = -w_local[axis] * assist_angular_gain
				counter = clampf(counter, -max_torque, max_torque)
				torque_local[axis] += counter

	if fuel_remaining <= 0.0:
		torque_local = Vector3.ZERO
	fx_torque_local = torque_local
	var torque_world: Vector3 = global_basis * torque_local
	if torque_world != Vector3.ZERO:
		apply_torque(torque_world)
		_consume_fuel(torque_world.length() * 0.01, delta)


func _consume_fuel(force_magnitude: float, delta: float) -> void:
	spend_fuel(force_magnitude * fuel_consumption_per_newton_second * delta)


## Deduct fuel directly. Used by the autopilot's cruise drive, which bills in
## delta-v rather than newton-seconds.
func spend_fuel(amount: float) -> void:
	if amount <= 0.0:
		return
	fuel_remaining = maxf(0.0, fuel_remaining - amount)
	fuel_changed.emit(fuel_remaining, fuel_capacity)


## Top the tank up. Station services while docked — instant for now, same as
## the EVA refill on boarding.
func refill_fuel() -> void:
	fuel_remaining = fuel_capacity
	fuel_changed.emit(fuel_remaining, fuel_capacity)


func _notification(what: int) -> void:
	# A stowed suit has no parent, so nothing else will free it. This must be
	# PREDELETE, not _exit_tree: docking and landing REPARENT the hull (port /
	# planet surface), and a reparent passes through _exit_tree — which was
	# silently destroying the stowed suit on every capture, killing EVA for
	# the rest of the session. Found when the landed-groundside screenshot
	# asked the freshly landed ship for its character and got null.
	if what == NOTIFICATION_PREDELETE:
		if character and is_instance_valid(character) and (character as Node).get_parent() == null:
			(character as Node).free()
			character = null


## Take the EVA suit out of the tree and hold it. Called once at bootstrap; the
## suit calls back into here whenever the player boards.
func stow_character() -> void:
	if character == null:
		character = get_node_or_null("Character")
	if character and character.has_method("stow"):
		character.stow()


## Local gravitational acceleration (LD3) — zero outside every surface shell.
func _gravity_accel() -> Vector3:
	if system == null:
		return Vector3.ZERO
	return system.gravity_at(OriginShift.to_true(global_position))


## Velocity of the reference frame flight assist should hold station in: the
## nearby body's orbital velocity, or zero out in open space.
func reference_velocity() -> Vector3:
	if system == null:
		return Vector3.ZERO
	return system.reference_velocity(OriginShift.to_true(global_position))


## Velocity relative to the local reference frame — what the HUD should show,
## since "12 m/s" only means something if you know what it is relative to.
func relative_velocity() -> Vector3:
	return linear_velocity - reference_velocity()
