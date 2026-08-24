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

## Sunlight falls with the inverse square of distance (Track SL1), normalized
## so Earth orbit keeps the tuned 1.5. The floor is a stated stylization —
## Neptune at the real 1/54th of Earth's compressed-distance light would be
## unreadable — and the cap keeps Mercury from clipping the tonemap.
const EARTH_ORBIT: float = 300000.0
const SUN_BASE_ENERGY: float = 1.5
const SUN_ENERGY_FLOOR: float = 0.12
const SUN_ENERGY_CAP: float = 2.5

## Gravity is a SURFACE SHELL, not a global field (Track LD3). The rails are
## dramatized — Meridian Relay's rail speed at 9 km matches no honest g(r), so
## a global field would drop every parked ship, station, and debris field out
## of the sky. Inside the shell gravity is inverse-square from the dramatized
## surface value, faded smoothly to zero across the top band; outside it,
## space rules exactly as before. Every autopilot standoff sits outside every
## shell (gated in travel_test), so transfers and parks are untouched.
const GRAVITY_SHELL_TOP: float = 1.5     # shell reaches this many radii
const GRAVITY_FADE_START: float = 1.35   # fade from full here to zero at top

signal system_built

## Unit vector from the render origin toward the Sun, refreshed every frame
## beside the global shader parameter of the same value. Scene-side code (detail
## sites gating their own city lights on the terminator) needs it too, and
## RenderingServer.global_shader_parameter_get is editor-only — calling it in a
## running game logs an error per call.
static var sun_direction: Vector3 = Vector3(0.0, 0.0, 1.0)

## Fraction of the sun's disc visible from the render origin (Track SL1):
## 1 in open space, 0 deep in a body's umbra, between in the penumbra.
var sun_visibility: float = 1.0

## Per-channel transmittance of direct sunlight at the origin (Track SL3):
## white in vacuum, gold-to-red when the sun ray grazes an atmosphere.
var sun_tint: Vector3 = Vector3.ONE

var bodies: Array[CelestialBody] = []

## Registered OrbitalStations. Not built here — stations are authored scenes,
## instanced by GameWorld and handed over via register_station().
var stations: Array[OrbitalStation] = []

var _by_id: Dictionary = {}
var _sun_light: DirectionalLight3D
var _sun: CelestialBody
var _environment: Environment = null
var _ambient_base_color: Color
var _ambient_base_energy: float = 1.1


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
	var defs: Array[BodyDef] = SolarSystemData.build()
	for def in defs:
		var body := CelestialBody.new()
		body.setup(def)
		add_child(body)
		bodies.append(body)
		_by_id[def.id] = body

	# Resolve parents; frame depth is derived from this chain on demand.
	for i in bodies.size():
		if defs[i].parent_id != &"":
			bodies[i].parent_body = _by_id.get(defs[i].parent_id) as CelestialBody

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
		if _sun != null and body != _sun:
			# Track SL5: each body is lit from where the sun is FOR IT.
			body.set_sun_direction(Vector3(
				float(_sun.true_pos[0] - body.true_pos[0]),
				float(_sun.true_pos[1] - body.true_pos[1]),
				float(_sun.true_pos[2] - body.true_pos[2])).normalized())
	for station in stations:
		station.update_render(t)
	_aim_sun_light()
	_update_ambient()


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
	# The planet shader gates night lights on the same sun the light is aimed
	# from: global parameter points from the render origin TOWARD the Sun.
	RenderingServer.global_shader_parameter_set(&"planet_sun_direction", -dir)
	sun_direction = -dir

	# Track SL1 + SL3: sunlight is distance-true, eclipsed by bodies, and
	# filtered by any atmosphere the sun ray grazes on its way here.
	#
	# Evaluated at the TRACKED SHIP's true position, never at the render
	# origin: the origin trails the ship by up to 10 km between rebases, so
	# an origin-based eclipse held a stale answer while you flew and then
	# re-evaluated all at once when the rebase fired — the sun winked on or
	# off after "moving a certain amount" (OR2, attributed by probe_or2:
	# `vis` flipped exactly on the rows where origin_x jumped, and read
	# fully-lit with the ship deep inside Earth's shadow).
	var eval_pos: Array = [OriginShift.origin_x, OriginShift.origin_y, OriginShift.origin_z]
	var tracked := OriginShift.tracked
	if tracked != null and is_instance_valid(tracked):
		eval_pos = OriginShift.to_true(tracked.global_position)
	sun_visibility = sun_visibility_at(eval_pos)
	sun_tint = sun_filter_at(eval_pos)
	var ex: float = _sun.true_pos[0] - eval_pos[0]
	var ey: float = _sun.true_pos[1] - eval_pos[1]
	var ez: float = _sun.true_pos[2] - eval_pos[2]
	var d_sun: float = maxf(sqrt(ex * ex + ey * ey + ez * ez), 1.0)
	var energy: float = clampf(
		SUN_BASE_ENERGY * pow(EARTH_ORBIT / d_sun, 2.0),
		SUN_ENERGY_FLOOR, SUN_ENERGY_CAP)
	_sun_light.light_energy = energy * sun_visibility
	_sun_light.light_color = Color(sun_tint.x, sun_tint.y, sun_tint.z)
	if _sun:
		_sun.set_glare_dim(sun_visibility)


