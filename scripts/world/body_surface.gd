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
## always produces bit-identical terrain — tests/planet_test.gd asserts it.

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
@export var sea_level: float = -1.0

## Land colours, sampled by normalized height above the sea (or above the
## global minimum when there is no sea). For banded bodies, sampled by latitude.
@export var palette: Gradient

@export var sea_color: Color = Color(0.07, 0.19, 0.36)

## > 0: albedo comes from latitude bands (gas giants) instead of height.
@export var band_frequency: float = 0.0

## How strongly noise wobbles the band boundaries (radians of latitude-ish).
@export var band_wobble: float = 0.0

## Bake emissive night lights clustered on coastal lowlands (Earth). Stands in
## for the hand-painted blob mask until authored maps exist (PR3).
@export var city_lights: bool = false

## Authored equirect night-lights mask. Overrides the baked `city_lights` mask.
@export var night_emissive: Texture2D

## Authored equirect 16-bit height map. Used INSTEAD of noise when set.
@export var authored_height: Texture2D

## Authored equirect albedo. Used INSTEAD of the palette bake when set.
@export var authored_albedo: Texture2D

var _authored_height_img: Image = null
var _prepared: bool = false


## Extract CPU-side images from authored textures. Main thread, once, before
## any sampler is created on a worker (Texture2D.get_image is not thread-safe).
func prepare() -> void:
	if _prepared:
		return
	_prepared = true
	if authored_height != null:
		_authored_height_img = authored_height.get_image()
		if _authored_height_img != null and _authored_height_img.is_compressed():
			_authored_height_img.decompress()


func authored_height_image() -> Image:
	return _authored_height_img


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
	var _authored: Image = null

	func _init(s: BodySurface) -> void:
		amplitude = s.amplitude
		sea_level = s.sea_level
		_mix = clampf(s.ridged_mix, 0.0, 1.0)
		_authored = s.authored_height_image()
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
		if _authored != null:
			return _sample_equirect(dir) * 2.0 - 1.0
		var n: float = _fbm.get_noise_3dv(dir)
		if _mix > 0.0:
			n = lerpf(n, _ridged.get_noise_3dv(dir), _mix)
		# Simplex fBm rarely leaves ±0.6; stretch so the palette's ends get used.
		return clampf(n * 1.6, -1.0, 1.0)

	## Displacement as a fraction of body radius, sea-clamped: below the sea the
	## surface is the flat sea shell, so the ocean floor is never rendered.
	func height(dir: Vector3) -> float:
		var n: float = height_normalized(dir)
		if sea_level > -1.0:
			n = maxf(n, sea_level)
		return n * amplitude

	func is_sea(dir: Vector3) -> bool:
		return sea_level > -1.0 and height_normalized(dir) <= sea_level

	func _sample_equirect(dir: Vector3) -> float:
		var lon: float = atan2(dir.z, dir.x)
		var lat: float = asin(clampf(dir.y, -1.0, 1.0))
		var w: int = _authored.get_width()
		var h: int = _authored.get_height()
		var px: int = clampi(int((lon / TAU + 0.5) * float(w)), 0, w - 1)
		var py: int = clampi(int((0.5 - lat / PI) * float(h)), 0, h - 1)
		return _authored.get_pixel(px, py).r
