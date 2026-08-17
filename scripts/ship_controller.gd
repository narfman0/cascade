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
		if character and character.has_method("request_exit"):
			character.request_exit()
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if GameState.input_mode != GameState.InputMode.SHIP_FLIGHT or GameState.autopilot_active:
		_mouse_delta_accum = Vector2.ZERO
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
		for axis in 3:
			if is_zero_approx(input_local[axis]):
				var counter: float = -v_local[axis] * _assist_gain
				counter = clampf(counter, -max_axis[axis], max_axis[axis])
				thrust_local[axis] += counter

	# --- Apply translation force in world space ---
	if fuel_remaining <= 0.0:
		thrust_local = Vector3.ZERO
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


func _exit_tree() -> void:
	# A stowed suit has no parent, so nothing else will free it.
	if character and (character as Node).get_parent() == null:
		(character as Node).queue_free()
		character = null


## Take the EVA suit out of the tree and hold it. Called once at bootstrap; the
## suit calls back into here whenever the player boards.
func stow_character() -> void:
	if character == null:
		character = get_node_or_null("Character")
	if character and character.has_method("stow"):
		character.stow()


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
