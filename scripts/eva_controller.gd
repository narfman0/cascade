extends RigidBody3D
## EVA controller — same 6DOF Newtonian model as the ship, MMU-scale.
##
## Active only when GameState.input_mode == EVA. All force in _physics_process
## for tick-rate independence. No damping, no clamps.
##
## IMPORTANT — why this node leaves the tree while aboard:
## Godot does not support a RigidBody3D parented under another RigidBody3D. Both
## bodies exist independently in the physics space, so the server keeps writing
## the child's global transform while the node tree keeps re-deriving its local
## transform from the moving parent. The two fight, the child's local position
## diverges without bound, and it drags the parent's reported transform with it —
## which, with a floating origin watching the ship's distance from the render
## origin, showed up as the whole world lurching sixteen kilometres every other
## frame. `freeze` does not help: a frozen body is still in the space.
##
## So while the player is aboard, the suit is removed from the scene tree
## entirely and held by the ship controller. It re-enters the tree under
## GameWorld on EVA. Group membership (origin_shiftable) follows the tree, so a
## stowed suit is correctly ignored by floating-origin shifts.

const EVAThrusterFuel = preload("res://scripts/resources/eva_thruster_fuel.gd")

# --- MMU-scale thrust ---
@export var thrust_translation: float = 300.0   # N per axis
@export var max_torque: float = 40.0             # N·m per axis
@export var mouse_torque_sensitivity: float = 4.0
@export var roll_torque_scale: float = 1.0

# --- Flight assist (defaults ON for EVA) ---
@export var assist_gain_override: float = -1.0
@export var assist_angular_gain: float = 200.0

# --- Fuel ---
@export var fuel: EVAThrusterFuel

# --- Board/exit ---
@export var ship_path: NodePath
var _ship: RigidBody3D
var _cargo_bay: Area3D
var _exit_point: Marker3D
var _in_cargo_bay: bool = false

signal boarded
signal exited

# --- Latching (LD2/LD4) ---
## Boot clamps: on a SpaceRock this is a locked joint (the suit rides the
## tumble); on a planet surface it is the shared landed-state capture. Push off
## a rock by holding translation thrust; lift off ground by holding thrust_up.
var clamped_rock: SpaceRock = null
var clamped_body: CelestialBody = null
var _rock_joint: Generic6DOFJoint3D = null
var _clamp_parent: Node = null
var _push_hold: float = 0.0

var _mouse_delta_accum: Vector2 = Vector2.ZERO
var _assist_gain: float = 0.0


func _ready() -> void:
	# The suit holds a real render-space position, so it moves with the origin.
	add_to_group(OriginShift.SHIFTABLE_GROUP)
	linear_damp = 0.0
	angular_damp = 0.0
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	can_sleep = false
	# Boot clamps read current contacts (LD2/LD4).
	contact_monitor = true
	max_contacts_reported = 8
	_assist_gain = assist_gain_override if assist_gain_override > 0.0 else mass * 4.0
	if fuel == null:
		fuel = EVAThrusterFuel.new()
	# Fuel refills on entry — start topped up.
	fuel.refill()

	if ship_path != NodePath():
		_ship = get_node(ship_path)
	if _ship == null and get_parent() is RigidBody3D:
		_ship = get_parent()
	if _ship:
		_cargo_bay = _ship.get_node_or_null("CargoBay") as Area3D
		_exit_point = _ship.get_node_or_null("ExitPoint") as Marker3D
		if _cargo_bay:
			_cargo_bay.body_entered.connect(_on_cargo_entered)
			_cargo_bay.body_exited.connect(_on_cargo_exited)


func _unhandled_input(event: InputEvent) -> void:
	if GameState.input_mode == GameState.InputMode.EVA:
		if event is InputEventMouseMotion:
			_mouse_delta_accum += (event as InputEventMouseMotion).relative
		if event.is_action_pressed("interact") and _in_cargo_bay:
			request_board()
		if event.is_action_pressed("latch"):
			if clamped_rock != null:
				release_rock()
			elif clamped_body == null:
				try_latch()


