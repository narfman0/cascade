extends RefCounted
class_name SolarSystemData
## The default system layout: every body the player can fly to.
##
## Distances are compressed hard. Real Neptune is 4.5 billion km out; here the
## whole system fits inside a 2,200 km sphere so that a brachistochrone transfer
## at the ship's cruise acceleration takes tens of minutes of simulation time,
## which the autopilot's time compression turns into well under five minutes of
## the player's actual time. See docs/architecture.md, "Scale and Precision".
##
## Orbital periods are hours instead of years for the same reason: a body should
## visibly move over a session, so a destination's position — and the intercept
## the autopilot has to solve for — is never quite the same twice.
##
## Surfaces (docs/planet-renderer.md): every body except the Sun carries a
## BodySurface — relief is exaggerated (~1–3% of radius) because true-scale
## relief would be invisible at this compression. Gas giants set amplitude 0
## and get banded albedo. Spin periods are dramatized like the orbits, roughly a
## 10x-orbit feel.
##
## Earth, the Moon and Mars are the three bodies we have real data for, so they
## take authored equirect maps out of `assets/planets/` (cooked from NASA/NOAA/
## USGS rasters by tools/cook_planet_maps.py) instead of the procedural base.
## Everything else keeps the noise — the authored path is an override, not a
## requirement, and a missing map degrades to a plausible invented world rather
## than to a hole.

## Sized for the REAL 0.53-degree disc from Earth orbit (Track SL2): the old
## 20,000 m sun was 7.7 degrees across — fourteen times too wide. Angular
## size at every other planet now falls out of the compressed distances.
const SUN_RADIUS: float = 1390.0
const EARTH_RADIUS: float = 2000.0

## Where the ship spawns: metres from Earth's centre, i.e. low orbit.
const SPAWN_ALTITUDE: float = 4000.0


