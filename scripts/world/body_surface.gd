class_name BodySurface extends Resource
## Per-body surface parameterization for the progressive planet renderer.
##
## Data only — PlanetSurface does the work. One resource per body describes how
## its terrain is generated (procedural noise, or an authored equirect map when
## present), how it is coloured, and whether it carries night lights. Gas giants
## set `amplitude` to 0 and use latitude bands: the pipeline treats "smooth with
## fancy albedo" as just another parameterization (docs/planet-renderer.md).
##
## Determinism matters: the noise seed is fixed per body, so the same body id
## always produces bit-identical terrain — tests/planet_test.gd asserts it. The
## authored path is deterministic for the same reason: it is a pure lookup into
## a committed raster.

## Seed for every noise field. Derived from the body id by SolarSystemData so it
## is stable across sessions and platforms.
@export var noise_seed: int = 0

## Base noise frequency on the unit sphere. ~1.2 gives a few continents.
@export var continent_frequency: float = 1.4

## 0 = pure fBm (rolling), 1 = pure ridged multifractal (mountainous).
@export var ridged_mix: float = 0.0

## Displacement amplitude as a fraction of body radius (~1–3% per the design
## doc: exaggerated relief reads like a globe, which is the correct look).
@export var amplitude: float = 0.02

## Sea level as a normalized height in [-1, 1]. Terrain below it renders as a
## flat shell at the sea surface with a distinct albedo. -1.0 = no sea.
##
## With an authored height map this stops being a tuned constant: the cook puts
## true mean sea level at exactly 0.0 (tools/cook_planet_maps.py), so Earth's
## coastline is the datum rather than whichever value happened to look right.
@export var sea_level: float = -1.0

## Land colours, sampled by normalized height above the sea (or above the
## global minimum when there is no sea). For banded bodies, sampled by latitude.
@export var palette: Gradient

@export var sea_color: Color = Color(0.07, 0.19, 0.36)

## > 0: albedo comes from latitude bands (gas giants) instead of height.
@export var band_frequency: float = 0.0

## How strongly noise wobbles the band boundaries (radians of latitude-ish).
@export var band_wobble: float = 0.0

## Bake emissive night lights clustered on coastal lowlands. The procedural
## stand-in for `night_emissive`, used only when no authored mask is set.
@export var city_lights: bool = false

## Authored equirect night-lights mask. Overrides the baked `city_lights` mask.
@export var night_emissive: Texture2D

## Authored equirect height map, 16 bits split across the red (high byte) and
## green (low byte) channels — see docs/assets.md §7. Used INSTEAD of the noise
## when set; a missing map degrades to the procedural base rather than breaking.
@export var authored_height: Texture2D

## Authored equirect albedo, used directly as the surface texture INSTEAD of
## baking one from `palette`.
@export var authored_albedo: Texture2D

## Authored places on this surface (docs/planet-renderer.md, "Detail sites").
@export var sites: Array[DetailSite] = []

## Fidelity tier (owner-approved 2026-08-23): resource-path prefix of a cooked
## height tile pyramid, e.g. "res://assets/planets/tiles/earth_h". Level L is a
## 2^(L+1) x 2^L equirect grid of 1024-square tiles in the same split encoding
## and reference elevations as the global map, so layers agree wherever both
## exist. Tiles are sparse — all-ocean L2 tiles are not cooked — and any lookup
## without a resident tile falls through to the global map. Empty = no tiles.
##
## Residency (streaming, owner-approved 2026-08-23): L1 is complete and small,
## so it loads eagerly in prepare() and never leaves — the seamless floor. L2
## tiles STREAM: PlanetSurface asks `wanted_l2_keys` for the observer's
## sub-body direction each evaluate, loads on the worker pool, and commits or
## releases through the replace-not-mutate swap below, which is what keeps
## in-flight patch builds consistent — their samplers snapshot the dictionary
## by reference and never see it change mid-build.
@export var height_tile_prefix: String = ""

const TILE_LEVELS: Array[int] = [2, 1]   # finest first — the sampler's order
const L2_COLS: int = 8
const L2_ROWS: int = 4

var _height_data: PackedByteArray
var _height_w: int = 0
var _height_h: int = 0
var _site_insets: Array = []
var _tiles: Dictionary = {}
var _l2_available: Dictionary = {}   # key -> res:// path, scanned once
var _prepared: bool = false


