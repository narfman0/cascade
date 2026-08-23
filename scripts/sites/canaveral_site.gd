extends SiteBase
## Cape Canaveral as a 400 m diorama — the second detail site (PR5 list).
##
## Unlike Manhattan's statistical lattice, a launch coast is a handful of
## LANDMARKS with water and scrub between them, so this scene places its
## pieces at the real installations' coordinates, squeezed through the same
## 29-km-window-into-400-m stylization as the terrain inset: the VAB block,
## the two LC-39 pads with their towers, the Shuttle Landing Facility strip,
## the CCSFS pad row down the cape, and the Port Canaveral cluster. The
## geography does the identifying — the hook of the cape and the Banana and
## Indian rivers come from the inset; the props just say what the place is.
##
## Deterministic like everything else: fixed seed, fixed coordinates.

const CITY_DIR := "res://assets/meshes/POLYGON_SciFi_City_SourceFiles_v5/Source_Files/FBX/"
const VAB_MESH := "SM_Bld_Background_Lrg_01.gltf"       # 25.5 m block
const INDUSTRIAL := [
	"SM_Bld_Background_Small_01.gltf",
	"SM_Bld_Background_Small_02.gltf",
	"SM_Bld_Background_Small_03.gltf",
	"SM_Bld_Background_Med_02.gltf",
]

## Window the inset was cooked from (tools/cook_planet_maps.py) — needed to
## map real lat/lon onto diorama metres.
const CENTER_LAT := 28.55
const CENTER_LON := -80.62
const SPAN_DEG := 0.26

## The real installations: [lat, lon, kind]. Coordinates match the night
## plate's glow anchors in the cook, so the props sit in their own light.
const LANDMARKS := [
	[28.586, -80.651, "vab"],
	[28.608, -80.604, "pad39"],
	[28.627, -80.621, "pad39"],
	[28.615, -80.694, "runway"],
	[28.488, -80.577, "padrow"],
	[28.410, -80.605, "port"],
]

@export var day_color: Color = Color(0.30, 0.30, 0.32)
@export var concrete_color: Color = Color(0.55, 0.54, 0.52)

var _concrete_mat: StandardMaterial3D


func _populate() -> void:
	_building_mat = StandardMaterial3D.new()
	_building_mat.albedo_color = day_color
	_building_mat.roughness = 0.8
	_building_mat.metallic = 0.0
	_building_mat.emission_enabled = true
	_building_mat.emission = light_color
	_building_mat.emission_energy_multiplier = 0.0

	_concrete_mat = StandardMaterial3D.new()
	_concrete_mat.albedo_color = concrete_color
	_concrete_mat.roughness = 0.95
	_concrete_mat.metallic = 0.0

	var holder := Node3D.new()
	holder.name = "Blocks"
	add_child(holder)

	var rng := RandomNumberGenerator.new()
	rng.seed = 0x434156   # "CAV"

	for mark in LANDMARKS:
		var pos := _local_of(mark[0], mark[1])
		match mark[2]:
			"vab":
				_place_mesh(holder, VAB_MESH, pos, 0.0, 1.25)
				for i in 3:
					_place_mesh(holder, INDUSTRIAL[i % INDUSTRIAL.size()],
						pos + Vector2(rng.randf_range(-14.0, -6.0),
							rng.randf_range(-10.0, 10.0)), 0.0, 0.9)
			"pad39":
				_place_pad(holder, pos, 6.5, true)
			"runway":
				# The SLF strip runs ~330 deg true.
				_place_strip(holder, pos, deg_to_rad(330.0), 52.0, 4.5)
			"padrow":
				# Three pads stepping down the cape, roughly along the coast.
				for i in 3:
					_place_pad(holder, pos + Vector2(3.0, -9.0) * float(i), 4.0, i == 0)
			"port":
				for i in 5:
					_place_mesh(holder, INDUSTRIAL[rng.randi() % INDUSTRIAL.size()],
						pos + Vector2(rng.randf_range(-12.0, 12.0),
							rng.randf_range(-6.0, 6.0)), rng.randf_range(0.0, TAU), 0.7)


## Real lat/lon -> diorama (east x, north z) metres, through the same squeeze
## as the terrain inset.
func _local_of(lat: float, lon: float) -> Vector2:
	var window_m: float = SPAN_DEG * 111320.0
	var s: float = footprint_m / window_m
	return Vector2(
		(lon - CENTER_LON) * 111320.0 * cos(deg_to_rad(CENTER_LAT)) * s,
		(lat - CENTER_LAT) * 111320.0 * s)


func _place_mesh(
	holder: Node3D, file: String, pos: Vector2, yaw: float, scale_f: float
) -> void:
	var path: String = CITY_DIR + file
	if not ResourceLoader.exists(path):
		return
	var packed := load(path) as PackedScene
	if packed == null:
		return
	var slot := _slot_at(holder, pos, yaw)
	slot.scale = Vector3.ONE * scale_f
	var inst: Node = packed.instantiate()
	slot.add_child(inst)
	for mesh_node in inst.find_children("*", "MeshInstance3D", true, false):
		(mesh_node as MeshInstance3D).material_override = _building_mat
	if inst is MeshInstance3D:
		(inst as MeshInstance3D).material_override = _building_mat


## A launch pad: concrete circle, and optionally the service tower beside it.
func _place_pad(holder: Node3D, pos: Vector2, pad_radius: float, tower: bool) -> void:
	var cyl := CylinderMesh.new()
	cyl.top_radius = pad_radius
	cyl.bottom_radius = pad_radius
	cyl.height = 0.8
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.material_override = _concrete_mat
	var slot := _slot_at(holder, pos, 0.0)
	slot.add_child(mi)
	if tower:
		var box := BoxMesh.new()
		box.size = Vector3(2.2, 13.0, 2.2)
		var tower_mi := MeshInstance3D.new()
		tower_mi.mesh = box
		tower_mi.material_override = _building_mat
		tower_mi.position = Vector3(pad_radius + 1.6, 6.5, 0.0)
		slot.add_child(tower_mi)


## The runway: one long concrete strip at a bearing (radians from north,
## toward east).
func _place_strip(
	holder: Node3D, pos: Vector2, bearing: float, length_m: float, width_m: float
) -> void:
	var box := BoxMesh.new()
	box.size = Vector3(width_m, 0.6, length_m)
	var mi := MeshInstance3D.new()
	mi.mesh = box
	mi.material_override = _concrete_mat
	_slot_at(holder, pos, bearing).add_child(mi)


## Tangent-oriented slot at a local offset, sunk slightly like NYC's plinths.
func _slot_at(holder: Node3D, pos: Vector2, yaw: float) -> Node3D:
	var slot := Node3D.new()
	var up: Vector3 = _up_at(pos.x, pos.y)
	var origin: Vector3 = _on_sphere(pos.x, pos.y, -1.5)
	var east: Vector3 = (Vector3.RIGHT - up * up.dot(Vector3.RIGHT)).normalized()
	var north: Vector3 = east.cross(up).normalized()
	var fwd: Vector3 = north * cos(yaw) + east * sin(yaw)
	slot.transform = Transform3D(Basis(up.cross(fwd).normalized(), up, fwd), origin)
	holder.add_child(slot)
	return slot
