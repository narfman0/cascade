extends Resource
class_name BodyAtmosphere
## Per-body atmosphere parameters (docs/planet-renderer.md, "Atmosphere and
## scattering"). Data only — the model lives in AtmosphereMath and
## assets/shaders/atmosphere.gdshader.
##
## EVERY length here is a fraction of the body's radius and every coefficient
## is per-radius. That is the scale trap made structural: real Earth's 8.5 km
## Rayleigh scale height enters as 8.5/6371 = 0.00133 and works identically on
## a 2,000 m planet. Nothing in this resource is in metres, so nothing can be
## accidentally authored at real scale.
##
## A body with NO atmosphere sets `BodyDef.atmosphere = null` — and must stay
## that way. The Moon's razor terminator and black limb are a real visual
## signature; airless bodies looking airless is a PR4 gate assertion.

## Shell top as a fraction of radius. The dense air lives in the bottom ~1-2%;
## the shell extends a little past it so the limb falloff has room to breathe.
@export var height_fraction: float = 0.025

## Rayleigh scattering at zero altitude, per radius, per channel.
## Earth reference: (5.802, 13.558, 33.1)e-6 /m x 6.371e6 m = (37.0, 86.4, 210.9).
@export var rayleigh_coefficients: Vector3 = Vector3(37.0, 86.4, 210.9)

## Rayleigh scale height / radius. Earth: 8.5 km / 6371 km.
@export var rayleigh_scale_height: float = 0.00133

## Mie scattering per radius, per channel — chromatic so dusty skies can tint.
@export var mie_coefficient: Vector3 = Vector3(25.4, 25.4, 25.4)

## Mie absorption per radius, per channel.
@export var mie_absorption: Vector3 = Vector3(2.8, 2.8, 2.8)

## Mie scale height / radius. Earth: 1.2 km / 6371 km.
@export var mie_scale_height: float = 0.00019

## Cornette-Shanks forward-scatter anisotropy, per channel. Mars pushes blue
## into a tighter forward lobe than red — that differential is the blue sunset.
@export var mie_g: Vector3 = Vector3(0.76, 0.76, 0.76)

## Ozone: pure absorption, no scattering, tent profile. This is what turns
## twilight deep blue instead of muddy grey.
## Earth reference: (0.650, 1.881, 0.085)e-6 /m x 6.371e6 m.
@export var ozone_absorption: Vector3 = Vector3.ZERO

## Tent profile centre / half-width as fractions of radius (Earth: ~25 km peak,
## ~15 km half-width).
@export var ozone_center: float = 0.0039
@export var ozone_width: float = 0.0024

## Radiance scale for the in-scatter integral, tuned against the scene's
## tonemap the same way the sun light's energy was.
@export var sun_intensity: float = 25.0

## Ground bounce colour for the multi-scattering LUT.
@export var ground_albedo_tint: Color = Color(0.3, 0.3, 0.3)

## Sky colour used for the near-body ambient fill (the PR4 stretch that
## replaces the flat ambient fudge).
@export var ambient_sky_color: Color = Color(0.45, 0.62, 0.95)

## Venus: optical depth so high the surface is never visible. Kept as intent
## and asserted by the gate test; the look itself comes from the coefficients.
@export var opaque: bool = false


## --- Derived: twilight geometry -------------------------------------------------

## Angular half-width of the twilight band, in radians: the sun depression at
## which the last visibly-scattering air above the observer leaves sunlight.
## Air stops mattering ~6 scale heights up (density e^-6), so the lit-sky
## height is min(shell top, 6H) and the band is acos(R / (R + h_lit)) — pure
## geometry from scale height and radius, exactly what the design doc asks the
## city-light gate to be driven by.
func twilight_angle() -> float:
	var h_lit: float = minf(
		height_fraction,
		6.0 * maxf(rayleigh_scale_height, mie_scale_height)
	)
	return acos(1.0 / (1.0 + maxf(h_lit, 1e-6)))