## Extract CPU-side pixel data from the authored textures and precompute the
## site inset lookups. Main thread, once, before any sampler is created on a
## worker: Texture2D.get_image() is not thread-safe, and neither is decoding.
## `radius` is the body's radius in metres — a site's footprint is metres on the
## sphere, so its angular extent is only knowable here.
func prepare(radius: float) -> void:
	if _prepared:
		return
	_prepared = true

	var img := _cpu_image(authored_height)
	if img != null:
		_height_data = img.get_data()
		_height_w = img.get_width()
		_height_h = img.get_height()

	_load_height_tiles()

	for site in sites:
		if site == null:
			continue
		var inset := _cpu_image(site.height_inset)
		if inset == null:
			continue
		_site_insets.append({
			"dir": site.direction(),
			"east": site.east(),
			"north": site.north(),
			"radius_rad": site.angular_radius(radius),
			"cos_limit": cos(minf(site.angular_radius(radius), PI)),
			"data": inset.get_data(),
			"w": inset.get_width(),
			"h": inset.get_height(),
		})


## Decode a Texture2D to an uncompressed RGB8 Image, or null. VRAM-compressed
## texture data would silently destroy the 16-bit split encoding, so this
## refuses rather than returning garbage — tests/planet_test.gd checks the
## decoded Earth map against the raster it was cooked from.
func _cpu_image(tex: Texture2D) -> Image:
	if tex == null:
		return null
	var img: Image = tex.get_image()
	if img == null:
		return null
	if img.is_compressed():
		push_warning(
			"BodySurface: %s imported VRAM-compressed; height precision is lost."
			% tex.resource_path)
		img.decompress()
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	return img


## Eager part of residency: all of L1 (the complete, seamless floor), plus a
## one-time scan of which L2 tiles the cook produced. L2 pixels arrive later
## through the streaming path below.
func _load_height_tiles() -> void:
	if height_tile_prefix == "":
		return
	var loaded := {}
	var cols: int = 1 << 2
	var rows: int = 1 << 1
	for ty in rows:
		for tx in cols:
			var path := "%s_L1_%d_%d.png" % [height_tile_prefix, tx, ty]
			if not ResourceLoader.exists(path):
				continue
			var timg := _cpu_image(load(path) as Texture2D)
			if timg == null:
				continue
			loaded["1:%d:%d" % [tx, ty]] = {
				"data": timg.get_data(),
				"w": timg.get_width(),
				"h": timg.get_height(),
			}
	_tiles = loaded
	for ty in L2_ROWS:
		for tx in L2_COLS:
			var path := "%s_L2_%d_%d.png" % [height_tile_prefix, tx, ty]
			if ResourceLoader.exists(path):
				_l2_available["2:%d:%d" % [tx, ty]] = path


func tile_count() -> int:
	return _tiles.size()


func l2_available_count() -> int:
	return _l2_available.size()


## --- L2 streaming (driven by PlanetSurface) -----------------------------------

## The available L2 keys whose footprint lies within `margin_deg` of the
## observer's sub-body direction (surface-local, i.e. the map frame). Called
## with a small margin to decide loads and a larger one to decide releases —
## the gap is the hysteresis that stops a boundary hover from thrashing tiles.
func wanted_l2_keys(dir_local: Vector3, margin_deg: float) -> Array:
	var out: Array = []
	if _l2_available.is_empty():
		return out
	var lon := rad_to_deg(atan2(dir_local.z, dir_local.x))
	var lat := rad_to_deg(asin(clampf(dir_local.y, -1.0, 1.0)))
	var span_lon := 360.0 / float(L2_COLS)
	var span_lat := 180.0 / float(L2_ROWS)
	for key in _l2_available:
		var parts: PackedStringArray = String(key).split(":")
		var tx := int(parts[1])
		var ty := int(parts[2])
		var lon0 := -180.0 + span_lon * float(tx)
		var lat1 := 90.0 - span_lat * float(ty)
		var dlon := _deg_outside(lon, lon0, lon0 + span_lon, true)
		var dlat := _deg_outside(lat, lat1 - span_lat, lat1, false)
		if maxf(dlon, dlat) <= margin_deg:
			out.append(key)
	return out


