# Cascade — Progressive Planet Renderer

Design for planets that gain detail as you approach: rough relief on **every**
body in the system, and authored detail — buildings, city lights, recognizable
places like New York — at select sites. Status: **designed, not built**. The
milestone breakdown is at the bottom and mirrored in docs/tasks.md.

## Goals

1. Every body the nav console can fly you to has terrain relief, not a smooth
   ball: coastlines and continents on Earth, maria on the Moon, canyons on Mars,
   banding on the gas giants. Detail increases continuously on approach with no
   pops and no loading screens.
2. Select surface sites carry authored detail: an inset heightmap plus placed
   geometry. Pilot site: **New York City**, visible as a recognizable lit
   coastline city from orbit.
3. Everything stays consistent with the systems already in place: 64-bit true
   space + floating origin, the angular-size proxy for far bodies, analytic
   orbits driven by SimClock, and the POLYGON art decision.

## Non-goals (for now)

- **Landing.** Ruled out for now (owner: gravity handling is the blocker, not
  interest). **Low skimming is in scope** — flying close over terrain — which
  promotes relief from visual-only to collidable near the surface; see "Skimming
  and collision" below. The renderer must hold up from standoff distance down to
  a skimming pass, not from a walking camera.
- **Atmospheric scattering / clouds.** A cheap rim-glow shell is listed as a
  stretch item; real scattering is out of scope.
- **Real-time terrain deformation.** Heightmaps are static.
- **Streamed or high-fidelity terrain data.** Explicitly deferred by the owner.
  Global maps are coarse (2k) and committed; the layered height lookup leaves
  room for a streaming tier later, but it is not built and not designed in detail.

## The scale problem, addressed head-on

The system is compressed: Earth's radius is 2,000 m against a real 6,371 km — a
factor of ~3,200. At that compression, real-scale NYC would be a 6 m smudge and
a real skyscraper less than 10 cm. **Surface detail therefore cannot be to
scale, and this document commits to that stylization** rather than fighting it,
exactly as architecture.md already does for distances and orbital periods:

- **Relief is exaggerated.** Displacement amplitude is a per-body parameter,
  ~1–3% of radius (Earth: ±40 m over r=2000). Real-Earth relief at true scale
  would be ±3 m — invisible. Exaggerated relief reads like a globe in relief,
  which is the correct look for a game played from orbit.
- **Detail sites are dioramas.** A site occupies a *gameplay-readable* footprint
  (200–500 m across on the sphere) regardless of its real extent, and its
  buildings are miniatures (tallest towers ~25–40 m). From the closest the
  player normally gets — a kilometre or two up — a 400 m lit grid with 30 m
  towers reads precisely as "looking down at Manhattan from orbit." This is the
  ISS-photo aesthetic, and it is the one the game's tone wants.
- **What we never do:** change a body's radius as the camera approaches, or run
  a second "surface scale" world. One world, one scale, stylized content. Every
  alternative (dynamic rescaling, scale bubbles) breaks the autopilot's analytic
  math, the reference-frame logic, or both, for the sake of a fidelity the
  gameplay never uses.

## Three regimes, one pipeline

The renderer is one cube-sphere quadtree per body; the "regimes" are just how
much of it is resident. Distances below are *true-space* distances from the
render origin (`CelestialBody.true_distance`).

```
distance:   >40 km (proxy)          40 km … ~3 r            < ~3 r (approach)
regime:     A — impostor            B — coarse shell        C — refined + sites
mesh:       root patches only,      quadtree to depth ~3,   quadtree to depth 6–7
            angular-size proxy      real position           near the camera,
            scaling (existing)                              site scenes streamed
```

- **Regime A** keeps the existing angular-size proxy exactly as is — but the
  mesh it scales is the LOD-0 cube-sphere with baked albedo/normal/emissive
  textures instead of today's flat-colour `SphereMesh`. Displacement scales with
  the proxy ratio like every other vertex, so the trick keeps working unchanged.
  From 2,000 km away, Earth is 12 triangles' worth of patches and one texture
  set, and looks like Earth.
- **Regime B** begins when the body un-proxies (≤40 km). Subdivision is driven
  by a screen-space-error metric (patch geometric error / distance), not by
  fixed distance bands, so it degrades gracefully at any FOV.