## The surface shader's night-lights gate, as (lo, hi) thresholds on
## dot(normal, sun_direction): lights start fading in as the sun nears the
## horizon and are fully on once the sky itself has gone dark.
func night_gate() -> Vector2:
	var tw := twilight_angle()
	return Vector2(sin(-tw), sin(0.25 * tw))


## --- Factories (SolarSystemData) -------------------------------------------------

static func earth() -> BodyAtmosphere:
	var a := BodyAtmosphere.new()
	# Real-Earth ratios throughout; see the per-field docs for the arithmetic.
	a.height_fraction = 0.025
	a.rayleigh_coefficients = Vector3(37.0, 86.4, 210.9)
	a.rayleigh_scale_height = 0.00133
	a.mie_coefficient = Vector3(25.4, 25.4, 25.4)
	a.mie_absorption = Vector3(2.8, 2.8, 2.8)
	a.mie_scale_height = 0.00019
	a.mie_g = Vector3(0.76, 0.76, 0.76)
	a.ozone_absorption = Vector3(4.14, 11.98, 0.54)
	a.ozone_center = 0.0039
	a.ozone_width = 0.0024
	a.sun_intensity = 25.0
	a.ground_albedo_tint = Color(0.25, 0.3, 0.35)
	a.ambient_sky_color = Color(0.45, 0.62, 0.95)
	return a


static func venus() -> BodyAtmosphere:
	var a := BodyAtmosphere.new()
	# Thick, yellow-white, opaque. Our rendered "surface" is already the cloud
	# deck, so the shell's job is the deep haze above it: high Mie optical
	# depth, mild blue absorption for the sulphuric cream colour.
	a.height_fraction = 0.045
	a.rayleigh_coefficients = Vector3(8.0, 18.0, 44.0)
	a.rayleigh_scale_height = 0.0025
	a.mie_coefficient = Vector3(820.0, 780.0, 640.0)
	a.mie_absorption = Vector3(8.0, 26.0, 120.0)
	a.mie_scale_height = 0.004
	a.mie_g = Vector3(0.72, 0.72, 0.72)
	a.sun_intensity = 16.0
	a.ground_albedo_tint = Color(0.6, 0.55, 0.4)
	a.ambient_sky_color = Color(0.93, 0.86, 0.66)
	a.opaque = true
	return a


static func mars() -> BodyAtmosphere:
	var a := BodyAtmosphere.new()
	# Thin and dusty: negligible Rayleigh, chromatic Mie. Red scatters more
	# than blue (butterscotch day sky), blue is absorbed along long paths but
	# forward-scatters in a tighter lobe (per-channel g) — so the sky near the
	# setting sun goes blue while the day sky stays tan: Earth inverted.
	a.height_fraction = 0.03
	a.rayleigh_coefficients = Vector3(1.2, 2.8, 6.6)
	a.rayleigh_scale_height = 0.0033
	a.mie_coefficient = Vector3(130.0, 80.0, 42.0)
	a.mie_absorption = Vector3(4.0, 18.0, 52.0)
	a.mie_scale_height = 0.0033
	a.mie_g = Vector3(0.74, 0.80, 0.90)
	a.sun_intensity = 28.0
	a.ground_albedo_tint = Color(0.5, 0.32, 0.2)
	a.ambient_sky_color = Color(0.85, 0.62, 0.4)
	return a


static func titan() -> BodyAtmosphere:
	var a := BodyAtmosphere.new()
	# Deep orange photochemical haze, strongly forward-scattering, extended —
	# Titan's atmosphere is famously tall relative to the body.
	a.height_fraction = 0.08
	a.rayleigh_coefficients = Vector3(4.0, 9.0, 22.0)
	a.rayleigh_scale_height = 0.008
	a.mie_coefficient = Vector3(420.0, 260.0, 110.0)
	a.mie_absorption = Vector3(10.0, 40.0, 130.0)
	a.mie_scale_height = 0.015
	a.mie_g = Vector3(0.68, 0.70, 0.74)
	a.sun_intensity = 18.0
	a.ground_albedo_tint = Color(0.45, 0.35, 0.2)
	a.ambient_sky_color = Color(0.86, 0.64, 0.32)
	return a