static func build() -> Array[BodyDef]:
	var bodies: Array[BodyDef] = []

	bodies.append(_sun())

	# --- Inner system ---
	var mercury := BodyDef.make(&"mercury", "Mercury", 900.0, &"sun",
		120000.0, 2400.0, 0.4, 0.12, Color(0.55, 0.51, 0.47),
		"No atmosphere, no cleanup contracts. Survey traffic only.")
	mercury.surface = _surf(&"mercury", 2.2, 0.7, 0.03, -1.0, _grad([
		[0.0, Color(0.33, 0.31, 0.29)], [0.5, Color(0.55, 0.51, 0.47)],
		[1.0, Color(0.70, 0.66, 0.62)]]))
	_spin(mercury, 4000.0, 0.01)
	bodies.append(mercury)

	var venus := BodyDef.make(&"venus", "Venus", 1900.0, &"sun",
		200000.0, 4000.0, 2.1, 0.06, Color(0.85, 0.78, 0.62),
		"Dense upper-atmosphere probes. Debris deorbits itself here.")
	# What you see is the cloud deck: gentle relief, banded haze.
	venus.surface = _surf(&"venus", 1.6, 0.0, 0.004, -1.0, _grad([
		[0.0, Color(0.72, 0.63, 0.46)], [0.4, Color(0.85, 0.78, 0.62)],
		[0.7, Color(0.93, 0.87, 0.72)], [1.0, Color(0.80, 0.70, 0.52)]]))
	venus.surface.band_frequency = 5.0
	venus.surface.band_wobble = 1.4
	venus.atmosphere = BodyAtmosphere.venus()
	_spin(venus, 6000.0, 0.05)
	bodies.append(venus)

	var earth := BodyDef.make(&"earth", "Earth", EARTH_RADIUS, &"sun",
		300000.0, 14400.0, 0.0, 0.0, Color(0.22, 0.42, 0.62),
		"Home lanes. Densest debris population in the system.")
	# Sea level is 0.0 because the cook puts true mean sea level at exactly the
	# encoding's zero — with real bathymetry this is a datum, not a knob. The
	# tuned -0.3 it replaces only flooded the deepest procedural basins, which is
	# why Earth's water used to read as scattered lakes.
	earth.surface = _surf(&"earth", 1.3, 0.25, 0.02, 0.0, _grad([
		[0.0, Color(0.76, 0.70, 0.50)], [0.08, Color(0.45, 0.58, 0.32)],
		[0.35, Color(0.24, 0.42, 0.20)], [0.65, Color(0.45, 0.38, 0.28)],
		[0.85, Color(0.56, 0.53, 0.49)], [1.0, Color(0.92, 0.93, 0.95)]]))
	earth.surface.city_lights = true
	_authored(earth.surface, "earth")
	# Fidelity tier: cooked ETOPO tile pyramid (L1 complete, L2 land-only) —
	# the sampler prefers the finest resident tile and falls back per lookup.
	earth.surface.height_tile_prefix = "res://assets/planets/tiles/earth_h"
	earth.surface.night_emissive = _map("earth_night")
	earth.surface.sites = [_nyc(), _canaveral()]
	earth.atmosphere = BodyAtmosphere.earth()
	earth.cloud_layer = true
	earth.cloud_coverage = 0.48
	# Real climatology (Blue Marble cloud composite): storm tracks and the
	# ITCZ cloudy, deserts clear — continents stay identifiable where a real
	# photo would show them.
	earth.cloud_map = _map("earth_clouds")
	_spin(earth, 1800.0, 0.41)
	bodies.append(earth)

	var moon := BodyDef.make(&"moon", "Moon", 550.0, &"earth",
		15000.0, 1800.0, 1.2, 0.09, Color(0.62, 0.61, 0.58),
		"Relay chain and a graveyard orbit nobody has cleared since the 40s.")
	moon.surface = _surf(&"moon", 2.6, 0.65, 0.025, -1.0, _grad([
		[0.0, Color(0.33, 0.32, 0.31)], [0.45, Color(0.55, 0.54, 0.52)],
		[1.0, Color(0.78, 0.77, 0.75)]]))
	_authored(moon.surface, "moon")
	_spin(moon, 1800.0, 0.03)   # tidally locked: spin period = orbit period
	bodies.append(moon)

	var mars := BodyDef.make(&"mars", "Mars", 1100.0, &"sun",
		450000.0, 21600.0, 3.6, 0.03, Color(0.72, 0.42, 0.30),
		"Transfer-window traffic. Abandoned insertion stages.")
	mars.surface = _surf(&"mars", 1.8, 0.6, 0.04, -1.0, _grad([
		[0.0, Color(0.42, 0.22, 0.15)], [0.4, Color(0.72, 0.42, 0.30)],
		[0.8, Color(0.85, 0.60, 0.45)], [1.0, Color(0.93, 0.84, 0.76)]]))
	_authored(mars.surface, "mars")
	mars.atmosphere = BodyAtmosphere.mars()
	_spin(mars, 1900.0, 0.44)
	bodies.append(mars)

	# --- Outer system ---
	var jupiter := BodyDef.make(&"jupiter", "Jupiter", 8000.0, &"sun",
		800000.0, 43200.0, 5.0, 0.02, Color(0.76, 0.68, 0.55),
		"Radiation belt work. Hazard pay, short shifts.")
	jupiter.surface = _banded(&"jupiter", 14.0, 1.6, _grad([
		[0.0, Color(0.58, 0.44, 0.32)], [0.25, Color(0.82, 0.72, 0.58)],
		[0.5, Color(0.93, 0.88, 0.78)], [0.7, Color(0.70, 0.53, 0.40)],
		[1.0, Color(0.87, 0.79, 0.65)]]))
	# Gas giants: no shell — the visible surface already is atmosphere. A
	# limb-softening term only (docs/planet-renderer.md, per-body table).
	jupiter.limb_darkening = 0.65
	_spin(jupiter, 900.0, 0.05)
	bodies.append(jupiter)

	var io := BodyDef.make(&"io", "Io", 480.0, &"jupiter",
		20000.0, 1200.0, 0.2, 0.04, Color(0.85, 0.78, 0.42))
	io.surface = _surf(&"io", 3.0, 0.4, 0.02, -1.0, _grad([
		[0.0, Color(0.55, 0.44, 0.18)], [0.4, Color(0.85, 0.78, 0.42)],
		[0.7, Color(0.93, 0.86, 0.55)], [1.0, Color(0.76, 0.48, 0.24)]]))
	_spin(io, 1200.0, 0.02)
	bodies.append(io)

	var europa := BodyDef.make(&"europa", "Europa", 460.0, &"jupiter",
		28000.0, 1800.0, 2.4, 0.05, Color(0.80, 0.80, 0.78),
		"Research station. They lose more equipment than they report.")
	europa.surface = _surf(&"europa", 3.5, 0.7, 0.006, -1.0, _grad([
		[0.0, Color(0.66, 0.58, 0.50)], [0.5, Color(0.82, 0.82, 0.80)],
		[1.0, Color(0.94, 0.94, 0.93)]]))
	_spin(europa, 1800.0, 0.02)
	bodies.append(europa)

	var ganymede := BodyDef.make(&"ganymede", "Ganymede", 700.0, &"jupiter",
		38000.0, 2700.0, 4.1, 0.03, Color(0.60, 0.58, 0.54))
	ganymede.surface = _surf(&"ganymede", 2.4, 0.5, 0.02, -1.0, _grad([
		[0.0, Color(0.38, 0.36, 0.33)], [0.5, Color(0.60, 0.58, 0.54)],
		[1.0, Color(0.80, 0.78, 0.74)]]))
	_spin(ganymede, 2700.0, 0.02)
	bodies.append(ganymede)

	var callisto := BodyDef.make(&"callisto", "Callisto", 660.0, &"jupiter",
		52000.0, 4200.0, 5.6, 0.06, Color(0.45, 0.42, 0.40))
	callisto.surface = _surf(&"callisto", 3.2, 0.5, 0.022, -1.0, _grad([
		[0.0, Color(0.28, 0.26, 0.24)], [0.6, Color(0.45, 0.42, 0.40)],
		[1.0, Color(0.67, 0.62, 0.57)]]))
	_spin(callisto, 4200.0, 0.02)
	bodies.append(callisto)

	var saturn := BodyDef.make(&"saturn", "Saturn", 7000.0, &"sun",
		1200000.0, 64800.0, 1.1, 0.05, Color(0.82, 0.75, 0.58),
		"Ring-plane crossings. Everything here is already debris.")
	saturn.has_rings = true
	saturn.surface = _banded(&"saturn", 10.0, 0.9, _grad([
		[0.0, Color(0.74, 0.64, 0.46)], [0.4, Color(0.88, 0.80, 0.62)],
		[0.7, Color(0.94, 0.89, 0.75)], [1.0, Color(0.80, 0.72, 0.55)]]))
	saturn.limb_darkening = 0.6
	_spin(saturn, 1000.0, 0.47)
	bodies.append(saturn)

	var titan := BodyDef.make(&"titan", "Titan", 720.0, &"saturn",
		34000.0, 3600.0, 3.0, 0.04, Color(0.72, 0.58, 0.36),
		"Atmospheric survey platforms, long rotations.")
	titan.surface = _surf(&"titan", 1.2, 0.0, 0.008, -1.0, _grad([
		[0.0, Color(0.55, 0.40, 0.22)], [0.5, Color(0.72, 0.58, 0.36)],
		[1.0, Color(0.86, 0.73, 0.48)]]))
	titan.atmosphere = BodyAtmosphere.titan()
	_spin(titan, 3600.0, 0.02)
	bodies.append(titan)

	var uranus := BodyDef.make(&"uranus", "Uranus", 4000.0, &"sun",
		1700000.0, 86400.0, 4.4, 0.08, Color(0.55, 0.75, 0.78),
		"Two derelict survey craft. Nobody has been out here in years.")
	uranus.surface = _banded(&"uranus", 4.0, 0.3, _grad([
		[0.0, Color(0.48, 0.68, 0.72)], [0.5, Color(0.55, 0.75, 0.78)],
		[1.0, Color(0.66, 0.84, 0.86)]]))
	uranus.limb_darkening = 0.5
	_spin(uranus, 1500.0, 1.71)   # rolls on its side, like the real thing
	bodies.append(uranus)

	var neptune := BodyDef.make(&"neptune", "Neptune", 3800.0, &"sun",
		2200000.0, 108000.0, 2.7, 0.07, Color(0.28, 0.42, 0.75),
		"The long haul. Bring everything you need.")
	neptune.surface = _banded(&"neptune", 6.0, 1.0, _grad([
		[0.0, Color(0.15, 0.26, 0.55)], [0.4, Color(0.28, 0.42, 0.75)],
		[0.75, Color(0.42, 0.56, 0.86)], [1.0, Color(0.72, 0.80, 0.95)]]))
	neptune.limb_darkening = 0.55
	_spin(neptune, 1400.0, 0.49)
	bodies.append(neptune)

	return bodies


