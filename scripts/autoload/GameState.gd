extends Node
## GameState — global session state.
##
## Responsibility (per architecture.md): current phase, active contract handle,
## session stats, current input_mode, and the flight_assist_enabled toggle.
## Exactly one controller processes input at a time, gated on input_mode.

enum InputMode { SHIP_FLIGHT, EVA, INTERIOR, FOCUSED }

signal flight_assist_changed(enabled: bool)
signal input_mode_changed(mode: InputMode)
signal autopilot_active_changed(active: bool)

var flight_assist_enabled: bool = true:
	set(value):
		if value == flight_assist_enabled:
			return
		flight_assist_enabled = value
		flight_assist_changed.emit(flight_assist_enabled)

var input_mode: InputMode = InputMode.SHIP_FLIGHT:
	set(value):
		if value == input_mode:
			return
		input_mode = value
		input_mode_changed.emit(input_mode)


## True while the destination autopilot is flying the ship. Manual controllers
## stand down; the autopilot owns attitude, position, and the clock.
var autopilot_active: bool = false:
	set(value):
		if value == autopilot_active:
			return
		autopilot_active = value
		autopilot_active_changed.emit(autopilot_active)


func toggle_flight_assist() -> void:
	flight_assist_enabled = not flight_assist_enabled