## Adopt the scene's Environment so ambient fill can be driven from the sky.
## The values it arrives with are the deep-space base the fill blends up from.
func bind_environment(env: Environment) -> void:
	_environment = env
	if env != null:
		_ambient_base_color = env.ambient_light_color
		_ambient_base_energy = env.ambient_light_energy


## Sky-derived ambient near an atmospheric body — the PR4 stretch that retires
## the flat ambient constant. Physically the fill light near a planet is its
## own sky and sunlit face; both terms come from the same BodyAtmosphere the
## shell renders with, scaled by proximity and by how much of the lit face the
## observer hangs over. In deep space this decays exactly to the old base
## values, so nothing changes far from a body.
func _update_ambient() -> void:
	if _environment == null:
		return
	var best: CelestialBody = null
	var best_f: float = 0.0
	for body in bodies:
		if body.def.atmosphere == null:
			continue
		# Fades in from 7 radii out; full strength at the surface.
		var f: float = clampf(
			1.0 - (body.true_distance - body.def.radius) / (body.def.radius * 6.0),
			0.0, 1.0)
		if f > best_f:
			best_f = f
			best = body
	if best == null or best_f <= 0.0:
		_environment.ambient_light_color = _ambient_base_color
		_environment.ambient_light_energy = _ambient_base_energy
		return
	# The render origin rides the tracked ship, so the body's render-space
	# position points from the observer to the body.
	var up: Vector3 = -best.position.normalized()
	var lit: float = clampf(sun_direction.dot(up) * 0.5 + 0.5, 0.0, 1.0)
	var atmo: BodyAtmosphere = best.def.atmosphere
	var strength: float = best_f * lit
	_environment.ambient_light_color = _ambient_base_color.lerp(
		atmo.ambient_sky_color.lerp(atmo.ground_albedo_tint, 0.35), strength)
	_environment.ambient_light_energy = _ambient_base_energy * (1.0 - strength * 0.35) \
		+ strength * 1.6


## --- Sunlight (Track SL) --------------------------------------------------------

## Fraction of the sun's disc covered when two discs of angular radii
## `ang_sun` and `ang_body` sit `sep` radians apart. Small-angle plane
## geometry — exact enough at the sub-degree scales eclipses happen at, and
## the smooth penumbra falls straight out of the lens-area formula.
static func disc_occlusion(ang_sun: float, ang_body: float, sep: float) -> float:
	if sep >= ang_sun + ang_body:
		return 0.0
	if sep <= ang_body - ang_sun:
		return 1.0
	if sep <= ang_sun - ang_body:
		return (ang_body * ang_body) / maxf(ang_sun * ang_sun, 1e-12)
	var r := ang_sun
	var rb := ang_body
	var d := maxf(sep, 1e-9)
	var a1 := r * r * acos(clampf((d * d + r * r - rb * rb) / (2.0 * d * r), -1.0, 1.0))
	var a2 := rb * rb * acos(clampf((d * d + rb * rb - r * r) / (2.0 * d * rb), -1.0, 1.0))
	var k := (-d + r + rb) * (d + r - rb) * (d - r + rb) * (d + r + rb)
	var lens := a1 + a2 - 0.5 * sqrt(maxf(k, 0.0))
	return clampf(lens / (PI * r * r), 0.0, 1.0)


