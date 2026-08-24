extends OrbitalAnchor
class_name RockField
## Spawns and manages a field of SpaceRocks pinned to a body's frame (LD1).
##
## The field node itself is a plain OrbitalAnchor — it rides the body's rails.
## Its rocks sleep as kinematic children (the field's _process turns them so the
## tumble reads) and wake into free physics when the player closes within
## `wake_radius`; a woken rock left behind re-anchors at its drifted position.
## This is the M3 debris substrate: contracts hang rocks on these fields.

@export var rock_count: int = 12
@export var field_seed: int = 1337
@export var spread_radius: float = 260.0
@export var size_min: float = 2.0
@export var size_max: float = 14.0
## Density-ish mass mapping: mass scales with size cubed between these bounds.
@export var mass_min: float = 500.0
@export var mass_max: float = 20000.0
@export var wake_radius: float = 500.0
@export var sleep_radius: float = 800.0

var rocks: Array[SpaceRock] = []


func setup(system: SolarSystem) -> void:
	super.setup(system)
	if not rocks.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = field_seed
	for i in rock_count:
		var rock := SpaceRock.new()
		rock.name = "Rock_%03d" % i
		var t: float = rng.randf()
		var size: float = lerpf(size_min, size_max, t * t)  # small rocks common
		var mass_t: float = pow((size - size_min) / maxf(size_max - size_min, 0.01), 3.0)
		rock.setup(rng.randi(), size, lerpf(mass_min, mass_max, mass_t))
		add_child(rock)
		rock.position = Vector3(
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0)).normalized() * rng.randf_range(
				spread_radius * 0.2, spread_radius)
		rock.rotation = Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU)
		# Sleeping rocks are tree-driven only — out of the physics space from
		# the first frame, or the frozen-kinematic write-back fight begins.
		PhysicsServer3D.body_set_space(rock.get_rid(), RID())
		rocks.append(rock)


func _process(delta: float) -> void:
	super._process(delta)
	var tracked := OriginShift.tracked
	if tracked == null or not is_instance_valid(tracked):
		return
	var eye: Vector3 = tracked.global_position
	for rock in rocks:
		if rock.asleep:
			# Kinematic tumble so a sleeping field still reads as adrift.
			if rock.tumble != Vector3.ZERO:
				rock.rotate(rock.tumble.normalized(), rock.tumble.length() * delta)
			if eye.distance_to(rock.global_position) < wake_radius:
				rock.wake(get_parent(), frame_velocity())
		else:
			if eye.distance_to(rock.global_position) > sleep_radius:
				rock.go_to_sleep(self)


## Velocity of the frame the field rides — the body's orbital velocity.
func frame_velocity() -> Vector3:
	if _body == null:
		return Vector3.ZERO
	var v: Array = _body.velocity_at(SimClock.sim_time)
	return Vector3(float(v[0]), float(v[1]), float(v[2]))
