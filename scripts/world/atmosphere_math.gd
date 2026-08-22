extends RefCounted
class_name AtmosphereMath
## CPU reference implementation of the PR4 scattering model (Hillaire 2020).
##
## Three jobs, one set of formulas:
##   1. Bake the per-body LUTs (transmittance, multi-scattering) on a worker.
##   2. Mirror the atmosphere shell shader for the headless gate tests — the
##      shader and these functions must agree, which is why every mapping and
##      phase function here is written to match assets/shaders/atmosphere.gdshader
##      line for line.
##   3. Answer analytic questions (twilight width) the surface shader's night
##      gate is driven by.
##
## ALL math runs in planet-radius units: the planet surface is r = 1.0 and
## every height, scale height and coefficient in BodyAtmosphere is a fraction
## of (or per-) radius. That makes the model scale-invariant by construction —
## the "preserve the ratios, not the absolutes" rule from the design doc is
## structural, not a convention someone has to remember.

const LUM := Vector3(0.2126, 0.7152, 0.0722)


## --- Density and extinction ----------------------------------------------------

## (rayleigh, mie, ozone) density at altitude h (fraction of radius above r=1).
static func densities(atmo: BodyAtmosphere, h: float) -> Vector3:
	h = maxf(h, 0.0)
	return Vector3(
		exp(-h / atmo.rayleigh_scale_height),
		exp(-h / atmo.mie_scale_height),
		maxf(0.0, 1.0 - absf(h - atmo.ozone_center) / atmo.ozone_width)
	)


static func extinction(atmo: BodyAtmosphere, h: float) -> Vector3:
	var d := densities(atmo, h)
	return atmo.rayleigh_coefficients * d.x \
		+ (atmo.mie_coefficient + atmo.mie_absorption) * d.y \
		+ atmo.ozone_absorption * d.z


static func scattering(atmo: BodyAtmosphere, h: float) -> Vector3:
	var d := densities(atmo, h)
	return atmo.rayleigh_coefficients * d.x + atmo.mie_coefficient * d.y


## --- Ray geometry (planet centre at origin, radius 1) --------------------------

## Distance along (r, mu) to the atmosphere top boundary. mu is the cosine of
## the angle between the ray and the local zenith. Finite at grazing incidence
## by construction — the sqrt argument reaches its minimum top^2 - r^2 >= 0.
static func dist_to_top(r: float, mu: float, top: float) -> float:
	var disc := r * r * (mu * mu - 1.0) + top * top
	return maxf(0.0, -r * mu + sqrt(maxf(disc, 0.0)))


## Distance to the ground sphere, or -1.0 if the ray misses it.
static func dist_to_ground(r: float, mu: float) -> float:
	if mu >= 0.0:
		return -1.0
	var disc := r * r * (mu * mu - 1.0) + 1.0
	if disc < 0.0:
		return -1.0
	return maxf(0.0, -r * mu - sqrt(disc))


## Cosine of the zenith angle of the horizon seen from radius r.
static func horizon_mu(r: float) -> float:
	return -sqrt(maxf(r * r - 1.0, 0.0)) / r


## --- Transmittance -------------------------------------------------------------

## Optical depth from radius r along direction mu to the top of the atmosphere.
static func optical_depth(atmo: BodyAtmosphere, r: float, mu: float, steps: int = 40) -> Vector3:
	var top := 1.0 + atmo.height_fraction
	var t_max := dist_to_top(r, mu, top)
	var dt := t_max / float(steps)
	var tau := Vector3.ZERO
	for i in steps:
		var t := (float(i) + 0.5) * dt
		# |p + dir*t| for p=(0,r,0), dir=(sin,cos matched to mu): closed form.
		var rr := sqrt(maxf(r * r + t * t + 2.0 * r * mu * t, 0.0))
		tau += extinction(atmo, rr - 1.0) * dt
	return tau


static func transmittance(atmo: BodyAtmosphere, r: float, mu: float, steps: int = 40) -> Vector3:
	var tau := optical_depth(atmo, r, mu, steps)
	return Vector3(exp(-tau.x), exp(-tau.y), exp(-tau.z))


