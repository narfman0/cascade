class_name StationDef extends Resource
## Definition of one orbital station. Data only — OrbitalStation does the work.
##
## Same orbital elements as BodyDef because stations ride the same analytic
## rails as moons: position is a closed-form function of SimClock.sim_time, so
## stations work under time compression and the autopilot can intercept them
## exactly like a body.

@export var id: StringName = &""
@export var display_name: String = ""

## `id` of the celestial body this station orbits.
@export var parent_id: StringName = &"earth"

## Orbit radius in metres from the parent body's centre.
@export var orbit_radius: float = 9000.0

## Simulation seconds for one full orbit.
@export var orbit_period: float = 2200.0

## Starting angle in radians.
@export var orbit_phase: float = 0.0

## Orbital plane tilt in radians.
@export var inclination: float = 0.0

## Short line shown in the nav console. Flavour, not lore — keep it factual.
@export var nav_note: String = ""

## Where the autopilot parks, metres from the station origin.
@export var standoff: float = 200.0

## Reference-frame reach. Small: inside it flight assist holds station in the
## station's frame — the docking prerequisite.
@export var influence: float = 2000.0
