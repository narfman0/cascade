extends Node
## Headless verification for PR4 — atmosphere and scattering.
##
## Run: godot --headless res://tests/atmosphere_test.tscn
##
## "It looks nice" is not a test (docs/tasks.md, PR4 gate). Every assertion here
## is either a CPU mirror of the scattering integral (AtmosphereMath is written
## to match atmosphere.gdshader line for line) or a scene-graph contract the
## renderer depends on. Published-value checks: zenith chromaticity, sunset
## reddening order-of-magnitude, civil twilight, and the Mars inversion.

var _failures: int = 0
var _world: Node3D
var _system: SolarSystem

## Baked once here on the CPU — small MS grid, plenty for assertions.
var _earth_atmo: BodyAtmosphere
var _earth_t: Dictionary
var _earth_ms: Dictionary


func _ready() -> void:
	_world = load("res://scenes/game_world.tscn").instantiate()
	add_child(_world)
	await get_tree().process_frame
	await get_tree().process_frame
	_system = _world.get_node("SolarSystem")

	_earth_atmo = BodyAtmosphere.earth()
	_earth_t = AtmosphereMath.bake_transmittance(_earth_atmo)
	_earth_ms = AtmosphereMath.bake_multi_scatter(_earth_atmo, _earth_t, 16, 24, 10)

	_test_airless_stay_airless()
	_test_shells_exist()
	_test_twilight_drives_the_gate()
	_test_optical_depth_toward_limb()
	_test_lut_matches_integral()
	_test_sunset_reddening()
	_test_zenith_chromaticity()
	_test_civil_twilight()
	_test_multi_scatter_contributes()
	_test_mars_inversion()
	_test_venus_opaque()
	_test_proxy_contract()
	_test_sunlight_filter()
	await _test_luts_reach_the_shell()

	print("")
	if _failures == 0:
		print("PASS — all checks green")
	else:
		print("FAIL — %d check(s) failed" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _check(ok: bool, label: String, detail: String = "") -> void:
	if ok:
		print("  ok    %s %s" % [label, detail])
	else:
		_failures += 1
		print("  FAIL  %s %s" % [label, detail])


## --- Scene contracts ----------------------------------------------------------

func _test_airless_stay_airless() -> void:
	print("\n== airless bodies stay airless ==")
	for id in [&"mercury", &"moon", &"io", &"europa", &"ganymede", &"callisto"]:
		var body := _system.get_body(id)
		_check(body.def.atmosphere == null, "%s has no atmosphere" % id)
		var surface := body.planet_surface()
		_check(surface != null and surface.atmosphere_shell() == null,
			"%s has no shell node" % id)
		# The hard terminator: the night gate must be the shader's default
		# band, untouched by any atmosphere derivation.
		var lo: Variant = surface.material().get_shader_parameter("night_gate_lo")
		_check(lo == null, "%s keeps the default hard night gate" % id)


func _test_shells_exist() -> void:
	print("\n== shells and limb softening ==")
	for id in [&"earth", &"venus", &"mars", &"titan"]:
		var body := _system.get_body(id)
		_check(body.def.atmosphere != null, "%s has an atmosphere" % id)
		var shell := body.planet_surface().atmosphere_shell()
		_check(shell != null, "%s has a shell node" % id)
		if shell != null:
			var want: float = body.def.radius * (1.0 + body.def.atmosphere.height_fraction)
			_check(absf(shell.scale.x - want) < 0.01,
				"%s shell sits at radius*(1+hf)" % id,
				"(%.1f m)" % shell.scale.x)
	for id in [&"jupiter", &"saturn", &"uranus", &"neptune"]:
		var body := _system.get_body(id)
		_check(body.def.atmosphere == null and body.def.limb_darkening > 0.0,
			"%s: no shell, limb softening only" % id)
	_check(_system.get_body(&"sun").def.atmosphere == null, "the Sun has no shell")


func _test_twilight_drives_the_gate() -> void:
	print("\n== twilight drives the city lights ==")
	var atmo: BodyAtmosphere = _system.get_body(&"earth").def.atmosphere
	var tw := rad_to_deg(atmo.twilight_angle())
	_check(tw > 4.0 and tw < 15.0,
		"Earth twilight band width is plausible", "(%.1f deg)" % tw)
	# The analytic prediction from scale height IS the band: h_lit = min(top,
	# 6H) and acos(R/(R+h_lit)). Assert the resource computes exactly that.
	var h_lit: float = minf(atmo.height_fraction,
		6.0 * maxf(atmo.rayleigh_scale_height, atmo.mie_scale_height))
	_check(absf(atmo.twilight_angle() - acos(1.0 / (1.0 + h_lit))) < 1e-9,
		"twilight width follows from scale height and radius")
	# And the surface material must be gated by that same band.
	var mat: ShaderMaterial = _system.get_body(&"earth").planet_surface().material()
	var gate := atmo.night_gate()
	_check(is_equal_approx(mat.get_shader_parameter("night_gate_lo"), gate.x)
		and is_equal_approx(mat.get_shader_parameter("night_gate_hi"), gate.y),
		"the city-light gate uses the derived band",
		"(lo %.3f hi %.3f)" % [gate.x, gate.y])


## --- CPU mirror: the scattering integral ---------------------------------------

func _test_optical_depth_toward_limb() -> void:
	print("\n== optical depth toward the limb ==")
	# From orbit (r = 3), rays at increasing impact parameter toward the limb:
	# optical depth must rise monotonically and stay finite at grazing — the
	# classic divide-by-zero at the horizon is exactly what the LUT mapping's
	# max() guards exist for.
	var r := 3.0
	var prev := -1.0
	var monotone := true
	var finite := true
	for b in [0.0, 0.3, 0.6, 0.8, 0.9, 0.96, 0.99, 0.999]:
		var sin_a: float = b / r
		var mu: float = -sqrt(1.0 - sin_a * sin_a)   # aimed at impact param b
		var tau := _od_along_ray(_earth_atmo, r, mu)
		if not (is_finite(tau.x) and is_finite(tau.y) and is_finite(tau.z)):
			finite = false
		if tau.z < prev:
			monotone = false
		prev = tau.z
	_check(monotone, "optical depth rises monotonically toward the limb")
	_check(finite, "optical depth is finite at grazing incidence")
	# A ray past the limb through only the shell is also finite and non-zero.
	var graze_sin: float = (1.0 + _earth_atmo.height_fraction * 0.5) / r
	var graze_mu: float = -sqrt(1.0 - graze_sin * graze_sin)
	var graze := _od_along_ray(_earth_atmo, r, graze_mu)
	_check(is_finite(graze.z) and graze.z > 0.0,
		"a grazing ray through the shell alone scatters", "(tau_b %.3f)" % graze.z)


## Optical depth along a full chord from radius r, direction mu, clamped at the
## ground — the view-ray integral, distinct from the to-space LUT integral.
func _od_along_ray(atmo: BodyAtmosphere, r: float, mu: float) -> Vector3:
	var top := 1.0 + atmo.height_fraction
	var o := Vector3(0.0, r, 0.0)
	var dir := Vector3(sqrt(maxf(1.0 - mu * mu, 0.0)), mu, 0.0)
	var res := AtmosphereMath.sky_radiance(
		atmo, _earth_t, _earth_ms, o, dir, Vector3.UP, false, 48)
	var t: Vector3 = res["transmittance"]
	return Vector3(-log(maxf(t.x, 1e-20)), -log(maxf(t.y, 1e-20)), -log(maxf(t.z, 1e-20)))


func _test_lut_matches_integral() -> void:
	print("\n== LUT mirrors the integral ==")
	var worst := 0.0
	for probe in [[1.001, 0.9], [1.005, 0.3], [1.012, 0.05], [1.02, 0.7]]:
		var direct := AtmosphereMath.transmittance(_earth_atmo, probe[0], probe[1], 80)
		var lut := AtmosphereMath.sample_transmittance(_earth_atmo, _earth_t, probe[0], probe[1])
		for i in 3:
			worst = maxf(worst, absf(direct[i] - lut[i]))
	_check(worst < 0.03, "transmittance LUT matches direct integration",
		"(worst %.4f)" % worst)


func _test_sunset_reddening() -> void:
	print("\n== sunset reddening ==")
	# Transmitted sunlight toward the sun from ground level: the R/B ratio must
	# rise monotonically as the sun drops, by roughly an order of magnitude
	# between +10 deg and the horizon (published behaviour, docs gate — the
	# doc's -2 deg figure includes refraction, which is out of scope, so the
	# sweep stops just above the geometric horizon at this altitude).
	var r := 1.0002
	var prev_ratio := 0.0
	var monotone := true
	var ratios: Array[float] = []
	for elev_deg in [10.0, 6.0, 3.0, 1.0, 0.0, -0.5, -1.0]:
		var mu := sin(deg_to_rad(elev_deg))
		var t := AtmosphereMath.sample_transmittance(_earth_atmo, _earth_t, r, mu)
		var ratio: float = t.x / maxf(t.z, 1e-12)
		if ratio < prev_ratio:
			monotone = false
		prev_ratio = ratio
		ratios.append(ratio)
	_check(monotone, "R/B rises monotonically as the sun drops")
	var gain: float = ratios[ratios.size() - 1] / maxf(ratios[0], 1e-12)
	_check(gain > 10.0, "R/B gains an order of magnitude toward the horizon",
		"(x%.1f)" % gain)


func _test_zenith_chromaticity() -> void:
	print("\n== zenith chromaticity at noon ==")
	# Overhead sun, looking straight up from the surface. Real zenith sky sits
	# blueward of D65 (the gate says "near D65" — a white-to-sky-blue window,
	# operationalized as: inside a generous box reaching from D65 blueward,
	# and never redward of the white point).
	var res := AtmosphereMath.sky_radiance(
		_earth_atmo, _earth_t, _earth_ms,
		Vector3(0.0, 1.0002, 0.0), Vector3.UP, Vector3.UP, true, 48)
	var xy := AtmosphereMath.chromaticity(res["radiance"])
	var d65 := Vector2(0.3127, 0.3290)
	_check(xy.x > 0.20 and xy.x <= d65.x + 0.01
		and xy.y > 0.20 and xy.y <= d65.y + 0.02,
		"noon zenith lands between D65 and sky blue",
		"(x %.3f y %.3f)" % [xy.x, xy.y])


func _test_civil_twilight() -> void:
	print("\n== civil twilight still lights the sky ==")
	var cam := Vector3(0.0, 1.0002, 0.0)
	var noon := AtmosphereMath.sky_radiance(
		_earth_atmo, _earth_t, _earth_ms, cam, Vector3.UP, Vector3.UP, true, 48)
	var lum_noon := AtmosphereMath.luminance(noon["radiance"])
	# Sun 6 degrees below the horizon, looking toward where it set, 10 degrees up.
	var sun := Vector3(cos(deg_to_rad(-6.0)), sin(deg_to_rad(-6.0)), 0.0)
	var view := Vector3(cos(deg_to_rad(10.0)), sin(deg_to_rad(10.0)), 0.0)
	var dusk := AtmosphereMath.sky_radiance(
		_earth_atmo, _earth_t, _earth_ms, cam, view, sun, true, 48)
	var lum_dusk := AtmosphereMath.luminance(dusk["radiance"])
	_check(lum_dusk > lum_noon * 0.002,
		"sun at -6 deg still lights the sky measurably",
		"(%.4f of noon)" % (lum_dusk / maxf(lum_noon, 1e-12)))


func _test_multi_scatter_contributes() -> void:
	print("\n== multiple scattering contributes ==")
	# Twilight zenith, psi_ms on vs forced off. If the LUT were wired up but
	# inert, this is the assertion that catches it.
	var cam := Vector3(0.0, 1.0002, 0.0)
	var sun := Vector3(cos(deg_to_rad(-4.0)), sin(deg_to_rad(-4.0)), 0.0)
	var with_ms := AtmosphereMath.sky_radiance(
		_earth_atmo, _earth_t, _earth_ms, cam, Vector3.UP, sun, true, 48)
	var without := AtmosphereMath.sky_radiance(
		_earth_atmo, _earth_t, _earth_ms, cam, Vector3.UP, sun, false, 48)
	var lum_with := AtmosphereMath.luminance(with_ms["radiance"])
	var lum_without := AtmosphereMath.luminance(without["radiance"])
	_check(lum_with > lum_without * 1.3 and lum_with > 0.0,
		"twilight is materially brighter with orders 2+",
		"(x%.1f)" % (lum_with / maxf(lum_without, 1e-12)))


func _test_mars_inversion() -> void:
	print("\n== the Mars inversion ==")
	var atmo := BodyAtmosphere.mars()
	var t_lut := AtmosphereMath.bake_transmittance(atmo)
	var ms_lut := AtmosphereMath.bake_multi_scatter(atmo, t_lut, 16, 24, 10)
	var cam := Vector3(0.0, 1.0005, 0.0)
	# Day: sun high, looking 30 deg up, 90 deg away in azimuth.
	var day_sun := Vector3(cos(deg_to_rad(50.0)), sin(deg_to_rad(50.0)), 0.0)
	var day_view := Vector3(0.0, sin(deg_to_rad(30.0)), cos(deg_to_rad(30.0)))
	var day := AtmosphereMath.sky_radiance(atmo, t_lut, ms_lut, cam, day_view, day_sun, true, 48)
	var day_rgb: Vector3 = day["radiance"]
	var day_ratio: float = day_rgb.x / maxf(day_rgb.z, 1e-12)
	# Sunset: sun on the horizon, looking just above it toward the sun.
	var set_sun := Vector3(cos(deg_to_rad(1.0)), sin(deg_to_rad(1.0)), 0.0)
	var set_view := Vector3(cos(deg_to_rad(4.0)), sin(deg_to_rad(4.0)), 0.0)
	var sunset := AtmosphereMath.sky_radiance(atmo, t_lut, ms_lut, cam, set_view, set_sun, true, 48)
	var set_rgb: Vector3 = sunset["radiance"]
	var set_ratio: float = set_rgb.x / maxf(set_rgb.z, 1e-12)
	_check(day_ratio > 1.2, "Mars day sky is butterscotch (R/B > 1.2)",
		"(%.2f)" % day_ratio)
	_check(set_ratio < day_ratio, "Mars sunset is bluer than its day sky",
		"(sunset %.2f vs day %.2f)" % [set_ratio, day_ratio])


func _test_venus_opaque() -> void:
	print("\n== Venus is opaque ==")
	var atmo := BodyAtmosphere.venus()
	_check(atmo.opaque, "Venus declares opacity")
	var t_lut := AtmosphereMath.bake_transmittance(atmo)
	var t := AtmosphereMath.sample_transmittance(atmo, t_lut, 1.0, 1.0)
	_check(AtmosphereMath.luminance(t) < 0.1,
		"straight-down sunlight barely reaches the deck", "(T %.3f)" % AtmosphereMath.luminance(t))


func _test_proxy_contract() -> void:
	print("\n== proxy contract ==")
	# The shell hangs under PlanetSurface, so it scales through the same
	# _apply_scale -> apply_scale_ratio path as the terrain. Verify against the
	# body's own visual_radius at whatever distance the spawn put it.
	for id in [&"earth", &"mars"]:
		var body := _system.get_body(id)
		var shell := body.planet_surface().atmosphere_shell()
		var want: float = body.visual_radius() * (1.0 + body.def.atmosphere.height_fraction)
		var got: float = shell.global_transform.basis.get_scale().x
		_check(absf(got - want) / want < 0.001,
			"%s shell tracks the drawn radius (proxy %s)" % [id, body.is_proxy],
			"(%.1f m vs %.1f m)" % [got, want])


func _test_luts_reach_the_shell() -> void:
	print("\n== the shell gets its LUTs ==")
	var surface := _system.get_body(&"earth").planet_surface()
	var deadline: int = Time.get_ticks_msec() + 90000
	while not surface.atmosphere_ready and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(surface.atmosphere_ready, "Earth's atmosphere LUTs baked")
	if surface.atmosphere_ready:
		var mat: ShaderMaterial = surface.atmosphere_shell().material_override
		_check(mat.get_shader_parameter("luts_ok") == true
			and mat.get_shader_parameter("transmittance_lut") != null
			and mat.get_shader_parameter("ms_lut") != null,
			"shell material carries both LUTs")
		# Track SL4: two passes — extinction base, in-scatter next_pass, both
		# fed the same LUTs so they march the same atmosphere.
		var next := mat.next_pass as ShaderMaterial
		_check(next != null
			and next.get_shader_parameter("luts_ok") == true
			and next.get_shader_parameter("transmittance_lut") != null,
			"the in-scatter pass rides next_pass with the same LUTs")
		# Track SL5: the shell is lit from THIS body's sun.
		_check(mat.get_shader_parameter("body_sun_dir") != null,
			"the shell carries a per-body sun direction")


## Track SL3: direct sunlight filtered by the air it grazes. Constructed
## geometry, asserted through SolarSystem.sun_filter_at.
func _test_sunlight_filter() -> void:
	print("\n== direct sunlight through the atmosphere ==")
	var sun := _system.get_body(&"sun")
	var earth := _system.get_body(&"earth")
	var to_earth := Vector3(
		earth.true_pos[0] - sun.true_pos[0],
		earth.true_pos[1] - sun.true_pos[1],
		earth.true_pos[2] - sun.true_pos[2]).normalized()
	var side := to_earth.cross(Vector3.UP).normalized()

	# Behind Earth, offset so the sun ray's perigee grazes the shell low, at
	# ~1.0025 radii: an orbital sunrise through the dense air. The compressed
	# sun is close enough that rays CONVERGE, pulling the perigee inward by
	# the factor (1 - standoff/d_sun) — computed exactly so the probe rides
	# just above the ground instead of guessing at it.
	var standoff: float = earth.def.radius * 4.0
	var parallax: float = 1.0 - standoff / (earth.def.orbit_radius + standoff)
	var graze_off: float = earth.def.radius * 1.0025 / parallax
	var graze: Array = [
		earth.true_pos[0] + to_earth.x * earth.def.radius * 4.0 + side.x * graze_off,
		earth.true_pos[1] + to_earth.y * earth.def.radius * 4.0 + side.y * graze_off,
		earth.true_pos[2] + to_earth.z * earth.def.radius * 4.0 + side.z * graze_off,
	]
	var tint: Vector3 = _system.sun_filter_at(graze)
	_check(tint.x / maxf(tint.z, 1e-9) > 3.0 and tint.x < 1.0,
		"a grazing sun ray comes through gold-to-red",
		"(R %.3f B %.4f)" % [tint.x, tint.z])

	# Well clear of the shell: white, exactly.
	var clear_off: float = earth.def.radius * 1.5
	var clear_pos: Array = [
		earth.true_pos[0] + to_earth.x * earth.def.radius * 4.0 + side.x * clear_off,
		earth.true_pos[1] + to_earth.y * earth.def.radius * 4.0 + side.y * clear_off,
		earth.true_pos[2] + to_earth.z * earth.def.radius * 4.0 + side.z * clear_off,
	]
	_check(_system.sun_filter_at(clear_pos).is_equal_approx(Vector3.ONE),
		"clear of the shell the light is white")

	# The Moon has no atmosphere to filter with — behind it, still white
	# (its umbra is the eclipse term's business, not the filter's).
	var moon := _system.get_body(&"moon")
	var near_moon: Array = [
		moon.true_pos[0] + moon.def.radius * 1.6,
		moon.true_pos[1], moon.true_pos[2],
	]
	_check(_system.sun_filter_at(near_moon).is_equal_approx(Vector3.ONE),
		"airless bodies never tint the light")
