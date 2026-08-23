# Cascade — Progressive Planet Renderer

Design for planets that gain detail as you approach: rough relief on **every**
body in the system, and authored detail — buildings, city lights, recognizable
places like New York — at select sites. Status: **PR1–PR3 built**; PR4 is the remaining stretch. The
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
- **Clouds.** A separate animated layer is still out of scope.
  (Atmospheric scattering is no longer a non-goal — the owner promoted it to
  PR4 on 2026-08-18, with accurate lighting as the point of the exercise. See
  "Atmosphere and scattering" below.)
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
   | Earth | NOAA **ETOPO 2022** 60 arc-sec surface elevation (topography + bathymetry, so the sea floor is real too) | NASA **Blue Marble NG** — plus **Black Marble 2016** as the night-lights map |
   | Moon | **LRO LOLA** (via the NASA SVS CGI Moon Kit) | **LROC WAC** mosaic (same kit) |
   | Mars | **MGS MOLA MEGDR** 16 px/deg | USGS **Viking** colourised global mosaic |

   **Built at PR3, all real data.** Exact URLs, the 16-bit split-channel PNG
   encoding, and the one authored (non-data) raster are documented in
   docs/assets.md §7; the cook is `tools/cook_planet_maps.py`. Earth's
   `sea_level` is now `0.0` because the cook puts true mean sea level at the
   encoding's exact zero — the coastline is a datum rather than a tuned
   constant, which is what stopped Earth's water reading as scattered lakes.

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

   **Update, 2026-08-23 (owner call): the fidelity tier is partially built.**
   PR6 added the tiled height layer — an ETOPO tile pyramid (L1 complete at
   effective 4096, L2 land-only at effective 8192), eagerly loaded, with the
   sampler preferring the finest resident tile per lookup — and raised Earth's
   albedo to 4096. See docs/tasks.md PR6 and docs/assets.md §7.3.
   **Still deferred:** distance-based tile streaming and any runtime fetch;
   the replace-not-mutate tile dictionary is the designed seam for both.
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
| Asset server | *no change*. The `CASCADE_Planets` drop was cancelled by the owner's coarse-and-committed decision; the maps live in `assets/planets/` in the repo. `POLYGON_SciFi_City` + `POLYGON_City` were added to `DEFAULT_PACKS` at PR3 |

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

## Atmosphere and scattering (PR4 — BUILT)

Status 2026-08-22: implemented and gated by `tests/atmosphere_test.gd`; see
docs/tasks.md PR4 for per-item notes. One deliberate deviation from the plan
below: the sky-view and froxel LUTs are replaced by a per-pixel march in the
shell shader that consumes the baked transmittance and multi-scatter LUTs —
at this scale the march is cheap, and clamping it against the live depth
buffer is the aerial perspective with nothing to rebuild when the sun or
camera moves.

Owner direction, 2026-08-18: atmosphere on all planets, **with special attention
to accurate lighting**. The lighting is the substance here; a coloured rim shell
would be a sticker. What follows is what "accurate" has to mean for a game played
from orbit.

### What atmosphere changes about light

1. **Rayleigh scattering** — molecular, wavelength⁻⁴, so blue scatters ~5.5×
   more than red. Gives the blue day sky, the blue limb arc from orbit, and red
   sunsets (long slant path scatters the blue out before it reaches the eye).
2. **Mie scattering** — aerosols and dust, largely wavelength-neutral and
   strongly forward-scattering. The white haze around the sun, the whole of
   Venus, and most of Mars's colour.
3. **A soft terminator.** This is the one that matters most here and the one a
   rim shell cannot fake. An airless body has a razor day/night line; an
   atmosphere lights a twilight band *past* the geometric terminator, whose
   angular width follows from scale height and planet radius. **Our city-lights
   gate currently hardcodes that width** as `smoothstep(0.05, -0.15, dot(n, sun))`
   in planet_surface.gdshader. Once atmosphere exists, twilight width must be
   derived from the atmosphere parameters and *drive* that gate, or the lights
   will fade across a different band than the sky does and the two will visibly
   disagree at the terminator.
4. **Aerial perspective** — terrain seen through air desaturates and shifts
   toward the sky colour with distance. Newly relevant because PR2 added
   skimming: flying low, distant terrain should haze out rather than stay
   crisp to the horizon.
