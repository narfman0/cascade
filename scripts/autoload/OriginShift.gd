extends Node
## OriginShift — floating origin for a solar-system-sized world.
##
## Godot's Vector3 is float32: at 2,000,000 m from the origin its precision is
## roughly a quarter metre, which is fine for cruising and useless for EVA work.
## So render space is kept near zero and the *true* system position of the render
## origin is tracked here in 64-bit floats.
##
## Two coordinate spaces, and it matters which one you are in:
##   - **true space**  — system-absolute, Sun at [0,0,0], stored as [x, y, z]
##                       arrays of 64-bit floats. Celestial bodies and the
##                       autopilot work here.
##   - **render space** — what Node3D transforms hold. Always within
##                       SHIFT_THRESHOLD_METERS of zero.
##
## Nodes that hold a physical render-space position must join the
## `origin_shiftable` group so they get moved when the origin jumps. Anything
## that recomputes its position every frame from true space (the solar system
## does) must NOT join — it would be shifted twice.
##
## Velocities are unaffected: a shift is an instantaneous translation of the
## frame, not motion of it, so the render frame stays inertial.

signal origin_shifted(offset: Vector3)

const SHIFT_THRESHOLD_METERS: float = 10000.0
const SHIFTABLE_GROUP: StringName = &"origin_shiftable"

## True-space position of the render origin, as 64-bit floats.
var origin_x: float = 0.0
var origin_y: float = 0.0
var origin_z: float = 0.0

## Node whose distance from render origin triggers automatic shifts.
var tracked: Node3D = null


func _physics_process(_delta: float) -> void:
	if tracked == null or not is_instance_valid(tracked):
		return
	if tracked.global_position.length() > SHIFT_THRESHOLD_METERS:
		shift_by(tracked.global_position)


## Set the render origin at bootstrap WITHOUT moving any nodes. Authored scene
## positions are then interpreted as offsets from this true-space point, which is
## how a debris field authored around the origin ends up in low Earth orbit.
## Only valid before anything has been placed — use shift_to() afterwards.
func initialize_origin(true_pos: Array) -> void:
	origin_x = true_pos[0]
	origin_y = true_pos[1]
	origin_z = true_pos[2]


## --- Space conversions -------------------------------------------------------

## Render-space position → true-space [x, y, z] (64-bit).
func to_true(render_pos: Vector3) -> Array:
	return [
		origin_x + render_pos.x,
		origin_y + render_pos.y,
		origin_z + render_pos.z,
	]


## True-space [x, y, z] → render-space Vector3. The subtraction happens in
## 64-bit before the narrowing conversion, which is the whole point.
func to_render(true_pos: Array) -> Vector3:
	return Vector3(
		float(true_pos[0] - origin_x),
		float(true_pos[1] - origin_y),
		float(true_pos[2] - origin_z),
	)


## True-space offset from the render origin, as a render-space vector. Safe for
## nearby targets; loses precision past ~1e7 m, which is why far bodies are
## rendered through CelestialBody's proxy clamp instead.
func true_delta(true_pos: Array) -> Vector3:
	return to_render(true_pos)


## --- Shifting ----------------------------------------------------------------

## Move the render origin by `offset` (render space): every shiftable node moves
## back by `offset`, and the tracked true origin moves forward by it.
func shift_by(offset: Vector3) -> void:
	if offset == Vector3.ZERO:
		return
	origin_x += offset.x
	origin_y += offset.y
	origin_z += offset.z
	for node in get_tree().get_nodes_in_group(SHIFTABLE_GROUP):
		var n3 := node as Node3D
		if n3 == null:
			continue
		n3.global_position -= offset
	origin_shifted.emit(offset)


## Place the render origin at a specific true-space point.
func shift_to(true_pos: Array) -> void:
	shift_by(to_render(true_pos))


## Teleport a shiftable node to a true-space position, re-centring the origin on
## it. Used by the autopilot when it hands a completed transfer back to physics.
func place_at_true(node: Node3D, true_pos: Array) -> void:
	shift_to(true_pos)
	node.global_position = to_render(true_pos)


## --- Helpers -----------------------------------------------------------------

func dv_add(a: Array, b: Array) -> Array:
	return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]


func dv_sub(a: Array, b: Array) -> Array:
	return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]


func dv_length(a: Array) -> float:
	return sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])


func dv_scaled(a: Array, s: float) -> Array:
	return [a[0] * s, a[1] * s, a[2] * s]


## Unit-length direction as 64-bit components. Returns [0,0,0] for a null vector.
func dv_normalized(a: Array) -> Array:
	var len: float = dv_length(a)
	if len < 1e-12:
		return [0.0, 0.0, 0.0]
	return [a[0] / len, a[1] / len, a[2] / len]


func dv_from_vec3(v: Vector3) -> Array:
	return [float(v.x), float(v.y), float(v.z)]


## Only safe when the vector's magnitude is small enough for float32.
func dv_to_vec3(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