func _physics_process(delta: float) -> void:
	if GameState.input_mode != GameState.InputMode.EVA:
		_mouse_delta_accum = Vector2.ZERO
		return

	# Ground-clamped: frozen out of the space, riding the surface through the
	# tree. Only the lift-off hold is live (thrust_up, deliberate).
	if clamped_body != null:
		if Input.get_action_strength("thrust_up") > 0.5:
			_push_hold += delta
			if _push_hold >= 0.3:
				release_ground()
		else:
			_push_hold = 0.0
		_mouse_delta_accum = Vector2.ZERO
		return

	# Gravity (LD3): the suit falls inside a shell like everything else live.
	var gravity := _gravity_accel()
	if gravity != Vector3.ZERO and not freeze:
		apply_central_force(gravity * mass)

	# Rock-clamped: a sustained shove is the unlatch gesture — the joint drops
	# and the same thrust pushes you off (LD2).
	if clamped_rock != null:
		var shove := Vector3(
			Input.get_action_strength("thrust_right") - Input.get_action_strength("thrust_left"),
			Input.get_action_strength("thrust_up") - Input.get_action_strength("thrust_down"),
			Input.get_action_strength("thrust_back") - Input.get_action_strength("thrust_forward"))
		if shove.length() > 0.7:
			_push_hold += delta
			if _push_hold >= 0.3:
				release_rock()
		else:
			_push_hold = 0.0
		# Bolted on: the locked joint owns the pose, thrusters stand down (and
		# flight assist must not burn fuel fighting the rock's own tumble).
		_mouse_delta_accum = Vector2.ZERO
		return

	var input_local := Vector3(
		Input.get_action_strength("thrust_right") - Input.get_action_strength("thrust_left"),
		Input.get_action_strength("thrust_up") - Input.get_action_strength("thrust_down"),
		Input.get_action_strength("thrust_back") - Input.get_action_strength("thrust_forward"),
	)

	var max_axis := Vector3(thrust_translation, thrust_translation, thrust_translation)
	var thrust_local := Vector3(
		input_local.x * max_axis.x,
		input_local.y * max_axis.y,
		input_local.z * max_axis.z,
	)

	if GameState.flight_assist_enabled and fuel.remaining > 0.0:
		# Station-keeping is measured against the local body, same as the ship.
		# Gravity feed-forward matches the ship too — and the per-axis clamp is
		# the whole point: 2.0 m/s² of suit thrust against Earth's 2.45 still
		# falls. EVA flight is a per-body capability, not a given (LD3).
		var v_local: Vector3 = global_basis.transposed() * relative_velocity()
		var g_local: Vector3 = global_basis.transposed() * gravity
		for axis in 3:
			if is_zero_approx(input_local[axis]):
				var counter: float = -v_local[axis] * _assist_gain - g_local[axis] * mass
				counter = clampf(counter, -max_axis[axis], max_axis[axis])
				thrust_local[axis] += counter

	if fuel.remaining <= 0.0:
		thrust_local = Vector3.ZERO
	var thrust_world: Vector3 = global_basis * thrust_local
	if thrust_world != Vector3.ZERO:
		apply_central_force(thrust_world)
		fuel.consume(thrust_world.length(), delta)

	var mouse_delta := _mouse_delta_accum
	_mouse_delta_accum = Vector2.ZERO
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

	if GameState.flight_assist_enabled and fuel.remaining > 0.0:
		var w_local: Vector3 = global_basis.transposed() * angular_velocity
		for axis in 3:
			if is_zero_approx(rotation_active[axis]):
				var counter: float = -w_local[axis] * assist_angular_gain
				counter = clampf(counter, -max_torque, max_torque)
				torque_local[axis] += counter

	if fuel.remaining <= 0.0:
		torque_local = Vector3.ZERO
	var torque_world: Vector3 = global_basis * torque_local
	if torque_world != Vector3.ZERO:
		apply_torque(torque_world)
		fuel.consume(torque_world.length() * 0.1, delta)


# --- Exit / enter ---

## Take the suit out of the physics space and out of the tree. Called at
## bootstrap and whenever the player boards.
func stow() -> void:
	# Defensive: a clamped suit being stowed must drop its anchors first.
	release_rock()
	if clamped_body != null:
		clamped_body = null  # boarding from clamped never happens; don't hand off
	var cs := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if cs:
		cs.disabled = true
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	var parent := get_parent()
	if parent:
		parent.remove_child(self)