5. **Limb glow** — the iconic orbital image: a bright arc on the limb against
   black, brightest where the sun sits behind it (forward Mie). Falls out of
   correct optical depth along a grazing ray; it does not need special-casing.
6. **Ambient from the sky.** `scenes/game_world.tscn` currently fakes fill with a
   flat `ambient_light_energy = 1.1`. In atmosphere that fill is really sky
   scattering, and should ideally come from the same model near a body — noted
   as a stretch, not required for the gate.

### Approach — precomputed multiple scattering (Hillaire 2020)

Owner direction 2026-08-19: use the most advanced modelling we can. This
supersedes the earlier single-scattering call.

The target is **Hillaire's "A Scalable and Production Ready Sky and Atmosphere
Rendering Technique" (2020)**, which is the current production standard and
strictly better than the Bruneton 2008 4D LUT for our case — it includes
multiple scattering at a fraction of the memory and rebuilds cheaply when
parameters change (which matters: we have a dozen bodies, not one Earth).

Four LUTs, all recomputed only when a body's parameters or the sun direction
change materially:

| LUT | Size | Contents |
|---|---|---|
| Transmittance | 256×64 | Optical depth from any altitude/zenith-angle to space. Analytic per texel |
| Multi-scattering | 32×32 | Hillaire's dual-scattering approximation of orders 2..∞ |
| Sky-view | 200×100 | The visible sky dome for the current camera altitude, non-linear latitude parameterization to keep horizon detail |
| Aerial perspective | 32×32×32 froxels | In-scatter + transmittance through the camera frustum, for terrain seen through air |

**Why multiple scattering is not optional here.** Single scattering makes
twilight far too dark and the day sky under-saturated — most of the light
reaching your eye from a clear sky has bounced more than once. Since the
terminator is the region this project frames every screenshot on, getting orders
2+ wrong would show up in exactly the shots that matter.

### Physical model — what "accurate" includes beyond Rayleigh + Mie

- **Ozone absorption.** The detail that separates accurate from approximate.
  Earth's ozone layer (peak ~25 km, tent-shaped profile) absorbs in the Chappuis
  band, ~500–700 nm. It is why twilight goes *deep blue* instead of muddy grey as
  the sun drops — without it the sunset gradient is visibly wrong no matter how
  good the scattering is. Modelled as a third extinction term with its own
  altitude profile, zero scattering, pure absorption.
- **Per-body phase functions.** Rayleigh's `(3/16π)(1+cos²θ)` for molecules;
  Cornette-Shanks (a better-behaved Henyey-Greenstein) for aerosols. Mars dust is
  coarser and more forward-scattering than terrestrial haze — that, plus the
  absence of significant Rayleigh, is *why* Mars has blue sunsets and a
  butterscotch day sky, the exact inverse of Earth. Titan wants a layered haze
  with strong forward scatter.
- **Planetary shadow in the atmosphere.** The night side's air is in the body's
  own shadow; the shell must respect it, or the limb glows all the way round.
- **Altitude-correct camera.** The sky-view LUT is parameterized on camera
  altitude, so the same model serves orbit, low pass and skim without special
  cases.
- **Refraction** (stretch): near-horizon bending — the sun sits visibly above its
  geometric position at sunrise. Physically real, cheap as a per-ray offset,
  entirely optional.

### The scale trap, and how to get it right

Our Earth is 2,000 m, not 6,371 km. Do **not** plug real scale heights in
metres — an 8.5 km Rayleigh scale height on a 2 km planet is an atmosphere four
times taller than the world.

**Preserve the ratios, not the absolutes.** What determines the look — twilight
band width, limb arc thickness, how fast the sky reddens — is scale height over
planet radius. Real Earth: 8.5 km / 6371 km ≈ 0.00133. Ours should be the same
fraction of 2,000 m ≈ 2.7 m, with the dense shell at ~1–2% of radius. Get the
ratio right and the compressed planet reads as a real one; get it wrong and it
looks like a gas giant or a bare rock with a blue line.

### Validating "accurate" against reality

Advanced technique earns its keep only if the output is checkable, so the gate
compares against published values rather than taste:

- Zenith sky chromaticity at solar noon should land near CIE daylight D65.
- The R/B ratio at the horizon should rise by roughly an order of magnitude
  between sun elevation +10° and −2°.
- Civil twilight (sun 0° to −6°) should still light the sky measurably; the band
  width in degrees follows from scale height / radius and is directly assertable.
