class_name OrbitMath
## Closed-form circular orbit, plane tilted about X — the one orbit model every
## on-rails object in the system shares (planets, moons, stations).
##
## Everything is a function of simulation time, never integrated: that is what
## lets the autopilot ask where a target *will be* at arrival, and what lets
## time compression skip ahead with no drift. Results are 64-bit [x, y, z]
## arrays (true space) — see OriginShift for why Vector3 is not enough.


## Offset from the orbited parent's centre at simulation time `t`.
static func offset_at(
	t: float, radius: float, period: float, phase: float, inclination: float
) -> Array:
	if radius <= 0.0:
		return [0.0, 0.0, 0.0]
	var w: float = TAU / maxf(period, 0.001)
	var a: float = phase + w * t
	var x: float = cos(a) * radius
	var z_flat: float = sin(a) * radius
	# Tilt the orbital plane about the X axis.
	var y: float = sin(inclination) * z_flat
	var z: float = cos(inclination) * z_flat
	return [x, y, z]


## Velocity of that offset at `t`, m/s — the exact derivative of `offset_at`,
## which the travel test verifies numerically.
static func velocity_offset_at(
	t: float, radius: float, period: float, phase: float, inclination: float
) -> Array:
	if radius <= 0.0:
		return [0.0, 0.0, 0.0]
	var w: float = TAU / maxf(period, 0.001)
	var a: float = phase + w * t
	var dx: float = -sin(a) * radius * w
	var dz_flat: float = cos(a) * radius * w
	var dy: float = sin(inclination) * dz_flat
	var dz: float = cos(inclination) * dz_flat
	return [dx, dy, dz]
