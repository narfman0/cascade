extends SiteBase
## New York as a 400 m diorama — the pilot detail site (docs/planet-renderer.md).
##
## The shared machinery (tangent anchoring, curvature, inset land/water, the
## lights plate, the twilight fade) lives in SiteBase; this script is only the
## Manhattan part: a lattice of Synty background towers laid along the city's
## ~29° street bearing, dense and tall in the core, low toward the boroughs,
## and only ever on land — so the dark gaps are the Hudson, the East River and
## the Upper Bay rather than a hand-placed guess.
##
## Scale is stylized and the design doc says so out loud: 29 km of real New
## York inside a 400 m footprint, 18–42 m towers standing in for skyscrapers.
## From the kilometre or two the player ever gets, a lit grid this size reads
## exactly as "Manhattan from orbit", which is the shot the game wants.

## Synty background-skyline meshes. Purpose-built filler: one material, no
## interiors, and already 18–42 m tall at native scale, so the miniature towers
## need no rescaling. Their MaterialList slot is "No Albedo Texture" — they are
## meant to be coloured by the scene, which is why everything here overrides
## the material rather than fighting the import.
const CITY_DIR := "res://assets/meshes/POLYGON_SciFi_City_SourceFiles_v5/Source_Files/FBX/"

const TOWERS := [
	"SM_Bld_Background_Lrg_02.gltf",   # 42.0 m
	"SM_Bld_Background_Lrg_03.gltf",   # 42.5 m
	"SM_Bld_Background_Med_09.gltf",   # 30.4 m
]
const BLOCKS := [
	"SM_Bld_Background_Lrg_01.gltf",   # 25.5 m
	"SM_Bld_Background_Med_01.gltf",
	"SM_Bld_Background_Med_03.gltf",
	"SM_Bld_Background_Med_04.gltf",
	"SM_Bld_Background_Med_05.gltf",
	"SM_Bld_Background_Med_06.gltf",
]
const LOW := [
	"SM_Bld_Background_Med_02.gltf",
	"SM_Bld_Background_Med_07.gltf",
	"SM_Bld_Background_Med_08.gltf",
	"SM_Bld_Background_Small_01.gltf",
	"SM_Bld_Background_Small_02.gltf",
	"SM_Bld_Background_Small_03.gltf",
]

## Manhattan's street grid runs about 29° off true north. The building rows and
## the lights plate share the bearing, which is most of why the diorama reads
## as this city rather than as a generic grid.
@export var grid_bearing_deg: float = 29.0

@export var max_buildings: int = 110

## Spacing of the placement lattice, metres. ~24 m against 25–42 m towers gives
## a dense core without interpenetration.
@export var block_spacing_m: float = 24.0

@export var day_color: Color = Color(0.26, 0.28, 0.33)


func _populate() -> void:
	_building_mat = StandardMaterial3D.new()
	_building_mat.albedo_color = day_color
	_building_mat.roughness = 0.8
	_building_mat.metallic = 0.0
	_building_mat.emission_enabled = true
	_building_mat.emission = light_color
	_building_mat.emission_energy_multiplier = 0.0

	var scenes: Dictionary = {}
	var rng := RandomNumberGenerator.new()
	# Fixed seed: the diorama must be identical every session, like everything
	# else in this renderer (docs/planet-renderer.md, "Determinism").
	rng.seed = 0x4e5943

	var bearing: float = deg_to_rad(grid_bearing_deg)
	var cb: float = cos(bearing)
	var sb: float = sin(bearing)
	var half: float = footprint_m * 0.5
	var cells: int = int(footprint_m / block_spacing_m)
	var placed: int = 0
	var holder := Node3D.new()
	holder.name = "Blocks"
	add_child(holder)

	for gj in cells + 1:
		for gi in cells + 1:
			if placed >= max_buildings:
				break
			# Lattice laid out along the street grid, then rotated into the
			# site's east/north frame.
			var lu: float = (float(gi) / float(cells) - 0.5) * footprint_m
			var lv: float = (float(gj) / float(cells) - 0.5) * footprint_m
			lu += rng.randf_range(-0.3, 0.3) * block_spacing_m
			lv += rng.randf_range(-0.3, 0.3) * block_spacing_m
			var x: float = lu * cb - lv * sb
			var z: float = lu * sb + lv * cb
			if absf(x) > half - 8.0 or absf(z) > half - 8.0:
				continue
			if not _is_land(x, z):
				continue
			# Density and height both fall away from the core, so midtown reads
			# as midtown and the outer boroughs as low-rise.
			var core: float = 1.0 - clampf(sqrt(x * x + z * z) / (footprint_m * 0.42), 0.0, 1.0)
			if rng.randf() > 0.25 + 0.7 * core:
				continue
			var roll: float = rng.randf()
			var pool: Array = LOW
			if roll < 0.18 * core + 0.02:
				pool = TOWERS
			elif roll < 0.55 * core + 0.15:
				pool = BLOCKS
			var file: String = pool[rng.randi() % pool.size()]
			var packed: PackedScene = scenes.get(file)
			if packed == null:
				var path: String = CITY_DIR + file
				if not ResourceLoader.exists(path):
					continue
				packed = load(path) as PackedScene
				if packed == null:
					continue
				scenes[file] = packed

			var slot := Node3D.new()
			var up: Vector3 = _up_at(x, z)
			# Sunk slightly: the terrain under the diorama varies by a few metres
			# and a floating tower reads worse than a buried plinth.
			var origin: Vector3 = _on_sphere(x, z, -4.0)
			var east: Vector3 = (Vector3.RIGHT - up * up.dot(Vector3.RIGHT)).normalized()
			var north: Vector3 = east.cross(up).normalized()
			var yaw: float = bearing + rng.randf_range(-0.06, 0.06)
			var fwd: Vector3 = north * cos(yaw) + east * sin(yaw)
			# Basis columns are (x, y, z) and must be right-handed: x = up x fwd,
			# not fwd x up, or every building is mirrored.
			slot.transform = Transform3D(
				Basis(up.cross(fwd).normalized(), up, fwd), origin)
			slot.scale = Vector3.ONE * rng.randf_range(0.8, 1.25)
			holder.add_child(slot)
			var inst: Node = packed.instantiate()
			slot.add_child(inst)
			for mesh_node in inst.find_children("*", "MeshInstance3D", true, false):
				(mesh_node as MeshInstance3D).material_override = _building_mat
			if inst is MeshInstance3D:
				(inst as MeshInstance3D).material_override = _building_mat
			placed += 1
