class_name SiteBase extends Node3D
## Shared machinery for detail-site dioramas (docs/planet-renderer.md).
##
## A site scene is authored FLAT — local +X east, +Z north, +Y up — and
## PlanetSurface anchors it to the sphere tangent at its (lat, lon), so it
## turns with the body's spin for free. This base carries everything every
## diorama needs: the curvature helpers (over 400 m of a 2,000 m sphere the
## surface drops ~10 m at the corners — a flat diorama buries its own edges),
## the inset land/water lookup, the additive city-lights plate, and the
## night fade.
##
## The fade band comes from the body's ATMOSPHERE via set_night_gate — the
## same derived twilight the surface shader's city lights use — so a site,
## the global night map and the sky all cross the terminator together. The
## default matches the shader's airless default.
##
## Visual props only — no physics bodies (PlanetSurface._detach_site_physics
## defends, but the right fix is not to author one). Subclasses override
## _populate() and should hang their props under a "Blocks" holder so
## building_count() serves the tests unchanged.

@export var footprint_m: float = 400.0
@export var radius_m: float = 2000.0

## Metres the lights plate floats above the datum sphere.
@export var light_lift_m: float = 15.0

@export var light_color: Color = Color(1.0, 0.86, 0.58)
@export var light_energy: float = 1.6

var _site: DetailSite
var _inset: Image
var _night: float = -1.0
var _night_gate: Vector2 = Vector2(-0.15, 0.05)
var _lights_mat: StandardMaterial3D
var _building_mat: StandardMaterial3D


## Called by PlanetSurface._instance_site before this node enters the tree.
func setup_site(site: DetailSite, radius: float = 0.0) -> void:
	_site = site
	footprint_m = site.footprint_m
	if radius > 0.0:
		radius_m = radius
	_build()


## Called by PlanetSurface._instance_site when the body has an atmosphere:
## (lo, hi) thresholds on dot(up, sun), from BodyAtmosphere.night_gate().
func set_night_gate(gate: Vector2) -> void:
	_night_gate = gate
	_night = -1.0   # re-fade on the new band


func _ready() -> void:
	# Instanced on its own (editor preview, or a scene test) rather than by
	# the streamer: build with the exported defaults so it is never empty.
	if _site == null:
		_build()


func _process(_delta: float) -> void:
	# Lights fade across the same twilight band as the planet shader's night
	# gate. SolarSystem.sun_direction, not the global shader parameter it
	# mirrors: global_shader_parameter_get is editor-only.
	var sun: Vector3 = SolarSystem.sun_direction
	var night: float = 1.0
	if sun.length() > 0.001:
		var up: Vector3 = global_transform.basis.y.normalized()
		night = 1.0 - smoothstep(_night_gate.x, _night_gate.y, up.dot(sun.normalized()))
	if absf(night - _night) < 0.002:
		return
	_night = night
	if _lights_mat:
		_lights_mat.albedo_color = Color(
			light_color.r * night, light_color.g * night, light_color.b * night, 1.0)
		_lights_mat.emission_energy_multiplier = light_energy * night
	if _building_mat:
		_building_mat.emission_energy_multiplier = night * 0.22


func _build() -> void:
	for child in get_children():
		child.queue_free()
	_inset = _load_inset()
	_add_lights_plate()
	_populate()


## Subclasses place their props here.
func _populate() -> void:
	pass


## Props actually placed under "Blocks". Read by tests and the shot harness.
func building_count() -> int:
	var blocks := get_node_or_null("Blocks")
	return blocks.get_child_count() if blocks else 0


## --- Inset lookups -------------------------------------------------------------

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
## inset in the 16-bit split-channel encoding. Above zero is land.
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


## --- Curvature helpers ----------------------------------------------------------

## Point on the body's sphere at a local tangent offset, `lift` metres above
## the datum. The anchor sits on the surface with +Y the outward normal, so
## locally the body's centre is straight down at (0, -radius, 0).
func _on_sphere(x: float, z: float, lift: float) -> Vector3:
	var d: Vector3 = Vector3(x, radius_m, z).normalized()
	return d * (radius_m + lift) - Vector3(0.0, radius_m, 0.0)


func _up_at(x: float, z: float) -> Vector3:
	return Vector3(x, radius_m, z).normalized()


## --- Lights plate ----------------------------------------------------------------

## The lit plate: a curvature-following sheet carrying the site's night
## emissive, additive so dark texels contribute nothing and it never fights
## the terrain for depth.
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
