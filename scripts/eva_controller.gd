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
## The free-flight world container, captured at bootstrap. request_exit must
## NEVER use the ship's current parent: a docked ship hangs under its port and
## a landed one under the planet surface — both rail-driven, and a live body
## added there enters the write-back fight (measured: 193 km of suit drift in
## three frames when exiting on the ground).
var _world_container: Node = null

signal boarded
signal exited

# --- Latching (LD2/LD4) ---
## Boot clamps: on a SpaceRock this is a locked joint (the suit rides the
## tumble). Push off a rock by holding translation thrust.
var clamped_rock: SpaceRock = null
var _rock_joint: Generic6DOFJoint3D = null
var _push_hold: float = 0.0

# --- Surface walking (LD6) ---
## On a planet the grounded state is a WALK SIMULATION, not a static clamp:
## the suit is frozen out of the physics space and parented under the
## spinning PlanetSurface (the landed-frame pattern — the only stable way to
## stand on ground that moves at 131 m/s), and this controller integrates
## run/jump/gravity in the surface's LOCAL frame. Fictitious forces of the
## rotating frame are ~0.03 m/s² at these spin rates — two orders under any
## g0 — so local ballistics are honest. Entering is automatic on touching a
## landable body's ground; leaving is the jetpack (hold SPACE), which only
## wins where suit thrust beats local gravity: you can jump off the Moon,
## but on Earth once you are down, you walk.
@export var run_speed: float = 4.0
@export var run_accel: float = 16.0
@export var jump_speed: float = 2.2
@export var walk_stand_height: float = 0.95
var clamped_body: CelestialBody = null
var _clamp_parent: Node = null
var _walk_vel: Vector3 = Vector3.ZERO      # surface-local frame
var _walk_fwd: Vector3 = Vector3.FORWARD   # surface-local frame
var _walk_airborne: bool = false
var _walk_cooldown: float = 0.0
var _walk_sampler = null
var _walk_sampler_age: int = 0

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
		_world_container = _ship.get_parent()
		_cargo_bay = _ship.get_node_or_null("CargoBay") as Area3D
		_exit_point = _ship.get_node_or_null("ExitPoint") as Marker3D
		if _cargo_bay:
			_cargo_bay.body_entered.connect(_on_cargo_entered)
			_cargo_bay.body_exited.connect(_on_cargo_exited)


func _unhandled_input(event: InputEvent) -> void:
	if GameState.input_mode == GameState.InputMode.EVA:
		if event is InputEventMouseMotion:
			_mouse_delta_accum += (event as InputEventMouseMotion).relative
		if event.is_action_pressed("interact") and (_in_cargo_bay or _walk_near_bay()):
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

	# On the ground: the walk simulation owns the frame (LD6).
	if clamped_body != null:
		_walk(delta)
		return

	# Gravity (LD3): the suit falls inside a shell like everything else live.
	var gravity := _gravity_accel()
	if gravity != Vector3.ZERO and not freeze:
		apply_central_force(gravity * mass)

	# Approaching a landable body's ground while slow enters the walk (LD6).
	# By PROXIMITY, not contact: the skim colliders teleport with the surface
	# every frame, and a live suit that actually touches them is solver-kicked
	# at ~20 m/s before a contact ever reports (trap #9). The walk captures
	# the suit just above the ground and owns it from there; a short cooldown
	# keeps a jetpack departure from being instantly recaptured.
	_walk_cooldown = maxf(_walk_cooldown - delta, 0.0)
	if _walk_cooldown <= 0.0 and not freeze and clamped_rock == null:
		var system = _ship.get("system") if _ship else null
		var ground: CelestialBody = null
		if system != null:
			ground = system.landable_body_at(OriginShift.to_true(global_position))
		if ground != null:
			var v_rel: Vector3 = linear_velocity \
				- LandingComputer.surface_point_velocity(ground, global_position)
			if v_rel.length() < 4.0 and _altitude_above_terrain(ground) < walk_stand_height + 0.4:
				_enter_walk(ground)
				return

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
	# Place the suit into the WORLD at the hatch — see _world_container: the
	# ship's own parent is a rail-driven node while docked or landed.
	var world := _world_container
	if world == null or not is_instance_valid(world):
		world = _ship.get_parent()
	if world == null:
		return
	var exit_xform: Transform3D = _exit_point.global_transform
	# Landed hulls sit belly-on-terrain: a hatch position can clip the relief,
	# and a live body spawned inside the ground gets solver-ejected at
	# hundreds of m/s (measured 255 m/s). Lift the exit along local up.
	if GameState.landed:
		var landing := _ship.get_node_or_null("LandingComputer")
		if landing != null and landing.get("landed_body") != null:
			var body_up: Vector3 = (_ship.global_position
				- (landing.get("landed_body") as Node3D).global_position).normalized()
			exit_xform.origin += body_up * 2.0
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
	if not _in_cargo_bay and not _walk_near_bay():
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


