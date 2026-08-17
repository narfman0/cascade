extends Node3D
class_name OrbitalAnchor
## Pins a group of authored nodes to a celestial body's frame.
##
## A debris field in low Earth orbit has to travel with Earth — Earth moves at
## 131 m/s in this system's compressed scale, so a field left at fixed true-space
## coordinates would be kilometres behind within a minute. Children keep their
## authored local offsets; this node supplies the body-relative origin.
##
## Position is recomputed from true space every frame, so this node must NOT join
## the `origin_shiftable` group.

@export var body_id: StringName = &"earth"

## Offset from the body's centre, in metres. Default puts the field in a low
## orbit above the body rather than inside it.
@export var anchor_offset: Vector3 = Vector3(0.0, 4000.0, 0.0)

var _body: CelestialBody
var _system: SolarSystem


func setup(system: SolarSystem) -> void:
	_system = system
	_body = system.get_body(body_id)
	if _body == null:
		push_warning("OrbitalAnchor: no body '%s' in the system." % body_id)
	_update()


func _process(_delta: float) -> void:
	_update()


func _update() -> void:
	if _body == null:
		return
	var anchor_true: Array = [
		_body.true_pos[0] + anchor_offset.x,
		_body.true_pos[1] + anchor_offset.y,
		_body.true_pos[2] + anchor_offset.z,
	]
	global_position = OriginShift.to_render(anchor_true)


## True-space position of this anchor — what the ship should be spawned at.
func true_position() -> Array:
	if _body == null:
		return [0.0, 0.0, 0.0]
	return [
		_body.true_pos[0] + anchor_offset.x,
		_body.true_pos[1] + anchor_offset.y,
		_body.true_pos[2] + anchor_offset.z,
	]