- Mars: day sky redder than its sunset, sunset bluer than its day sky — the
  inversion is the correctness test for the phase-function work.

### Per-body parameters (new `BodyAtmosphere` resource)

Every body gets an explicit answer, including "none" — **airless bodies must keep
looking airless**. The Moon's harsh, high-contrast, hard-terminator look is a
real visual signature and the easy failure mode here is applying a default
atmosphere everywhere and quietly destroying it.

| Body | Atmosphere |
|---|---|
| Earth | Rayleigh-dominant, blue, ~1% of radius |
| Venus | Thick, opaque, yellow-white; surface effectively never visible |
| Mars | Thin, dusty; Mie-dominant butterscotch, blue-ish sunsets (the inverse of Earth) |
| Titan | Thick orange haze, Mie-dominant |
| Jupiter, Saturn, Uranus, Neptune | No shell — the visible "surface" already *is* atmosphere. A limb-softening term only |
| Mercury, Moon, Io, Europa, Ganymede, Callisto | **None.** Hard terminator, black limb |

### Traps this will hit

- **The proxy clamp.** A far body renders at `MAX_RENDER_DISTANCE` scaled down; the
  shell must scale through the same `_apply_scale` path or it detaches from its
  planet at range. This is the contract travel_test guards.
- **Camera inside the shell.** Skimming and low orbit put the camera *inside* the
  atmosphere volume. Back-face rendering with the right depth handling is
  required, or the sky vanishes exactly when the player is closest to it.
- **Sun direction** already exists — `planet_sun_direction` global uniform,
  mirrored by `SolarSystem.sun_direction`. Reuse it; do not add a second source.
- **Composite order** with the surface shader's ALBEDO/EMISSION, so night lights
  read *through* thin atmosphere but are properly extinguished by thick.

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
- **PR3 — Detail sites + NYC pilot. BUILT.** `DetailSite` streaming (in at 3 km,
  out at 4 km), inset blending with a smoothstep falloff, coarse authored
  Earth/Moon/Mars maps committed under `assets/planets/` (the asset-server drop
  was dropped — see the note above), Manhattan diorama from
  `POLYGON_SciFi_City`, night-emissive street grid, screenshots 21–27.
- **PR4 — Atmosphere and scattering. BUILT.** Hillaire-2020 precomputed
  multiple scattering (transmittance + ψ_ms LUTs per body, worker-baked),
  per-pixel shell march with planetary shadow and depth-clamped aerial
  perspective, per-channel Cornette-Shanks (the Mars inversion), ozone,
  derived twilight driving the city-light gate, sky-derived ambient fill.
- **PR5 — clouds + geomorphing + sun glare. BUILT** (2026-08-22, see
  docs/tasks.md): procedural lit cloud deck under the atmosphere shell,
  per-vertex parent-surface geomorph targets with an error-driven morph
  factor (LOD transitions no longer pop geometry), limb-darkened blooming
  sun disc with an occlusion-correct billboard glare. More detail sites
  remain the open item.

Ordering rationale: PR1 is the highest visible value per line of code (every
destination in the nav console improves at once, and city lights land), PR2 is
pure infrastructure with a test suite, PR3 is the first authored content and
depends on both. Each PR is independently shippable and screenshot-reviewable.

## Open questions for the owner

1. ~~**Real-Earth maps:** green-light the `CASCADE_Planets` asset-server drop?~~
   **Answered and shipped at PR3**, in a smaller form than proposed: coarse
   (2048x1024) public-domain rasters committed to `assets/planets/`, no server
   drop, no streaming. Earth, the Moon and Mars all carry real data; NYC sits on
   the real coastline.
2. ~~**Site list beyond NYC:** natural candidates given the tone — Cape Canaveral,
   Baikonur, Shanghai lights, Tycho crater base (Moon), Olympus Mons survey
   station (Mars). Which matter enough to author?~~ **Answered 2026-08-23:
   Cape Canaveral built; everything else dropped permanently by owner
   decision.** Do not propose more sites — the owner is evaluating the two
   that exist and will say explicitly if the system should roll out further.
3. ~~Does relief ever need to be felt (collision)?~~ **Answered: yes — low
   skimming is wanted** (no landing yet; gravity is the blocker there). Folded
   into PR2 as the skim-collision item above.
