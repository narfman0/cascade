extends Node3D
## New York as a 400 m diorama — the pilot detail site (docs/planet-renderer.md).
##
## Authored FLAT: local +X is east, +Z is north, +Y is up, and PlanetSurface
## anchors this node to the sphere tangent at (40.75 N, 73.98 W) so it turns with
## Earth's spin for free. Everything here is built in code from the site's own
## height inset, which means the lit blocks land on real land and the dark gaps
## are the Hudson, the East River and the Upper Bay — not a hand-placed guess.
##
## Scale is stylized and the design doc says so out loud: 29 km of real New York
## inside a 400 m footprint, with 18–42 m towers standing in for skyscrapers. At
## Cascade's 2,000 m Earth radius the honest alternative is a 6 m smudge. From
## the kilometre or two the player ever gets, a lit grid this size reads exactly
## as "Manhattan from orbit", which is the shot the game wants.
##
## Visual props only — no physics bodies. Anything with one under the rail-driven
## PlanetSurface hits the frozen-kinematic write-back problem; the streamer
## defends against it, but the right fix is not to author one.

## Synty background-skyline meshes. Purpose-built filler: one material, no
## interiors, and already 18–42 m tall at native scale, so the miniature towers
## need no rescaling. Their MaterialList slot is "No Albedo Texture" — they are
## meant to be coloured by the scene, which is why everything here overrides the
## material rather than fighting the import.
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

## Diorama width on the sphere. Overwritten from the DetailSite in `setup_site`.
@export var footprint_m: float = 400.0

## Body radius, used only for curvature: over 400 m of a 2,000 m sphere the
## surface drops ~10 m at the corners, which is more than a building is tall.
## A flat diorama would bury its own edges.
@export var radius_m: float = 2000.0

## Manhattan's street grid runs about 29° off true north. The building rows and
## the lights plate share the bearing, which is most of why the diorama reads as
## this city rather than as a generic grid.
@export var grid_bearing_deg: float = 29.0

@export var max_buildings: int = 110

## Spacing of the placement lattice, metres. ~24 m against 25–42 m towers gives
## a dense core without interpenetration.
@export var block_spacing_m: float = 24.0

## Metres the lights plate floats above the datum sphere. Above the tallest land
## in the inset (~+13 m) and far below anything the player can resolve from a
## kilometre up.
@export var light_lift_m: float = 15.0

@export var day_color: Color = Color(0.26, 0.28, 0.33)
@export var light_color: Color = Color(1.0, 0.86, 0.58)
@export var light_energy: float = 1.6

var _site: DetailSite
var _inset: Image
var _night: float = -1.0
var _lights_mat: StandardMaterial3D
var _building_mat: StandardMaterial3D


## Called by PlanetSurface._instance_site. `radius` is the body's radius; the
## site needs it for curvature and for nothing else.
func setup_site(site: DetailSite, radius: float = 0.0) -> void:
	_site = site
	footprint_m = site.footprint_m
	if radius > 0.0:
		radius_m = radius
	_build()


func _ready() -> void:
	# Instanced on its own (editor preview, or a scene test) rather than by the
	# streamer: build with the exported defaults so it is never an empty node.
	# The streamer calls setup_site *before* adding this node to the tree, so a
	# streamed site has already built by the time _ready runs.
	if _site == null:
		_build()


func _process(_delta: float) -> void:
	# City lights fade in across dusk on exactly the curve the planet shader
	# uses — smoothstep(0.05, -0.15, dot(up, sun)) — so the diorama and the
	# global night-lights map cross the terminator together instead of one
	# switching on ahead of the other.
	# SolarSystem.sun_direction, not the global shader parameter it mirrors:
	# RenderingServer.global_shader_parameter_get is editor-only and logs an
	# error on every call in a running game.
	var sun: Vector3 = SolarSystem.sun_direction
	var night: float = 1.0
	if sun.length() > 0.001:
		var up: Vector3 = global_transform.basis.y.normalized()
		night = 1.0 - smoothstep(-0.15, 0.05, up.dot(sun.normalized()))
	if absf(night - _night) < 0.002:
		return
	_night = night
	if _lights_mat:
		_lights_mat.albedo_color = Color(
			light_color.r * night, light_color.g * night, light_color.b * night, 1.0)
		_lights_mat.emission_energy_multiplier = light_energy * night
	if _building_mat:
		_building_mat.emission_energy_multiplier = night * 0.22