## --- Transmittance LUT (Bruneton mapping, unit radius) --------------------------
## u encodes distance-to-boundary between its geometric min and max, v encodes
## rho/H — the standard non-linear mapping that keeps precision at the horizon,
## where the limb lives. Covers rays that do NOT hit the ground; sun visibility
## below the horizon is a separate analytic test (the planetary shadow).

static func lut_uv_from_r_mu(atmo: BodyAtmosphere, r: float, mu: float) -> Vector2:
	var top := 1.0 + atmo.height_fraction
	var big_h := sqrt(maxf(top * top - 1.0, 1e-12))
	var rho := sqrt(maxf(r * r - 1.0, 0.0))
	var d := dist_to_top(r, mu, top)
	var d_min := top - r
	var d_max := rho + big_h
	var u := clampf((d - d_min) / maxf(d_max - d_min, 1e-12), 0.0, 1.0)
	return Vector2(u, clampf(rho / big_h, 0.0, 1.0))


static func lut_r_mu_from_uv(atmo: BodyAtmosphere, uv: Vector2) -> Vector2:
	var top := 1.0 + atmo.height_fraction
	var big_h := sqrt(maxf(top * top - 1.0, 1e-12))
	var rho := uv.y * big_h
	var r := sqrt(rho * rho + 1.0)
	var d_min := top - r
	var d_max := rho + big_h
	var d := d_min + uv.x * (d_max - d_min)
	var mu := 1.0
	if d > 1e-9:
		mu = clampf((big_h * big_h - rho * rho - d * d) / (2.0 * r * d), -1.0, 1.0)
	return Vector2(r, mu)


## Bake the transmittance LUT. Returns {"data": PackedFloat32Array (RGB
## triplets), "w": int, "h": int}. Worker-safe: touches no scene state.
static func bake_transmittance(atmo: BodyAtmosphere, w: int = 256, h: int = 64) -> Dictionary:
	var data := PackedFloat32Array()
	data.resize(w * h * 3)
	for y in h:
		var v := (float(y) + 0.5) / float(h)
		for x in w:
			var u := (float(x) + 0.5) / float(w)
			var rm := lut_r_mu_from_uv(atmo, Vector2(u, v))
			var t := transmittance(atmo, rm.x, rm.y)
			var i := (y * w + x) * 3
			data[i] = t.x
			data[i + 1] = t.y
			data[i + 2] = t.z
	return {"data": data, "w": w, "h": h}


## Bilinear sample of a baked LUT dict at (r, mu) — the CPU twin of the
## shader's texture() call.
static func sample_transmittance(atmo: BodyAtmosphere, lut: Dictionary, r: float, mu: float) -> Vector3:
	var uv := lut_uv_from_r_mu(atmo, r, mu)
	return _bilinear(lut, uv)


