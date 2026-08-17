extends Node3D
class_name CelestialBody
## One planet, moon, or star. Builds its own visuals from a BodyDef.
##
## Position is analytic: a function of SimClock.sim_time, never integrated. That
## is what lets the autopilot ask "where will Neptune be in four hours?" and get
## an exact answer, and what lets time compression skip ahead without drift.
##
## Rendering far bodies is the other half of the job. A body 2,000 km away cannot
## be drawn at its true offset — float32 has no precision left there and it would
## sit far beyond the camera's far plane. Instead it is drawn along its true
## direction at a clamped distance, scaled by the same ratio, which preserves its
## apparent angular size exactly. A planet looks right from anywhere; only its
## depth is a lie, and nothing the player can do reveals it.

## Bodies past this render distance are drawn as angular-size-preserving proxies.
const MAX_RENDER_DISTANCE: float = 40000.0

## Collision is only worth simulating when the player could plausibly hit it.
const COLLISION_ACTIVATION_MARGIN: float = 20000.0

## A body's reference frame never reaches beyond this fraction of its own orbit.
const ORBIT_INFLUENCE_FRACTION: float = 0.4

var def: BodyDef
var parent_body: CelestialBody = null

## True-space position, refreshed once per frame by SolarSystem.
var true_pos: Array = [0.0, 0.0, 0.0]

## Metres from the render origin to this body's centre, in true space.
var true_distance: float = 0.0

## True while the body is drawn as a clamped proxy rather than at true offset.
var is_proxy: bool = false

var _mesh: MeshInstance3D
var _static_body: StaticBody3D
var _collision: CollisionShape3D
var _rings: MeshInstance3D


func setup(p_def: BodyDef) -> void:
	def = p_def
	name = String(def.id).capitalize()
	_build_visuals()


func _build_visuals() -> void:
	# Unit sphere, scaled to radius — so proxy scaling is a single multiply.
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 64
	sphere.rings = 32

	var mat := StandardMaterial3D.new()
	mat.albedo_color = def.albedo
	mat.roughness = def.roughness
	mat.metallic = 0.0
	if def.emissive:
		mat.emission_enabled = true
		mat.emission = def.albedo
		mat.emission_energy_multiplier = def.emission_energy
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_mesh = MeshInstance3D.new()
	_mesh.name = "Mesh"
	_mesh.mesh = sphere
	_mesh.material_override = mat
	_mesh.scale = Vector3.ONE * def.radius
	add_child(_mesh)

	if def.has_rings:
		var torus := TorusMesh.new()
		torus.inner_radius = def.ring_inner_scale
		torus.outer_radius = def.ring_outer_scale
		torus.rings = 64
		var ring_mat := StandardMaterial3D.new()
		ring_mat.albedo_color = def.albedo.lightened(0.15)
		ring_mat.roughness = 0.9
		ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_rings = MeshInstance3D.new()
		_rings.name = "Rings"
		_rings.mesh = torus
		_rings.material_override = ring_mat
		# Flatten the torus into a disc.
		_rings.scale = Vector3(def.radius, def.radius * 0.02, def.radius)
		add_child(_rings)

	# Collision, disabled until the player is near enough for it to matter.
	var shape := SphereShape3D.new()
	shape.radius = def.radius
	_collision = CollisionShape3D.new()
	_collision.shape = shape
	_collision.disabled = true
	_static_body = StaticBody3D.new()
	_static_body.name = "Surface"
	_static_body.collision_layer = 8   # environment
	_static_body.collision_mask = 0
	_static_body.add_child(_collision)
	add_child(_static_body)


## --- Analytic position -------------------------------------------------------

## True-space position at simulation time `t`, as 64-bit [x, y, z].
func position_at(t: float) -> Array:
	var base: Array = [0.0, 0.0, 0.0]
	if parent_body != null:
		base = parent_body.position_at(t)
	if def.orbit_radius <= 0.0:
		return base
	var w: float = TAU / maxf(def.orbit_period, 0.001)
	var a: float = def.orbit_phase + w * t
	var x: float = cos(a) * def.orbit_radius
	var z_flat: float = sin(a) * def.orbit_radius
	# Tilt the orbital plane about the X axis.
	var y: float = sin(def.inclination) * z_flat
	var z: float = cos(def.inclination) * z_flat
	return [base[0] + x, base[1] + y, base[2] + z]


## True-space velocity at simulation time `t`, in m/s. Used by the autopilot to
## arrive matched to a body's motion rather than merely at its coordinates.
func velocity_at(t: float) -> Array:
	var base: Array = [0.0, 0.0, 0.0]
	if parent_body != null:
		base = parent_body.velocity_at(t)
	if def.orbit_radius <= 0.0:
		return base
	var w: float = TAU / maxf(def.orbit_period, 0.001)
	var a: float = def.orbit_phase + w * t
	var dx: float = -sin(a) * def.orbit_radius * w
	var dz_flat: float = cos(a) * def.orbit_radius * w
	var dy: float = sin(def.inclination) * dz_flat
	var dz: float = cos(def.inclination) * dz_flat
	return [base[0] + dx, base[1] + dy, base[2] + dz]


## --- Rendering ---------------------------------------------------------------

## Refresh cached true position and place the body in render space.
func update_render(t: float) -> void:
	true_pos = position_at(t)
	var delta_x: float = true_pos[0] - OriginShift.origin_x
	var delta_y: float = true_pos[1] - OriginShift.origin_y
	var delta_z: float = true_pos[2] - OriginShift.origin_z
	true_distance = sqrt(delta_x * delta_x + delta_y * delta_y + delta_z * delta_z)

	if true_distance <= MAX_RENDER_DISTANCE or true_distance < 1e-6:
		is_proxy = false
		position = Vector3(float(delta_x), float(delta_y), float(delta_z))
		_apply_scale(1.0)
	else:
		# Angular size is preserved: draw at the clamped distance, shrink by the
		# same ratio. tan(θ) = r/d is unchanged when r and d scale together.
		is_proxy = true
		var ratio: float = MAX_RENDER_DISTANCE / true_distance
		var dir := Vector3(
			float(delta_x / true_distance),
			float(delta_y / true_distance),
			float(delta_z / true_distance)
		)
		position = dir * MAX_RENDER_DISTANCE
		_apply_scale(ratio)

	var want_collision: bool = true_distance < def.radius + COLLISION_ACTIVATION_MARGIN
	if _collision.disabled == want_collision:
		_collision.disabled = not want_collision


func _apply_scale(ratio: float) -> void:
	var r: float = def.radius * ratio
	_mesh.scale = Vector3.ONE * r
	if _rings:
		_rings.scale = Vector3(r, r * 0.02, r)
	if _collision and not _collision.disabled:
		# Collision only runs un-proxied, so the true radius is correct there.
		(_collision.shape as SphereShape3D).radius = def.radius


## Standoff distance the autopilot parks at.
func arrival_standoff() -> float:
	return def.radius * def.arrival_standoff_scale


## How far this body's reference frame reaches. Scaled off the body's radius, but
## never more than a fraction of its own orbit — otherwise the Moon's frame would
## swallow low Earth orbit, and a ship parked over Earth would try to hold station
## against the Moon.
func influence_radius() -> float:
	var r: float = def.radius * SolarSystem.REFERENCE_INFLUENCE_SCALE
	if def.orbit_radius > 0.0:
		r = minf(r, def.orbit_radius * ORBIT_INFLUENCE_FRACTION)
	return r
