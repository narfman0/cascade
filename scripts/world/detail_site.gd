class_name DetailSite extends Resource
## One authored place on a body's surface — the PR3 half of the planet renderer.
##
## Data only; PlanetSurface streams it. A site is a *diorama*, not a model: it
## occupies a gameplay-readable footprint (200–500 m on the sphere) regardless of
## how large the real place is, and its buildings are miniatures. At Cascade's
## compression a true-scale Manhattan would be a 6 m smudge, so the design doc
## commits to the stylization instead of fighting it — see docs/planet-renderer.md,
## "The scale problem, addressed head-on".
##
## The scene is authored FLAT — local XZ plane, +Y up — and the streamer orients
## it to the sphere tangent at (lat, lon). Authoring a site is therefore ordinary
## Godot scene work rather than spherical-coordinate misery.

## Stable id, used as the streamer's key. &"nyc".
@export var id: StringName = &""

@export var display_name: String = ""

@export var lat_deg: float = 0.0

## East-positive, matching the equirect maps: lon = atan2(dir.z, dir.x).
@export var lon_deg: float = 0.0

## Diorama width on the sphere, metres. Also the extent of `height_inset`.
@export var footprint_m: float = 400.0

## Optional high-resolution height inset covering the footprint, in the same
## 16-bit split-channel encoding as the global maps (docs/assets.md §7). Blended
## into the patches over the site with a smoothstep falloff, so the local
## coastline survives a global texel hundreds of real kilometres wide.
@export var height_inset: Texture2D

## Buildings and props. Instanced under a tangent-oriented anchor when the site
## streams in. Must contain no physics bodies — see PlanetSurface._instance_site.
@export var scene: PackedScene

## City-lights plate for the site, handed to the scene through `setup_site`.
@export var night_emissive: Texture2D

## Shown when the site is scanned or targeted. Factual, not lore.
@export var nav_note: String = ""


## Unit direction to the site in surface-local space, in exactly the convention
## the equirect maps and the shader use (lon = atan2(z, x), lat = asin(y)). Get
## this wrong and the site sits somewhere else than its own inset.
func direction() -> Vector3:
	var lat: float = deg_to_rad(lat_deg)
	var lon: float = deg_to_rad(lon_deg)
	var cl: float = cos(lat)
	return Vector3(cl * cos(lon), sin(lat), cl * sin(lon))


## Angular radius of the footprint on a body of `radius`, radians.
func angular_radius(radius: float) -> float:
	return (footprint_m * 0.5) / maxf(radius, 1.0)


## Local east (increasing longitude) at the site. Matches the shader's
## `east_l = vec3(-sdir.z, 0, sdir.x)`.
func east() -> Vector3:
	var d := direction()
	var e := Vector3(-d.z, 0.0, d.x)
	if e.length() < 1e-5:
		# Straight over a pole: any tangent will do, pick a stable one.
		return Vector3(1.0, 0.0, 0.0)
	return e.normalized()


## Local north at the site. east × up is right-handed with up, so
## Basis(east, up, north) is a valid, non-mirrored orientation.
func north() -> Vector3:
	return east().cross(direction()).normalized()


static func make(
	p_id: StringName, p_name: String, p_lat: float, p_lon: float,
	p_footprint: float, p_note: String = ""
) -> DetailSite:
	var s := DetailSite.new()
	s.id = p_id
	s.display_name = p_name
	s.lat_deg = p_lat
	s.lon_deg = p_lon
	s.footprint_m = p_footprint
	s.nav_note = p_note
	return s
