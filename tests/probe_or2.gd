extends Node
## OR2 instrumentation: fly three scripted sweeps that each cross a different
## set of movement thresholds, and log mean frame luminance against every
## suspect's state per step. A dramatic lighting change timestamps itself
## against exactly one column. Run: xvfb-run -a godot res://tests/probe_or2.tscn
##
## Columns: step parameter | mean luminance | sun visibility (eclipse) |
## sun tint blue (SL3) | light energy | skim | resident L2 tiles | patch cache |
## origin_x (rebases show as jumps) | JUMP marker when luminance steps >12%.

var _system: SolarSystem
var _ship: RigidBody3D
var _earth: CelestialBody
var _sun_light: DirectionalLight3D
var _prev_lum: float = -1.0


func _ready() -> void:
	var world: Node3D = load("res://scenes/game_world.tscn").instantiate()
	add_child(world)
	for _i in 8:
		await get_tree().process_frame
	_system = world.get_node("SolarSystem")
	_ship = world.get_node("Ship")
	_earth = _system.get_body(&"earth")
	_sun_light = _system.get_node("SunLight")
	_ship.freeze = true
	GameState.flight_assist_enabled = false

	var surface := _earth.planet_surface()
	var deadline: int = Time.get_ticks_msec() + 60000
	while not (surface.textures_ready and surface.atmosphere_ready) \
			and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	# Sunlit fixed ground point for the descent (France-ish).
	var base := _latlon(46.5, 2.5)
	await _warp_sunlit(base, 0.7)

	print("\n=== SWEEP A: radial descent over sunlit land, 2600 -> 140 m ===")
	_prev_lum = -1.0
	for i in 42:
		var alt: float = 2600.0 - 60.0 * float(i)
		await _pose_over(base, alt, 0.0)
		await _sample("alt %6.0f" % alt)

	print("\n=== SWEEP B: terminator walk at 300 m, subsolar angle 40 -> 175 deg ===")
	_prev_lum = -1.0
	for i in 55:
		var theta: float = deg_to_rad(40.0 + 2.5 * float(i))
		await _pose_ring(theta, 300.0)
		await _sample("theta %5.1f" % rad_to_deg(theta))

	print("\n=== SWEEP C: radial retreat over the same point, 0.5 -> 22 km ===")
	_prev_lum = -1.0
	await _warp_sunlit(base, 0.7)
	for i in 30:
		var alt: float = 500.0 + 740.0 * float(i)
		await _pose_over(base, alt, 0.0)
		await _sample("alt %6.0f" % alt)

	get_tree().quit()


func _latlon(lat_deg: float, lon_deg: float) -> Vector3:
	var lat := deg_to_rad(lat_deg)
	var lon := deg_to_rad(lon_deg)
	return Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))


## Warp SimClock until `local_dir` faces the sun at ~`elev`, then jump the
## ship with the body (the _frame_site lesson).
func _warp_sunlit(local_dir: Vector3, elev: float) -> void:
	var period: float = _earth.def.spin_period
	var axis := Vector3(
		0.0, cos(_earth.def.spin_axis_tilt), sin(_earth.def.spin_axis_tilt)).normalized()
	var best_t: float = SimClock.sim_time
	var best_err: float = 1e9
	for step in 720:
		var t: float = SimClock.sim_time + period * float(step) / 720.0
		var spun: Vector3 = Basis(axis, fposmod(TAU * (t / period), TAU)) * local_dir
		var ep: Array = _earth.position_at(t)
		var sp: Array = _system.get_body(&"sun").position_at(t)
		var sd := Vector3(float(sp[0] - ep[0]), float(sp[1] - ep[1]),
			float(sp[2] - ep[2])).normalized()
		var err: float = absf(spun.dot(sd) - elev)
		if err < best_err:
			best_err = err
			best_t = t
	SimClock.sim_time = best_t
	for _i in 4:
		await get_tree().physics_frame
	var jump: Vector3 = (
		_earth.planet_surface().global_transform.basis * local_dir).normalized()
	_ship.global_position = OriginShift.to_render(_earth.true_pos) \
		+ jump * (_earth.def.radius + 2000.0)
	await get_tree().physics_frame


## Hold above `local_dir` at `alt`, aimed 20 deg off nadir toward local north —
## constant relative framing so luminance changes mean lighting, not framing.
func _pose_over(local_dir: Vector3, alt: float, _unused: float) -> void:
	for _i in 14:
		var centre: Vector3 = OriginShift.to_render(_earth.true_pos)
		var b: Basis = _earth.planet_surface().global_transform.basis
		var up: Vector3 = (b * local_dir).normalized()
		var north: Vector3 = (b * _latlon(51.5, 2.5)).normalized()
		north = (north - up * up.dot(north)).normalized()
		var where: Vector3 = centre + up * (_earth.def.radius + alt)
		_ship.global_position = where
		_ship.look_at(where + (-up).rotated(north, deg_to_rad(20.0)) * alt, north)
		await get_tree().physics_frame


## Hold at `theta` from the subsolar point along a great-circle ring, aimed
## along the direction of travel with a fixed down-tilt.
func _pose_ring(theta: float, alt: float) -> void:
	for _i in 14:
		var centre: Vector3 = OriginShift.to_render(_earth.true_pos)
		var to_sun: Vector3 = (OriginShift.to_render(
			_system.get_body(&"sun").true_pos) - centre).normalized()
		var axis: Vector3 = to_sun.cross(Vector3.UP)
		if axis.length() < 0.1:
			axis = to_sun.cross(Vector3.RIGHT)
		axis = axis.normalized()
		var up: Vector3 = to_sun.rotated(axis, theta)
		var travel: Vector3 = to_sun.rotated(axis, theta + PI / 2.0)
		var where: Vector3 = centre + up * (_earth.def.radius + alt)
		_ship.look_at_from_position(
			where, where + travel * 300.0 - up * 120.0, up)
		await get_tree().physics_frame


func _sample(label: String) -> void:
	for _i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	img.resize(64, 36, Image.INTERPOLATE_NEAREST)
	var sum := 0.0
	for y in 36:
		for x in 64:
			sum += img.get_pixel(x, y).get_luminance()
	var lum := sum / (64.0 * 36.0)
	var surface := _earth.planet_surface()
	var jump := ""
	if _prev_lum > 0.0 and absf(lum - _prev_lum) / maxf(_prev_lum, 1e-4) > 0.12:
		jump = "   <-- JUMP %+.0f%%" % ((lum - _prev_lum) / _prev_lum * 100.0)
	print("%s | lum %.4f | vis %.3f | tintB %.3f | E %.2f | skim %s | L2 %d | cache %d | ox %.0f%s" % [
		label, lum, _system.sun_visibility, _system.sun_tint.z,
		_sun_light.light_energy, surface.skim_active,
		surface.surface_res.resident_l2_keys().size(), surface.stats()["cache"],
		OriginShift.origin_x, jump,
	])
	_prev_lum = lum
