extends Resource
class_name EVAThrusterFuel
## Suit MMU propellant tank. Consumed on any thrust (including FA counter-thrust).

signal low_fuel
signal critical_fuel
signal depleted
signal fuel_changed(remaining: float, capacity: float)

@export var capacity: float = 8000.0
@export var consumption_rate: float = 5.0e-4  # per Newton-second

var remaining: float = 8000.0

var _low_fired: bool = false
var _critical_fired: bool = false
var _depleted_fired: bool = false


func refill() -> void:
	remaining = capacity
	_low_fired = false
	_critical_fired = false
	_depleted_fired = false
	fuel_changed.emit(remaining, capacity)


func consume(force_magnitude: float, delta: float) -> void:
	if remaining <= 0.0:
		return
	remaining = maxf(0.0, remaining - force_magnitude * consumption_rate * delta)
	fuel_changed.emit(remaining, capacity)
	var pct: float = remaining / maxf(capacity, 1.0)
	if not _low_fired and pct <= 0.20:
		_low_fired = true
		low_fuel.emit()
	if not _critical_fired and pct <= 0.05:
		_critical_fired = true
		critical_fuel.emit()
	if not _depleted_fired and remaining <= 0.0:
		_depleted_fired = true
		depleted.emit()


func percent() -> float:
	return 100.0 * remaining / maxf(capacity, 1.0)