# --- Boot clamps (LD2) ---

## Latch to a touched SpaceRock: a locked joint, ride the tumble. (Planet
## ground needs no latch — touching it enters the walk automatically.)
func try_latch() -> void:
	for body in get_colliding_bodies():
		var rock := body as SpaceRock
		if rock != null and not rock.asleep:
			if (linear_velocity - rock.linear_velocity).length() <= 1.0:
				_rock_joint = LatchComputer.make_lock_joint(self, rock)
				clamped_rock = rock
				_push_hold = 0.0
			return


func release_rock() -> void:
	if _rock_joint != null:
		_rock_joint.queue_free()
		_rock_joint = null
	clamped_rock = null
	_push_hold = 0.0


# --- Surface walking (LD6) ---

## Height of the suit's origin above the terrain along local up — raycast
## against the skim colliders where they exist, cooked heights elsewhere.
func _altitude_above_terrain(body: CelestialBody) -> float:
	var up_w: Vector3 = (global_position - body.global_position).normalized()
	var from: Vector3 = global_position + up_w * 1.0
	var q := PhysicsRayQueryParameters3D.create(from, from - up_w * 40.0)
	var exclude: Array = [get_rid()]
	if _ship:
		exclude.append(_ship.get_rid())
	q.exclude = exclude
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		return (global_position - hit.position).dot(up_w)
	var surface = body.planet_surface()
	if surface == null:
		return INF
	_walk_sampler_age += 1
	if _walk_sampler == null or _walk_sampler_age > 300:
		_walk_sampler = surface.surface_res.make_sampler()
		_walk_sampler_age = 0
	var local_dir: Vector3 = (surface as Node3D).to_local(global_position).normalized()
	var ground_r: float = body.def.radius * (1.0 + _walk_sampler.height(local_dir))
	return (global_position - body.global_position).length() - ground_r


## Public entry for harnesses and future systems: start walking on `body`
## from the suit's current pose.
func enter_walk_on(body: CelestialBody) -> void:
	if clamped_body == null:
		_enter_walk(body)


func _enter_walk(body: CelestialBody) -> void:
	_clamp_parent = LandingComputer.clamp_to_surface(self, body)
	clamped_body = body
	# Seed the walk state from the arrival pose, in the surface-local frame.
	var up: Vector3 = transform.origin.normalized()
	_walk_fwd = -transform.basis.z
	_walk_fwd = (_walk_fwd - up * _walk_fwd.dot(up)).normalized()
	if not _walk_fwd.is_finite() or _walk_fwd.length() < 0.5:
		_walk_fwd = up.cross(Vector3.RIGHT).normalized()
	_walk_vel = Vector3.ZERO
	_walk_airborne = true  # settle onto the ground over the first frames
	_walk_sampler = null
	_walk_sampler_age = 999


## Leave the walk into free flight, carrying the local velocity into world
## space on top of the moving ground's velocity (which release hands off).
func _exit_walk() -> void:
	if clamped_body == null:
		return
	var surface: Node3D = get_parent()
	var vel_world: Vector3 = surface.global_transform.basis * _walk_vel
	var body := clamped_body
	LandingComputer.release_from_surface(self, body, _clamp_parent)
	linear_velocity += vel_world
	clamped_body = null
	_walk_cooldown = 0.6


