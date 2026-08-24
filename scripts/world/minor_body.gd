extends CelestialBody
class_name MinorBody
## An asteroid sized for the ship (Track LD7): the middle class between
## SpaceRock (free physics, latch, no gravity) and CelestialBody (planet
## scale, belly jets). ~100–600 m radius, on the same analytic rails as a
## moon, displaced-sphere rock mesh + TRIMESH collision at true scale, and a
## gravity shell entirely inside the ship's RCS envelope (g0 0.05–0.5 vs
## 1.25 m/s²) — landing here is an everyday act flown on lateral thrusters;
## the belly-jet promotion never triggers. The class boundary is the design:
## if you latch it, it's a rock; if you land on it, it's a minor body.
##
## Spin rotates THIS node (planets spin only their PlanetSurface): the mesh,
## the trimesh collider, a landed hull, and a walking suit all co-rotate for
## free through the tree — LD4's landed-frame pattern with the body itself
## as the port. On a tumbling asteroid the sky wheels overhead.

## Extra deterministic knobs beyond BodyDef.
var mesh_seed: int = 1


func _build_visuals() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = mesh_seed
	# Displaced sphere at unit scale (like SpaceRock, higher res, gentler
	# lumps): displacement is a function of the unit direction, so the
	# sphere's own triangulation stays a valid closed surface.
	var base := SphereMesh.new()
	base.radius = 1.0
	base.height = 2.0
	base.radial_segments = 32
	base.rings = 20
	var arrays: Array = base.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	# The envelope hugs def.radius (±12%): every altitude computed against the
	# analytic radius — the descent profile, the SURFACE panel, the walk's
	# fallback — stays honest within metres, not a third of the body.
	var squash := Vector3(
		rng.randf_range(0.9, 1.0), rng.randf_range(0.88, 1.0), rng.randf_range(0.9, 1.0))
	var lump1 := Vector3(rng.randf(), rng.randf(), rng.randf()).normalized()
	var lump2 := Vector3(rng.randf() - 0.5, rng.randf() - 0.5, rng.randf() - 0.5).normalized()
	var f1: float = rng.randf_range(2.5, 4.5)
	var f2: float = rng.randf_range(5.0, 9.0)
	for i in verts.size():
		var d: Vector3 = verts[i].normalized()
		var bump: float = 1.0 \
			+ 0.05 * absf(d.dot(lump1)) \
			+ 0.04 * d.dot(lump2) * d.dot(lump2) \
			+ 0.03 * sin(d.x * f1 + d.y * f2 + d.z * f1 * 1.7) \
			+ 0.02 * sin(d.y * f2 * 1.3 + d.z * f1)
		verts[i] = verts[i] * squash * bump
	arrays[Mesh.ARRAY_VERTEX] = verts

	var st := SurfaceTool.new()
	var src := ArrayMesh.new()
	src.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	st.create_from(src, 0)
	st.generate_normals()
	var rock_mesh: ArrayMesh = st.commit()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = def.albedo
	mat.roughness = def.roughness
	_mesh = MeshInstance3D.new()
	_mesh.name = "Mesh"
	_mesh.mesh = rock_mesh
	_mesh.material_override = mat
	_mesh.scale = Vector3.ONE * def.radius
	add_child(_mesh)

	# Trimesh collision of the SAME displaced geometry, at true radius: what
	# you see is what you land on. Always enabled at true scale — the whole
	# body is smaller than a planet's skim range.
	var faces: PackedVector3Array = rock_mesh.get_faces()
	for i in faces.size():
		faces[i] = faces[i] * def.radius
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	_collision = CollisionShape3D.new()
	_collision.shape = shape
	_collision.disabled = true
	_static_body = StaticBody3D.new()
	_static_body.name = "Surface"
	_static_body.collision_layer = 8
	_static_body.collision_mask = 0
	_static_body.add_child(_collision)
	add_child(_static_body)


## Spin the whole node — the collider and any landed guest ride along.
func update_render(t: float) -> void:
	super.update_render(t)
	if def.spin_period > 0.0:
		var axis := Vector3(
			0.0, cos(def.spin_axis_tilt), sin(def.spin_axis_tilt)).normalized()
		global_basis = Basis(axis, fposmod(TAU * (t / def.spin_period), TAU))


## The parent sphere-collider sizing in _apply_scale expects a SphereShape3D;
## the trimesh is baked at true radius, so proxy scaling touches the mesh only
## (collision is disabled long before proxy range anyway).
func _apply_scale(ratio: float) -> void:
	if _mesh:
		_mesh.scale = Vector3.ONE * (def.radius * ratio)
