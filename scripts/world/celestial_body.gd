extends NavTarget
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

## Metres from the render origin to this body's centre, in true space.
var true_distance: float = 0.0

## True while the body is drawn as a clamped proxy rather than at true offset.
var is_proxy: bool = false

var _mesh: MeshInstance3D
var _static_body: StaticBody3D
var _collision: CollisionShape3D
var _rings: MeshInstance3D
var _surface: PlanetSurface
var _glare: MeshInstance3D


func setup(p_def: BodyDef) -> void:
	def = p_def
	name = String(def.id).capitalize()
	_build_visuals()


func _build_visuals() -> void:
	if def.surface != null:
		# Progressive cube-sphere terrain (docs/planet-renderer.md). Patch
		# geometry is baked at metre scale, so the proxy ratio is the node
		# scale itself — the same single multiply the sphere used.
		_surface = PlanetSurface.new()
		_surface.name = "PlanetSurface"
		_surface.setup(
			def.surface, def.radius, def.spin_period, def.spin_axis_tilt,
			def.albedo, def.roughness, def.atmosphere, def.limb_darkening
		)
		if def.cloud_layer:
			_surface.configure_clouds(def.cloud_height_fraction, def.cloud_coverage)
		add_child(_surface)
	else:
		_build_sphere_visual()

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


## The flat-shaded sphere: the Sun (emissive), and any body without a surface.
func _build_sphere_visual() -> void:
	# Unit sphere, scaled to radius — so proxy scaling is a single multiply.
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 64
	sphere.rings = 32

	var mat: Material
	if def.emissive:
		# A limb-darkened disc bright enough to bloom, plus an additive
		# billboard glare — the Sun reads as a star, not a cream sticker.
		var disc := ShaderMaterial.new()
		disc.shader = load("res://assets/shaders/sun_disc.gdshader")
		disc.set_shader_parameter("tint", Vector3(def.albedo.r, def.albedo.g, def.albedo.b))
		disc.set_shader_parameter("core_energy", def.emission_energy * 2.2)
		disc.set_shader_parameter("edge_energy", def.emission_energy * 0.5)
		mat = disc

		var glare_mat := ShaderMaterial.new()
		glare_mat.shader = load("res://assets/shaders/sun_glare.gdshader")
		glare_mat.render_priority = -20
		var quad := QuadMesh.new()
		quad.size = Vector2(2.0, 2.0)
		_glare = MeshInstance3D.new()
		_glare.name = "Glare"
		_glare.mesh = quad
		_glare.material_override = glare_mat
		_glare.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_glare.scale = Vector3.ONE * (def.radius * 4.0)
		_glare.extra_cull_margin = def.radius * 4.0
		add_child(_glare)
	else:
		var std := StandardMaterial3D.new()
		std.albedo_color = def.albedo
		std.roughness = def.roughness
		std.metallic = 0.0
		mat = std

	_mesh = MeshInstance3D.new()
	_mesh.name = "Mesh"
	_mesh.mesh = sphere
	_mesh.material_override = mat
	_mesh.scale = Vector3.ONE * def.radius
	add_child(_mesh)


## --- Analytic position -------------------------------------------------------

## True-space position at simulation time `t`, as 64-bit [x, y, z].
func position_at(t: float) -> Array:
	var base: Array = [0.0, 0.0, 0.0]
	if parent_body != null:
		base = parent_body.position_at(t)
	var off: Array = OrbitMath.offset_at(
		t, def.orbit_radius, def.orbit_period, def.orbit_phase, def.inclination
	)
	return [base[0] + off[0], base[1] + off[1], base[2] + off[2]]


## True-space velocity at simulation time `t`, in m/s. Used by the autopilot to
## arrive matched to a body's motion rather than merely at its coordinates.
func velocity_at(t: float) -> Array:
	var base: Array = [0.0, 0.0, 0.0]
	if parent_body != null:
		base = parent_body.velocity_at(t)
	var off: Array = OrbitMath.velocity_offset_at(
		t, def.orbit_radius, def.orbit_period, def.orbit_phase, def.inclination
	)
	return [base[0] + off[0], base[1] + off[1], base[2] + off[2]]


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

	if _surface:
		_surface.body_is_proxy = is_proxy
		# Spin is analytic from sim_time, like the orbits — never accumulated.
		_surface.update_spin(t)

	var want_collision: bool = true_distance < def.radius + COLLISION_ACTIVATION_MARGIN
	if _surface and _surface.skim_active:
		# Inside skim range the resident patches are the physics truth: the
		# sphere would wall the ship out of valleys and let peaks through.
		want_collision = false
	if _collision.disabled == want_collision:
		_collision.disabled = not want_collision


func _apply_scale(ratio: float) -> void:
	var r: float = def.radius * ratio
	if _mesh:
		_mesh.scale = Vector3.ONE * r
	if _surface:
		# Scales the surface exactly as it scaled the sphere mesh — the
		# angular-size proxy contract (docs/planet-renderer.md).
		_surface.apply_scale_ratio(ratio)
	if _rings:
		_rings.scale = Vector3(r, r * 0.02, r)
	if _glare:
		_glare.scale = Vector3.ONE * (r * 4.0)
	if _collision and not _collision.disabled:
		# Collision only runs un-proxied, so the true radius is correct there.
		(_collision.shape as SphereShape3D).radius = def.radius


## Radius as currently drawn — def.radius, shrunk by the proxy ratio when far.
func visual_radius() -> float:
	if is_proxy and true_distance > 0.0:
		return def.radius * (MAX_RENDER_DISTANCE / true_distance)
	return def.radius


## The progressive terrain node, or null for sphere-only bodies (the Sun).
## Whether the analytic sphere is currently carrying collision. False in skim
## range, where the resident patches take over — the swap has to happen in both
## directions or the ship is either walled out of valleys or passes through peaks.
func sphere_collider_enabled() -> bool:
	return _collision != null and not _collision.disabled


func planet_surface() -> PlanetSurface:
	return _surface


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


## Depth in the orbital hierarchy (Sun 0, Earth 1, Moon 2). The chain is at most
## a few links, so walking it beats caching it somewhere that can go stale.
func frame_depth() -> int:
	var d: int = 0
	var walk: CelestialBody = self
	while walk.parent_body != null:
		d += 1
		walk = walk.parent_body
	return d


func nav_display_name() -> String:
	return def.display_name


func nav_note() -> String:
	return def.nav_note


func is_nav_destination() -> bool:
	return def.is_destination
