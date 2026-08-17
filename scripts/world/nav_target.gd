class_name NavTarget extends Node3D
## Anything the autopilot can fly to and flight assist can hold station against.
##
## GDScript has no interfaces, so this base class is the honest version: the
## overridable set below is exactly what the transfer math and the reference
## frame rule consume. CelestialBody and OrbitalStation both extend it; NPC
## ships would too, if they land. The autopilot, nav console, and
## SolarSystem.reference_body() must only ever touch targets through these
## methods — reaching into a subclass's def defeats the point.

## True-space position, refreshed once per frame by whoever drives this target
## (SolarSystem). Cached so reference-frame queries don't recompute the whole
## parent chain per candidate per frame.
var true_pos: Array = [0.0, 0.0, 0.0]


## True-space position at simulation time `t`, as 64-bit [x, y, z].
func position_at(_t: float) -> Array:
	return [0.0, 0.0, 0.0]


## True-space velocity at simulation time `t`, in m/s.
func velocity_at(_t: float) -> Array:
	return [0.0, 0.0, 0.0]


## Distance from the target's centre the autopilot parks at.
func arrival_standoff() -> float:
	return 100.0


## How far this target's reference frame reaches. Zero means it never owns one.
func influence_radius() -> float:
	return 0.0


## Orbital-hierarchy depth for the deepest-wins reference rule: a station
## orbiting Earth is deeper than Earth, so it wins close in.
func frame_depth() -> int:
	return 0


func nav_display_name() -> String:
	return String(name)


## Short line shown in the nav console footer. Flavour, not lore.
func nav_note() -> String:
	return ""


## Listed as an autopilot destination in the nav console.
func is_nav_destination() -> bool:
	return true
