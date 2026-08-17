extends Node
## SimClock — the simulation's own clock, decoupled from wall time.
##
## Everything that moves on rails (celestial bodies, orbital background objects)
## derives its position from `sim_time`, never from accumulated frame deltas.
## That makes time compression exact: multiply the clock, and the whole solar
## system fast-forwards analytically with no integration drift and no physics
## tunnelling. The autopilot uses this to compress a multi-hour transfer burn
## into under a minute of real time (see scripts/autopilot.gd).
##
## `sim_time` is a GDScript float — 64-bit — so it stays precise across long
## sessions. Do not store it in a Vector3 component or any float32 field.

signal warp_changed(factor: float)

## Simulation seconds elapsed. Bodies are positioned from this value.
var sim_time: float = 0.0

## Time compression. 1.0 = real time. The autopilot raises this during cruise
## and returns it to 1.0 on arrival or cancel.
var warp: float = 1.0:
	set(value):
		var clamped: float = clampf(value, 1.0, MAX_WARP)
		if is_equal_approx(clamped, warp):
			return
		warp = clamped
		warp_changed.emit(warp)

const MAX_WARP: float = 500.0

## True while the clock is compressed — HUD and controllers use this to know
## the player is not in direct control of a live physics burn.
var is_warping: bool:
	get:
		return warp > 1.0001


func _process(delta: float) -> void:
	sim_time += delta * warp


## Seconds of simulation that will pass in `real_seconds` at the current warp.
func sim_span(real_seconds: float) -> float:
	return real_seconds * warp


## Real seconds needed to cover `sim_seconds` at the current warp.
func real_span(sim_seconds: float) -> float:
	return sim_seconds / maxf(warp, 0.0001)


func reset_warp() -> void:
	warp = 1.0