## --- Construction ------------------------------------------------------------

func _build() -> void:
	for child in get_children():
		child.queue_free()
	_inset = _load_inset()
	_add_lights_plate()
	_add_buildings()


func _load_inset() -> Image:
	var tex: Texture2D = _site.height_inset if _site else null
	if tex == null:
		return null
	var img: Image = tex.get_image()
	if img == null:
		return null
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	return img


## Normalized height at a local (east, north) offset, decoded from the site's
## inset in the same 16-bit split-channel encoding the global maps use. Above
## zero is land, at or below is water — the cook puts sea level at exactly zero.
func _inset_height(x: float, z: float) -> float:
	if _inset == null:
		return 1.0
	var u: float = 0.5 + x / footprint_m
	var v: float = 0.5 - z / footprint_m
	var px: int = clampi(int(u * float(_inset.get_width())), 0, _inset.get_width() - 1)
	var py: int = clampi(int(v * float(_inset.get_height())), 0, _inset.get_height() - 1)
	var c: Color = _inset.get_pixel(px, py)
	return ((c.r * 255.0 * 256.0 + c.g * 255.0) / 65535.0) * 2.0 - 1.0


func _is_land(x: float, z: float) -> bool:
	return _inset_height(x, z) > 0.0


## Point on the body's sphere at a local tangent offset, `lift` metres above the
## datum. The anchor sits on the surface with +Y along the outward normal, so in
## local space the body's centre is straight down at (0, -radius, 0).
func _on_sphere(x: float, z: float, lift: float) -> Vector3:
	var d: Vector3 = Vector3(x, radius_m, z).normalized()
	return d * (radius_m + lift) - Vector3(0.0, radius_m, 0.0)


func _up_at(x: float, z: float) -> Vector3:
	return Vector3(x, radius_m, z).normalized()


## The lit street grid: a curvature-following sheet carrying the site's
## night-lights plate, additive so its dark texels contribute nothing and it
## never has to win a depth fight with the terrain under it.
func _add_lights_plate() -> void:
	var tex: Texture2D = _site.night_emissive if _site else null
	if tex == null:
		return
	var steps: int = 24
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for j in steps + 1:
		for i in steps + 1:
			var x: float = (float(i) / float(steps) - 0.5) * footprint_m
			var z: float = (float(j) / float(steps) - 0.5) * footprint_m
			verts.append(_on_sphere(x, z, light_lift_m))
			normals.append(_up_at(x, z))
			# Matches the inset's own mapping: u east, v north-to-south.
			uvs.append(Vector2(0.5 + x / footprint_m, 0.5 - z / footprint_m))
	var row: int = steps + 1
	for j in steps:
		for i in steps:
			var a: int = j * row + i
			indices.append_array([a, a + 1, a + row, a + 1, a + row + 1, a + row])

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	_lights_mat = StandardMaterial3D.new()
	_lights_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_lights_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_lights_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_lights_mat.cull_mode = BaseMaterial3D.CULL_BACK
	_lights_mat.albedo_texture = tex
	_lights_mat.albedo_color = light_color
	_lights_mat.emission_enabled = true
	_lights_mat.emission_texture = tex
	_lights_mat.emission = light_color
	_lights_mat.emission_energy_multiplier = light_energy

	var mi := MeshInstance3D.new()
	mi.name = "CityLights"
	mi.mesh = mesh
	mi.material_override = _lights_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _add_buildings() -> void:
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


## Buildings actually placed. Read by tests and by the shot harness.
func building_count() -> int:
	var blocks := get_node_or_null("Blocks")
	return blocks.get_child_count() if blocks else 0