## Visible fraction of the sun's disc from a true-space position: 1 in open
## space, 0 in an umbra, in between across the penumbra. Every body between
## here and the sun gets a say; the closest full occluder wins outright.
func sun_visibility_at(true_pos: Array) -> float:
	if _sun == null:
		return 1.0
	var sx: float = _sun.true_pos[0] - true_pos[0]
	var sy: float = _sun.true_pos[1] - true_pos[1]
	var sz: float = _sun.true_pos[2] - true_pos[2]
	var ds: float = sqrt(sx * sx + sy * sy + sz * sz)
	if ds < 1.0:
		return 1.0
	var sun_dir := Vector3(float(sx / ds), float(sy / ds), float(sz / ds))
	var ang_sun: float = asin(clampf(_sun.def.radius / ds, 0.0, 1.0))
	var vis: float = 1.0
	for body in bodies:
		if body == _sun:
			continue
		var bx: float = body.true_pos[0] - true_pos[0]
		var by: float = body.true_pos[1] - true_pos[1]
		var bz: float = body.true_pos[2] - true_pos[2]
		var db: float = sqrt(bx * bx + by * by + bz * bz)
		if db >= ds or db <= body.def.radius:
			continue
		var body_dir := Vector3(float(bx / db), float(by / db), float(bz / db))
		var ang_body: float = asin(clampf(body.def.radius / db, 0.0, 1.0))
		var sep: float = sun_dir.angle_to(body_dir)
		vis *= 1.0 - disc_occlusion(ang_sun, ang_body, sep)
		if vis <= 0.0:
			return 0.0
	return vis


## Per-channel transmittance of the direct sun ray reaching a true-space
## position (Track SL3). Vacuum is exactly white; a ray whose perigee grazes
## an atmospheric shell is filtered through both half-paths of the tangent
## chord, which is what turns the hull gold at an orbital sunrise. The solid
## body itself is `sun_visibility_at`'s job, not this one's.
func sun_filter_at(true_pos: Array) -> Vector3:
	if _sun == null:
		return Vector3.ONE
	var sx: float = _sun.true_pos[0] - true_pos[0]
	var sy: float = _sun.true_pos[1] - true_pos[1]
	var sz: float = _sun.true_pos[2] - true_pos[2]
	var ds: float = sqrt(sx * sx + sy * sy + sz * sz)
	if ds < 1.0:
		return Vector3.ONE
	var sun_dir := Vector3(float(sx / ds), float(sy / ds), float(sz / ds))
	var tint := Vector3.ONE
	for body in bodies:
		var atmo: BodyAtmosphere = body.def.atmosphere
		if atmo == null:
			continue
		# Body centre relative to this position, in body radii.
		var co := Vector3(
			float(body.true_pos[0] - true_pos[0]),
			float(body.true_pos[1] - true_pos[1]),
			float(body.true_pos[2] - true_pos[2])) / body.def.radius
		var top: float = 1.0 + atmo.height_fraction
		var here_r: float = co.length()
		if here_r < top:
			# Inside the shell (skimming): one path out toward the sun.
			var mu: float = (-co / here_r).dot(sun_dir)
			tint *= AtmosphereMath.transmittance(atmo, maxf(here_r, 1.0), mu, 24)
			continue
		# Outside: does the ray to the sun graze the shell? Perigee of the
		# line against the body, clamped to the segment toward the sun.
		var t_perigee: float = co.dot(sun_dir)
		if t_perigee <= 0.0 or t_perigee * body.def.radius >= ds:
			continue
		var perigee: float = (co - sun_dir * t_perigee).length()
		if perigee >= top or perigee < 1.0:
			# Clear miss, or blocked by the ground (the eclipse term's job).
			continue
		var half := AtmosphereMath.transmittance(atmo, maxf(perigee, 1.0), 0.0, 24)
		tint *= half * half
	return tint


## --- Gravity (Track LD3) ------------------------------------------------------

