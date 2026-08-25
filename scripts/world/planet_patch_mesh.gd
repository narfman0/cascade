class_name PlanetPatchMesh
## Pure, deterministic cube-sphere patch geometry builder.
##
## A patch is a 33×33 vertex grid (32×32 quads) on one cube face, normalized to
## the sphere and displaced by the body's height sampler, plus a skirt ring
## dropped below the surface to hide cracks between neighbouring depths.
## Vertices are BODY-local (patch node sits at the body origin). They used to
## be patch-relative, with the shader re-adding a `patch_center` instance
## uniform — until an Android build showed instance uniforms do not survive
## real GLES drivers: patch_center read as zero and every patch textured
## itself as a starburst. float32 is comfortable here anyway (Jupiter's
## 8000 m radius leaves ~1 mm against metre-scale vertex spacing).
##
## Everything here is a static function of (surface, radius, face, depth, x, y)
## with no other state — same inputs, bit-identical arrays, on any thread. That
## is what makes the worker-pool build path and the determinism test honest.

## Quads per patch side. 33×33 vertices.
const GRID: int = 32


## Map face-local (u, v) in [0,1]² to a unit sphere direction. Values outside
## [0,1] are legal (the normal-sampling apron pokes past face edges) — the cube
## point just extends beyond the face square and still normalizes cleanly.
## Every face is oriented u-right / v-down as seen from outside the sphere, so
## one triangle winding serves all six.
static func face_dir(face: int, u: float, v: float) -> Vector3:
	var a: float = 2.0 * u - 1.0
	var b: float = 2.0 * v - 1.0
	match face:
		0:
			return Vector3(1.0, -b, -a).normalized()
		1:
			return Vector3(-1.0, -b, a).normalized()
		2:
			return Vector3(a, 1.0, b).normalized()
		3:
			return Vector3(a, -1.0, -b).normalized()
		4:
			return Vector3(a, -b, 1.0).normalized()
		_:
			return Vector3(-a, -b, -1.0).normalized()


static func patch_key(face: int, depth: int, x: int, y: int) -> String:
	return "%d:%d:%d:%d" % [face, depth, x, y]


## Arc length of one patch side, metres, at a given depth.
static func span_m(radius: float, depth: int) -> float:
	return radius * (PI / 2.0) / float(1 << depth)