## One tick of the surface-local walk: run, jump, per-body gravity, terrain
## height tracking. Positions and velocities live in the surface's LOCAL
## (co-rotating) frame; the tree converts to world for rendering. Fictitious
## forces of the rotating frame are ~0.03 m/s² here — ignored on purpose.
func _walk(delta: float) -> void:
	var surface: Node3D = get_parent()
	if surface == null or clamped_body == null:
		return
	var pos: Vector3 = transform.origin
	var up: Vector3 = pos.normalized()
	var body_radius: float = clamped_body.def.radius
	var g: float = clamped_body.def.surface_gravity \
		* (body_radius * body_radius) / maxf(pos.length_squared(), 1.0)

	# Yaw from the mouse; the suit stays upright against local up.
	var mouse := _mouse_delta_accum
	_mouse_delta_accum = Vector2.ZERO
	_walk_fwd = (_walk_fwd - up * _walk_fwd.dot(up)).normalized()
	_walk_fwd = _walk_fwd.rotated(up, -mouse.x * 0.003)
	var right: Vector3 = _walk_fwd.cross(up)

	var move: Vector3 = _walk_fwd * (Input.get_action_strength("thrust_forward")
		- Input.get_action_strength("thrust_back")) \
		+ right * (Input.get_action_strength("thrust_left")
		- Input.get_action_strength("thrust_right"))
	if move.length() > 1.0:
		move = move.normalized()

	var v_rad: float = _walk_vel.dot(up)
	var v_tan: Vector3 = _walk_vel - up * v_rad

	if not _walk_airborne:
		# Grounded: velocity chases the commanded run; SPACE jumps.
		v_tan = v_tan.move_toward(move * run_speed, run_accel * delta)
		if Input.is_action_pressed("thrust_up"):
			v_rad = jump_speed
			_walk_airborne = true
	else:
		# Airborne: ballistic under local gravity. Holding SPACE burns the
		# jetpack straight up — it only out-climbs g where thrust beats it,
		# so the Moon lets go and Earth does not.
		v_rad -= g * delta
		if Input.is_action_pressed("thrust_up") and fuel.remaining > 0.0:
			v_rad += (thrust_translation / mass) * delta
			fuel.consume(thrust_translation, delta)

	_walk_vel = v_tan + up * v_rad
	pos += _walk_vel * delta

	# Terrain under the boots — collider truth near the ship, cooked-height
	# truth anywhere else on the planet.
	var stand_r: float = _walk_ground_radius(pos.normalized()) + walk_stand_height
	var r: float = pos.length()
	if r <= stand_r and v_rad <= 0.0:
		pos = pos.normalized() * stand_r
		_walk_vel -= up * v_rad
		_walk_airborne = false
	elif r > stand_r + 0.05:
		_walk_airborne = true

	# Jetpack departure: clearly climbing and clear of the ground → free EVA.
	# The bar sits above the highest jump+thrust hop Earth allows (5.4 m at
	# TWR 0.8), so on Earth the walk keeps you and the hop comes back down;
	# the Moon's net +1.6 m/s² blows through it and lets go.
	if _walk_airborne and v_rad > 1.0 and r > stand_r + 6.0:
		transform.origin = pos
		_exit_walk()
		return

	transform = Transform3D(Basis.looking_at(_walk_fwd, pos.normalized()), pos)


## Ground radius under a surface-local direction: raycast against the skim
## colliders (exact near the ship), cooked height sampler beyond their range.
func _walk_ground_radius(local_dir: Vector3) -> float:
	var surface: Node3D = get_parent()
	var w_up: Vector3 = (global_position - clamped_body.global_position).normalized()
	var from: Vector3 = global_position + w_up * 3.0
	var q := PhysicsRayQueryParameters3D.create(from, from - w_up * 20.0)
	var exclude: Array = [get_rid()]
	if _ship:
		exclude.append(_ship.get_rid())
	q.exclude = exclude
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		return (surface.to_local(hit.position)).length()
	_walk_sampler_age += 1
	if _walk_sampler == null or _walk_sampler_age > 300:
		var ps = clamped_body.planet_surface()
		if ps != null and ps.get("surface_res") != null:
			_walk_sampler = ps.surface_res.make_sampler()
			_walk_sampler_age = 0
	if _walk_sampler != null:
		return clamped_body.def.radius * (1.0 + _walk_sampler.height(local_dir))
	return clamped_body.def.radius


## Near enough to the cargo bay to board on foot — the Area3D can't see a
## walking suit (it is out of the physics space), so boarding goes by hand.
func _walk_near_bay() -> bool:
	return (
		clamped_body != null and _cargo_bay != null
		and _cargo_bay.global_position.distance_to(global_position) < 3.5
	)


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
	return (
		(_in_cargo_bay or _walk_near_bay())
		and GameState.input_mode == GameState.InputMode.EVA
	)
