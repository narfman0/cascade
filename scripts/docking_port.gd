class_name DockingPort extends Node3D
## One docking port: a capture volume plus an approach axis.
##
## The port's local +Z is the approach axis, pointing away from the station
## structure — a docking ship flies down it nose-first, so a correct approach
## has the ship's forward (-Z) anti-parallel to `axis_out()`. The capture
## volume is an Area3D box extending along +Z; DockingComputer polls it each
## physics tick and applies the soft-capture conditions below.
##
## Docking is a state, not a joint: on capture the ship is frozen kinematic and
## parented under this node. The station is on rails, not a physics body, so
## that is plain node-under-Node3D parenting — the never-nest-RigidBody rule is
## not violated.

## Relative speed above which contact is a bump, not a capture. m/s.
@export var capture_speed_max: float = 1.5

## Maximum angle between the ship's nose and the approach axis, degrees.
@export var capture_angle_max_deg: float = 20.0

var _volume: Area3D
var _station: OrbitalStation


func _ready() -> void:
	add_to_group(&"docking_ports")
	_volume = get_node_or_null("CaptureVolume") as Area3D
	# The owning station is an ancestor; resolve once, the tree above is static.
	var walk: Node = get_parent()
	while walk != null and not walk is OrbitalStation:
		walk = walk.get_parent()
	_station = walk as OrbitalStation


func station() -> OrbitalStation:
	return _station


## Velocity of the port in render space — the station's orbital velocity. What
## an approach is flown relative to, and what a docked ship inherits.
func station_velocity() -> Vector3:
	if _station == null:
		return Vector3.ZERO
	return _station.render_velocity()


## Approach axis, world space, pointing away from the station.
func axis_out() -> Vector3:
	return global_basis.z.normalized()


func contains(body: PhysicsBody3D) -> bool:
	return _volume != null and _volume.overlaps_body(body)


func display_name() -> String:
	if _station == null:
		return String(name)
	return _station.nav_display_name()