## Build the mesh arrays for one patch. Returns:
##   verts / normals: PackedVector3Array (grid then 4 skirt rows)
##   indices: PackedInt32Array (grid triangles first, then skirt triangles)
##   grid_index_count: int — index count before skirts (collision uses only
##     these: skirts point inward and would add useless triangles)
##   center: Vector3 — undisplaced sphere point at patch center. Vertices are
##   BODY-local (not patch-relative), so this is metadata for LOD/site math
##   and collider placement, NOT an offset to add to verts.
##     local position under PlanetSurface
static func build_arrays(
	surface: BodySurface, radius: float, face: int, depth: int, x: int, y: int,
	skirt_drop: float
) -> Dictionary:
	var sampler := surface.make_sampler()
	var div: float = float(1 << depth)
	var n: int = GRID + 1
	var apron_n: int = n + 2

	# Displaced positions over the grid plus a one-vertex apron on every side,
	# so central-difference normals are computed from the same analytic height
	# field on both sides of a patch edge — normals then agree across seams.
	var apron: PackedVector3Array = PackedVector3Array()
	apron.resize(apron_n * apron_n)
	for jj in apron_n:
		var v: float = (float(y) + float(jj - 1) / float(GRID)) / div
		for ii in apron_n:
			var u: float = (float(x) + float(ii - 1) / float(GRID)) / div
			var dir := face_dir(face, u, v)
			apron[jj * apron_n + ii] = dir * (radius * (1.0 + sampler.height(dir)))

	var center: Vector3 = face_dir(
		face, (float(x) + 0.5) / div, (float(y) + 0.5) / div
	) * radius

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	verts.resize(n * n)
	normals.resize(n * n)
	for j in n:
		for i in n:
			var ai: int = (j + 1) * apron_n + (i + 1)
			var p: Vector3 = apron[ai]
			# BODY-local, not patch-local. Patch-local vertices existed only so
			# the shader could re-add a `patch_center` instance uniform — and
			# instance uniforms do not survive real GLES drivers under the
			# Compatibility renderer (Android): patch_center read as zero,
			# v_sdir swept the whole equirect map across every patch, and the
			# planet textured itself as per-patch starbursts. Body-local costs
			# nothing: Jupiter's 8000 m radius still leaves ~1 mm of float32
			# precision against metre-scale vertex spacing.
			verts[j * n + i] = p
			# cross(dv, du) points outward on every face (u-right, v-down).
			var du: Vector3 = apron[ai + 1] - apron[ai - 1]
			var dv: Vector3 = apron[ai + apron_n] - apron[ai - apron_n]
			var nrm: Vector3 = dv.cross(du).normalized()
			if nrm.dot(p) < 0.0:
				nrm = -nrm
			normals[j * n + i] = nrm

	# Geomorph targets (PR5): every vertex's position and normal on the PARENT
	# depth's rendered surface. Even-indexed vertices sample the same sphere
	# point as a parent vertex, so their target is their own position; odd ones
	# sit on the parent's linear interpolation — edge midpoints, and for the
	# odd/odd quad centre the midpoint of the ANTI-diagonal, because that is
	# the edge the parent's two triangles actually share. The surface shader
	# lerps toward these by a per-patch morph factor, so a freshly split patch
	# renders exactly as its parent did and refinement never pops.
	var pverts := PackedVector3Array()
	var pnorms := PackedVector3Array()
	pverts.resize(n * n)
	pnorms.resize(n * n)
	if depth == 0:
		for k in n * n:
			pverts[k] = verts[k]
			pnorms[k] = normals[k]
	else:
		for j in n:
			for i in n:
				var idx: int = j * n + i
				var odd_i: bool = (i & 1) == 1
				var odd_j: bool = (j & 1) == 1
				if not odd_i and not odd_j:
					pverts[idx] = verts[idx]
					pnorms[idx] = normals[idx]
				elif odd_i and not odd_j:
					pverts[idx] = (verts[idx - 1] + verts[idx + 1]) * 0.5
					pnorms[idx] = (normals[idx - 1] + normals[idx + 1]).normalized()
				elif not odd_i:
					pverts[idx] = (verts[idx - n] + verts[idx + n]) * 0.5
					pnorms[idx] = (normals[idx - n] + normals[idx + n]).normalized()
				else:
					pverts[idx] = (verts[idx - n + 1] + verts[idx + n - 1]) * 0.5
					pnorms[idx] = (normals[idx - n + 1] + normals[idx + n - 1]).normalized()

	var indices := PackedInt32Array()
	for j in GRID:
		for i in GRID:
			var i00: int = j * n + i
			var i10: int = j * n + i + 1
			var i01: int = (j + 1) * n + i
			var i11: int = (j + 1) * n + i + 1
			# Godot front faces wind clockwise as seen from outside.
			indices.append(i00)
			indices.append(i10)
			indices.append(i01)
			indices.append(i10)
			indices.append(i11)
			indices.append(i01)
	var grid_index_count: int = indices.size()

	# Skirts: each edge gets a duplicate row dropped radially below the surface.
	# Treating the skirt row as one more (virtual) grid row beyond the edge lets
	# the standard grid winding apply unchanged, so the walls face outward.
	var drop: float = skirt_drop * span_m(radius, depth)
	var edges: Array = [
		# [start grid index, step, is outer row "before" the edge in grid order]
		[0, 1, true],                    # top (j = 0), outer row is j = -1
		[(n - 1) * n, 1, false],         # bottom (j = 32), outer row is j = 33
		[0, n, true],                    # left (i = 0), outer col is i = -1
		[n - 1, n, false],               # right (i = 32), outer col is i = 33
	]
	for edge in edges:
		var start: int = edge[0]
		var step: int = edge[1]
		var outer_first: bool = edge[2]
		var base: int = verts.size()
		for k in n:
			var gi: int = start + k * step
			# verts are already body-local — adding center here double-counted
			# it and skewed every skirt's fall direction.
			var p: Vector3 = verts[gi]
			var fall: Vector3 = p.normalized() * drop
			verts.append(verts[gi] - fall)
			normals.append(normals[gi])
			# Skirts morph with the edge they hang from, or they would tear
			# open exactly during the transition they exist to hide.
			pverts.append(pverts[gi] - fall)
			pnorms.append(pnorms[gi])
		for k in GRID:
			var s0: int = base + k
			var s1: int = base + k + 1
			var g0: int = start + k * step
			var g1: int = start + (k + 1) * step
			if outer_first:
				indices.append(s0)
				indices.append(s1)
				indices.append(g0)
				indices.append(s1)
				indices.append(g1)
				indices.append(g0)
			else:
				indices.append(g0)
				indices.append(g1)
				indices.append(s0)
				indices.append(g1)
				indices.append(s1)
				indices.append(s0)

	return {
		"verts": verts,
		"normals": normals,
		"indices": indices,
		"grid_index_count": grid_index_count,
		"center": center,
		"key": patch_key(face, depth, x, y),
		"parent_pos": _flatten(pverts),
		"parent_nrm": _flatten(pnorms),
	}


## CUSTOM mesh arrays take flat floats, not Vector3s — and FOUR of them per
## vertex, not three. `ARRAY_CUSTOM_RGB_FLOAT` (3-component) is not reliably
## delivered by GLES3 drivers under the Compatibility renderer: CUSTOM0 then
## reads as zero, the geomorph mixes every vertex toward the patch's own
## local origin, and the planet shatters into per-patch starbursts (seen on
## an Android build, reproduced on the desktop by
## tests/capture_morph_probe.gd). RGBA_FLOAT costs one padding float per
## vertex per channel and works everywhere.
static func _flatten(v: PackedVector3Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(v.size() * 4)
	for i in v.size():
		var p: Vector3 = v[i]
		out[i * 4] = p.x
		out[i * 4 + 1] = p.y
		out[i * 4 + 2] = p.z
		out[i * 4 + 3] = 0.0
	return out


## Flattened triangle list for a ConcavePolygonShape3D, body-local.
## Grid triangles only — skirts are render-side crack fillers, not terrain.
static func collision_faces(arrays: Dictionary) -> PackedVector3Array:
	var verts: PackedVector3Array = arrays["verts"]
	var indices: PackedInt32Array = arrays["indices"]
	var count: int = arrays["grid_index_count"]
	var faces := PackedVector3Array()
	faces.resize(count)
	for i in count:
		faces[i] = verts[indices[i]]
	return faces