## World-space gravitational acceleration at a true-space position. Zero
## everywhere except inside a solid body's surface shell; shells never overlap
## (1.5 R is far inside every orbit), so at most one body contributes.
func gravity_at(true_pos: Array) -> Vector3:
	for body in bodies:
		var g0: float = body.def.surface_gravity
		if g0 <= 0.0:
			continue
		var r_vec := Vector3(
			float(body.true_pos[0] - true_pos[0]),
			float(body.true_pos[1] - true_pos[1]),
			float(body.true_pos[2] - true_pos[2]))
		var radius: float = body.def.radius
		var r: float = r_vec.length()
		if r >= radius * GRAVITY_SHELL_TOP or r < 1e-3:
			continue
		var fade: float = 1.0 - smoothstep(
			radius * GRAVITY_FADE_START, radius * GRAVITY_SHELL_TOP, r)
		var rr: float = maxf(r, radius)  # inside the ground: no singularity
		return r_vec / r * (g0 * (radius * radius) / (rr * rr) * fade)
	return Vector3.ZERO


## The body whose gravity shell contains a true-space position, or null in
## open space — regardless of whether it has ground (Track HZ): gas giants
## and the Sun pull without offering a landing. What the hazard monitor and
## the autopilot's engage refusal ask.
func shell_body_at(true_pos: Array) -> CelestialBody:
	for body in bodies:
		if body.def.surface_gravity <= 0.0:
			continue
		var dx: float = true_pos[0] - body.true_pos[0]
		var dy: float = true_pos[1] - body.true_pos[1]
		var dz: float = true_pos[2] - body.true_pos[2]
		var r: float = sqrt(dx * dx + dy * dy + dz * dz)
		if r < body.def.radius * GRAVITY_SHELL_TOP:
			return body
	return null


## As shell_body_at, but only bodies with ground to land on — what the
## landing computer and the EVA walk ask.
func landable_body_at(true_pos: Array) -> CelestialBody:
	var body := shell_body_at(true_pos)
	if body != null and body.def.has_solid_surface:
		return body
	return null


## --- Queries -----------------------------------------------------------------

func get_body(id: StringName) -> CelestialBody:
	return _by_id.get(id) as CelestialBody


## Hand an authored station over to the system: resolve its parent body, include
## it in destinations and reference frames, and drive its render position from
## here on. Call after the render origin exists (GameWorld._wire_systems), never
## from a `_ready` — children run before parents.
func register_station(station: OrbitalStation) -> void:
	station.setup(self)
	stations.append(station)
	station.update_render(SimClock.sim_time)


## Targets the nav console offers as autopilot destinations.
func destinations() -> Array[NavTarget]:
	var out: Array[NavTarget] = []
	for body in bodies:
		if body.is_nav_destination():
			out.append(body)
	for station in stations:
		if station.is_nav_destination():
			out.append(station)
	return out


## The target whose reference frame a true-space point sits in — the deepest one
## in the hierarchy whose influence sphere contains the point. Returns null out
## in open space between bodies.
func reference_body(true_pos: Array) -> NavTarget:
	var best: NavTarget = null
	var best_depth: int = -1
	var best_dist: float = INF
	var candidates: Array[NavTarget] = []
	candidates.append_array(bodies)
	candidates.append_array(stations)
	for target in candidates:
		var dx: float = true_pos[0] - target.true_pos[0]
		var dy: float = true_pos[1] - target.true_pos[1]
		var dz: float = true_pos[2] - target.true_pos[2]
		var dist: float = sqrt(dx * dx + dy * dy + dz * dz)
		if dist > target.influence_radius():
			continue
		var d: int = target.frame_depth()
		# Deeper wins: near the Moon you hold station on the Moon, not Earth —
		# and inside a station's influence, on the station, not its planet.
		if d > best_depth or (d == best_depth and dist < best_dist):
			best = target
			best_depth = d
			best_dist = dist
	return best


## Velocity flight assist should null out toward, for a given true-space point.
## In open space that is zero (the system's inertial frame); near a body it is
## that body's orbital velocity, so parking next to it actually parks.
func reference_velocity(true_pos: Array) -> Vector3:
	var target := reference_body(true_pos)
	if target == null:
		return Vector3.ZERO
	var v: Array = target.velocity_at(SimClock.sim_time)
	return Vector3(float(v[0]), float(v[1]), float(v[2]))