static func _deg_outside(x: float, lo: float, hi: float, wrap: bool) -> float:
	if x >= lo and x <= hi:
		return 0.0
	var d := minf(absf(x - lo), absf(x - hi))
	if wrap:
		d = minf(d, minf(absf(x - lo + 360.0), absf(x - hi - 360.0)))
		d = minf(d, minf(absf(x - lo - 360.0), absf(x - hi + 360.0)))
	return d


func l2_path(key: String) -> String:
	return _l2_available.get(key, "")


func is_tile_resident(key: String) -> bool:
	return _tiles.has(key)


func resident_l2_keys() -> Array:
	var out: Array = []
	for key in _tiles:
		if String(key).begins_with("2:"):
			out.append(key)
	return out


## Replace-not-mutate: in-flight samplers hold the old dictionary.
func commit_tile(key: String, tile: Dictionary) -> void:
	var next := _tiles.duplicate()
	next[key] = tile
	_tiles = next


func release_tile(key: String) -> void:
	if not _tiles.has(key):
		return
	var next := _tiles.duplicate()
	next.erase(key)
	_tiles = next


## Angular rect of a tile in the map frame, degrees: [lon0, lon1, lat0, lat1].
static func tile_rect_deg(key: String) -> Array:
	var parts: PackedStringArray = key.split(":")
	var level := int(parts[0])
	var cols: float = float(1 << (level + 1))
	var rows: float = float(1 << level)
	var tx := float(parts[1])
	var ty := float(parts[2])
	return [
		-180.0 + 360.0 / cols * tx, -180.0 + 360.0 / cols * (tx + 1.0),
		90.0 - 180.0 / rows * (ty + 1.0), 90.0 - 180.0 / rows * ty,
	]


func has_authored_height() -> bool:
	return _height_w > 0


## A sampler owns its noise instances, so each worker task can create one and
## sample without sharing mutable state across threads.
func make_sampler() -> HeightSampler:
	return HeightSampler.new(self)