static func _sun() -> BodyDef:
	# The Sun keeps its emissive sphere: no surface, no relief, no lights.
	# Near-white: space sunlight is unfiltered 5772 K. Any warm cast now comes
	# from real atmospheric transmittance (SL3/SL4), never from the source.
	var sun := BodyDef.make(&"sun", "Sun", SUN_RADIUS, &"", 0.0, 1.0, 0.0, 0.0,
		Color(1.0, 0.98, 0.95),
		"Do not plot a course here.")
	sun.emissive = true
	sun.emission_energy = 30.0
	sun.arrival_standoff_scale = 6.0
	sun.is_destination = false
	return sun


## --- Surface helpers ----------------------------------------------------------

static func _surf(
	id: StringName, freq: float, ridged: float, amp: float, sea: float,
	palette: Gradient
) -> BodySurface:
	var s := BodySurface.new()
	# Seed derives from the body id, so terrain is identical across sessions.
	s.noise_seed = int(String(id).hash() % 1000000)
	s.continent_frequency = freq
	s.ridged_mix = ridged
	s.amplitude = amp
	s.sea_level = sea
	s.palette = palette
	return s


## Gas-giant parameterization: perfectly smooth, latitude-banded albedo — the
## pipeline treats "smooth with fancy albedo" as just another surface.
static func _banded(
	id: StringName, band_frequency: float, wobble: float, palette: Gradient
) -> BodySurface:
	var s := _surf(id, 1.2, 0.0, 0.0, -1.0, palette)
	s.band_frequency = band_frequency
	s.band_wobble = wobble
	return s