static func _bilinear(lut: Dictionary, uv: Vector2) -> Vector3:
	var w: int = lut["w"]
	var h: int = lut["h"]
	var data: PackedFloat32Array = lut["data"]
	var fx := clampf(uv.x * float(w) - 0.5, 0.0, float(w - 1))
	var fy := clampf(uv.y * float(h) - 0.5, 0.0, float(h - 1))
	var x0 := int(fx)
	var y0 := int(fy)
	var x1 := mini(x0 + 1, w - 1)
	var y1 := mini(y0 + 1, h - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var p00 := _texel(data, w, x0, y0)
	var p10 := _texel(data, w, x1, y0)
	var p01 := _texel(data, w, x0, y1)
	var p11 := _texel(data, w, x1, y1)
	return p00.lerp(p10, tx).lerp(p01.lerp(p11, tx), ty)


static func _texel(data: PackedFloat32Array, w: int, x: int, y: int) -> Vector3:
	var i := (y * w + x) * 3
	return Vector3(data[i], data[i + 1], data[i + 2])


## --- Multi-scattering LUT (Hillaire 2020 §5.5.2) --------------------------------
## psi_ms(mu_s, h): the dual-scattering approximation of orders 2..inf, assuming
## isotropic phase for the higher orders. x axis: sun zenith cosine mapped
## 0..1; y axis: altitude 0..height_fraction.

static func bake_multi_scatter(
	atmo: BodyAtmosphere, t_lut: Dictionary, n: int = 32,
	dirs: int = 32, steps: int = 12
) -> Dictionary:
	var data := PackedFloat32Array()
	data.resize(n * n * 3)
	var sphere := _sphere_dirs(dirs)
	var top := 1.0 + atmo.height_fraction
	var p_iso := 1.0 / (4.0 * PI)
	for y in n:
		var h := ((float(y) + 0.5) / float(n)) * atmo.height_fraction
		var r := 1.0 + h
		for x in n:
			var mu_s := ((float(x) + 0.5) / float(n)) * 2.0 - 1.0
			var sun := Vector3(sqrt(maxf(1.0 - mu_s * mu_s, 0.0)), mu_s, 0.0)
			var p0 := Vector3(0.0, r, 0.0)
			var l2 := Vector3.ZERO
			var f_ms := Vector3.ZERO
			for dir in sphere:
				var mu := dir.y   # cos to zenith at p0
				var t_ground := dist_to_ground(r, mu)
				var hits_ground := t_ground >= 0.0
				var t_max := t_ground if hits_ground else dist_to_top(r, mu, top)
				if t_max <= 1e-9:
					continue
				var dt := t_max / float(steps)
				var tau := Vector3.ZERO
				for i in steps:
					var t := (float(i) + 0.5) * dt
					var pos := p0 + dir * t
					var rr := pos.length()
					var hh := rr - 1.0
					var ext := extinction(atmo, hh)
					var t_view := (-(tau + ext * dt * 0.5)).clamp(
						Vector3.ONE * -60.0, Vector3.ZERO)
					t_view = Vector3(exp(t_view.x), exp(t_view.y), exp(t_view.z))
					tau += ext * dt
					var sca := scattering(atmo, hh)
					var mu_sun_here := pos.dot(sun) / rr
					var t_sun := Vector3.ZERO
					if mu_sun_here >= horizon_mu(rr):
						t_sun = sample_transmittance(atmo, t_lut, rr, mu_sun_here)
					# Hillaire's reference: the radiance term carries the uniform
					# phase; the energy-transfer term f_ms does not.
					l2 += t_view * sca * t_sun * p_iso * dt
					f_ms += t_view * sca * dt
				if hits_ground:
					# Ground bounce: sunlit albedo seen through the path.
					var pg := p0 + dir * t_max
					var upg := pg.normalized()
					var mu_g := upg.dot(sun)
					if mu_g > 0.0:
						var t_path := Vector3(exp(-tau.x), exp(-tau.y), exp(-tau.z))
						var t_sun_g := sample_transmittance(atmo, t_lut, 1.0, mu_g)
						var alb := Vector3(
							atmo.ground_albedo_tint.r, atmo.ground_albedo_tint.g,
							atmo.ground_albedo_tint.b)
						# Lambert ground: albedo/pi carries the BRDF's own norm;
						# the final /dirs below is the sphere average.
						l2 += t_path * t_sun_g * alb * (mu_g / PI)
			l2 /= float(dirs)
			f_ms /= float(dirs)
			var psi := Vector3(
				l2.x / maxf(1.0 - f_ms.x, 1e-4),
				l2.y / maxf(1.0 - f_ms.y, 1e-4),
				l2.z / maxf(1.0 - f_ms.z, 1e-4)
			)
			var idx := (y * n + x) * 3
			data[idx] = psi.x
			data[idx + 1] = psi.y
			data[idx + 2] = psi.z
	return {"data": data, "w": n, "h": n}


static func sample_multi_scatter(atmo: BodyAtmosphere, ms_lut: Dictionary, h: float, mu_s: float) -> Vector3:
	var uv := Vector2(
		clampf(mu_s * 0.5 + 0.5, 0.0, 1.0),
		clampf(h / atmo.height_fraction, 0.0, 1.0)
	)
	return _bilinear(ms_lut, uv)


static func _sphere_dirs(n: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var ga := PI * (3.0 - sqrt(5.0))
	for i in n:
		var y := 1.0 - 2.0 * (float(i) + 0.5) / float(n)
		var rad := sqrt(maxf(0.0, 1.0 - y * y))
		var th := ga * float(i)
		out.append(Vector3(cos(th) * rad, y, sin(th) * rad))
	return out


## --- Phase functions ------------------------------------------------------------

static func rayleigh_phase(c: float) -> float:
	return 3.0 / (16.0 * PI) * (1.0 + c * c)


## Cornette-Shanks, per channel — mie_g is a Vector3 so bodies like Mars can
## push blue into a tighter forward lobe than red (that differential is what
## makes the Martian sunset blue while its day sky stays butterscotch).
static func cornette_shanks_phase(c: float, g: Vector3) -> Vector3:
	var out := Vector3.ZERO
	for i in 3:
		var gg := g[i]
		var g2 := gg * gg
		var den := (2.0 + g2) * pow(maxf(1.0 + g2 - 2.0 * gg * c, 1e-6), 1.5)
		out[i] = 3.0 / (8.0 * PI) * ((1.0 - g2) * (1.0 + c * c)) / den
	return out


## --- Sky radiance (the shader's march, mirrored for tests) ----------------------

## In-scattered radiance seen from `cam` (planet units) along `view`, sun toward
## `sun`. Returns {"radiance": Vector3, "transmittance": Vector3}. `use_ms`
## false disables the psi_ms term — the test that proves multiple scattering is
## actually contributing flips exactly this switch.
static func sky_radiance(
	atmo: BodyAtmosphere, t_lut: Dictionary, ms_lut: Dictionary,
	cam: Vector3, view: Vector3, sun: Vector3,
	use_ms: bool = true, steps: int = 40
) -> Dictionary:
	var top := 1.0 + atmo.height_fraction
	var o := cam
	var b := o.dot(view)
	var c_top := o.dot(o) - top * top
	var disc := b * b - c_top
	if disc < 0.0:
		return {"radiance": Vector3.ZERO, "transmittance": Vector3.ONE}
	var t0 := maxf(-b - sqrt(disc), 0.0)
	var t1 := -b + sqrt(disc)
	var c_g := o.dot(o) - 1.0
	var disc_g := b * b - c_g
	if disc_g >= 0.0:
		var tg := -b - sqrt(disc_g)
		if tg > 0.0:
			t1 = minf(t1, tg)
	if t1 - t0 <= 1e-9:
		return {"radiance": Vector3.ZERO, "transmittance": Vector3.ONE}

	var dt := (t1 - t0) / float(steps)
	var cos_theta := view.dot(sun)
	var pr := rayleigh_phase(cos_theta)
	var pm := cornette_shanks_phase(cos_theta, atmo.mie_g)
	var tau := Vector3.ZERO
	var radiance := Vector3.ZERO
	for i in steps:
		var t := t0 + (float(i) + 0.5) * dt
		var pos := o + view * t
		var r := pos.length()
		var h := maxf(r - 1.0, 0.0)
		var d := densities(atmo, h)
		var s_r := atmo.rayleigh_coefficients * d.x
		var s_m := atmo.mie_coefficient * d.y
		var ext := s_r + s_m + atmo.mie_absorption * d.y + atmo.ozone_absorption * d.z
		var half_tau := tau + ext * dt * 0.5
		var t_view := Vector3(
			exp(-minf(half_tau.x, 60.0)), exp(-minf(half_tau.y, 60.0)),
			exp(-minf(half_tau.z, 60.0)))
		tau += ext * dt
		var mu_s := pos.dot(sun) / r
		var t_sun := Vector3.ZERO
		if mu_s >= horizon_mu(r):
			t_sun = sample_transmittance(atmo, t_lut, r, mu_s)
		var step_l := t_sun * (s_r * pr + s_m * pm)
		if use_ms:
			step_l += sample_multi_scatter(atmo, ms_lut, h, mu_s) * (s_r + s_m)
		radiance += t_view * step_l * dt
	radiance *= atmo.sun_intensity
	var t_total := Vector3(
		exp(-minf(tau.x, 60.0)), exp(-minf(tau.y, 60.0)), exp(-minf(tau.z, 60.0)))
	return {"radiance": radiance, "transmittance": t_total}


## --- Colour helpers (tests) ------------------------------------------------------

static func luminance(v: Vector3) -> float:
	return v.dot(LUM)


## Linear sRGB -> CIE xy chromaticity.
static func chromaticity(rgb: Vector3) -> Vector2:
	var x := 0.4124 * rgb.x + 0.3576 * rgb.y + 0.1805 * rgb.z
	var y := 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
	var z := 0.0193 * rgb.x + 0.1192 * rgb.y + 0.9505 * rgb.z
	var sum := x + y + z
	if sum < 1e-9:
		return Vector2.ZERO
	return Vector2(x / sum, y / sum)
