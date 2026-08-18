class_name PlanetBake
## Bakes a body's equirect albedo / normal / emissive textures from its
## BodySurface. Pure function of the surface parameters — deterministic — and
## safe to run on a WorkerThreadPool task (it only builds Images; the caller
## turns them into ImageTextures on the main thread, where GPU upload belongs).

## Exaggerates baked slope shading; relief is stylized, so is its lighting.
const NORMAL_EXAGGERATION: float = 2.0


## Returns { albedo: Image or null, normal: Image, emissive: Image or null }.
## An entry is null when the body carries an authored texture for it — the
## authored raster is used directly, so baking a substitute would be waste.
##
## `size` is the equirect WIDTH; the map is 2:1, as an equirect projection is.
static func bake(surface: BodySurface, radius: float, size: int = 1024) -> Dictionary:
	var sampler := surface.make_sampler()
	var w: int = size
	var h: int = size / 2

	var heights := PackedFloat32Array()
	heights.resize(w * h)
	for py in h:
		var lat: float = (0.5 - (float(py) + 0.5) / float(h)) * PI
		var cl: float = cos(lat)
		var sl: float = sin(lat)
		for px in w:
			var lon: float = ((float(px) + 0.5) / float(w) - 0.5) * TAU
			var dir := Vector3(cos(lon) * cl, sl, sin(lon) * cl)
			heights[py * w + px] = sampler.height_normalized(dir)

	var albedo: Image = null
	if surface.authored_albedo == null:
		albedo = _bake_albedo(surface, heights, w, h)
	var normal := _bake_normal(surface, heights, radius, w, h)
	var emissive: Image = null
	if surface.night_emissive == null:
		emissive = _bake_emissive(surface, heights, w, h)
	return {"albedo": albedo, "normal": normal, "emissive": emissive}


static func _bake_albedo(
	surface: BodySurface, heights: PackedFloat32Array, w: int, h: int
) -> Image:
	var data := PackedByteArray()
	data.resize(w * h * 3)
	var sea: float = surface.sea_level
	var has_sea: bool = sea > -1.0
	var banded: bool = surface.band_frequency > 0.0
	var palette: Gradient = surface.palette
	for py in h:
		var lat: float = (0.5 - (float(py) + 0.5) / float(h)) * PI
		for px in w:
			var idx: int = py * w + px
			var n: float = heights[idx]
			var c: Color
			if banded:
				# Latitude bands, wobbled by the height noise so the boundaries
				# meander instead of reading as ruled lines.
				var t: float = 0.5 + 0.5 * sin(
					lat * surface.band_frequency + n * surface.band_wobble
				)
				c = palette.sample(t) if palette else Color(0.7, 0.65, 0.55)
			elif has_sea and n <= sea:
				# Depth-shaded sea: darker toward the deeps.
				var depth: float = clampf((sea - n) / maxf(sea + 1.0, 0.05), 0.0, 1.0)
				c = surface.sea_color.darkened(depth * 0.55)
			else:
				var lo: float = sea if has_sea else -1.0
				var t: float = clampf((n - lo) / maxf(1.0 - lo, 0.05), 0.0, 1.0)
				c = palette.sample(t) if palette else Color(0.6, 0.6, 0.6)
			data[idx * 3] = int(clampf(c.r, 0.0, 1.0) * 255.0)
			data[idx * 3 + 1] = int(clampf(c.g, 0.0, 1.0) * 255.0)
			data[idx * 3 + 2] = int(clampf(c.b, 0.0, 1.0) * 255.0)
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RGB8, data)
	img.generate_mipmaps()
	return img