## Committed coarse global maps (2048x1024 equirect, docs/assets.md §7). Missing
## files are not an error: without them the body falls back to its procedural
## parameters, which is the behaviour every other body already has.
static func _authored(surface: BodySurface, body: String) -> void:
	surface.authored_height = _map("%s_height" % body)
	surface.authored_albedo = _map("%s_albedo" % body)


static func _map(name: String) -> Texture2D:
	var path := "res://assets/planets/%s.png" % name
	if not ResourceLoader.exists(path):
		push_warning("Planet map missing: %s (run tools/cook_planet_maps.py)" % path)
		return null
	return load(path) as Texture2D


## The pilot detail site. 400 m of diorama standing in for New York — see
## docs/planet-renderer.md, "Detail sites"; the inset is real terrain and the
## buildings are miniatures, because true scale would put Manhattan inside a
## 6 m smudge.
static func _nyc() -> DetailSite:
	var site := DetailSite.make(
		&"nyc", "New York", 40.75, -73.98, 400.0,
		"Eastern seaboard traffic control. Half the LEO launches you clean up after.")
	site.height_inset = _map("nyc_height_inset")
	site.night_emissive = _map("nyc_night")
	if ResourceLoader.exists("res://scenes/sites/nyc.tscn"):
		site.scene = load("res://scenes/sites/nyc.tscn") as PackedScene
	return site


## The launch coast (PR5 site list, owner-picked). Geography identifies it —
## the cape's hook and the Banana/Indian rivers come from the real inset; the
## scene adds the VAB, the LC-39 pads, the SLF strip and Port Canaveral.
static func _canaveral() -> DetailSite:
	var site := DetailSite.make(
		&"canaveral", "Cape Canaveral", 28.55, -80.62, 400.0,
		"Launch heritage coast. Half the catalogue you clean up left from here.")
	site.height_inset = _map("canaveral_height_inset")
	site.night_emissive = _map("canaveral_night")
	if ResourceLoader.exists("res://scenes/sites/canaveral.tscn"):
		site.scene = load("res://scenes/sites/canaveral.tscn") as PackedScene
	return site


static func _spin(def: BodyDef, period: float, tilt: float) -> void:
	def.spin_period = period
	def.spin_axis_tilt = tilt


static func _grad(stops: Array) -> Gradient:
	var g := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for stop in stops:
		offsets.append(stop[0])
		colors.append(stop[1])
	g.offsets = offsets
	g.colors = colors
	return g
