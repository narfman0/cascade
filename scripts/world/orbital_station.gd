class_name OrbitalStation extends NavTarget
## A dockable station on analytic rails around a celestial body.
##
## Position and velocity are closed-form functions of SimClock.sim_time — the
## parent body's analytic position plus a shared-orbit-math offset — so the
## station survives time compression and the autopilot intercepts it exactly
## like a moon. SolarSystem drives `update_render` every frame once the station
## is registered; render position is always recomputed from true space, so this
## node must NOT join the `origin_shiftable` group or it gets shifted twice.
##
## While a ship is docked it is parented under this station's DockingPort, so
## it inherits every recompute through the tree — that is the whole docked
## state, no joint involved. See docking_computer.gd.

@export var def: StationDef

var parent_body: CelestialBody = null


## Resolve the parent body. Called by SolarSystem.register_station — never from
## `_ready`, which runs before the render origin exists (bootstrap rule).
func setup(system: SolarSystem) -> void:
	if def == null:
		push_error("OrbitalStation '%s' has no StationDef." % name)
		return
	parent_body = system.get_body(def.parent_id)
	if parent_body == null:
		push_error("OrbitalStation '%s': parent body '%s' not found." % [name, def.parent_id])


## --- Analytic position -------------------------------------------------------

func position_at(t: float) -> Array:
	var base: Array = [0.0, 0.0, 0.0]
	if parent_body != null:
		base = parent_body.position_at(t)
	var off: Array = OrbitMath.offset_at(
		t, def.orbit_radius, def.orbit_period, def.orbit_phase, def.inclination
	)
	return [base[0] + off[0], base[1] + off[1], base[2] + off[2]]


func velocity_at(t: float) -> Array:
	var base: Array = [0.0, 0.0, 0.0]
	if parent_body != null:
		base = parent_body.velocity_at(t)
	var off: Array = OrbitMath.velocity_offset_at(
		t, def.orbit_radius, def.orbit_period, def.orbit_phase, def.inclination
	)
	return [base[0] + off[0], base[1] + off[1], base[2] + off[2]]


## Current velocity as a render-space vector. Safe: orbital speeds are small
## even though positions are not.
func render_velocity() -> Vector3:
	var v: Array = velocity_at(SimClock.sim_time)
	return Vector3(float(v[0]), float(v[1]), float(v[2]))


## --- Rendering ---------------------------------------------------------------

## Refresh cached true position and place the station in render space. A station
## is only tens of metres across, so it needs no far-field proxy — past a few
## kilometres it is subpixel anyway.
func update_render(t: float) -> void:
	true_pos = position_at(t)
	global_position = OriginShift.to_render(true_pos)


## --- NavTarget ---------------------------------------------------------------

func arrival_standoff() -> float:
	return def.standoff


func influence_radius() -> float:
	return def.influence


## One deeper than the parent, so the deepest-wins reference rule resolves the
## station over its planet close in — no special cases.
func frame_depth() -> int:
	if parent_body == null:
		return 1
	return parent_body.frame_depth() + 1


func nav_display_name() -> String:
	return def.display_name


func nav_note() -> String:
	return def.nav_note
