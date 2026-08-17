class_name DockingComputer extends Node
## Ship-side docking logic: soft capture, the docked state, undock.
##
## Docking is a state, not a joint. When the ship meets the capture conditions
## inside a port's volume — slow enough, aligned enough — it is frozen kinematic
## and parented under the port. The station is on analytic rails (a Node3D, not
## a physics body), so the ship inherits every rail recompute and every origin
## shift through the tree from then on. Undock reverses the sequence with a
## small push-off.
##
## The order of operations in `_capture` and `undock` is load-bearing; each
## step's comment says why. Get it wrong and it looks like the 16 km lurch bug.

## Separation speed imparted along the port axis on undock, m/s. Gentle: flight
## assist re-parks the ship a few metres out, which is the calm exit we want.
@export var push_off_speed: float = 1.0

## Metres from the last port before capture re-arms after an undock. Must
## exceed the capture volume's reach, or the push-off (slow, aligned, still in
## the volume) meets the capture conditions on the next tick and snaps back.
@export var rearm_distance: float = 14.0

signal captured(port: DockingPort)
signal released(port: DockingPort)

var docked_port: DockingPort = null

## Port whose capture volume the ship currently occupies, null outside one.
## The HUD approach readout renders from these.
var approach_port: DockingPort = null
var approach_distance: float = 0.0
var approach_speed: float = 0.0
var approach_axis_error_deg: float = 0.0

var _ship: RigidBody3D
var _undocked_parent: Node = null

## See `rearm_distance`. Volume membership cannot be the re-arm signal: the
## undock reparent resets the Area3D overlap for a frame, which reads as an
## exit-and-re-entry.
var _capture_armed: bool = true
var _rearm_port: DockingPort = null


func _ready() -> void:
	_ship = get_parent() as RigidBody3D
	if _ship == null:
		push_error("DockingComputer must be a child of the ship RigidBody3D.")


func _physics_process(_delta: float) -> void:
	if _ship == null:
		return
	if docked_port != null:
		# A frozen hull's linear_velocity is stale, but EVA exit and the HUD's
		# relative-velocity readout both read it — keep it tracking the station
		# so a suit stepping out of a docked ship leaves co-moving, not 130 m/s
		# behind (standing trap #5).
		_ship.linear_velocity = docked_port.station_velocity()
		return
	if not _capture_armed:
		if (
			_rearm_port == null
			or (_ship.global_position - _rearm_port.global_position).length() > rearm_distance
		):
			_capture_armed = true
			_rearm_port = null
	if GameState.autopilot_active or _ship.freeze:
		approach_port = null
		return
	var port := _port_containing_ship()
	approach_port = port
	if port == null:
		return
	var rel: Vector3 = _ship.linear_velocity - port.station_velocity()
	approach_distance = (port.global_position - _ship.global_position).length()
	approach_speed = rel.length()
	# A correct approach flies nose-first down the port axis, so the ship's
	# forward (-Z) should be anti-parallel to the outward axis.
	approach_axis_error_deg = rad_to_deg((-_ship.global_basis.z).angle_to(-port.axis_out()))
	if (
		_capture_armed
		and approach_speed <= port.capture_speed_max
		and approach_axis_error_deg <= port.capture_angle_max_deg
	):
		_capture(port)


func _port_containing_ship() -> DockingPort:
	for node in get_tree().get_nodes_in_group(&"docking_ports"):
		var port := node as DockingPort
		if port != null and port.contains(_ship):
			return port
	return null


func _capture(port: DockingPort) -> void:
	# 1. Freeze first: the physics server owns a live body's transform, and the
	#    reparent below rewrites it.
	_ship.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	_ship.freeze = true
	# 2. Leave the shiftable group BEFORE parenting under the port. The station
	#    recomputes from true space every frame, so from here the ship inherits
	#    origin shifts through the tree — staying in the group would move it
	#    twice per shift (standing trap #3 wearing a new hat).
	_ship.remove_from_group(OriginShift.SHIFTABLE_GROUP)
	# 3. Reparent under the port, preserving the global transform: capture keeps
	#    the pose you flew in with, it does not snap the hull around.
	_undocked_parent = _ship.get_parent()
	var xf: Transform3D = _ship.global_transform
	_undocked_parent.remove_child(_ship)
	port.add_child(_ship)
	_ship.global_transform = xf
	# 3b. Take the body out of the physics space. `freeze` is not enough: the
	#     server still writes a frozen kinematic body's global transform back
	#     every step, one frame behind the rail-driven parent, and the local
	#     offset accumulates without bound (~0.8 m per frame here). With no
	#     space, the tree alone owns the transform — the same reasoning that
	#     stows the EVA suit out of the tree. The CargoBay Area3D is its own
	#     physics object and keeps detecting EVA boarding; the station's
	#     collision covers the docked hull. Must happen AFTER the reparent —
	#     re-entering the world re-adds a body to the world space.
	PhysicsServer3D.body_set_space(_ship.get_rid(), RID())
	# 4. Zero relative motion. The stored velocity tracks the station (see
	#    _physics_process) so stale readers stay honest.
	_ship.linear_velocity = port.station_velocity()
	_ship.angular_velocity = Vector3.ZERO
	# 5. Announce. Flight controls and the autopilot stand down on this flag.
	docked_port = port
	approach_port = null
	GameState.docked = true
	# Station services: fuel refills while docked — instant for now, the same
	# precedent as the EVA refill on boarding.
	if _ship.has_method("refill_fuel"):
		_ship.refill_fuel()
	captured.emit(port)


func undock() -> void:
	if docked_port == null:
		return
	var port := docked_port
	# Mirror of capture, reversed: reparent back to the world first — which also
	# re-adds the body to the world's physics space via ENTER_WORLD — preserve
	# the global transform, rejoin the shiftable group, then go live.
	var xf: Transform3D = _ship.global_transform
	port.remove_child(_ship)
	_undocked_parent.add_child(_ship)
	_ship.global_transform = xf
	_ship.add_to_group(OriginShift.SHIFTABLE_GROUP)
	_ship.freeze = false
	# Depart matched to the station plus a gentle push-off down the port axis.
	_ship.linear_velocity = port.station_velocity() + port.axis_out() * push_off_speed
	_ship.angular_velocity = Vector3.ZERO
	docked_port = null
	_capture_armed = false
	_rearm_port = port
	GameState.docked = false
	GameState.flight_assist_enabled = true
	released.emit(port)


func docked_station_name() -> String:
	if docked_port == null:
		return ""
	return docked_port.display_name()
