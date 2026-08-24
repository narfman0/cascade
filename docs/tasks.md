# Cascade — Task Board

_This file is populated by agents. Do not edit manually._

**Ordering directive (from project owner, updated 2026-08-17):** Implementation
order is now **Track SD (stations + docking) first, then Track PR (planet
renderer)**. The original directive stands underneath: model 3D flight
accurately; movement correctness before content.

**Flight feel SIGNED OFF by owner 2026-08-23** ("flight feel is good") — the
M1/M2 human-feel gate on M3 is satisfied. Track LD is BUILT (owner approved
2026-08-24): **M3 (debris/tools/contracts) is now the main line**, and its
debris substrate already exists — `SpaceRock` fields with wake/sleep and
latching are live in the world. Contracts hang directly off them.

**Running the suites:** all exit cleanly and fast — travel ~8 s, docking
~7 s, eva ~8 s, station ~12 s, planet ~127 s, atmosphere ~35 s, every one exit 0. If a suite ever
hangs after printing PASS again, suspect un-drained `WorkerThreadPool` tasks:
Godot blocks on the pool at shutdown, so any node that spawns tasks must wait for
them in `_exit_tree` (see `PlanetSurface._exit_tree`).

**Standing traps — read before writing any code in this project:**
1. Never nest a RigidBody3D under another RigidBody3D (both transforms corrupt; see architecture.md). The EVA suit stows *out of the tree* while aboard.
2. The physics server owns a live RigidBody3D's transform and reverts script writes — `freeze = true` before setting position/basis, and hold poses across *physics* frames (a frozen kinematic body's transform only commits through a physics step).
3. `origin_shiftable` group membership: join it only for nodes holding a real render-space position (ship, suit). Anything recomputed from true space each frame (bodies, anchors, stations) must NOT join, or it gets double-shifted.
4. Children `_ready` before parents: never place world content against the render origin in a child's `_ready` — GameWorld establishes the origin, then calls `refresh()`. Follow that bootstrap pattern.
5. The ship station-keeps at ~131 m/s absolute (Earth's orbital velocity). Anything that must stay near it has to co-move; a one-shot teleport falls behind ~2 m per physics tick.
6. After any change to flight, world, autopilot, or docking code, run BOTH suites: `godot --headless res://tests/travel_test.tscn` and `res://tests/eva_test.tscn`. They are the regression net for everything above.
7. GDScript lambdas capture locals BY VALUE: a `var fired := false` flipped inside a signal-connected lambda never propagates out. Mutate through an array cell (`var fired := [false]`) or an instance var.
8. In test harnesses, a held teleport target goes stale the moment an origin shift fires mid-hold (and the world it targets is itself moving at ~131 m/s) — pose targets must be Callables re-evaluated every held frame, never fixed vectors (see anchor_test `_park_ship_at`).
9. Never rest a live RigidBody3D in contact with the rail-driven world (skim terrain, station hulls): the colliders teleport every frame and the solver eventually ejects the body violently. Frozen-and-parented states (docked, landed, clamped) exist precisely to avoid this; on release, push off and re-arm capture only after contact clears.

Read `docs/architecture.md` before starting. Scene tree, physics approach, and autoload responsibilities defined there are authoritative.

**Conventions (apply everywhere):**
- Units: 1 Godot unit = 1 meter. Velocities in m/s, forces in N, masses in kg.
- Collision layers: 1 = ship, 2 = character, 3 = debris, 4 = environment (Earth). Ship and character collide with everything including each other (bumping your own hull on EVA is correct behavior).
- All tuning constants are `@export` vars with the starting values given below — they are starting points for the feel pass, not final.
- Verification: the godot MCP tools are available (`run_project`, `game_screenshot`, `game_get_errors`, `game_eval`, input simulation) — use them to run the gate checks and capture the review screenshots/clips automatically where possible.

---

## Milestone 1 — Travel + Lighting

### M1.1 Project scaffold
- [ ] Create Godot 4 project (`project.godot`) at repo root, pinned to **Godot 4.7** (installed: 4.7.1 stable). Directories: `scenes/`, `scripts/`, `resources/`, `assets/`. Add `.gitignore` covering `.godot/` and import artifacts.
- [ ] Project settings:
  - `physics/3d/default_gravity = 0`
  - Physics tick rate 60 Hz (default); do not tie flight logic to render framerate — all force application in `_physics_process`.
  - Renderer: Forward+.
  - Physics engine: keep the 4.7 default — do not switch engines mid-project.
  - Main scene: `scenes/game_world.tscn`.
- [ ] Input map (keyboard + mouse; leave controller bindings for later):
  - `thrust_forward` (W), `thrust_back` (S), `thrust_left` (A), `thrust_right` (D)
  - `thrust_up` (Space), `thrust_down` (C or Ctrl)
  - `roll_left` (Q), `roll_right` (E)
  - Pitch/yaw from relative mouse motion (captured mouse mode)
  - `interact` (F) — the universal context-sensitive action (see architecture.md "Input Modes and Interaction"): EVA exit/board in M2, consoles and dialogue later. Never bind mode-specific actions to F.
  - `toggle_flight_assist` (X), `toggle_camera` (V), `ui_cancel` releases mouse
- [ ] Autoload skeletons: `GameState`, `ContractManager`, `OriginShift`, `AudioManager` (`scripts/autoload/`). Empty but registered, with class-level doc comment stating responsibility per architecture.md. In M1 `GameState` holds `flight_assist_enabled` and `input_mode` (enum `InputMode { SHIP_FLIGHT, EVA, INTERIOR, FOCUSED }` per architecture.md), each with a changed signal. Exactly one controller processes input at a time, gated on `input_mode` — build this gating in M1 even though only SHIP_FLIGHT exists yet.

### M1.2 Newtonian flight model (accuracy is the point)
- [ ] `scenes/ship.tscn`: `Ship` RigidBody3D per architecture.md tree — `Mesh`, `Thrusters` (Node3D), `CargoBay` (Area3D), `Camera` mount, `Character` (RigidBody3D child, frozen/dormant placeholder for M2).
- [ ] RigidBody setup for true Newtonian behavior:
  - `linear_damp = 0`, `angular_damp = 0`, damp mode Replace (no inherited default damping)
  - `can_sleep = false`
  - Explicit `mass` (pick a plausible value, e.g. 12000 kg) and a CollisionShape3D whose extents give a sane auto-computed inertia tensor. Do not fight the inertia tensor with hacks; if rotation feels wrong, adjust shape or use `PhysicsServer3D` inertia override, and comment why.
- [ ] `scripts/ship_controller.gd`:
  - Read the six translation inputs into a local-space thrust vector; transform to global with `basis` before `apply_central_force()`. Force = direction * per-axis max thrust. Starting values: `thrust_main = 48000.0` N forward (~4 m/s² at 12 t), `thrust_rcs = 15000.0` N lateral/vertical/reverse (~1.25 m/s²).
  - Rotation is a **torque command, not direct rotation**. Each physics tick: sum the mouse relative-motion events received since the last tick (collect in `_input`, consume in `_physics_process`, then zero the accumulator — never integrate across ticks). Commanded torque = `clamp(mouse_delta * mouse_torque_sensitivity, -max_torque, max_torque)` per axis for pitch/yaw; roll from Q/E at `max_torque`. Transform local torque vector to global, `apply_torque()`. Starting values: `max_torque = 20000.0` N·m per axis, `mouse_torque_sensitivity` tuned so a brisk mouse sweep saturates the clamp. Mouse idle ⇒ zero commanded torque ⇒ ship keeps rotating (Newtonian); FA is what stops rotation, never the mouse mapping.
  - No velocity clamping, no artificial speed limit, no drag. Velocity persists exactly (verify: thrust to speed, release input, velocity magnitude constant indefinitely).
  - All input→force in `_physics_process` using forces (not impulses) so behavior is tick-rate independent.
- [ ] Flight assist (FA):
  - Translation: for each local axis with no player input this tick, compute counter-force `-v_axis * assist_gain`, clamp magnitude to that axis's max thrust (assist can never out-thrust the real thrusters). Axes with active input get raw thrust — assist never fights the player. Starting value: `assist_gain = mass * 2.0` (converges in a few seconds without overshoot; tune from there).
  - Rotation: same scheme on angular velocity per local axis, clamped to max torque. Starting value: `assist_angular_gain = 40000.0`.
  - FA state lives in `GameState.flight_assist_enabled`, toggled by input action, announced via signal so HUD can react.
  - With FA on and no input, ship must converge to full stop (linear and angular) without oscillation — tune gain, don't add snapping/lerp-to-zero shortcuts.
- [ ] Fuel: float on Ship, drained proportional to |thrust| * delta (assist burns fuel too — it's real thruster fire). No consequences at 0 yet beyond thrust cutoff; keep the tank generous.

### M1.3 Camera
- [ ] Third-person: follow position with critically-damped smoothing (no spring bounce), orientation tracks ship basis. Slight positional lag is fine; rotational lag should be minimal so the player can judge attitude.
- [ ] Cockpit: fixed transform inside ship mesh, no smoothing.
- [ ] `toggle_camera` switches modes; both cameras respect mouse-captured look only insofar as ship rotation moves them (no free-look yet).

### M1.4 Environment + lighting (get this solid now)
- [ ] `scenes/game_world.tscn` — `GameWorld` root per architecture.md.
- [ ] Earth: sphere of radius ~2000 m centered ~12000 m below spawn (compressed scale per architecture.md — it should fill a large arc of the "down" view but never be reachable in normal play; no gravity from it in M1/M2). StaticBody3D + MeshInstance3D. Material: simple albedo texture or procedural blue-white; unshaded is not acceptable — it must take light so day/night terminator reads.
- [ ] Sun: single `DirectionalLight3D`, intensity high, shadows enabled (directional shadow tuned so ship self-shadows crisply at gameplay range).
- [ ] `WorldEnvironment`:
  - Sky: dark starfield (procedural `Sky` with star texture or generated star panorama in `assets/`). Space is black, not navy.
  - Ambient light: very low, sourced slightly from sky so the shadow side isn't pure black — a hint of Earthshine, not studio fill.
  - Tonemap: ACES/AgX (Filmic acceptable), exposure tuned so sunlit hull is bright without blowing out and shadow side is readably dark.
  - No fog, no glow abuse; subtle glow on emissives only.
- [ ] Ship material pass: hull material with sensible metallic/roughness so sunlight models the shape; small emissive markers (nav lights) that read on the dark side.
- [ ] 5–10 static debris meshes (varied primitives, varied scale/rotation) scattered 50–500 m from spawn as velocity/parallax reference. StaticBody3D for now, with collision so you can bump them (they don't move yet — full physics debris is M3).

### M1.5 HUD
- [ ] CanvasLayer HUD scene:
  - Velocity readout: magnitude (m/s) plus a prograde/retrograde style directional marker relative to ship facing.
  - Orientation indicator: attitude relative to the **global inertial frame** (world axes), shown as pitch/roll/yaw readouts or a minimal nav-ball placeholder. Reference frame choice is fixed — do not reference Earth or velocity for attitude (the prograde marker already covers velocity).
  - Fuel gauge.
  - FA indicator: clear on/off state, updates via `GameState` signal.
- [ ] Calm visual language per narrative.md — thin lines, muted color, no red alerts.

### M1.6 Solar system + travel (added at owner request)
- [x] `SimClock` autoload — simulation time and time compression, registered in project.godot
- [x] `OriginShift` implemented for real: 64-bit true space, `origin_shiftable` group, bootstrap `initialize_origin` vs runtime `shift_to`
- [x] `SolarSystemData` / `BodyDef` / `CelestialBody` / `SolarSystem` — 15 bodies (Sun, 8 planets, 6 moons), analytic circular orbits, far-field angular-size-preserving proxy rendering, one system light re-aimed from the Sun each frame
- [x] Reference frames: flight assist holds station against the nearby body, not the Sun; HUD shows the active frame
- [x] `OrbitalAnchor` — debris field travels with its parent body
- [x] `Autopilot` — brachistochrone transfers to any body, closed-loop guidance onto a moving target, midpoint flip, velocity-matched standoff park, adaptive time compression bounded to ≤300 s real
- [x] `NavConsole` — destination list with live distance/ETA, `FOCUSED` input mode, M to open, Enter to engage; any stick input cancels a transfer
- [x] Procedural starfield sky shader (the asset server has no orbital sky — see docs/assets.md)
- [x] Synty hull mesh integrated; collision matched to the measured AABB
- [x] `tests/travel_test.gd` — headless verification: spawn, orbits, analytic velocity, and a transfer to all 14 destinations
- [x] `tests/capture_shots.gd` — screenshot harness (runs under xvfb)

Fixed on the way through, worth knowing:
- A `RigidBody3D` nested under another `RigidBody3D` corrupts both transforms. The EVA suit is now stowed out of the tree while aboard. See architecture.md.
- `SolarSystem` must not place bodies in `_ready`: children run before parents, so the origin does not exist yet, and the Sun's collision sphere ends up enabled on top of the spawn point.
- The physics server reverts transform writes to a live `RigidBody3D` — steer only while frozen.

Remaining in this area (not blocking M2):
- [ ] Per-body debris fields / arrival content (currently one field at the spawn body; M3 scope)
- [ ] Cruise visual treatment — no sense of speed during a compressed transfer beyond the HUD
- [ ] Nav console does not yet offer a "return to previous location" or arbitrary waypoints
- [ ] Bodies are untextured procedural spheres; art-family decision in docs/assets.md §5 is still open

### M1 VERIFICATION GATE — must pass before starting M2
- [ ] Momentum conservation: thrust to ~20 m/s, cut input, coast ≥60 s with zero velocity change; same for rotation (constant tumble persists).
- [ ] FA-off is challenging but controllable; a deliberate player can null a tumble manually.
- [ ] FA-on: from full tumble + drift, releasing all input reaches complete stop, no oscillation; precise translation (hold a heading, strafe a slow circle around a debris piece at ~10 m).
- [ ] Tick-rate independence sanity check: behavior consistent at 60 vs 120 physics Hz.
- [ ] Lighting: terminator visible on Earth; ship reads clearly in full sun, half-lit, and shadow-side (nav lights carry it); stars visible without washing out; no shadow acne/peter-panning at gameplay range.
- [ ] Cameras: both modes usable for precision maneuvering; switching is instant and doesn't pop the mouse.
- [ ] Record a short flight clip or screenshots (sunlit, terminator, shadow side) for owner review before proceeding.

---

## Milestone 2 — EVA

Same physics standard as M1: the suit is a small Newtonian body, not a character controller.

### M2.1 EVA character body
- [ ] Activate `Character` (RigidBody3D): capsule collision, simple suit-proportioned placeholder mesh, `linear_damp = 0`, `angular_damp = 0`, `can_sleep = false`, mass ~150 kg (suit + person + pack).
- [ ] `scripts/eva_controller.gd`: same 6DOF force/torque model as ship_controller — consider extracting shared logic into `scripts/flight_common.gd` (base class or helper) rather than copy-paste; thrust and torque maxima much lower than ship (MMU-scale: a few hundred N translation, gentle torque).
- [ ] FA works identically on EVA (shared logic makes this free). EVA defaults to FA on.

### M2.2 Exit / enter ship
- [ ] Enter/exit uses the universal `interact` action (F): exits when aboard, enters when on EVA inside the CargoBay. Drive it through the `input_mode` switch (SHIP_FLIGHT ↔ EVA). HUD shows an `InteractionPrompt` label whenever `interact` has a valid target ("F — EVA" / "F — Board"); hidden otherwise. Ship near-stationary is NOT required — exiting a moving ship is allowed and must inherit velocity correctly.
- [ ] Add `ExitPoint` (Marker3D) to Ship, positioned **clear of the hull's collision shape** near the hatch (validate: character capsule at ExitPoint does not overlap ship collision — a spawn-overlap ejection pop is a gate failure).
- [ ] While aboard: Character is `freeze = true` (`FREEZE_MODE_KINEMATIC`) with its CollisionShape3D disabled — it must not collide with the ship interior or contribute contacts while carried.
- [ ] On exit: Character re-parented from Ship to GameWorld, global transform set to ExitPoint's global transform; collision shape re-enabled, `freeze = false`. Velocity: `linear_velocity = ship.linear_velocity + ship.angular_velocity.cross(exit_point_global_pos - ship.global_position)` (the ω × r term — exiting a rotating ship flings you tangentially); `angular_velocity` copied from ship. Camera and input control transfer to character; ship becomes an uncontrolled free body (keeps its momentum, ship FA disables — it just coasts).
- [ ] On enter: valid only while Character overlaps ship `CargoBay` Area3D; freeze character and disable its collision **before** re-parenting under Ship (order matters — no contact frame between the two bodies during the transition), restore ship control and ship camera. Relative velocity at entry is simply absorbed (no docking damage — peaceful game).
- [ ] HUD swaps to EVA variant: adds EVA fuel gauge and a ship marker (direction + distance to ship, always visible — getting lost must be recoverable).

### M2.3 EVA fuel
- [ ] `EVAThrusterFuel` Resource (`scripts/resources/eva_thruster_fuel.gd`, instance in `resources/`): `capacity`, `remaining`, `consumption_rate` (per Newton-second). Drained by eva_controller on any thrust including FA counter-thrust.
- [ ] Signals on the resource: `low_fuel` (20%), `critical_fuel` (5%), `depleted`.
- [ ] HUD: low-fuel warning at 20% (calm, per tone — amber tint, no klaxon); at 5%, return-to-ship prompt showing ship direction/distance.
- [ ] At 0 fuel: thrusters dead, character coasts. Recovery path exists but is M3 scope (ship-side rescue); for now dying is impossible — just stranded until scene reload. Note this openly in code comment.
- [ ] Fuel refills automatically on ship entry (instant for now; tie to resource later).

### M2.4 EVA camera + feel
- [ ] Third-person EVA camera: closer follow distance than ship, same smoothing scheme.
- [ ] Optional helmet cam (reuse cockpit-mode logic) — include if cheap, skip if not.
- [ ] Feel pass: EVA should feel deliberate and slightly fragile vs the ship — lower acceleration, faster FA convergence (suit computer is nimble), audible-in-future thruster puffs (leave `AudioManager` hook comments, no audio assets yet).

### M2 VERIFICATION GATE — must pass before any M3 (debris/tools/contracts) work

Automated in `tests/eva_test.gd` (26 checks, all green — run
`godot --headless res://tests/eva_test.tscn`):

- [x] Exit ship while ship drifts at 5 m/s: character exits co-moving (0.058 m/s relative), ship coasts on unchanged (4.97 m/s).
- [x] Exit ship while ship is rotating: character inherits the tangential velocity of the hatch (1.36 m/s expected, 0.058 error). Note the test spins about an axis perpendicular to the hatch offset — with a fixed world axis the cross product can collapse and the check passes whether or not the ω × r term exists.
- [x] Fuel: 20% and 5% warnings fire exactly once each, at 20.1% and 5.1%; refill tops up and rearms them.
- [x] Momentum conservation holds for the suit (zero drift over 120 ticks, linear and angular).
- [x] Camera handoff ship↔EVA: correct camera current in each mode, EVA camera in the tree, ship camera restored on boarding.
- [x] Boarding: cargo-bay overlap detected, suit stowed out of the tree, input mode restored, no impulse imparted to the hull.
- [x] Suit is stowed (out of tree, frozen, collision disabled) while aboard — guards the nested-RigidBody3D regression.

Still needs a human at a keyboard — no assertion captures these:

- [ ] Fly 100+ m from the ship under thrust, FA off, null velocity manually, return and re-enter. The automated check holds the suit in the bay rather than flying it in.
- [ ] FA-off is challenging but controllable; FA-on EVA feels deliberate and slightly fragile next to the ship.
- [ ] Camera/control handoff *feels* seamless; no stuck mouse.
- [ ] Screenshots: the harness (`tests/capture_eva_shots.gd`) produces correct HUD and state but does not yet frame the astronaut legibly — see note below.

---

## Track PR — Progressive Planet Renderer (start after SD2 gate passes)

Design authority: `docs/planet-renderer.md` — the regimes, scale stylization,
budgets and verification plan live there; this is the build order.

### PR1 — Relief everywhere + night lights — BUILT (pending screenshot review)
- [x] `scripts/world/body_surface.gd`: `BodySurface extends Resource` — noise seed (derive from body id), `continent_frequency`, `ridged_mix`, `amplitude` (as fraction of radius, default 0.02), `sea_level` (-1 = none), `palette` (Gradient or 3–4 colors), `night_emissive: Texture2D` (optional), `authored_height/albedo: Texture2D` (optional, used INSTEAD of noise when set).
- [x] `BodyDef` gains `surface: BodySurface`, `spin_period` (0 = no spin), `spin_axis_tilt`. `SolarSystemData` fills surfaces for all 15 bodies (gas giants: amplitude 0, banded palette; Earth: sea_level set, hand-painted night-lights blob mask; Sun: none — keeps its emissive sphere).
- [x] `scripts/world/planet_surface.gd`: `PlanetSurface extends Node3D`, built by `CelestialBody._build_visuals()` when `def.surface` exists (else current sphere fallback). PR1 scope: 6 root cube-faces at fixed 33×33, displaced by the height source, one shared `ShaderMaterial`.
- [x] Bake per body at build: equirect albedo (from palette × height/sea), normal (from height gradient), emissive (night lights) — 512² is enough at PR1. Bake on a background thread; body shows flat color until ready (bodies build during bootstrap, so in practice it is ready before the player can look).
- [x] Shader `assets/shaders/planet_surface.gdshader`: albedo/normal lookup, emissive gated by terminator — `emissive_strength = smoothstep(0.05, -0.15, dot(normal, sun_dir))` so lights fade in across dusk. Sun direction as a global shader parameter set by SolarSystem (it already aims the light).
- [x] Spin: `CelestialBody` rotates the `PlanetSurface` child (NOT the collision sphere, NOT the node itself — children like future site anchors hang off the surface node) by `TAU * sim_time / spin_period` about the tilted axis. Analytic from `SimClock.sim_time` — never accumulate per-frame (trap: breaks time compression).
- [x] Proxy check (delegated through `_apply_scale` → `apply_scale_ratio`): `_apply_scale` scales `PlanetSurface` exactly as it scaled the sphere mesh. Verify by screenshot at proxy range and at 30 km — same apparent size as before the change.
- [ ] **PR1 gate**: travel + EVA + station suites green; `capture_shots.gd` extended — Earth full disc showing continents/sea, terminator with visible night lights, Moon relief at 10 km, Jupiter banding. Screenshots to owner.

### PR2 — Progressive refinement + skim collision — BUILT (pending screenshot review)
- [x] Quadtree in `planet_surface.gd` (or split `planet_patch.gd`): subdivide when `patch_geometric_error / distance_to_camera > threshold` (start `0.004`), merge on hysteresis (×1.5). Re-evaluate at most every 0.25 s per body. Max depth 7.
- [x] Patch build on `WorkerThreadPool` (arrays on worker, `ArrayMesh` commit on main thread), ≤4 in flight per body; LRU cache 256 patches, never evict depth ≤2.
- [x] Skirts: edge ring dropped 2% of patch span below the surface. No T-junction stitching — skirts only.
- [x] Vertices relative to patch center; patch node positioned by center (float32 discipline per design doc).
- [x] **Skim collision**: when ship's true distance to surface < 500 m — build `ConcavePolygonShape3D` for resident patches within 300 m of the ship (on the worker), disable the body's sphere collider, enable ship CCD (`continuous_cd = true`). Reverse all three above 600 m (hysteresis). The sphere/patch swap is mandatory in BOTH directions — sphere walls you out of valleys, missing patches make peaks intangible.
- [x] `tests/planet_test.gd`: seam agreement (shared-edge vertices of same-depth neighbours within epsilon), determinism (same patch id ⇒ bit-identical arrays), approach monotonicity + return-to-baseline (streaming leak), budget caps never exceeded during a scripted proxy→spawn approach, scripted low pass at 60 m altitude / 80 m/s over 20 km of terrain — no tunnel-through, no invisible-sphere contact.
- [ ] **PR2 gate**: all suites green; screenshot set: continuous approach series (5 frames, no visible pop), low-skim frame with terrain filling the lower third.


**Fixed / learned on the way through (PR1+PR2):**
- `cache_capacity` raised 256 → 512. Measured: a depth-5 settle over Earth holds
  ~230 leaves plus ancestors (~300 entries), and eviction correctly refuses to
  drop live or shallow entries — so a 256 cap could not be honoured and only
  caused thrash. The design doc's 256 was an estimate made before measuring.
- `CelestialBody.sphere_collider_enabled()` added so the skim swap is observable
  from tests.
- Three test-harness traps worth knowing, all of which produced false readings
  before being fixed: (1) a split commits only once all four children are built,
  so the build queue empties *between* rounds — waiting on `is_quiescent()` alone
  reports a far shallower tree than the metric asks for; settle until depth stops
  changing. (2) The body's sphere collider is already distance-gated at
  radius + 20 km, so a skim-swap assertion made from 30 km fails for an unrelated
  reason — test the swap from inside the activation margin. (3) Cube-face patch
  adjacency depends on the `face_dir` convention; assert shell closure (24 root
  corners collapsing onto 8 cube corners, each shared by 3 faces) instead of
  guessing which patches border each other.

**PR1/PR2 visual gate: PASSING.** Screenshots 14–20 in `screenshots/`. Earth
renders with continents, water, mountain relief and snow caps; city lights read
along the terminator; the Moon shows cratered relief; refinement reaches depth 4
in the harness with ~220 leaves resident.

Two defects found and fixed while closing this gate, both worth remembering:

- **`MODELVIEW_MATRIX` does not exist in a Godot 4 `fragment()` shader** — it is
  a vertex-stage builtin. Referencing it failed shader compilation, which
  silently falls the whole surface back to the engine's default grey material;
  that was the "flat grey facets". Worse, the compile error fired *inside*
  `PlanetSurface.setup()`, which left the rest of surface init in a degenerate
  state — that is why the harness also reported `max_depth: 0` and `skim=false`.
  One symptom, two apparent bugs. `VIEW_MATRIX * MODEL_MATRIX` is the
  fragment-stage equivalent.
- **A harness-added Camera3D does not reliably win `current`** against the
  ship's rig camera, so shots render from behind the ship instead of the intended
  framing. This silently affected the EVA portraits too. Pose the *ship* and let
  the gameplay rig camera follow — it is what the original `capture_shots.gd`
  did, it works, and the shots then show what the player would actually see.

Remaining polish (not gate-blocking):
- [x] Earth's water reads as scattered lakes rather than oceans — `sea_level`
  at -0.3 only floods the deepest basins. **Closed by PR3**: with ETOPO 2022
  bathymetry the cook puts true mean sea level at the encoding's exact zero, so
  `sea_level` is `0.0` and the coastline is a datum rather than a knob. The
  decoded map's land fraction is 0.293 against a real 0.292.

### PR3 — Detail sites + NYC pilot — BUILT (scope set by owner 2026-08-17)

Owner direction: seed from NASA / open GIS data at **coarse granularity**, add
**NYC detail**, and **defer streaming and higher fidelity** ("later we can
investigate ... if we even want it"). That makes this milestone smaller than
originally designed — no fetch pipeline, no tiling, no server drop.

- [x] **Coarse global maps, committed.** 2048×1024 equirect height + albedo for Earth, Moon, Mars into `assets/planets/`, cooked by `tools/cook_planet_maps.py`. All real public-domain data: Earth ETOPO 2022 + Blue Marble NG + Black Marble 2016; Moon LOLA LDEM + LROC WAC (NASA SVS CGI Moon Kit); Mars MOLA MEGDR + USGS Viking mosaic. `assets/planets/` was never in `.gitignore` (only `assets/meshes/` is), so nothing needed un-ignoring — an explicit note was added there instead so the exception is visible. Full source table and encoding in docs/assets.md §7.
- [x] **Wire the authored path in `BodySurface`.** Sampled instead of the noise when set, bilinear, in exactly the shader's equirect convention. Procedural stays the automatic fallback: eleven of the fourteen surfaced bodies still use it.
- [x] **Sea level from real bathymetry.** Earth's `sea_level` is now `0.0` — the cook puts mean sea level at the encoding's exact zero. `planet_test` re-derives the land fraction from the decoded map (0.293 vs 0.292) and spot-checks the Pacific, Atlantic, Sahara, Himalaya and New York, so orientation and decode are both pinned.
- [x] `scripts/world/detail_site.gd` per the design-doc schema, plus `direction()` / `east()` / `north()` helpers so the tangent frame is defined in one place instead of at every call site.
- [x] Site streamer in `PlanetSurface`: in at 3 km, out at 4 km; scene anchored to the sphere tangent and turning with spin (it hangs under the surface node, so spin is free); inset height blended with a smoothstep falloff that reaches zero at the footprint edge. Site scenes are visual props — the streamer detaches any physics body it finds from the physics space and warns, the DockingComputer `_capture` pattern.
- [x] NYC pilot `scenes/sites/nyc.tscn` at 40.75 N, −73.98 W: `POLYGON_SciFi_City` + `POLYGON_City` added to `DEFAULT_PACKS`, ~68 buildings from `SM_Bld_Background_*` at native 18–42 m, placed from the inset's own land mask so the skyline lands on the real coastline; rivers and harbour from the inset; authored emissive street grid on Manhattan's 29° bearing.
- [x] **PR3 gate**: all five suites green + the site stream-in/out test (in at 3 km, out at 4 km, 3.5 km neither acquires nor releases, right-handed tangent frame, antipodal after half a spin period); money shot `screenshots/25_nyc_night_2km.png`, plus 21–27.

**Fixed / learned on the way through (PR3):**
- **Frame-count settles are a lie in this harness.** Both `planet_test._settle_at`
  and `capture_planet_shots._settle` waited a fixed number of frames. Headless
  frames are sub-millisecond, so "400 frames" expired in well under a second —
  faster than the worker pool could build anything — and the suite reported
  `max_depth: 0` with four builds permanently in flight. Both now bound on wall
  clock. Same class of bug as the PR2 "settle until depth stops changing" note.
- **The camera rig has to be waited for, not the ship.** The error metric is a
  *camera* metric and the rig follows on a 0.12 s half-life against the process
  delta; four hold frames move it a couple of metres out of a several-kilometre
  jump. Every settle now converges on the rig's own target. This was silently
  under-reporting refinement (depth 2 where the metric asks for 6) and, worse,
  made the site-streaming test read a stale decision — a resident site pins its
  patch depth, so the leaf count stabilises even while the camera is still
  hundreds of metres away.
- **A pose captured once goes stale the moment the origin shifts.** Teleporting
  the ship more than 10 km rebases the floating origin, so a render-space
  position computed beforehand is off by exactly the shift. That is what pointed
  the Moon and Mars frames at empty space. `_hold_pose` now takes a Callable and
  recomputes every frame — which also fixes surface sites walking out of frame
  as the planet spins during a 30 s settle.
- **WorkerThreadPool caps low-priority tasks.** Patch builds were queued at the
  default (low) priority behind fourteen bodies' worth of texture bakes and
  starved for seconds after bootstrap. Patch and collision builds are now high
  priority; the bakes stay low. `bake_size` also dropped to 768 (a bake costs
  ~2.7 µs/texel in GDScript and they all run at once).
- **Godot's PNG importer does not preserve 16-bit greyscale**, and one 8-bit
  channel quantises Earth's ±40 m into 0.31 m terraces. Height is therefore
  packed as red = high byte, green = low byte in an RGB8 PNG. It survives only
  because these textures are read with `get_image()` and never assigned to a
  material — otherwise the importer's detect-3d pass would VRAM-compress them
  and shred the encoding. The land-fraction check in `planet_test` exists to
  catch exactly that.
- **`RenderingServer.global_shader_parameter_get` is editor-only** and logs an
  error per call in a running game. The site needs the sun direction to gate its
  own city lights on the terminator, so `SolarSystem` now mirrors the value into
  a `static var sun_direction` beside the global uniform it already sets.
- **The published Black Marble is a composite, not a radiance image**: warm
  lights painted over a blue-purple land base whose luminance plateaus around
  52/255. Using luminance as the mask set every continent glowing. Separating on
  hue (`R - 0.6B`, which keeps the saturated white city cores that a plain
  `R - B` would zero) gives a clean lights mask.
- **The error metric alone cannot feed a detail site.** At the 2 km a site is
  read from it stops at depth 3 — a 393 m patch, 12 m vertex spacing — against a
  512² inset over a 400 m footprint. A resident site now pins its patches to
  `site_min_depth` (6: 49 m patches, 1.5 m spacing). That takes a 2.6 km settle
  to 429 leaves / 570 cache entries, so `cache_capacity` went 512 → 1024 for the
  same measured reason it went 256 → 512 at PR2.
- Framing a 400 m diorama is not the same problem as framing a planet: the rig
  draws the ship dead centre, and near nadir the local up is nearly parallel to
  the view axis, so "yaw the aim 26°" about it moves the target only 11° on
  screen — still behind the hull. The offsets in `_frame_site` are built about
  axes perpendicular to the view instead.
- Known cosmetic: `xvfb-run` occasionally aborts at shutdown with
  `8 RIDs of type "Texture" were leaked` (exit 134) *after* every screenshot has
  been written. Not reproducible on every run and not gate-blocking.
- **Pre-existing, not PR3: `travel_test`, `docking_test` and `eva_test` do not
  self-terminate.** They print `PASS — all checks green` within seconds and then
  sit at 0% CPU forever; `timeout` is what ends them, so the exit code is 124 no
  matter how the checks went. `station_test` exits cleanly in 12 s and
  `planet_test` in 127 s, so it is not the world build. Confirmed
  pre-existing by stashing every PR3 change and running `travel_test` again —
  identical behaviour, PASS at four seconds and then a stall to the timeout.
  **Read the log for the PASS/FAIL line; do not read the exit code.** Worth
  someone's afternoon eventually (a WorkerThreadPool or server finalize wait,
  most likely), but it is not this milestone's bug.

### PR4 — Atmosphere and scattering — BUILT (owner-requested 2026-08-18)

Design: `docs/planet-renderer.md` → "Atmosphere and scattering". Read it first;
the lighting behaviour is the requirement, not a coloured rim.

- [x] `scripts/world/body_atmosphere.gd`: `BodyAtmosphere extends Resource` — `height_fraction`, `rayleigh_coefficients: Vector3`, `rayleigh_scale_height`, `mie_coefficient` (Vector3 — chromatic, see the Mars note below), `mie_absorption: Vector3`, `mie_scale_height`, `mie_g` (Vector3, per-channel — that is the Mars blue-sunset mechanism), ozone (absorption Vector3 + tent centre/width), `sun_intensity`, `ground_albedo_tint`, `ambient_sky_color`, `opaque`. Every field is a fraction of / per radius — the scale trap is structural, nothing is in metres.
- [x] `BodyDef.atmosphere = null` means airless and stays visibly airless — Mercury, Moon, Io, Europa, Ganymede, Callisto keep null; asserted by the gate.
- [x] `SolarSystemData`: Earth (Rayleigh blue + ozone), Venus (thick opaque yellow-white, `opaque = true`), Mars (thin chromatic Mie, butterscotch day / blue sunset), Titan (tall orange haze). Gas giants: `BodyDef.limb_darkening` on the surface shader only, no shell.
- [x] **LUT chain (Hillaire 2020)**: transmittance 256×64 (Bruneton's non-linear horizon-preserving mapping) + multi-scattering 32×32 (dual-scattering ψ_ms, orders 2..∞, ground bounce included), baked per body in `AtmosphereMath` on `WorkerThreadPool` (0.4 s + 1.0 s per body, drained in `PlanetSurface._exit_tree` like every other worker task). **Deliberate deviation:** the sky-view and froxel LUTs from the paper are replaced by a per-pixel march in the shell shader that consumes the two baked LUTs. Those two LUTs are pure performance caches that must rebuild whenever the sun or camera moves; at our scale the shells cover a fraction of the screen from orbit, the march is cheap, and marching against the live depth buffer *is* the aerial perspective — terrain seen through air hazes correctly at any LOD with nothing to go stale.
- [x] **Multiple scattering** contributes measurably (gate: twilight ×1.3 brighter with ψ_ms than without — exactly the "LUT wired up but inert" guard).
- [x] **Ozone**: third extinction term, tent profile, pure absorption. The noon zenith chromaticity lands at (0.234, 0.238) — blueward of D65 as a real sky is.
- [x] **Phase functions**: Rayleigh analytic; Cornette-Shanks per channel. Mars pushes blue into a tighter forward lobe (g = 0.74/0.80/0.90 RGB) with blue-absorbing dust — measured inversion: day sky R/B 5.9, near-sun sunset R/B 0.2.
- [x] **Planetary shadow**: per-sample horizon test against the ground sphere — the night side's air stays dark, the limb does not glow all the way round.
- [x] `assets/shaders/atmosphere.gdshader` + `AtmosphereShell` MeshInstance3D under `PlanetSurface` at `radius * (1 + height_fraction)`, back-face rendered, `depth_test_disabled`, marching camera→scene-depth so it works from orbit AND from inside the shell (skim) through one code path. Sun from the existing `planet_sun_direction` global.
- [x] **Scale ratios**: all parameters are radius-relative and the shader normalizes world positions by the drawn radius recovered from `MODEL_MATRIX` — so real-Earth ratios (H/R = 0.00133) are entered verbatim and the proxy clamp cancels out of the optics entirely.
- [x] **Camera inside the shell**: cull_front + depth_test_disabled + scene-depth clamp; verified by the skim framing in the capture harness.
- [x] **Proxy integration**: the shell hangs under `PlanetSurface`, so it scales through the same `_apply_scale` → `apply_scale_ratio` path as the terrain by construction. Gate asserts shell world-scale == `visual_radius() * (1+hf)` both proxied and not.
- [x] **Twilight drives the city lights**: `BodyAtmosphere.twilight_angle()` = acos(R/(R+h_lit)) with h_lit = min(shell top, 6 scale heights) — 7.2° for Earth — feeds `night_gate_lo/hi` surface-shader uniforms (which default to the old hardcoded band for airless bodies). Gate asserts the material uniform equals the analytic value.
- [x] **Aerial perspective**: the shell march clamps at the depth buffer, so in-scatter accumulates in front of terrain and city lights extinguish through thick slant paths — composite order falls out of the same clamp. Skim shot 34 is the evidence.
- [x] Stretch: flat ambient replaced — `SolarSystem.bind_environment()` derives ambient fill near an atmospheric body from its `ambient_sky_color`/`ground_albedo_tint`, proximity, and the sunlit fraction, decaying to the old deep-space base far from bodies.

**PR4 gate — `tests/atmosphere_test.gd`, ALL GREEN** (CPU mirror `AtmosphereMath` matches the shader line for line):
- [x] Airless bodies: no atmosphere resource, no shell node, default hard night gate.
- [x] Twilight band width follows analytically from scale height and radius; the city-lights gate uses exactly that band.
- [x] Optical depth monotone toward the limb, finite at grazing (and a ray through the shell alone still scatters).
- [x] Transmittance LUT matches direct integration (worst error 0.0008).
- [x] Sunset reddening: R/B monotone rising, ×11,000 from +10° to the geometric horizon (the doc's −2° figure includes refraction, which is out of scope — sweep stops at the horizon).
- [x] Published values: noon zenith between D65 and sky blue; civil twilight at −6° still lights the sky (1.8% of noon); the Mars inversion above.
- [x] Multi-scatter contributes ×1.3 at twilight; Venus vertical transmittance 0.037 (opaque).
- [x] Proxy: shell tracks the drawn radius exactly, proxied (Mars) and near (Earth).
- [x] Screenshots 28–34: Earth limb arc, sunset from low orbit, soft-vs-hard terminator pair (Earth beside Moon), Mars, Titan, Venus, skim aerial perspective — `tests/capture_planet_shots.gd`.

### PR5 — clouds, geomorphing, sun glare (owner-approved 2026-08-22) — BUILT except sites

- [x] **Cloud deck** — `assets/shaders/cloud_layer.gdshader` + `PlanetSurface.configure_clouds()`: translucent sphere at `BodyDef.cloud_height_fraction` (Earth 0.012, coverage 0.48), seamless value-noise fbm over the sphere direction, lit by the scene sun so the terminator crosses clouds and ground together, TIME-drifting weather relative to the spin. Draws under the atmosphere shell (`render_priority` −16 vs −15) so limb haze and twilight composite over it; depth testing clips the sheet around relief taller than the deck. No cloud shadows on the ground yet — noted, not hidden.
- [x] **Geomorphing** — `PlanetPatchMesh.build_arrays` now emits per-vertex parent-surface position/normal (CUSTOM0/1: even vertices coincide with parent vertices, odd ones sit on the parent's interpolation — quad centres on the ANTI-diagonal, the edge the parent's triangles actually share; skirts morph with their edge). The surface shader lerps by a per-patch `morph_t` instance uniform driven from the same screen-space error that decides splits: children arrive rendering exactly as the parent they replace and reach full detail by 0.75× threshold. Site-pinned patches stay at morph 1. Gate: `planet_test` "geomorph targets" — even-exact, odd-midpoint, roots self-target.
- [x] **Sun glare** — `sun_disc.gdshader` (limb-darkened disc pushed past the tonemap white so glow blooms it) + `sun_glare.gdshader` (additive billboard halo, depth-tested so planets occlude it per-pixel, pulled camera-ward past the disc so the Sun cannot occlude its own glare). Replaces the flat cream circle.
- [ ] More detail sites (Canaveral, Baikonur, Shanghai, Tycho, Olympus Mons) — still owner's call on which matter.

### PR6 — Real clouds + Earth fidelity tier (owner-requested 2026-08-23) — BUILT

- [x] **Cloud climatology** — `earth_clouds.png` cooked from the NASA Blue Marble cloud composite (L8 cloud fraction, docs/assets.md §7). The cloud shader anchors its coverage to it: `d = fraction^0.7 * (0.5 + 0.62*fbm)` against a coverage-driven cut, so storm tracks and the ITCZ are cloudy, the Sahara is clear (map means: Sahara 0.005, N-Atlantic 0.354, ITCZ 0.504), and the fbm still provides texture and TIME drift. Bodies without a map keep the procedural deck.
- [x] **Earth height tile pyramid** — `cook_earth_tiles` cuts ETOPO 2022 at full source resolution into L1 (complete, effective 4096) + L2 (land-only, effective 8192) 1024² tiles, same encoding/references as the global map (36 tiles, ~54 MB, committed). `BodySurface` loads them eagerly in `prepare()`; the sampler prefers the finest resident tile per lookup and falls through to the global map, so sparse coverage is seamless by construction. Per-tile coastline majority rule matches the global cook.
- [x] **Albedo ceiling raise** — `earth_albedo.png` recooked at 4096×2048 from the 5400-wide Blue Marble source (real detail, no shader change). Other bodies keep 2048 deliberately.
- [x] Gate (`planet_test`, all green): cloud map present + shader anchored + Sahara clear + storm tracks cloudy; ≥30 tiles resident; the Himalaya resolves higher through tiles than the 2k global map; no step across a tile boundary; oceans stay oceans and the Sahara stays land through the tiled sampler.
- [x] **Distance-based tile streaming** (owner-requested 2026-08-23) — L1 stays eager (the complete, seamless floor); L2 tiles stream by the observer's sub-body point with 14°/28° enter/exit hysteresis. Loads run on the worker pool (the decode lands on the main thread — `Texture2D.get_image()` is not thread-safe), residency changes go through the replace-not-mutate dictionary swap so in-flight samplers stay consistent, and cached depth-3+ patches over a changed tile are purged for the refine loop to rebuild. The generous enter margin is the correctness argument: a tile is resident before any deep patch is built over it, so residency changes only ever touch refs==0 cache entries. Steady-state residency: ~1–4 L2 tiles (~12 MB) instead of all 28. Gate: `planet_test` "tile streaming" — the Himalaya's tile streams in on approach, sharpens the terrain, and streams back out on departure.

### Lighting audit (owner-requested 2026-08-23) — findings and fixes

Checked: sun energy/angular size (0.5° ≈ the real 0.53°), orthogonal directional shadows (4096 texels over the 500 m range ≈ 12 cm/texel, biases healthy), terrain/ship cast+receive in skim range, atmosphere composite order, ambient derivation, glare depth handling. Three defects found, all fixed:
- [x] The cloud deck used `diffuse_lambert_wrap`, lighting clouds ~30° past the terminator — far outside the 7.2° derived twilight band. Now plain lambert: clouds, sky and city lights cross the terminator together.
- [x] Detail-site lights still faded on the pre-PR4 hardcoded band (−0.15, 0.05) while the surface uses the derived (−0.126, 0.031). `PlanetSurface._instance_site` now hands the atmosphere's `night_gate()` to any site scene with `set_night_gate` — one band for everything.
- [x] `capture_shots._shot` read a `Mesh` child that surface bodies do not have (error spam on every planet shot); now uses `visual_radius()`.

### PR5 sites — Cape Canaveral (owner-picked 2026-08-23) — BUILT

- [x] `cook_canaveral`: the NYC treatment on the launch coast — 29 km terrarium window at (28.55, −80.62) squeezed into a 400 m footprint. The cape's hook and the Banana/Indian rivers survive the squeeze (21.9% land); Florida-flat local references (60 m up) so the terrain reads instead of smearing. Night plate: authored gaussians at the real installations plus faint land mottle — a launch coast, not a metropolis.
- [x] Site scripts refactored: shared `SiteBase` (tangent anchoring, curvature, inset lookups, lights plate, twilight fade) with `nyc_site` and `canaveral_site` as thin subclasses. Canaveral places LANDMARKS at real coordinates rather than a statistical lattice: the VAB block, LC-39A/B pads with towers, the SLF strip at its real ~330° bearing, the CCSFS pad row, Port Canaveral cluster — 15 props, deterministic seed.
- [x] Gate: `planet_test` "canaveral site" — inset+scene+night plate present, streams in at 2.5 km and out past 4 km, landmarks placed, no physics bodies.

**OWNER DECISION (2026-08-23): no further detail sites.** Baikonur, Shanghai,
Tycho and Olympus Mons are dropped from the plan permanently — do NOT propose
or build them. The owner is evaluating NYC + Canaveral and will say so
explicitly if the site system should ever roll out elsewhere.

### Cloud shadows (owner-requested 2026-08-23) — BUILT

- [x] The deck is transparent and cannot render into the shadow map, so the ground darkens itself: `planet_surface.gdshader` samples the cloud field at the point where each fragment's sun ray pierces the cloud shell — real offset shadows that stretch as the sun drops, fading out at the terminator where the twilight band owns the look.
- [x] One field, one definition: the noise/threshold math moved into `assets/shaders/cloud_field.gdshaderinc`, included by BOTH the deck and the surface shader, and both materials are parameterized from `configure_clouds` alone — the shadow can never disagree with its cloud.
- [x] Gate: surface material carries the shadow uniforms on Earth (matching the def), and `cloud_shadows` stays unset on airless bodies.

### OR5 — landing plan DELIVERED 2026-08-23 → Track LD below (awaiting owner approval)

The design questions queued here are all answered in **architecture.md §
Landing**; the implementation-ready breakdown is **Track LD**. Nothing is
built. Owner approves the plan (or amends it) before LD1 starts.

## Track LD — Landing (BUILT 2026-08-24; LD5 partial — HUD done, polish open)

Full design rationale in architecture.md § Landing. Decisions in one breath:
rocks are a new free-physics class that sleeps on rails and wakes with a
velocity handoff; latching is a locked Generic6DOF joint (never a reparent);
planetary gravity is a per-body surface SHELL to 1.5 R (a global field is
impossible against dramatized rails — Meridian Relay would fall), dramatized
×0.25 so the 4 m/s² main lands Earth at TWR 1.6; landed is the docking-capture
pattern anchored by the site-transform chain, takeoff is the EVA-exit velocity
handoff. Suit hovers on the Moon, not on Earth — on purpose. Gas giants: no.

### LD1 — SpaceRock class + fields
- [x] `SpaceRock` (RigidBody3D): procedural rock mesh + convex collision, sizes 2–50 m, masses 0.5–20 t, spin seeded.
- [x] Sleep-on-rails: kinematic follow under the field's `OrbitalAnchor`; wake within ~500 m of the player with anchor-frame velocity handed off; re-sleep when abandoned.
- [x] Field spawner config on `OrbitalAnchor` fields (count, size/mass ranges, seed) — the M3 debris substrate.
- [x] Gates (`tests/anchor_test.gd`, new suite): woken rock co-moves with its field (< 0.1 m/s error), tumble persists, sleeping rock tracks the anchor under warp.

### LD2 — Latching (ship clamps + suit boots)
- [x] Latch: contact + relative velocity < 0.5 m/s + input → locked `Generic6DOFJoint3D`. Unlatch on input; force-limit break (clamp rating vs towed mass).
- [x] Suit boot clamps: same joint; torque-only control while clamped; push off by exceeding the break limit.
- [x] HUD: latch-ready indicator (the docking-computer pattern), latched-state readout.
- [x] Gates: latch succeeds under threshold and refuses over it; ship+rock couple tows under thrust with combined-mass acceleration; release is impulse-clean; jointed suit rides a tumbling rock.

### LD3 — Gravity shells
- [x] `SolarSystem.gravity_at(true_pos)`: inverse-square inside each solid body's shell (surface → 1.5 R), smooth fade at the top, zero elsewhere; per-body `surface_gravity` in `SolarSystemData` at ×0.25 real (Earth 2.45, Mars 0.93, Moon 0.40 m/s²); gas giants none.
- [x] Ship + suit apply it in `_physics_process`; flight assist gains a gravity feed-forward term so station-keeping in a shell holds altitude without sag.
- [x] Autopilot: integrator adds the same term; engagement refused from inside a shell ("TAKE OFF FIRST").
- [x] Gates (travel + new checks): field values at R/1.2 R/1.6 R (zero), every arrival standoff outside every shell, FA hover drift < 0.2 m/s, all existing transfer gates unchanged.

### LD4 — Touchdown + the landed state
- [x] Capture: skim-collider contact + surface-relative speed < 2 m/s + up-alignment < 25°, else bounce. On capture: freeze, `body_set_space(RID())`, leave `origin_shiftable`, record surface-local pose.
- [x] Landed placement each frame via the site-transform chain — co-rotation for free; verify against a surface point over half a spin period (the site antipodal-test pattern).
- [x] Takeoff: re-enter space at the anchor pose with surface-point velocity (frame + ω×r) handed off; a thrust-up hold triggers it.
- [x] EVA while landed: exit works, suit falls under shell gravity, boot-clamp latch to the ground = LD2 path; Moon EVA flies, Earth EVA stays clamped (TWR < 1) — assert both.
- [x] Gates (`tests/landing_test.gd`, new suite): scripted descent → landed on Earth and Moon, co-rotation tracks, takeoff clean (no teleport frame, velocity error < 0.1 m/s), origin shift while landed does not move the ship relative to the surface, all six existing suites green.

### LD5 — Descent presentation + HUD (HUD built; look-pass open)
- [x] SURFACE panel on the HUD inside shells: radial ALT, VSPD (green under the 2 m/s capture limit), lateral HSPD; LANDED banner with the lift-off hint; latch prompts (G — Latch / LATCHED / CLAMPED / GROUNDED).
- [ ] Descent look: aerial perspective + reddened terminator light already carry it; judge in play whether shell-entry needs anything more. No new shader work planned.
- [x] Scope statement honored: land, look, take off. No walking, no ground content — a later owner-approved track if ever.

**Build findings (2026-08-24) — three things the gates caught:**
1. **Belly landing jets.** 15 kN of vertical RCS against the 12 t hull is
   1.25 m/s² — less than Earth's 2.45, so no upright hover, braked descent,
   or landing could exist at all. Inside a gravity shell the vertical axis now
   gets the main-engine budget (48 kN → TWR 1.6, the plan's promised number);
   deep-space RCS feel is untouched. Attitude matters: gravity on a flat
   ship's RCS axes still sinks it, by design (the FA hover gate parks upright).
2. **Skim-collider swap guard (real pre-existing hazard).** A LOD change swaps
   in a different triangulation of the same relief; a trimesh materializing
   inside a hull 5 m off the deck got it ejected at a measured 68 m/s on
   climb-out. While a hull is within the relief band + 80 m, the collider set
   in its footprint is frozen (no adds, no frees); far patches swap freely.
3. **Capture re-arm + push-off.** Lift-off leaves the hull in contact at zero
   relative speed — exactly the capture conditions — so capture disarms on
   release and re-arms after 10 ground-clear frames (the docking pattern), and
   release adds a 2.5 m/s vertical push-off (the undock pattern): a live hull
   left resting on per-frame-teleporting colliders is eventually thrown by
   the solver.

**Owner follow-up (2026-08-24): "if we LOD transitioned after we passed where
the surface was, that's way too late."** Correct — and fixed at the root:
4. **Transition-earlier pin.** The skim ship's footprint now pins the quadtree
   to max depth (the detail-site pinning mechanism, reused): terrain under a
   hull converges to final geometry when skim engages at 500 m, splits finish
   on approach, and merges wait until the hull leaves. The collider swap
   guard remains as a backstop only. Gated: ground height under the final
   approach moves < 0.021 m below 60 m altitude (`landing_test`).
The convincing-screenshot hunt then flushed out three more real bugs:
5. **Reparent killed EVA.** `ship_controller._exit_tree` freed the stowed
   suit — and docking/landing captures REPARENT the hull, which passes
   through `_exit_tree`. EVA died after any capture. Cleanup moved to
   NOTIFICATION_PREDELETE; gated in `landing_test`.
6. **EVA exit under a rail parent.** `request_exit` parented the suit under
   `_ship.get_parent()` — the PORT while docked, the PLANET SURFACE while
   landed; a live body there enters the write-back fight (measured 193 km of
   drift in three frames). The suit now enters the world container captured
   at bootstrap; gated in `landing_test`.
7. **Hatch clips the relief when landed.** Exit position lifts 2 m along
   local up on the ground, else the solver ejects the suit at ~255 m/s.

Suites: `anchor_test` (16 checks) and `landing_test` (26 checks) — both green,
all six prior suites green. Harness traps for the standing list:
- GDScript lambdas capture locals BY VALUE (signal-fired flags need an array cell).
- A held teleport goes stale when an origin shift fires mid-hold — pose
  targets must be Callables re-evaluated per frame, never fixed vectors.
- A stowed body re-enters the physics space holding its stale pre-stow SERVER
  transform and node writes converge over many steps — hard-sync with
  `PhysicsServer3D.body_set_state(BODY_STATE_TRANSFORM)` before trusting a pose.
- After ANY `SimClock.sim_time` jump, re-centre the origin from analytic TRUE
  space (body position + spin-rotated local offset), NEVER from
  `to_true(node.global_position)`: the jump proxies the body, drags its
  children to the 40 km proxy shell, and to_true() of that locks the garbage
  in (the `_frame_site` trap, third appearance).

### LD6 — EVA surface locomotion (BUILT 2026-08-24, owner-requested: "can we run around and jump?")

Yes. On a planet the grounded state is a WALK SIMULATION, not a static clamp:
the suit stays frozen out of the physics space, parented under the spinning
PlanetSurface (the landed-frame pattern — the only stable stance on ground
moving at 131 m/s), and the controller integrates run/jump/gravity in the
surface's LOCAL frame (fictitious forces ~0.03 m/s² — ignored on purpose).

- [x] Auto-enter on approach — by PROXIMITY, never contact: a live suit that
  touches the per-frame-teleporting skim colliders is solver-kicked at
  ~20 m/s before any contact reports (trap #9's EVA verse).
- [x] WASD run (4 m/s), mouse yaw, upright against local up; SPACE jumps.
- [x] Ballistics gated against theory: apex = v²/2g (1.04 m measured vs 0.99
  on Earth), airtime = 2v/g. On the Moon the same legs jump ~6 m for ~11 s.
- [x] Hold SPACE = jetpack: net +1.6 m/s² on the Moon climbs away into free
  EVA past the 6 m departure bar; Earth's TWR 0.8 tops out at 5.4 m and the
  hop comes back down — gated. Once you're down on Earth, you walk.
- [x] Terrain truth: raycast against skim colliders near the ship, cooked
  height sampler anywhere else — walk the whole planet if you like.
- [x] Board on foot at the cargo bay (the Area3D cannot see an out-of-space
  suit; boarding goes by distance). G-latch is rocks-only now.
- [ ] Polish later: walk/run animations (the Synty rig ships one take),
  camera pitch on foot, footstep audio hooks.

## Track AN — Suit animation: walk, run, jump, land (BUILT 2026-08-24)

The suit T-poses through the whole LD6 walk because its cook ships exactly one
take. The asset server has the fix: **ANIMATION_Base_Locomotion_SourceFiles_v3**
(verified in the index, 721 files) carries a full in-place locomotion set for
BOTH Synty rig generations — and crucially a `Animations/Polygon/...` tree for
the classic Polygon rig the scifi-space EVA suit is built on, plus
`Character/PolygonSyntyCharacter.glb` as the reference skeleton.

Built as an OFFLINE RETARGET BAKE, not an in-engine AnimationTree:
`tools/bake_eva_anims.gd` (headless -s) retargets eight in-place clips
(idle/walk/run/jump/fall/land×3) onto the suit rig and saves
`assets/anims/eva_locomotion.res`; `scripts/eva_animator.gd` mounts it on the
suit's own player and maps the walk state to clips (idle↔walk↔run by speed
with playback scaling, jump→fall by radial velocity, landing weight by
impact speed). Rebake command in the tool header; rerun it if clips change.

**What the build actually taught (all verified, all in the tool's header):**
- The two Synty generations share a body plan but NOT rest rotations — a
  name-swap retarget explodes the pose. World-space per-bone orientation
  deltas transfer cleanly... against the right rest:
- The pack's CLIP rigs rest in a deep A-POSE (arm 52° down); the suit rests
  in T-pose. Deltas vs the clip rest pinned the arms at T forever (legs
  animated, arms frozen — the tell). The pack ships
  `Character/PolygonSyntyCharacter.glb` in T-pose precisely for this:
  rotation deltas calibrate against the REFERENCE rests, position deltas
  against the clip rig (right bob amplitude), scaled by hip-height ratio.
- Two headless-Godot traps for the standing list: `seek(update=true)` (and
  even `play()`+seek) never applies a pose in a frameless `-s` run — sample
  tracks and set bone poses BY HAND; and `get_bone_global_pose` reads a
  cache that never refreshes there — compose globals from local poses
  yourself.
- [x] Gates: `tests/anim_test.gd` (15 checks) — library shape, keys actually
  animate (max-swing probe at quarter phase; half phase of a run cycle is
  left/right symmetric and probes as zero), bones leave rest AT RUNTIME
  (clip-on-player is not tracks-on-bones), full idle→run→jump→fall→land→idle
  state tracking on the Moon.
- [x] Evidence: 15_landed_moon (natural standing idle beside the hull),
  19_moon_run (mid-stride), 16_moon_jump.
- [ ] Stretch, unbuilt: zero-g drifting idle for free EVA; EVA suit thruster
  puffs (from Track FX); Walk_ToIdle/Idle_ToRun transition clips.

## Track FX — Ship engine light and RCS puffs (BUILT 2026-08-24)

"When we engage the engine we should see lights; 6DOF should fire particles
along appropriate axes." Built as scoped, all in-engine:

- [x] `fx_thrust_local` / `fx_torque_local` on ship_controller, written where
  forces are applied — flight-assist counter-burns included (they are real
  firings); the autopilot writes its cruise burn (throttle from dv spent per
  step) and zeroes it on release. Hands-off states read engines-cold.
- [x] `ShipEffects` node (scripts/ship_effects.gd): stern plume + OmniLight
  scaled by main throttle; per-face RCS puffs expelling OPPOSITE the thrust;
  torque as opposed pairs (pitch/yaw nose+tail, roll wingtips); the belly
  emitter is plume-sized and normalized against the main budget — it is the
  landing engine inside gravity shells. Deadband (400 N / 300 N·m) keeps the
  flight-assist station-keeping trickle from strobing the thrusters.
- [x] Particles are LOCAL-space (world-space exhaust streaks out of frame at
  the 131 m/s frame velocity — readability wins), soft radial-gradient
  billboards (untextured additive quads read as literal white squares).
- [x] AudioManager hook comments at the emitter flips; no audio assets yet.
- [x] Gates: `tests/fx_test.gd` (17 checks) — pure signal→emitter mapping per
  axis and opposed pair, deadband, end-to-end player burn, autopilot cruise
  plume with cutoff-on-cancel. Evidence: 17_engine_burn.png (stern plume over
  night-side city lights), 18_rcs_puffs.png.
- [ ] EVA suit thruster puffs: stretch, same pattern at MMU scale — folds
  into Track AN's suit pass.

## Track LD7 — Minor-body landing: asteroids sized for the ship (QUEUED 2026-08-24, owner-requested)

"Details when landing on sufficiently small asteroids where the ship is
designed within that amount of gravity." The sweet spot the owner is naming:
bodies whose gravity sits INSIDE the ship's RCS envelope — where landing is a
gentle everyday act flown on lateral thrusters, not the belly-jet event a
planet demands. Design decisions to build against:

- **A new middle class: MinorBody.** Between SpaceRock (free physics, latch,
  no gravity) and CelestialBody (planet-scale, shells, belly jets): asteroids
  ~100–600 m radius, on analytic rails like moons (closed-form position, warp
  safe), procedural displaced-sphere mesh + trimesh collision at TRUE scale
  (no proxy needed at these sizes), tiny gravity shell g0 ≈ 0.05–0.5 m/s² —
  all inside the 1.25 m/s² RCS envelope, so the ship hovers on RCS alone and
  the belly-jet promotion never triggers. The class boundary IS the design:
  if you latch it, it's a rock; if you land on it, it's a minor body.
- **Landing reuses LD4 wholesale.** Same capture conditions, same freeze +
  leave-space + parent-under-the-body pattern, same takeoff handoff — the
  LandingComputer just needs MinorBody in its landable query. Tumbling
  asteroids make the co-rotation machinery earn its keep: land on a slowly
  tumbling one and the sky wheels overhead.
- **The details the owner asked for** (the reason this track exists):
  touchdown puffs of regolith dust (Track FX's emitter kit pointed down),
  the SURFACE HUD panel adapting its scale (ALT in tens of metres, VSPD
  threshold soft on a 0.1 g rock), EVA walking on a minor body (LD6's walk
  with g from the minor body's shell — jump 30 m and float down), boot-clamp
  irrelevant here because gravity holds you, and the nav console listing
  minor bodies as destinations with honest standoffs.
- Seed 2–3 of them: one near the spawn debris field (the tutorial asteroid),
  one in a distinct orbit worth a transfer, one tumbling.
- Gates: land/takeoff on a minor body via the full descent path; hover on
  RCS alone (belly jets never promoted); EVA jump ballistics under micro-g;
  co-rotation on the tumbling one; all existing suites green.

## Track AL — Autoland (QUEUED 2026-08-24, owner-requested)

One key from inside a gravity shell: the computer flies the descent the
landing gates already prove out manually — the docking computer's philosophy
(manual first, assisted second) now earning its second act.

- **Scope: from shell to ground.** Engage only inside a gravity shell (the
  autopilot's refusal boundary is autoland's jurisdiction line — the two
  hand off at 1.5 R). From orbit, the existing autopilot takes you to the
  standoff; autoland takes you down.
- **Fly it live, not analytically.** Unlike the autopilot's frozen-hull
  cruise, autoland drives the REAL physics ship through the real controller
  signal path (fx signals light the belly jets for free): pitch upright
  against local up, kill lateral drift against the surface point under you,
  descend on a braked profile (v_target ≈ sqrt(2·a_avail·alt)·0.7, capped),
  flare to 1.5 m/s under the 2 m/s capture limit, let the LD4 capture fire.
  No new landing state — autoland is an input source, same as a pilot.
- **Site choice is the pilot's.** Autoland lands where you are pointing DOWN
  from — it nulls lateral drift and descends radially; it does not pick
  sites. (A "land at site X" upgrade belongs to the nav console later.)
- **Abort honestly.** Any stick input cancels (the autopilot's discoverable
  rule); fuel-out mid-descent just cuts thrust — the hazard track below owns
  what happens next.
- HUD: AUTOLAND armed/active line in the SURFACE panel; the M2 AudioManager
  hook comments at engage/touchdown.
- Gates: engage at 1.4 R over Earth and the Moon → landed state captured
  with touchdown speed under limit and upright; abort mid-descent returns a
  live controllable ship; refuses outside a shell; works on a MinorBody once
  LD7 lands.

## Track HZ — Gravity-well hazard: warning, failure, restart (BUILT 2026-08-24)

The first real fail state in Cascade. Two beats: a WARNING while the well is
still winnable, and a FAILURE with a clean restart when it is not — "burned
in atmosphere or similar."

- **Make gas giants pull.** Today only landable bodies have shells, so
  nothing can truly suck you in. Gas giants (and Neptune/Uranus/Saturn/
  Jupiter + Venus's deep atmosphere + the Sun as a special case) get gravity
  shells WITH NO SURFACE CAPTURE: Jupiter at ×0.25 real is 6.2 m/s² — more
  than the main engine's 4.0, so inside a Jovian shell there is an altitude
  below which escape is arithmetically impossible. That line is the game's
  first cliff, and it must be computed, not authored: r_no_return where
  g(r) = a_ship_max, with fuel state folded in.
- **Warning beat (HUD + audio hooks).** Inside any shell, compute escape
  margin = a_ship_max − g(r) and time-to-floor at current v_rad. Bands:
  CAUTION (amber, margin thinning), WARNING (the calm HUD's one permitted
  urgent tone: "GRAVITY WELL — ESCAPE MARGIN 0.8 m/s²"), POINT OF NO RETURN
  crossed → the failure beat is now guaranteed physics. The Planetes tone
  survives by the warning being INFORMATIVE, never a klaxon screen-flash.
- **Failure beat.** Below the kill boundary — atmosphere entry interface for
  bodies with atmospheres (1 + height_fraction shell at excessive speed, hull
  heating presentation: reuse the reddened-light + camera shake kit), cloud
  deck for gas giants, corona distance for the Sun — the ship is lost:
  short whiteout/burn presentation, then RESTART FROM THE LAST SAFE STATE.
- **Safe state = periodic checkpoint, not a save system.** Every N seconds
  while the ship is (a) outside every shell or landed/docked, (b) autopilot
  idle, (c) under 5 m/s relative to its reference frame, snapshot true
  position + velocity + fuel + sim_time offset into GameState. Failure
  restores the snapshot through the OriginShift.shift_to + velocity-handoff
  pattern (the autopilot release path, reused). Docked/landed snapshots
  restore docked/landed.
- **The escape-proof cases stay honest:** Earth reentry at orbital speed
  burns you even though Earth is landable (interface speed check, not just
  depth); a dead-stick ship falling into ANY shell with empty tanks fails
  through the same path. Dying is now possible — dying UNFAIRLY is not:
  every failure was preceded by the warning beat and the physics were
  winnable at CAUTION.
- [x] BUILT as specced: gas giants + the Sun pull (`has_solid_surface=false`
  splits `shell_body_at` from `landable_body_at`; the autopilot refusal
  upgraded to ANY shell), `HazardMonitor` on the ship computes escape margin
  and the no-return radius (gated: Jupiter 9,960 m = R·√(6.2/4), exact),
  bands CAUTION/WARNING/NO RETURN on the calm HUD line with the margin
  number, kill at the cloud deck (1.05 R), corona (1.5 R), or atmosphere
  interface above 80 m/s (landing descents cross at 1.5 m/s — gated safe),
  2.5 s loss presentation (white-out + reason), restore through the
  autopilot release pattern from a reference-relative checkpoint (taken
  every 5 s only when stable + outside shells or landed/docked; never
  falling, never warping). `tests/hazard_test.gd`, 23 checks. Evidence:
  20_gravity_warning (margin line over Jupiter), 21_hull_lost (white-out),
  22_restored (back at the checkpoint beside Earth).
- Note: landing_test's "gas giants have no shell" gate updated — the rule
  CHANGED (they pull, harder than the main engine; they just never capture).

## Track SL — The Sun and the Stars (SL1–SL7 BUILT 2026-08-23; SL8 open, owner call)

Audit findings, then the plan. What is already RIGHT and must not regress:
one system light re-aimed every frame (the terminator is exact at the
reference body); `light_angular_distance = 0.5°` (real-sun-soft shadows);
stars do not twinkle (vacuum) and sit fixed on the inertial sphere; bodies
occlude stars; the glare is depth-tested and pulled past its own disc; the
atmosphere's in-scatter reddening is gate-validated physics.

**Defects found (ordered by how wrong they are):**
1. **No eclipse.** A ship in Earth's shadow stays fully sunlit — directional
   shadows reach 500 m and nothing else occludes the sun. The night-side of
   an orbit is the game's bread and butter, and it is lit wrong.
2. **Sunlight ignores distance.** `light_energy = 1.5` at Earth AND at
   Neptune. Real insolation falls 1/d² — Mars gets 43% of Earth's light,
   Neptune 0.1%. The outer system should FEEL far.
3. **The sun is ~14× too wide.** Radius 20,000 m at 300,000 m ⇒ 7.7° across
   from Earth (the harness measures it); the real sun is 0.53°.
4. **Direct sunlight never reddens.** The light's colour is constant white;
   at an orbital sunrise the hull should go gold-to-red as the sun drops
   through hundreds of kilometres of slant atmosphere. (Only the sky's
   in-scatter reddens today.)
5. **Scalar-alpha limb composite.** The shell multiplies the scene by a
   luminance-average transmittance (documented compromise), so the sun and
   city lights seen THROUGH the limb dim but never redden per-channel.
6. **One sun direction for every body.** `planet_sun_direction` is
   sun→origin. Correct at the reference body; wrong by tens of degrees for
   bodies at large elongation — Venus's crescent faces the wrong way when
   viewed across the system, and its night gate crosses the wrong meridian.
7. **The stars are invented.** Procedural hash field — plausible magnitude
   tail and colour spread, but no real sky: no constellations to recognize,
   no Milky Way band. (For the Planetes tone, the real sky matters the way
   the real coastline did.)
8. **No sun glint on the sea.** Ocean shares land roughness (0.9); the
   specular disc tracking the sun across the Pacific — the single most
   recognizable sun-planet interaction from orbit — does not exist.

### SL1 — Eclipse + distance-true sunlight (build first: cheap, dramatic)
- [x] Analytic umbra: each frame, cast the segment ship→sun in TRUE space against every body sphere between; light dims by the fraction of the sun's disc covered (angular overlap of the two discs — smooth penumbra falls out of the geometry, no shadow maps involved). Apply to `light_energy` and to the glare material's intensity through one shared factor on SolarSystem.
- [x] Inverse-square energy: `light_energy = 1.5 * (earth_orbit / d_sun)²`, clamped below by a playability floor (~0.12 at Neptune, owner-tunable) — the floor is a stated stylization, not a bug.
- [x] Gate (travel_test): park in Earth's umbra ⇒ energy < 5% of sunlit; graze the penumbra ⇒ strictly between; at Jupiter ⇒ energy matches 1/d² within the floor; the Moon eclipsing the sun dims the light at Earth.

### SL2 — True-scale sun (owner call embedded: 0.53° real vs ~2° stylized)
- [x] Shrink `SUN_RADIUS` so the disc is 0.53° from Earth (radius ≈ 1,390 m at 300,000 m) — or the stylized compromise ~2° if the real disc reads as "just another star" in playtest. Angular size then scales correctly at every other planet for free.
- [x] Whiten the disc: space-sunlight is white (5772 K unfiltered); keep the warm cast ONLY where transmittance produces it (SL3/SL4). Retune glare span against the smaller disc; keep `light_angular_distance` at the real 0.53°.
- [x] Gate: harness measures the disc width from Earth (assert within 10% of chosen target); sun-disc chromaticity near white at high elevation.

### SL3 — Sunlight through the atmosphere (direct-light reddening)
- [x] Each frame, when the tracked ship sits near an atmospheric body, tint the sun light by `AtmosphereMath.sample_transmittance` along the ship→sun path (CPU, the LUT already exists) — the hull goes gold at the terminator crossing and white in open space. Also drives the ambient tint it already modulates.
- [x] Gate (atmosphere_test): light colour R/B at sun-elevation −1° from low orbit ≥ 3× the value at +30°; in deep space exactly white; airless bodies never tint.

### SL4 — Per-channel limb composite (two-pass shell)
- [x] Replace the shell's scalar-alpha blend with two passes: a `blend_mul` pass writing per-channel transmittance, then a `next_pass` additive pass writing in-scatter. The setting sun seen through the limb reddens and dims per-channel; city lights keep their colour through thin air. Removes the documented compromise outright.
- [x] Gate: screenshot the sun on the limb; CPU mirror asserts the composite formula L·T + inscatter per channel now matches the shader path.

### SL5 — Per-body sun direction (correct far phases)
- [x] Per-body `body_sun_dir` uniform (surface material, night gate, atmosphere shell, cloud deck), set each frame from sun→body in true space; the scene DirectionalLight keeps sun→origin (exact for the ship and its reference body). `SolarSystem.sun_direction` stays for scene code.
- [x] Gate: Venus at max elongation shows a half phase from Earth's frame (sample its material's lit fraction analytically); the Moon's night gate crosses the sub-solar meridian of the MOON, not of the origin.

### SL6 — The real sky (catalog stars + Milky Way)
- [x] Cook the Yale Bright Star Catalog (~9,100 stars to mag 6.5, public domain) into a small binary the sky shader can read as a texture: direction, magnitude→intensity (2.512^−m), B−V→temperature tint. Render as a baked 4k equirect HDR panorama at cook time (zero runtime cost, no seams at this star density) — Orion, the Southern Cross and the Dipper become findable, which is the Planetes move: the real sky for the same reason as the real coastline.
- [x] Milky Way: band from the same cook (integrated unresolved starlight by galactic latitude — procedural density model seeded by the catalog's own distribution; no third-party panorama, no licensing tail).
- [x] Keep the current procedural layer as the faint-star floor under the catalog. Orientation: align the catalog's equatorial frame to the ecliptic so the band crosses the orbital plane at the real ~60°.
- [x] Gate: Polaris sits within 1° of the spin axis's north as seen from Earth; Orion's Belt spacing matches catalog angles; total sky luminance within 2× of today's (exposure unchanged).

### SL7 — Sun glint on the sea
- [x] Cook an ocean mask into `earth_albedo.png`'s alpha channel (land 0 / sea 1, from the same ETOPO majority rule); surface shader: sea texels get roughness ~0.15, METALLIC 0, SPECULAR 0.6 — Godot's lighting produces the tracking glint disc; polar ice gets a milder version.
- [x] Gate: harness shot of the glint; planet_test asserts the alpha channel land fraction matches the height map's within 2%.

### SL8 — Exposure adaptation — CLOSED (owner, 2026-08-23: "the stars are fine"). Do not build.
- [ ] Mild auto-exposure so stars wash out while the sunlit disc fills the frame and bloom back in shadow — real orbital-camera behaviour; clamp the range hard so the HUD and hull never crush. Skip if it fights readability in playtest.

Ordering rationale: SL1 is the largest correctness win per line and everything
later composes with it (eclipse feeds SL3's tinting naturally). SL2 changes
every framing that includes the disc, so it lands before glare-dependent
screenshots are retuned. SL4 and SL5 are pure fidelity with no new content;
SL6 and SL7 are content cooks with existing pipelines. Each stage is
independently shippable and screenshot-reviewable, per house rules.

**Built 2026-08-23, measured at the gates:** sun 0.53° from Earth exactly;
umbra visibility 0.000, penumbra a real gradient (0.09 mid-slide); vacuum
sunlight exactly white, the grazing-sunrise ray R 0.388 / B 0.047 (R/B ≈ 8) —
note the test computes its probe offset through the CONVERGING-ray parallax
factor, because the compressed sun is close enough that a parallel-ray guess
puts the perigee underground; 9,096 catalog stars splatted, Polaris peak 0.27
over the spin axis, Sirius 0.90, south pole dim, sky mean luminance 0.023;
sea-mask land fraction 0.290 vs the real 0.292. Shell now extinction
(blend_mul) + in-scatter (blend_add via next_pass) on one mesh, both marching
`atmosphere_common.gdshaderinc`; surface shading, night gate, cloud shadows
and shell all take per-body `body_sun_dir`, while the scene light keeps the
origin aim (exact at the ship) and carries eclipse energy + transmittance
tint. SL8 (exposure adaptation) remains unbuilt pending the owner's
readability playtest.

## Track SD — Stations and Docking (SD1 + SD2 COMPLETE — SD3 remains stretch)

Design authority: architecture.md "Stations and Docking". Read it, then this.

### SD1 — Stations on rails + destination interface

**SD1.1 Extract the orbit math**
- [x] New `scripts/world/orbit_math.gd` (`class_name OrbitMath`), static funcs `offset_at(t, radius, period, phase, inclination) -> Array` and `velocity_offset_at(...) -> Array` — 64-bit `[x,y,z]`, exactly the formulas now inlined in `CelestialBody.position_at/velocity_at` (circular orbit, plane tilted about X).
- [x] Refactor `CelestialBody` to call them. `tests/travel_test.gd` must stay green unchanged — it asserts orbit integrity and the velocity/position-derivative match, so it IS the refactor's safety net.

**SD1.2 NavTarget base class (the destination interface)**
- [x] New `scripts/world/nav_target.gd`: `class_name NavTarget extends Node3D` with overridable methods: `position_at(t) -> Array`, `velocity_at(t) -> Array`, `arrival_standoff() -> float`, `influence_radius() -> float`, `frame_depth() -> int`, `nav_display_name() -> String`, `nav_note() -> String`, `is_nav_destination() -> bool`. GDScript has no interfaces — a base class is the honest version. (NavTarget also holds the `true_pos` cache both subclasses refresh, so `reference_body()` reads one field.)
- [x] `CelestialBody extends NavTarget`; move `def.display_name` / `def.nav_note` / `def.is_destination` access behind the new methods.
- [x] Update every call site that reaches into `.def` from outside: `autopilot.gd` (3 sites: engaged emit, arrival name, status line), `nav_console.gd` (row text, footer note), `solar_system.gd` (`destinations()` filter, `reference_body()` depth/influence). Grep for `\.def\.` outside `celestial_body.gd` afterwards — zero hits is the done condition. (Tests updated too: travel_test's Earth-frame check is now an identity comparison, the Moon radius check measures constancy against t=0, and display names go through `nav_display_name()`.)
- [x] `Autopilot.target`, `engage()`, `_aim_point()`, `estimate_transfer()` retype `CelestialBody` → `NavTarget`. `SolarSystem.destinations()` returns `Array[NavTarget]`.

**SD1.3 OrbitalStation**
- [x] `scripts/world/station_def.gd`: `StationDef extends Resource` — `id`, `display_name`, `parent_id` (body), `orbit_radius`, `orbit_period`, `orbit_phase`, `inclination`, `nav_note`, `standoff` (default 200.0), `influence` (default 2000.0).
- [x] `scripts/world/orbital_station.gd`: `OrbitalStation extends NavTarget`. Position = parent body's `position_at(t)` + `OrbitMath.offset_at(...)`; velocity likewise. Recomputes render position from true space every frame (driven by `SolarSystem._update_bodies` alongside the bodies; NOT in `origin_shiftable` — trap #3). `frame_depth()` = parent's depth + 1, so the deepest-wins reference rule resolves the station without special cases.
- [x] Station scene `scenes/stations/meridian_relay.tscn`: built from `SM_Ship_Station_06.gltf` (60×101×52 m, base at origin, tower up +Y) plus emissive nav lights and a glowing capture collar at the port. StaticBody3D collision (environment layer) from 3 box shapes measured off the mesh's per-height-band extents — NOT a trimesh.
- [x] First station: "Meridian Relay", Earth orbit — `orbit_radius 9000.0`, `orbit_period 2200.0`, phase 2.0. Registered by GameWorld bootstrap via `SolarSystem.register_station()`; included in `destinations()` and `reference_body()`.
- [x] Nav console shows it with live distance/ETA — zero console logic changes were needed, which was itself the SD1.2 check.

**SD1 gate (`tests/station_test.gd`) — ALL GREEN:**
- [x] Station's distance from parent body equals `orbit_radius` at 200 sampled times (max error 0.000 m).
- [x] Autopilot `engage(station)` converges: arrives 151 m off (standoff 200), velocity-matched to 0.00 m/s relative. travel_test also now flies the station as a 15th destination.
- [x] `reference_body()` at the standoff returns the station; flight assist settles to 0.033 m/s relative in its frame.
- [x] Both existing suites green.

### SD2 — Docking

**SD2.1 DockingPort**
- [x] `scripts/docking_port.gd`: `DockingPort extends Node3D`, child `Area3D` capture volume (box 6×6×10 m extending along the port's +Z approach axis), joins group `&"docking_ports"`. Exports: `capture_speed_max = 1.5` (m/s, relative), `capture_angle_max_deg = 20.0`. One port on Meridian Relay at (0, 35, 23), +Z face, axis pointing away from the tower.
- [x] `scripts/docking_computer.gd`: node on Ship (like Autopilot). Each physics tick while not docked: port whose volume holds the ship → check relative velocity (`ship.linear_velocity - port.station_velocity()`) and alignment (ship −Z vs port axis). All conditions met → capture.

**SD2.2 The docked state**
- [x] Capture sequence, in order: `ship.freeze = true` (FREEZE_MODE_KINEMATIC) → **remove ship from `origin_shiftable` group** → reparent ship under the port preserving global transform → **take the ship's body out of the physics space** (see note below — freeze alone is NOT enough) → zero relative motion → `GameState.docked = true` (new bool + signal on GameState).
- [x] While docked: ship_controller and autopilot stand down (`GameState.docked` guard); nav console may open but `engage` refuses (`can_engage()` checks docked); HUD shows "DOCKED — Meridian Relay" and `F — Undock` (interact priority while docked: undock beats EVA-exit).
- [x] Ship fuel refills while docked (station services; instant, same as EVA refill precedent).
- [x] Undock, in order: reparent ship back under GameWorld (preserve global transform; re-entering the world also re-adds the body to the physics space) → re-add to `origin_shiftable` → `freeze = false` → `linear_velocity = station velocity` + push-off `1.0 m/s` along port axis → `docked = false`. Flight assist on.
- [x] EVA while docked: `request_exit` allowed; the DockingComputer refreshes the frozen hull's `linear_velocity` to the station's each tick, so the suit exits co-moving (trap #5). Boarding returns to the docked ship.

**SD2.3 Approach HUD**
- [x] When inside a port's capture volume (and not docked): readout block — distance to port, relative speed, axis error in degrees; speed and axis lines flip modulate to a calm green tint when within capture tolerance. No red.

**SD2 gate (`tests/docking_test.gd`) — ALL GREEN:**
- [x] Scripted clean approach (co-moving with station, drift in aligned at 0.5 m/s) → captures; ship frozen, parented under port, `docked == true`, NOT in shiftable group, fuel topped up.
- [x] Hot approach (3 m/s) does NOT capture; misaligned (35°) does NOT capture.
- [x] Docked through an origin shift (`OriginShift.shift_by(Vector3(20000,0,0))`) — ship stays exactly at the port (local drift 0.000000 m).
- [x] Docked through 60 s of sim time — station orbits on, ship rides it, zero drift relative to port.
- [x] Undock: free flight restored, velocity = station velocity + push-off (error 0.0000 m/s), back in shiftable group, both other suites re-run green.
- [x] Screenshots via `tests/capture_docking_shots.gd` (xvfb): `screenshots/11_dock_approach.png` (nose at the collar, APPROACH readout, REL out of tolerance), `12_docked_wide.png` (docked hull at the glowing collar, tower + Earth, DOCKED HUD), `13_undock.png` (push-off separation, readout live).

Fixed on the way through, worth knowing:
- **Freeze is not enough for a docked ship.** Even frozen kinematic, the physics
  server writes the body's global transform back to the node every physics
  step, one frame behind the rail-driven parent — the ship's local offset under
  the port grew ~0.8 m per frame. The fix: `PhysicsServer3D.body_set_space(rid,
  RID())` on capture (after the reparent — re-entering the world re-adds a body
  to the space, which is also what silently restores it on undock). Same
  reasoning as the stowed EVA suit. The CargoBay Area3D is a separate physics
  object and keeps detecting EVA boarding while the hull is out of the space.
- **Capture must re-arm by distance, not volume exit.** The undock reparent
  resets the Area3D overlap for a frame (reads as exit/re-enter), and the
  push-off is slow, aligned, and still inside the volume — without a re-arm
  distance (`rearm_distance = 14 m` > volume reach) the ship recaptures on the
  next tick.
- The gameplay camera's damped follow trails a target that teleports or
  co-moves fast; the docking screenshot harness parents its review camera under
  the station (which translates ~2.6 m/frame but never rotates) so framing
  holds across settle frames.

### SD3 (stretch — do not start without owner)
- [ ] Assisted approach via ManeuverMinigame; ship-to-ship ports (host stays live, guest freezes — the stowed-suit pattern).

## Owner requests — queued 2026-08-23

Raised by the owner during a play session, in no fixed order. The session ran on
the pre-PR6 build; the list below was reconciled against PR6 / the lighting audit
/ Track SL afterwards, and says so per item. OR2/OR3/OR4 are investigations: find
the cause and report before committing to a fix.

### OR1 — ~~Disable EVA~~ RESCINDED (owner, 2026-08-23): EVA stays.
Replaced by a suit audit, findings below (investigated 2026-08-23):

**The suit is NOT mis-scaled.** Runtime-measured: world AABB 2.88 m arm-span x
1.73 m standing height, every node scale 1.0, capsule 1.8 m x 0.35 r, 150 kg.
The Synty SK_ root-scale trap was correctly handled by the patcher.

**Why it READS giant — the ship is small, not the suit big.** The hull is
4.59 x 3.01 x 7.24 m — a 12-tonne vessel in a van-sized shell. A 1.73 m
figure stands over half the hull's height; beside the hatch that reads as a
giant. (Cameras are equivalent: EVA rig (0, 1.2, 4) frames the suit at about
the same screen fraction as the ship rig (0, 3, 12) frames the hull — the
mismatch is world scale, not framing.)

**Control audit: complete 6DOF Newtonian MMU.** WASD/Space/C translation at
300 N (2 m/s^2 — dramatized but proportionate), mouse pitch/yaw torque
(40 N-m clamp), Q/E roll, linear+angular flight assist on by default holding
station against the local body's frame, F boards from the cargo bay. Fuel
drains on thrust AND torque and cuts both at empty (spec-intended dead-stick).
Weak spots if EVA gets a feel pass later: keys are binary full-thrust, no
free-look, empty-tank tumble is unforgiving.

- [x] **Ship rescaled 1.8x** (owner call, 2026-08-23): hull instance, box
  collision, cargo bay, thruster markers, nav lights, exit point and both
  camera offsets, all together (hull now ~13.0 m long; mass/thrust already
  fit). Harnesses read the rig offset instead of hardcoding it.
- [x] **CORRECTION to the audit above — the suit WAS broken, differently.**
  The rest-pose measurements were true but blind: `get_aabb()` on a skinned
  mesh reports REST space and cannot see skinning. In the render, the suit's
  limbs exploded ~100x — `patch_gltf_materials` stripped the 0.01 root scale
  from the character cook (correct for its metre vertices) but the cook keeps
  its skeleton joints AND inverse bind matrices in centimetres, and glTF
  skinning runs in the skeleton's space: the root scale is what brings the
  skinned result back to metres. That was the owner's original "giant suit".
  Fixed: the patcher never strips the root from a cook with `skins` (rule
  documented in the patcher docstring), the local asset is restored, and the
  suit renders a posed 1.73 m figure beside the 13 m hull.
- [x] EVA handoff verified as requested: `request_exit` already sets the suit
  to the ship's velocity including the hatch's rotational term (zero relative
  speed at exit), full 6DOF thrust retained, assist on by default.

### OR2 — Dramatic lighting change tied to MOVEMENT — FIXED 2026-08-23
**Still reproduces.** The owner playtested the current build and re-reported
with sharper symptoms: it is not (only) a startup pop — *moving a certain
amount* triggers a dramatic lighting change, "like shadows turn off or don't
apply, or fight with bloom". That phrasing points at a DISCRETE THRESHOLD the
ship crosses, not a converging system. The startup-luminance probe (below)
stays useful context but no longer bounds the bug.

Threshold suspects, in order of how well they match "moved a certain amount":
1. **`directional_shadow_max_distance = 500`** (`solar_system.gd`): anything
   crossing 500 m from the camera snaps between shadowed and unshadowed — on
   approach to terrain, a station, or debris, whole surfaces pop. "Shadows
   turn off" is this suspect's exact signature. Try raising it (with the
   4096 map, 12 cm/texel headroom exists) or switching to PSSM splits, and
   check the bias pair still holds.
2. **OriginShift rebase** (>10 km of travel): everything render-space jumps
   in one frame; if any lighting-adjacent state reads a stale position for
   one frame (ambient's `best.position`, the glare billboard, shadow cascade
   fitting), the frame flashes. Correlate: does the change land exactly on a
   rebase? Log `OriginShift.shift_to` alongside a frame-luminance probe.
3. **Skim collider swap at 500/600 m altitude** — should be physics-only,
   but the patch colliders pin refinement, which changes geometry density.
4. **L2 tile residency margins (14°/28°)** and the depth-3+ cache purge:
   terrain rebuilds under the camera as tiles stream — a visible relief
   change reads as a lighting change at grazing sun.
5. **Proxy flip at `MAX_RENDER_DISTANCE` 40 km** — limb/shell/glare all
   rescale in one frame when a body crosses the clamp.
6. **Glow response, not a light at all**: `glow_intensity 0.4 / strength
   0.9` reacts frame-to-frame to bright emitters entering the frame (sun
   glare, city lights, the blooming disc) — "fights with bloom" suggests the
   owner is seeing the bloom term itself swing as framing changes.

Method: reproduce while logging every candidate's toggle (one print per
threshold crossing) against a mean-frame-luminance probe; the jump will
timestamp itself against exactly one of them. Fix the mechanism, not the
constant, then re-run all six suites and recapture the SL screenshots.

- [x] Instrumented and attributed with `tests/probe_or2.gd` (kept as the
  standing instrument: three scripted sweeps logging mean frame luminance
  against every suspect per step). The data was unambiguous: `sun_visibility`
  flipped 1.000 -> 0.000 on exactly the rows where `origin_x` jumped — an
  ORIGIN REBASE — and later read fully-lit with the ship deep inside Earth's
  shadow. **Root cause: suspect #2.** The SL1 eclipse, SL3 tint and 1/d²
  energy were all evaluated at the RENDER ORIGIN, which trails the tracked
  ship by up to 10 km between rebases: stale lighting while flying, then a
  single-frame re-evaluation when the rebase fired — the sun winking on/off
  after "moving a certain amount", bloom collapsing with it, shadows dying
  with the light. Suspects #1/#3/#4/#5 were exonerated by Sweep A (a full
  descent through skim/tile/shadow ranges produced not one luminance jump);
  #6 was a symptom, not a cause.
- [x] Fix: `SolarSystem._aim_sun_light` evaluates visibility, tint and solar
  distance at `OriginShift.tracked`'s TRUE position (origin only as a
  fallback). Eclipse crossings now happen where the ship actually is, and
  the on-ramp is the physical sequence — atmosphere-reddened light, then the
  penumbra gradient, then umbra — instead of a rebase-timed snap.
- [x] Regression gate (`travel_test`): frozen ship parked in the umbra at
  9,874 m from the origin (inside the rebase threshold, origin still
  sunlit) — the live light must follow the ship to sub-5% visibility.
- [ ] If it does still happen, note what is now ruled out: **auto-exposure is not
  implemented** — SL8 (exposure adaptation) is unbuilt and pending an owner call,
  and the only exposure control in the project is the static
  `tonemap_exposure = 1.0` in `scenes/game_world.tscn:30`. So a converging
  auto-exposure cannot be the cause.
- [ ] Remaining suspects, in order: the PR6 L2 tile streaming swapping in a
  different-looking surface as it becomes resident (`scripts/world/body_surface.gd`,
  `planet_surface.gd`), the PR4 atmosphere LUTs finishing their precompute and
  swapping in (`scripts/world/body_atmosphere.gd`, `atmosphere_math.gd`), or the
  cloud layer resolving. Time the jump against each system's ready signal before
  changing any values — the fix for a late texture swap (blend it in) is nothing
  like the fix for a bad constant.
- [ ] Re-run `atmosphere_test` and `planet_test` after any change, and re-capture
  the lighting screenshots the PR4/PR5/SL entries reference.

### OR3 — Recognisable Earth surface up close
**Largely superseded by PR6, which the owner had not seen when raising this.**
PR6 shipped exactly the work this task was going to scope: an ETOPO 2022 height
tile pyramid (L1 complete at effective 4096, L2 land-only at effective 8192, 36
tiles / 55 MB committed under `assets/planets/tiles/`), `earth_albedo.png`
recooked to 4096×2048 from Blue Marble, and distance-based L2 streaming with
hysteresis. `planet_test` already asserts the Himalaya resolves higher through
tiles than the 2 k global map. So what remains is a judgement, not an
investigation.

- [ ] Owner: fly down and say whether PR6 clears the bar — "recognise all the
  coastlines, mountains, continents". The answer decides whether this closes or
  turns into a further fidelity tier.
- [ ] If it does not clear the bar, the honest next question is which of the three
  is short: height detail (tile pyramid depth), colour detail (albedo ceiling), or
  the shading that makes relief legible. They have very different costs and only
  one is likely to be the actual complaint — establish which before cooking
  anything, and bring the owner a recommendation.
- [ ] Note the git boundary: `assets/planets/` is the one committed asset
  directory and the tiles already put 55 MB in the repo. A further tier needs a
  deliberate call about whether it belongs in git.

### OR4 — Audit displayed distances against true scale — VERIFIED CLEAN 2026-08-23
**Audited end to end, 2026-08-23 — the readouts are unit-true and true-space:**
`Autopilot.estimate_transfer` computes its route in 64-bit TRUE space
(`OriginShift.to_true` -> `position_at` -> `dv_length`), so the feared
proxy-clamp leak does not exist; `_format_distance` is a plain m/km
formatter; the docking readout measures render space but only inside a
capture volume, where render IS true; HUD velocity is already
reference-frame-relative (the 131 m/s only appears in open space, where
absolute is the honest answer). New gate in `travel_test`: Jupiter, drawn at
the 40 km proxy, must still report its ~800 km true route; the Moon's route
must equal separation minus standoff plus intercept lead.

**The one real confusion source (by design, owner may want a UI tweak):** the
nav console shows PLANNED ROUTE length — distance to the intercept point at
arrival time, minus the arrival standoff — not current separation. For a
moving target these legitimately differ by double-digit percent — measured: a 22 km route to the Moon against a 14 km separation, because the Moon orbits at ~52 m/s and the intercept leads it by ~2 minutes of flight. If that is
what read as "wrong scale," the fix is labelling (e.g. "route"), not math.
Minor note: the prograde marker uses absolute velocity while VEL shows
frame-relative — spec-conformant, but worth a look in a HUD pass.

- [ ] Owner suspects the UI is reporting distances in a different scale than it
  should. Verify end to end rather than adjusting a formatter until numbers look
  right.
- [ ] The convention is fixed and stated at the top of this file: **1 Godot unit =
  1 metre**. Check every readout against it: `_format_distance()`
  (`scripts/nav_console.gd:176`) and the nav row distances it renders from
  `Autopilot.estimate_transfer()`, the docking readout (`scripts/hud.gd:171`,
  `PORT %6.1f m`), and the HUD velocity/reference-frame lines.
- [ ] The likely trap is true space vs render space, not a unit constant. Far
  bodies are drawn as **angular-size proxies** — `CelestialBody` clamps distance
  and scales radius by the same ratio (`scripts/world/celestial_body.gd:181-222`,
  `is_proxy`). Any distance measured off a proxy's `global_position` is the
  clamped render distance, not the true one, and will read far too small for
  anything beyond the clamp. Distances must come from true space
  (`OriginShift.dv_sub` / `dv_length` on `true_pos`).
- [ ] Sanity-check the results against known values — Moon ≈ 384,400 km, Sun ≈
  1 AU ≈ 149.6 M km — and add the check to `tests/travel_test.gd`, which already
  prints a per-destination distance column and is where a scale regression should
  get caught.

## Milestone 3 — Debris capture + contracts (DO NOT START)

Gated on M1 + M2 verification and owner sign-off on movement feel. Not yet broken down. Headline scope from plan.md Phase 2/3: physics-active debris, Grapple Arm `Tool` Resource + RotationMatch minigame, tether joint, CargoBay stow, first contract via `ContractManager`.
