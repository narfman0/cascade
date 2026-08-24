extends RigidBody3D
class_name SpaceRock
## A free-physics rock: small/medium debris or asteroid (Track LD1).
##
## The first rails-free rigid bodies in the world besides the ship and the suit.
## A rock cannot ride an OrbitalAnchor while dynamic (the frozen-kinematic
## write-back fight), and it cannot stay dynamic while ignored (Earth's frame
## velocity rotates, so a loose rock is off its field within minutes). So rocks
## SLEEP as kinematic props under the field — frozen, out of the physics space,
## the tree owns the transform, exactly the docked-ship pattern — and WAKE into
## free physics with the field's frame velocity handed off, exactly the EVA-exit
## pattern. RockField drives the transitions by player distance.
##
## Group membership follows the state: awake rocks hold a real render-space
## position and join `origin_shiftable`; sleeping rocks are recomputed through
## the rail-driven field and must not.

## Angular velocity, world-space. While asleep this is applied by RockField as a
## kinematic rotation so the tumble reads; on wake it becomes the real thing.
var tumble: Vector3 = Vector3.ZERO

var asleep: bool = true


func setup(seed_value: int, size_m: float, mass_kg: float) -> void:
	mass = mass_kg
	linear_damp = 0.0
	angular_damp = 0.0
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	can_sleep = false
	continuous_cd = true

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	tumble = Vector3(
		rng.randf_range(-0.3, 0.3),
		rng.randf_range(-0.3, 0.3),
		rng.randf_range(-0.3, 0.3))

	# Displace a low-poly sphere: displacement is a function of the unit
	# direction, so seam-coincident vertices stay coincident and the sphere's
	# own triangulation stays a valid closed surface — no hull computation.
	var base := SphereMesh.new()
	base.radius = size_m * 0.5
	base.height = size_m
	base.radial_segments = 10
	base.rings = 6
	var arrays: Array = base.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var squash := Vector3(
		rng.randf_range(0.6, 1.0), rng.randf_range(0.55, 1.0), rng.randf_range(0.6, 1.0))
	var lump_dir := Vector3(rng.randf(), rng.randf(), rng.randf()).normalized()
	var lump2 := Vector3(rng.randf() - 0.5, rng.randf() - 0.5, rng.randf() - 0.5).normalized()
	for i in verts.size():
		var d: Vector3 = verts[i].normalized()
		var bump: float = 1.0 \
			+ 0.28 * absf(d.dot(lump_dir)) \
			+ 0.18 * d.dot(lump2) * d.dot(lump2) \
			+ 0.10 * sin(d.x * 5.1 + d.y * 3.7 + d.z * 4.3)
		verts[i] = verts[i] * squash * bump
	arrays[Mesh.ARRAY_VERTEX] = verts

	var st := SurfaceTool.new()
	var src := ArrayMesh.new()
	src.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	st.create_from(src, 0)
	st.generate_normals()
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "Mesh"
	mesh_inst.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.39, 0.36).lerp(
		Color(0.55, 0.50, 0.44), rng.randf())
	mat.roughness = 0.95
	mesh_inst.material_override = mat
	add_child(mesh_inst)

	# Convex hull of the same displaced points: what you see is what you hit.
	var shape := ConvexPolygonShape3D.new()
	shape.points = verts
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	col.shape = shape
	add_child(col)

	# Rocks are born asleep; RockField holds them until the player closes in.
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true


## --- Sleep/wake (driven by RockField) ---------------------------------------

## Freeze, leave the physics space, and hand the transform to the tree under
## `field`. The docked-ship pattern at prop scale.
func go_to_sleep(field: Node3D) -> void:
	if asleep:
		return
	asleep = true
	tumble = angular_velocity
	freeze = true
	remove_from_group(OriginShift.SHIFTABLE_GROUP)
	var xf := global_transform
	var parent := get_parent()
	if parent:
		parent.remove_child(self)
	field.add_child(self)
	global_transform = xf
	# After the reparent — re-entering the tree re-added the body to the world
	# space, so it must be pulled back out here, not before.
	PhysicsServer3D.body_set_space(get_rid(), RID())
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


## Enter free physics in `world` co-moving with the field's frame — reparenting
## back into the tree re-adds the body to the space (ENTER_WORLD), then the
## frame velocity is handed off like an EVA exit.
func wake(world: Node3D, frame_velocity: Vector3) -> void:
	if not asleep:
		return
	asleep = false
	var xf := global_transform
	var parent := get_parent()
	if parent:
		parent.remove_child(self)
	world.add_child(self)
	global_transform = xf
	freeze = false
	add_to_group(OriginShift.SHIFTABLE_GROUP)
	linear_velocity = frame_velocity
	angular_velocity = tumble
