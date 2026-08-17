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

const SUN_RADIUS: float = 20000.0
const EARTH_RADIUS: float = 2000.0

## Where the ship spawns: metres from Earth's centre, i.e. low orbit.
const SPAWN_ALTITUDE: float = 4000.0


static func build() -> Array[BodyDef]:
	var bodies: Array[BodyDef] = []

	bodies.append(_sun())

	# --- Inner system ---
	bodies.append(BodyDef.make(&"mercury", "Mercury", 900.0, &"sun",
		120000.0, 2400.0, 0.4, 0.12, Color(0.55, 0.51, 0.47),
		"No atmosphere, no cleanup contracts. Survey traffic only."))
	bodies.append(BodyDef.make(&"venus", "Venus", 1900.0, &"sun",
		200000.0, 4000.0, 2.1, 0.06, Color(0.85, 0.78, 0.62),
		"Dense upper-atmosphere probes. Debris deorbits itself here."))

	var earth := BodyDef.make(&"earth", "Earth", EARTH_RADIUS, &"sun",
		300000.0, 14400.0, 0.0, 0.0, Color(0.22, 0.42, 0.62),
		"Home lanes. Densest debris population in the system.")
	bodies.append(earth)
	bodies.append(BodyDef.make(&"moon", "Moon", 550.0, &"earth",
		15000.0, 1800.0, 1.2, 0.09, Color(0.62, 0.61, 0.58),
		"Relay chain and a graveyard orbit nobody has cleared since the 40s."))

	bodies.append(BodyDef.make(&"mars", "Mars", 1100.0, &"sun",
		450000.0, 21600.0, 3.6, 0.03, Color(0.72, 0.42, 0.30),
		"Transfer-window traffic. Abandoned insertion stages."))

	# --- Outer system ---
	var jupiter := BodyDef.make(&"jupiter", "Jupiter", 8000.0, &"sun",
		800000.0, 43200.0, 5.0, 0.02, Color(0.76, 0.68, 0.55),
		"Radiation belt work. Hazard pay, short shifts.")
	bodies.append(jupiter)
	bodies.append(BodyDef.make(&"io", "Io", 480.0, &"jupiter",
		20000.0, 1200.0, 0.2, 0.04, Color(0.85, 0.78, 0.42)))
	bodies.append(BodyDef.make(&"europa", "Europa", 460.0, &"jupiter",
		28000.0, 1800.0, 2.4, 0.05, Color(0.80, 0.80, 0.78),
		"Research station. They lose more equipment than they report."))
	bodies.append(BodyDef.make(&"ganymede", "Ganymede", 700.0, &"jupiter",
		38000.0, 2700.0, 4.1, 0.03, Color(0.60, 0.58, 0.54)))
	bodies.append(BodyDef.make(&"callisto", "Callisto", 660.0, &"jupiter",
		52000.0, 4200.0, 5.6, 0.06, Color(0.45, 0.42, 0.40)))

	var saturn := BodyDef.make(&"saturn", "Saturn", 7000.0, &"sun",
		1200000.0, 64800.0, 1.1, 0.05, Color(0.82, 0.75, 0.58),
		"Ring-plane crossings. Everything here is already debris.")
	saturn.has_rings = true
	bodies.append(saturn)
	bodies.append(BodyDef.make(&"titan", "Titan", 720.0, &"saturn",
		34000.0, 3600.0, 3.0, 0.04, Color(0.72, 0.58, 0.36),
		"Atmospheric survey platforms, long rotations."))

	bodies.append(BodyDef.make(&"uranus", "Uranus", 4000.0, &"sun",
		1700000.0, 86400.0, 4.4, 0.08, Color(0.55, 0.75, 0.78),
		"Two derelict survey craft. Nobody has been out here in years."))
	bodies.append(BodyDef.make(&"neptune", "Neptune", 3800.0, &"sun",
		2200000.0, 108000.0, 2.7, 0.07, Color(0.28, 0.42, 0.75),
		"The long haul. Bring everything you need."))

	return bodies


static func _sun() -> BodyDef:
	var sun := BodyDef.make(&"sun", "Sun", SUN_RADIUS, &"", 0.0, 1.0, 0.0, 0.0,
		Color(1.0, 0.93, 0.75),
		"Do not plot a course here.")
	sun.emissive = true
	sun.emission_energy = 12.0
	sun.arrival_standoff_scale = 6.0
	sun.is_destination = false
	return sun