class HeightSampler extends RefCounted:
	var amplitude: float
	var sea_level: float

	var _mix: float
	var _fbm := FastNoiseLite.new()
	var _ridged := FastNoiseLite.new()
	var _data: PackedByteArray
	var _w: int = 0
	var _h: int = 0
	var _sites: Array = []
	var _tiles: Dictionary = {}

	func _init(s: BodySurface) -> void:
		amplitude = s.amplitude
		sea_level = s.sea_level
		_mix = clampf(s.ridged_mix, 0.0, 1.0)
		_data = s._height_data
		_w = s._height_w
		_h = s._height_h
		_sites = s._site_insets
		# Snapshot reference: the dict is replaced (never mutated) on reload,
		# so a sampler mid-build on a worker keeps a consistent world.
		_tiles = s._tiles
		_fbm.noise_type = FastNoiseLite.TYPE_SIMPLEX
		_fbm.fractal_type = FastNoiseLite.FRACTAL_FBM
		_fbm.fractal_octaves = 5
		_fbm.frequency = s.continent_frequency
		_fbm.seed = s.noise_seed
		_ridged.noise_type = FastNoiseLite.TYPE_SIMPLEX
		_ridged.fractal_type = FastNoiseLite.FRACTAL_RIDGED
		_ridged.fractal_octaves = 4
		_ridged.frequency = s.continent_frequency * 2.3
		_ridged.seed = s.noise_seed + 101

	## Raw terrain height in [-1, 1] for a unit direction, before the sea clamp.
	func height_normalized(dir: Vector3) -> float:
		var n: float
		if _w > 0:
			n = _sample_authored(dir) * 2.0 - 1.0
		else:
			n = _fbm.get_noise_3dv(dir)
			if _mix > 0.0:
				n = lerpf(n, _ridged.get_noise_3dv(dir), _mix)
			# Simplex fBm rarely leaves ±0.6; stretch so the palette's ends get used.
			n = clampf(n * 1.6, -1.0, 1.0)
		return _blend_sites(dir, n)

	## Displacement as a fraction of body radius, sea-clamped: below the sea the
	## surface is the flat sea shell, so the ocean floor is never rendered.
	func height(dir: Vector3) -> float:
		var n: float = height_normalized(dir)
		if sea_level > -1.0:
			n = maxf(n, sea_level)
		return n * amplitude

	func is_sea(dir: Vector3) -> bool:
		return sea_level > -1.0 and height_normalized(dir) <= sea_level

	## Site insets, blended over the global height with a smoothstep falloff
	## across the footprint. Weight reaches zero exactly at the footprint edge,
	## so a site never puts a step into the surrounding terrain no matter how
	## differently its inset was encoded.
	func _blend_sites(dir: Vector3, n: float) -> float:
		for site in _sites:
			var d: float = dir.dot(site["dir"])
			if d <= site["cos_limit"]:
				continue
			var r: float = site["radius_rad"]
			var t: float = acos(clampf(d, -1.0, 1.0)) / r
			if t >= 1.0:
				continue
			var u: float = 0.5 + dir.dot(site["east"]) / (2.0 * r)
			var v: float = 0.5 - dir.dot(site["north"]) / (2.0 * r)
			var inset: float = _sample_split(
				site["data"], site["w"], site["h"], u, v, false) * 2.0 - 1.0
			n = lerpf(inset, n, smoothstep(0.0, 1.0, t))
		return n

	## Authored height: the finest resident tile wins, the global map is the
	## floor. Tiles share the global map's encoding and reference elevations,
	## so the switch between layers is a resolution change, not a value jump.
	func _sample_authored(dir: Vector3) -> float:
		var lon: float = atan2(dir.z, dir.x)
		var lat: float = asin(clampf(dir.y, -1.0, 1.0))
		var u: float = lon / TAU + 0.5
		var v: float = 0.5 - lat / PI
		if not _tiles.is_empty():
			for level in BodySurface.TILE_LEVELS:
				var cols: int = 1 << (level + 1)
				var rows: int = 1 << level
				var tx: int = clampi(int(u * float(cols)), 0, cols - 1)
				var ty: int = clampi(int(v * float(rows)), 0, rows - 1)
				var tile: Variant = _tiles.get("%d:%d:%d" % [level, tx, ty])
				if tile == null:
					continue
				return _sample_split(
					tile["data"], tile["w"], tile["h"],
					u * float(cols) - float(tx), v * float(rows) - float(ty),
					false)
		return _sample_split(_data, _w, _h, u, v, true)

	## Equirect lookup in exactly the shader's convention:
	## lon = atan2(dir.z, dir.x), lat = asin(dir.y), u = 0.5 + lon/TAU,
	## v = 0.5 - lat/PI. Any disagreement here shows up as a seam and as sites
	## sitting off their own coastline.
	func _sample_equirect(dir: Vector3) -> float:
		var lon: float = atan2(dir.z, dir.x)
		var lat: float = asin(clampf(dir.y, -1.0, 1.0))
		return _sample_split(_data, _w, _h, lon / TAU + 0.5, 0.5 - lat / PI, true)

	## Bilinear sample of a 16-bit height packed as red = high byte, green = low
	## byte in an RGB8 image. Nearest-neighbour would terrace the surface: a
	## depth-6 patch has 1.5 m vertex spacing against a 6 m global texel.
	func _sample_split(
		data: PackedByteArray, w: int, h: int, u: float, v: float, wrap_u: bool
	) -> float:
		var fx: float = u * float(w) - 0.5
		var fy: float = clampf(v * float(h) - 0.5, 0.0, float(h - 1))
		var x0: int = int(floor(fx))
		var y0: int = int(floor(fy))
		var tx: float = fx - float(x0)
		var ty: float = fy - float(y0)
		var x1: int = x0 + 1
		var y1: int = mini(y0 + 1, h - 1)
		if wrap_u:
			x0 = posmod(x0, w)
			x1 = posmod(x1, w)
		else:
			x0 = clampi(x0, 0, w - 1)
			x1 = clampi(x1, 0, w - 1)
		y0 = clampi(y0, 0, h - 1)
		var a: float = _texel(data, w, x0, y0)
		var b: float = _texel(data, w, x1, y0)
		var c: float = _texel(data, w, x0, y1)
		var e: float = _texel(data, w, x1, y1)
		return lerpf(lerpf(a, b, tx), lerpf(c, e, tx), ty)

	func _texel(data: PackedByteArray, w: int, x: int, y: int) -> float:
		var i: int = (y * w + x) * 3
		return (float(data[i]) * 256.0 + float(data[i + 1])) / 65535.0