func is_stowed() -> bool:
	return get_parent() == null


func request_exit() -> void:
	if _ship == null or _exit_point == null:
		return
	# Place the suit into the world at the hatch, as an independent body.
	var world := _ship.get_parent()
	if world == null:
		return
	var exit_xform: Transform3D = _exit_point.global_transform
	var ship_lin: Vector3 = _ship.linear_velocity
	var ship_ang: Vector3 = _ship.angular_velocity
	var r: Vector3 = exit_xform.origin - _ship.global_position

	# The suit is normally stowed (out of tree) while aboard; detach first if a
	# caller handed it to us still parented.
	if get_parent() != null:
		get_parent().remove_child(self)
	world.add_child(self)
	global_transform = exit_xform
	freeze = false
	var cs := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if cs:
		cs.disabled = false
	linear_velocity = ship_lin + ship_ang.cross(r)
	angular_velocity = ship_ang

	GameState.input_mode = GameState.InputMode.EVA
	# EVA defaults to FA on per M2.1.
	GameState.flight_assist_enabled = true
	exited.emit()


func request_board() -> void:
	if _ship == null:
		return
	if not _in_cargo_bay:
		return
	# Freeze and disable collision BEFORE leaving the tree, so no contact frame
	# is generated against the hull on the way in.
	stow()
	transform = Transform3D.IDENTITY

	fuel.refill()
	GameState.input_mode = GameState.InputMode.SHIP_FLIGHT
	boarded.emit()


func _on_cargo_entered(body: Node) -> void:
	if body == self:
		_in_cargo_bay = true


func _on_cargo_exited(body: Node) -> void:
	if body == self:
		_in_cargo_bay = false


# --- Boot clamps (LD2/LD4) ---

## Latch to whatever the boots are touching: a SpaceRock gets a locked joint
## (ride the tumble), a landable body gets the shared landed-state capture.
func try_latch() -> void:
	var system = _ship.get("system") if _ship else null
	for body in get_colliding_bodies():
		var rock := body as SpaceRock
		if rock != null and not rock.asleep:
			if (linear_velocity - rock.linear_velocity).length() <= 1.0:
				_rock_joint = LatchComputer.make_lock_joint(self, rock)
				clamped_rock = rock
				_push_hold = 0.0
			return
		# Ground: any collider whose ancestry reaches a landable body.
		if system != null:
			var node: Node = body
			while node != null:
				var cb := node as CelestialBody
				if cb != null and cb.def.surface_gravity > 0.0:
					var v_rel: Vector3 = linear_velocity \
						- LandingComputer.surface_point_velocity(cb, global_position)
					if v_rel.length() <= 2.0:
						_clamp_parent = LandingComputer.clamp_to_surface(self, cb)
						clamped_body = cb
						_push_hold = 0.0
					return
				node = node.get_parent()


func release_rock() -> void:
	if _rock_joint != null:
		_rock_joint.queue_free()
		_rock_joint = null
	clamped_rock = null
	_push_hold = 0.0


func release_ground() -> void:
	if clamped_body == null:
		return
	LandingComputer.release_from_surface(self, clamped_body, _clamp_parent)
	clamped_body = null
	_push_hold = 0.0


## Velocity of the frame the suit should hold station in — inherited from the
## ship's system reference so EVA near Europa parks against Europa.
func reference_velocity() -> Vector3:
	if _ship == null:
		return Vector3.ZERO
	var system = _ship.get("system")
	if system == null:
		return Vector3.ZERO
	return system.reference_velocity(OriginShift.to_true(global_position))


func relative_velocity() -> Vector3:
	return linear_velocity - reference_velocity()


## Local gravitational acceleration (LD3), via the ship's system reference.
func _gravity_accel() -> Vector3:
	if _ship == null:
		return Vector3.ZERO
	var system = _ship.get("system")
	if system == null:
		return Vector3.ZERO
	return system.gravity_at(OriginShift.to_true(global_position))


func can_board() -> bool:
	return _in_cargo_bay and GameState.input_mode == GameState.InputMode.EVA
