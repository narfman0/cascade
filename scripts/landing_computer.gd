class_name LandingComputer extends Node
## Planetary touchdown and the landed state (LD4).
##
## Landed is a state, not a contact: on capture the hull is frozen, taken out
## of the physics space, and parented under the body's PlanetSurface — the
## docking-capture pattern with the spin-driven surface node as the port, so a
## landed ship co-rotates with the surface and survives origin shifts through
## the tree, exactly like NYC does. Takeoff reverses it with the surface
## point's velocity (body frame + spin ω×r) handed off — the EVA-exit pattern.
##
## Capture conditions mirror docking soft-capture: ground contact, surface-
## relative speed under `touchdown_speed_limit`, ship's up within
## `touchdown_tilt_limit_deg` of local up. Anything else bounces.

signal landed(body_name: String)
signal lifted(body_name: String)

@export var touchdown_speed_limit: float = 2.0
@export var touchdown_tilt_limit_deg: float = 25.0
## Hold thrust_up this long to lift off — deliberate, not a bumped key.
@export var takeoff_hold_seconds: float = 0.4
## Separation kick along local up on release — the undock push-off precedent.
## Load-bearing, not flavor: a live hull left resting in contact with the
## skim colliders (which teleport with the spinning surface every frame) is
## eventually thrown by the solver; the kick breaks contact on frame one.
@export var push_off_speed: float = 2.5

var landed_body: CelestialBody = null

var _ship: RigidBody3D
var _system: SolarSystem = null
var _undocked_parent: Node = null
var _takeoff_hold: float = 0.0
# Lift-off leaves the hull in contact at zero relative speed — exactly the
# capture conditions — so capture disarms on release and re-arms only once
# the ground has been clear of contact for a beat (the docking computer's
# _capture_armed pattern wearing dirt-side boots).
var _capture_armed: bool = true
var _clear_frames: int = 0


func _ready() -> void:
	_ship = get_parent() as RigidBody3D


func setup(system: SolarSystem) -> void:
	_system = system


func _physics_process(delta: float) -> void:
	if _ship == null or _system == null:
		return
	if landed_body != null:
		_while_landed(delta)
		return
	if GameState.docked or GameState.autopilot_active or _ship.freeze:
		return
	if GameState.input_mode != GameState.InputMode.SHIP_FLIGHT:
		return
	var body := _system.landable_body_at(OriginShift.to_true(_ship.global_position))
	if body == null:
		_capture_armed = true
		return
	if not _capture_armed:
		_clear_frames = _clear_frames + 1 if not _ground_contact(body) else 0
		if _clear_frames >= 10:
			_capture_armed = true
		return
	_try_capture(body)


func _try_capture(body: CelestialBody) -> void:
	if not _ground_contact(body):
		return
	var v_rel: Vector3 = _ship.linear_velocity - surface_point_velocity(body, _ship.global_position)
	if v_rel.length() > touchdown_speed_limit:
		return
	var local_up: Vector3 = (_ship.global_position - body.global_position).normalized()
	if _ship.global_basis.y.dot(local_up) < cos(deg_to_rad(touchdown_tilt_limit_deg)):
		return
	_capture(body)


## Any current contact whose collider belongs to this body — the skim patches
## (children of PlanetSurface) near the ground, or the analytic sphere farther
## out. Debris and rocks don't count as ground.
func _ground_contact(body: CelestialBody) -> bool:
	for collider in _ship.get_colliding_bodies():
		var node: Node = collider
		while node != null:
			if node == body:
				return true
			node = node.get_parent()
	return false


func _capture(body: CelestialBody) -> void:
	_undocked_parent = clamp_to_surface(_ship, body)
	landed_body = body
	_takeoff_hold = 0.0
	GameState.landed = true
	landed.emit(body.nav_display_name())


func _while_landed(delta: float) -> void:
	# Keep the stored velocity tracking the moving ground so stale readers
	# (HUD, EVA exit) stay honest — the docking computer's precedent.
	_ship.linear_velocity = surface_point_velocity(landed_body, _ship.global_position)
	if GameState.input_mode != GameState.InputMode.SHIP_FLIGHT:
		_takeoff_hold = 0.0
		return
	if Input.get_action_strength("thrust_up") > 0.5:
		_takeoff_hold += delta
		if _takeoff_hold >= takeoff_hold_seconds:
			release()
	else:
		_takeoff_hold = 0.0


## Lift off: mirror of capture, reversed — the reparent re-adds the body to
## the world's physics space, then the moving ground's velocity is handed off.
func release() -> void:
	if landed_body == null:
		return
	var body := landed_body
	release_from_surface(_ship, body, _undocked_parent)
	var local_up: Vector3 = (_ship.global_position - body.global_position).normalized()
	_ship.linear_velocity += local_up * push_off_speed
	landed_body = null
	_capture_armed = false
	_clear_frames = 0
	GameState.landed = false
	GameState.flight_assist_enabled = true
	lifted.emit(body.nav_display_name())


## World velocity of the ground under `pos_render`: the body's orbital velocity
## plus the spin term ω×r. Shared with the EVA ground clamp.
static func surface_point_velocity(body: CelestialBody, pos_render: Vector3) -> Vector3:
	var v: Array = body.velocity_at(SimClock.sim_time)
	var out := Vector3(float(v[0]), float(v[1]), float(v[2]))
	if body.def.spin_period > 0.0:
		var axis := Vector3(
			0.0, cos(body.def.spin_axis_tilt), sin(body.def.spin_axis_tilt)).normalized()
		var omega: Vector3 = axis * (TAU / body.def.spin_period)
		out += omega.cross(pos_render - body.global_position)
	return out


## Shared surface capture for any rigid body — the ship on touchdown, the EVA
## suit's boot clamps. The docking-capture order, load-bearing for the same
## reasons: freeze → leave shiftable → reparent (global preserved) → leave the
## physics space. The caller owns state flags and keeps velocity readers honest.
static func clamp_to_surface(rigid: RigidBody3D, body: CelestialBody) -> Node:
	rigid.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	rigid.freeze = true
	rigid.remove_from_group(OriginShift.SHIFTABLE_GROUP)
	var old_parent: Node = rigid.get_parent()
	var xf: Transform3D = rigid.global_transform
	var port: Node3D = body.planet_surface()
	if port == null:
		port = body
	old_parent.remove_child(rigid)
	port.add_child(rigid)
	rigid.global_transform = xf
	PhysicsServer3D.body_set_space(rigid.get_rid(), RID())
	rigid.linear_velocity = surface_point_velocity(body, rigid.global_position)
	rigid.angular_velocity = Vector3.ZERO
	return old_parent


static func release_from_surface(rigid: RigidBody3D, body: CelestialBody, old_parent: Node) -> void:
	var xf: Transform3D = rigid.global_transform
	rigid.get_parent().remove_child(rigid)
	old_parent.add_child(rigid)
	rigid.global_transform = xf
	rigid.add_to_group(OriginShift.SHIFTABLE_GROUP)
	rigid.freeze = false
	rigid.linear_velocity = surface_point_velocity(body, rigid.global_position)
	rigid.angular_velocity = Vector3.ZERO