- **Regime C** is the same metric letting the tree run deeper near the camera,
  plus **detail-site streaming**: any site whose center is within ~3 km of the
  camera gets its scene instantiated and its inset heightmap blended into the
  patches that overlap it.

### Patch geometry

- Cube-sphere: 6 root faces, each a quadtree. Patch = 33×33 vertex grid
  (32×32 quads), normalized to the sphere, displaced by heightmap sample,
  vertices stored **relative to the patch center** (float32 stays exact at
  patch scale; the center is applied via the node transform, which the existing
  origin/proxy machinery already moves).
- Depth budget: face arc on Earth ≈ π/2 · 2000 ≈ 3,141 m. At depth 7 a patch
  spans ~24.5 m → ~0.77 m vertex spacing, far below anything visible from 1 km
  up. **Max depth 7**, and in practice the error metric will rarely ask past 5.
- Cracks: neighbouring patches at different depths are stitched with **skirts**
  (a ring of vertices dropped ~2% of patch size below the surface). Skirts are
  the boring, robust answer; geomorphing is a stretch goal, not a requirement.
- Collision — **skimming is supported** (owner decision, 2026-08-17). Far away,
  the analytic sphere collider from `celestial_body.gd` remains the physics
  truth. Within skim range (ship's true distance to surface < ~500 m) the
  renderer swaps collision sources: the sphere collider is disabled and the
  resident patches under and around the ship get trimesh
  (`ConcavePolygonShape3D`) colliders built from their render mesh on the same
  worker tasks. The swap matters in both directions: keeping the sphere enabled
  would wall the ship out of valleys (terrain dips below nominal radius), and
  without patch colliders the peaks above it would be intangible. Ship CCD is
  enabled inside skim range — 60 Hz physics and a fast pass over 25 m patches
  will tunnel otherwise. No gravity: skimming is powered flight over terrain,
  not a descent; gravity wells for the player stay out of scope until landing
  does (owner: landing is blocked on exactly that).

### Height sources: rough everywhere, authored where it matters

Layered, in order of precedence at any surface point:

1. **Procedural base — every body, free.** FastNoiseLite fBm seeded from the
   body id (deterministic across sessions), with per-body parameters in the new
   `BodySurface` resource: continent frequency, ridged mix for rocky bodies,
   sea level (bodies with a sea render a flat shell + distinct albedo below it),
   amplitude. Gas giants set amplitude 0 and get banded albedo instead — the
   pipeline treats "smooth with fancy albedo" as just another parameterization.
2. **Authored global map — coarse, committed, no streaming.** (Owner decision,
   2026-08-17: seed from NASA / open GIS data at coarse granularity; higher
   fidelity and streaming are explicitly deferred — "later we can investigate
   streaming and higher fidelity options if we even want it.")

   One equirectangular height map + albedo map per body, sampled instead of (not
   blended with) the procedural base where present. Public-domain / open sources:

   | Body | Height | Albedo |
   |---|---|---|
   | Earth | GEBCO or ETOPO1 (topography + bathymetry, so the sea floor is real too) | NASA Blue Marble |
   | Moon | LRO LOLA | LROC WAC mosaic |
   | Mars | MGS MOLA | Viking / MDIM colour mosaic |

   **Coarse means 2048×1024, and that is a deliberate ceiling, not a placeholder.**
   At Earth's compressed radius of 2,000 m one texel spans ~6 m of surface —
   already finer than the depth-7 vertex spacing of 0.77 m can be *fed* from a
   global map, and far finer than anything reads from orbit. A 4k map would cost
   4× the memory to describe detail the geometry cannot express.

   **Committed to the repo under `assets/planets/`, not fetched.** Three 2k PNG
   pairs are a few MB total, they never change, and committing them removes the
   asset-server write dependency and the whole fetch/cook path for this data.
   The server remains the right home for *mesh* packs; a handful of static
   scientific rasters is not the same problem. (This supersedes the earlier
   `CASCADE_Planets` raw-drop plan.)

   **Deferred, on the owner's call:** tiled/streamed height data, per-region
   high-resolution insets beyond the authored detail sites, and any runtime
   fetch. Nothing in this design forecloses them — the height source is already
   a layered lookup, so a streaming tier would slot in as a fourth layer above
   the site insets — but none of that machinery gets built now.
3. **Site insets — small and sharp.** Each detail site may carry a small
   high-resolution height inset (e.g. 512², covering its footprint) blended
   into patches over the site radius with a smoothstep falloff, so Manhattan
   gets its rivers and harbor even though the global map's texel there is
   hundreds of meters wide.

### Detail sites

```gdscript
class_name DetailSite extends Resource
@export var id: StringName            # &"nyc"
@export var display_name: String      # "New York"
@export var lat_deg: float            # +40.7
@export var lon_deg: float            # -74.0
@export var footprint_m: float        # 400.0 — diorama width on the sphere
@export var height_inset: Texture2D   # optional 16-bit inset
@export var scene: PackedScene        # buildings/props, authored miniature
@export var night_emissive: Texture2D # city-lights mask for the dark side
@export var nav_note: String          # shown when scanned/targeted (lore hook)
```

- The scene is authored flat (local XZ plane, Y up) and the streamer orients it
  to the sphere tangent at (lat, lon), so authoring a site is ordinary Godot
  scene work, not spherical-coordinate misery.
- **NYC pilot content:** POLYGON fits this better than it first appears —
  `POLYGON_SciFi_City` ships `SM_Bld_Background_*` meshes (purpose-built
  skyline filler, already low-poly) and `POLYGON_City` has 84 building glTFs
  for near-ground variety. A Manhattan diorama is a grid of ~60–100 background
  buildings at miniature scale on the site inset, plus an emissive
  street-grid texture for the night side. Near-future NYC in POLYGON style is
  tonally right for Planetes; add it to `fetch_assets.sh` DEFAULT_PACKS when
  PR3 starts, not before.
- Sites rotate with the body (see spin, below) and stream in/out on a distance
  hysteresis (in at 3 km, out at 4 km) so hovering at the boundary doesn't
  thrash.

### City lights (cheap, and the whole point)

The single highest-value visual in this design is **emissive city lights on the
dark side** — it is the canonical from-orbit image and it costs one emissive
texture channel at every regime. Baked into the global emissive map (Regime
A/B), sharpened by the site's `night_emissive` up close (Regime C), masked by
the terminator in the shader (emissive strength ramps in as the sun's dot
product goes negative). This lands in PR1 with even a hand-painted blob map,
long before real building geometry exists.

### Planet spin

Sites fix a point on the surface, so bodies must rotate. `BodyDef` gains
`spin_period` (simulation seconds, dramatized like orbital periods; ~10× the
orbit period feel, e.g. Earth ~1,800 s) and `spin_axis_tilt`. The surface mesh
and site anchors rotate; the collision sphere and all orbital/autopilot math are
untouched (rotation does not move the center). Reference-frame velocity
continues to ignore spin — parking "over" a site and watching it drift past at
~7 m/s is correct and is exactly the low-orbit feel we want. Time compression
during transfers makes planets visibly turn, for free, because spin derives from
`SimClock.sim_time` like everything else on rails.

## Generation pipeline

- Patch meshes are built on `WorkerThreadPool` tasks: sample heights → build
  arrays → `ArrayMesh` on the main thread (mesh upload is main-thread in Godot).
  One in-flight budget per body (~4 patches), so approach streams smoothly
  instead of hitching.
- LRU cache of built patches per body (budget ~256 patches ≈ 33² × 256 verts ≈
  9 MB); eviction only above depth 2 so the coarse shell never re-generates.
- Subdivision decisions run at most once per 0.25 s per body — the error metric
  changes slowly at flight speeds, and this keeps the quadtree walk off the
  frame budget.
- Determinism: same body id + same camera path ⇒ same meshes. No `Date`/random
  state anywhere in generation (noise is seeded), which keeps the golden-image
  tests meaningful.

## Integration contract (what changes in existing code)

| Existing piece | Change |
|---|---|
| `CelestialBody._build_visuals()` | builds a `PlanetSurface` node (root patches + baked textures) instead of `SphereMesh` when the body has a `BodySurface`; falls back to the current sphere otherwise. Sun keeps its emissive sphere. |
| Proxy clamp (`update_render`) | unchanged logic; it scales the `PlanetSurface` root exactly as it scaled the sphere. Regime B/C only ever run un-proxied, so patch code never sees a scaled world. |
| `BodyDef` | + `spin_period`, `spin_axis_tilt`, `surface: BodySurface` |
| `SolarSystemData` | per-body surface parameters (noise seeds, sea levels, palettes; Earth/Moon/Mars flagged for authored maps) |
| `OriginShift` | no change — patches live under the body node, which already repositions from true space per frame |
| Autopilot / nav console | no change; later, sites can appear as scan targets (`nav_note` hook) |
| Asset server | new raw drop `CASCADE_Planets` (public-domain height/albedo maps, cooked to PNG pairs); city packs added to fetch defaults at PR3 |

## Performance budget

Worst case (hovering at spawn altitude over Earth with NYC resident): ~120
patches ≈ 130k vertices, one material per body (all patches share it; per-patch
data rides in instance uniforms), plus a ~100-building site scene ≈ 50k
vertices. Trivial for any real GPU; the constraint that actually binds is the
**llvmpipe software renderer the headless test rig uses**, so the automated
tests pin patch *counts*, not frame times, and screenshot capture uses Regime B
depth caps.

## Verification (same discipline as travel/EVA)

`tests/planet_test.gd`, headless:
- seam integrity: shared-edge vertices of adjacent same-depth patches agree to
  within epsilon (catches the classic quadtree crack bug analytically, no
  screenshots needed)
- error metric monotonicity: approaching camera ⇒ tree depth never decreases;
  receding ⇒ resident patch count returns to baseline (streaming leak check)
- determinism: two builds of the same patch id are bit-identical
- budget: resident patches / in-flight tasks never exceed caps during a scripted
  approach from proxy range to spawn altitude
- spin: a site's world position at t and t + spin_period/2 are antipodal about
  the spin axis; site streams in only inside its radius
- plus `capture_shots.gd` additions: Earth full disc (A), limb at 30 km (B),
  NYC at night from 2 km (C) — the money shot for review

## Milestones

- **PR1 — Relief everywhere + night lights.** `BodySurface` resource, cube-sphere
  root patches with procedural height + baked albedo/normal/emissive, spin,
  terminator-masked city-light emissive (hand-painted mask), proxy integration.
  Every body immediately stops being a smooth ball. No quadtree yet.
- **PR2 — Progressive refinement.** Quadtree + screen-error metric + skirts +
  threaded generation + cache + `planet_test.gd`. Approach becomes continuous.
  Includes **skim collision**: trimesh colliders on near patches, the
  sphere-collider swap, and ship CCD in skim range — with a test that flies a
  scripted low pass and asserts no tunnelling and no invisible-sphere blocking.
- **PR3 — Detail sites + NYC pilot.** `DetailSite` streaming, inset blending,
  authored Earth/Moon/Mars maps cooked onto the asset server, Manhattan diorama
  from POLYGON city packs, night-emissive street grid, screenshots.
- **PR4 (stretch).** Atmosphere rim shell, cloud layer, geomorphing, more sites.

Ordering rationale: PR1 is the highest visible value per line of code (every
destination in the nav console improves at once, and city lights land), PR2 is
pure infrastructure with a test suite, PR3 is the first authored content and
depends on both. Each PR is independently shippable and screenshot-reviewable.

## Open questions for the owner

1. **Real-Earth maps:** green-light the `CASCADE_Planets` asset-server drop
   (public-domain NASA data)? Without it Earth is plausible-but-fictional and
   NYC sits on an invented coastline; the pilot loses its punch.
2. **Site list beyond NYC:** natural candidates given the tone — Cape Canaveral,
   Baikonur, Shanghai lights, Tycho crater base (Moon), Olympus Mons survey
   station (Mars). Which matter enough to author?
3. ~~Does relief ever need to be felt (collision)?~~ **Answered: yes — low
   skimming is wanted** (no landing yet; gravity is the blocker there). Folded
   into PR2 as the skim-collision item above.