static func _bake_normal(
	surface: BodySurface, heights: PackedFloat32Array, radius: float, w: int, h: int
) -> Image:
	var data := PackedByteArray()
	data.resize(w * h * 3)
	var sea: float = surface.sea_level
	var has_sea: bool = sea > -1.0
	var amp_m: float = surface.amplitude * radius
	var dv_m: float = PI * radius / float(h)
	for py in h:
		var lat: float = (0.5 - (float(py) + 0.5) / float(h)) * PI
		# Texel width shrinks toward the poles; clamp so slopes stay finite.
		var du_m: float = TAU * radius * maxf(cos(lat), 0.05) / float(w)
		var py_n: int = maxi(py - 1, 0)
		var py_s: int = mini(py + 1, h - 1)
		for px in w:
			var idx: int = py * w + px
			var hc: float = _clamped(heights[idx], has_sea, sea)
			var he: float = _clamped(heights[py * w + (px + 1) % w], has_sea, sea)
			var hw: float = _clamped(heights[py * w + (px - 1 + w) % w], has_sea, sea)
			var hs: float = _clamped(heights[py_s * w + px], has_sea, sea)
			var hn: float = _clamped(heights[py_n * w + px], has_sea, sea)
			# x: slope east (+lon), y: slope south (+v). The shader rebuilds the
			# same east/south frame per pixel from the sphere direction.
			var sx: float = (he - hw) * amp_m / (2.0 * du_m)
			var sy: float = (hs - hn) * amp_m / (2.0 * dv_m)
			var nvec := Vector3(
				-sx * NORMAL_EXAGGERATION, -sy * NORMAL_EXAGGERATION, 1.0
			).normalized()
			data[idx * 3] = int((nvec.x * 0.5 + 0.5) * 255.0)
			data[idx * 3 + 1] = int((nvec.y * 0.5 + 0.5) * 255.0)
			data[idx * 3 + 2] = int((nvec.z * 0.5 + 0.5) * 255.0)
			# Suppress relief entirely on the flat sea shell.
			if has_sea and heights[idx] <= sea:
				data[idx * 3] = 127
				data[idx * 3 + 1] = 127
				data[idx * 3 + 2] = 255
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RGB8, data)
	img.generate_mipmaps()
	return img


static func _clamped(n: float, has_sea: bool, sea: float) -> float:
	return maxf(n, sea) if has_sea else n


## City lights clustered on coastal lowlands. The stand-in for an authored mask
## (see BodySurface.night_emissive, which Earth now carries as real Black Marble
## data): with the continents procedural, deriving lights from "land near the
## sea" puts them where cities read from orbit — along the coasts. Still the
## right answer for any body given a sea and no authored mask.
static func _bake_emissive(
	surface: BodySurface, heights: PackedFloat32Array, w: int, h: int
) -> Image:
	if not surface.city_lights or surface.sea_level <= -1.0:
		return null
	var clump := FastNoiseLite.new()
	clump.noise_type = FastNoiseLite.TYPE_SIMPLEX
	clump.fractal_type = FastNoiseLite.FRACTAL_FBM
	clump.fractal_octaves = 3
	clump.frequency = 7.0
	clump.seed = surface.noise_seed + 523
	var sea: float = surface.sea_level
	var data := PackedByteArray()
	data.resize(w * h)
	for py in h:
		var lat: float = (0.5 - (float(py) + 0.5) / float(h)) * PI
		var cl: float = cos(lat)
		var sl: float = sin(lat)
		for px in w:
			var n: float = heights[py * w + px]
			if n <= sea:
				continue
			# Brightest just above the waterline, fading uphill.
			var coast: float = 1.0 - clampf((n - sea) / 0.4, 0.0, 1.0)
			if coast <= 0.0:
				continue
			var lon: float = ((float(px) + 0.5) / float(w) - 0.5) * TAU
			var dir := Vector3(cos(lon) * cl, sl, sin(lon) * cl)
			var c: float = smoothstep(0.35, 0.75, clump.get_noise_3dv(dir) * 1.6)
			data[py * w + px] = int(clampf(coast * c, 0.0, 1.0) * 255.0)
	var img := Image.create_from_data(w, h, false, Image.FORMAT_L8, data)
	img.generate_mipmaps()
	return img
