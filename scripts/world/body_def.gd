extends Resource
class_name BodyDef
## Definition of one celestial body. Data only — CelestialBody does the work.
##
## Scale is compressed and orbital periods are dramatised, exactly as
## docs/architecture.md permits: LEO is close, the outer system is far, and a
## Neptune run is minutes rather than decades. Orbits are circular and set by
## period rather than derived from mass — this is a game, not an ephemeris.

@export var id: StringName = &""
@export var display_name: String = ""

## Body radius in metres (render scale, compressed).
@export var radius: float = 1000.0

## `id` of the body this one orbits. Empty means it orbits the system centre.
@export var parent_id: StringName = &""

## Orbit radius in metres from the parent's centre. 0 = stationary at parent.
@export var orbit_radius: float = 0.0

## Simulation seconds for one full orbit. Dramatised: hours, not years.
@export var orbit_period: float = 3600.0

## Starting angle in radians, so the system doesn't spawn in a straight line.
@export var orbit_phase: float = 0.0

## Orbital plane tilt in radians. Small values, for visual interest.
@export var inclination: float = 0.0

@export var albedo: Color = Color(0.6, 0.6, 0.6)
@export var roughness: float = 0.85

## Self-lit (the Sun). Emissive bodies do not receive the system light.
@export var emissive: bool = false
@export var emission_energy: float = 8.0

## Draw a simple ring disc (Saturn).
@export var has_rings: bool = false
@export var ring_inner_scale: float = 1.5
@export var ring_outer_scale: float = 2.4

## Surface parameterization for the progressive planet renderer. Bodies with a
## surface get a PlanetSurface (relief, baked textures, spin); bodies without
## one (the Sun) keep the plain sphere. See docs/planet-renderer.md.
@export var surface: BodySurface = null

## Atmosphere and scattering parameters (docs/planet-renderer.md, PR4).
## null means AIRLESS and must stay visibly airless — hard terminator, black
## limb. Mercury, the Moon, Io, Europa, Ganymede and Callisto keep null on
## purpose; the gate test asserts it.
@export var atmosphere: BodyAtmosphere = null

## Gas giants: limb-softening on the surface material instead of a shell —
## their visible "surface" already is atmosphere. 0 disables.
@export var limb_darkening: float = 0.0

## Simulation seconds per rotation, dramatized like orbital periods. 0 = none.
@export var spin_period: float = 0.0

## Spin axis tilt in radians, leaning the axis from +Y about the X axis.
@export var spin_axis_tilt: float = 0.0

## Where the autopilot parks, as a multiple of `radius` from the centre.
@export var arrival_standoff_scale: float = 2.5

## Listed as an autopilot destination in the nav console.
@export var is_destination: bool = true

## Short line shown in the nav console. Flavour, not lore — keep it factual.
@export var nav_note: String = ""


static func make(
	p_id: StringName,
	p_name: String,
	p_radius: float,
	p_parent: StringName,
	p_orbit_radius: float,
	p_period: float,
	p_phase: float,
	p_inclination: float,
	p_albedo: Color,
	p_note: String = ""
) -> BodyDef:
	var d := BodyDef.new()
	d.id = p_id
	d.display_name = p_name
	d.radius = p_radius
	d.parent_id = p_parent
	d.orbit_radius = p_orbit_radius
	d.orbit_period = p_period
	d.orbit_phase = p_phase
	d.inclination = p_inclination
	d.albedo = p_albedo
	d.nav_note = p_note
	return d
