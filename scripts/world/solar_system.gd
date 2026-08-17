extends Node3D
class_name SolarSystem
## Builds and drives every celestial body, and owns the system's single light.
##
## Bodies are generated from SolarSystemData rather than authored as scene nodes:
## a dozen planets and moons differ only in numbers, and hand-placing them would
## just be a worse copy of the same table.
##
## This node must NOT join the `origin_shiftable` group — bodies recompute their
## render position from true space every frame, so a floating-origin shift would
## be applied twice.

## How many body radii out a body's reference frame reaches. Inside it, flight
## assist holds station relative to that body instead of the system centre.
const REFERENCE_INFLUENCE_SCALE: float = 30.0

signal system_built

var bodies: Array[CelestialBody] = []

var _by_id: Dictionary = {}
var _depth: Dictionary = {}
var _sun_light: DirectionalLight3D
var _sun: CelestialBody


func _ready() -> void:
	# Build only — do NOT place bodies yet. Node `_ready` runs children-first, so
	# the render origin has not been established at this point; placing bodies
	# against a still-zeroed origin would put every body relative to the Sun. The
	# Sun's collision sphere would then be enabled 20 km wide directly over the
	# spawn point, and the physics engine would depenetrate the ship out of it at
	# 16 km per frame. GameWorld calls `refresh()` once the origin is set.
	_build()


## Place every body against the current render origin. Call after the origin has
## been established, and any time it changes outside the normal frame loop.
func refresh() -> void:
	_update_bodies()


func _build() -> void:
	for def in SolarSystemData.build():
		var body := CelestialBody.new()
		body.setup(def)
		add_child(body)
		bodies.append(body)
		_by_id[def.id] = body

	# Resolve parents, then cache orbital depth for reference-frame selection.
	for body in bodies:
		if body.def.parent_id != &"":
			body.parent_body = _by_id.get(body.def.parent_id) as CelestialBody
	for body in bodies:
		var d: int = 0
		var walk: CelestialBody = body
		while walk.parent_body != null:
			d += 1
			walk = walk.parent_body
		_depth[body.def.id] = d

	_sun = _by_id.get(&"sun") as CelestialBody

	# One directional light for the whole system, re-aimed every frame from the
	# Sun's true position toward the render origin. Cheap, and it means the
	# terminator is correct on every body from anywhere in the system.
	_sun_light = DirectionalLight3D.new()
	_sun_light.name = "SunLight"
	# Tuned against a lit Earth: much above this and a 0.4-albedo planet clips to
	# white and the terminator stops reading.
	_sun_light.light_energy = 1.5
	_sun_light.light_angular_distance = 0.5
	_sun_light.shadow_enabled = true
	_sun_light.shadow_bias = 0.06
	_sun_light.shadow_normal_bias = 1.5
	_sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	_sun_light.directional_shadow_max_distance = 500.0
	add_child(_sun_light)

	system_built.emit()


func _process(_delta: float) -> void:
	_update_bodies()


func _update_bodies() -> void:
	var t: float = SimClock.sim_time
	for body in bodies:
		body.update_render(t)
	_aim_sun_light()


func _aim_sun_light() -> void:
	if _sun_light == null or _sun == null:
		return
	# Light travels from the Sun's true position toward the render origin.
	var dx: float = OriginShift.origin_x - _sun.true_pos[0]
	var dy: float = OriginShift.origin_y - _sun.true_pos[1]
	var dz: float = OriginShift.origin_z - _sun.true_pos[2]
	var len: float = sqrt(dx * dx + dy * dy + dz * dz)
	if len < 1e-6:
		return
	var dir := Vector3(float(dx / len), float(dy / len), float(dz / len))
	# A DirectionalLight3D emits along its local -Z, so look down `dir`.
	var up := Vector3.UP
	if absf(dir.dot(up)) > 0.999:
		up = Vector3.RIGHT
	_sun_light.look_at_from_position(Vector3.ZERO, dir, up)


## --- Queries -----------------------------------------------------------------

func get_body(id: StringName) -> CelestialBody:
	return _by_id.get(id) as CelestialBody


## Bodies the nav console offers as autopilot destinations.
func destinations() -> Array[CelestialBody]:
	var out: Array[CelestialBody] = []
	for body in bodies:
		if body.def.is_destination:
			out.append(body)
	return out


## The body whose reference frame a true-space point sits in — the deepest body
## in the hierarchy whose influence sphere contains the point. Returns null out
## in open space between bodies.
func reference_body(true_pos: Array) -> CelestialBody:
	var best: CelestialBody = null
	var best_depth: int = -1
	var best_dist: float = INF
	for body in bodies:
		var dx: float = true_pos[0] - body.true_pos[0]
		var dy: float = true_pos[1] - body.true_pos[1]
		var dz: float = true_pos[2] - body.true_pos[2]
		var dist: float = sqrt(dx * dx + dy * dy + dz * dz)
		if dist > body.influence_radius():
			continue
		var d: int = _depth.get(body.def.id, 0)
		# Deeper wins: near the Moon you hold station on the Moon, not Earth.
		if d > best_depth or (d == best_depth and dist < best_dist):
			best = body
			best_depth = d
			best_dist = dist
	return best


## Velocity flight assist should null out toward, for a given true-space point.
## In open space that is zero (the system's inertial frame); near a body it is
## that body's orbital velocity, so parking next to it actually parks.
func reference_velocity(true_pos: Array) -> Vector3:
	var body := reference_body(true_pos)
	if body == null:
		return Vector3.ZERO
	var v: Array = body.velocity_at(SimClock.sim_time)
	return Vector3(float(v[0]), float(v[1]), float(v[2]))
