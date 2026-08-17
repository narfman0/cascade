# Cascade — Task Board

_This file is populated by agents. Do not edit manually._

**Ordering directive (from project owner, updated 2026-08-17):** Implementation
order is now **Track SD (stations + docking) first, then Track PR (planet
renderer)**. M3 (debris/tools/contracts) remains gated on the M1/M2 human feel
checks. The original directive stands underneath: model 3D flight accurately;
movement correctness before content.

**Standing traps — read before writing any code in this project:**
1. Never nest a RigidBody3D under another RigidBody3D (both transforms corrupt; see architecture.md). The EVA suit stows *out of the tree* while aboard.
2. The physics server owns a live RigidBody3D's transform and reverts script writes — `freeze = true` before setting position/basis, and hold poses across *physics* frames (a frozen kinematic body's transform only commits through a physics step).
3. `origin_shiftable` group membership: join it only for nodes holding a real render-space position (ship, suit). Anything recomputed from true space each frame (bodies, anchors, stations) must NOT join, or it gets double-shifted.
4. Children `_ready` before parents: never place world content against the render origin in a child's `_ready` — GameWorld establishes the origin, then calls `refresh()`. Follow that bootstrap pattern.
5. The ship station-keeps at ~131 m/s absolute (Earth's orbital velocity). Anything that must stay near it has to co-move; a one-shot teleport falls behind ~2 m per physics tick.
6. After any change to flight, world, autopilot, or docking code, run BOTH suites: `godot --headless res://tests/travel_test.tscn` and `res://tests/eva_test.tscn`. They are the regression net for everything above.

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

### PR1 — Relief everywhere + night lights
- [ ] `scripts/world/body_surface.gd`: `BodySurface extends Resource` — noise seed (derive from body id), `continent_frequency`, `ridged_mix`, `amplitude` (as fraction of radius, default 0.02), `sea_level` (-1 = none), `palette` (Gradient or 3–4 colors), `night_emissive: Texture2D` (optional), `authored_height/albedo: Texture2D` (optional, used INSTEAD of noise when set).
- [ ] `BodyDef` gains `surface: BodySurface`, `spin_period` (0 = no spin), `spin_axis_tilt`. `SolarSystemData` fills surfaces for all 15 bodies (gas giants: amplitude 0, banded palette; Earth: sea_level set, hand-painted night-lights blob mask; Sun: none — keeps its emissive sphere).
- [ ] `scripts/world/planet_surface.gd`: `PlanetSurface extends Node3D`, built by `CelestialBody._build_visuals()` when `def.surface` exists (else current sphere fallback). PR1 scope: 6 root cube-faces at fixed 33×33, displaced by the height source, one shared `ShaderMaterial`.
- [ ] Bake per body at build: equirect albedo (from palette × height/sea), normal (from height gradient), emissive (night lights) — 512² is enough at PR1. Bake on a background thread; body shows flat color until ready (bodies build during bootstrap, so in practice it is ready before the player can look).
- [ ] Shader `assets/shaders/planet_surface.gdshader`: albedo/normal lookup, emissive gated by terminator — `emissive_strength = smoothstep(0.05, -0.15, dot(normal, sun_dir))` so lights fade in across dusk. Sun direction as a global shader parameter set by SolarSystem (it already aims the light).
- [ ] Spin: `CelestialBody` rotates the `PlanetSurface` child (NOT the collision sphere, NOT the node itself — children like future site anchors hang off the surface node) by `TAU * sim_time / spin_period` about the tilted axis. Analytic from `SimClock.sim_time` — never accumulate per-frame (trap: breaks time compression).
- [ ] Proxy check: `_apply_scale` scales `PlanetSurface` exactly as it scaled the sphere mesh. Verify by screenshot at proxy range and at 30 km — same apparent size as before the change.
- [ ] **PR1 gate**: travel + EVA + station suites green; `capture_shots.gd` extended — Earth full disc showing continents/sea, terminator with visible night lights, Moon relief at 10 km, Jupiter banding. Screenshots to owner.

### PR2 — Progressive refinement + skim collision
- [ ] Quadtree in `planet_surface.gd` (or split `planet_patch.gd`): subdivide when `patch_geometric_error / distance_to_camera > threshold` (start `0.004`), merge on hysteresis (×1.5). Re-evaluate at most every 0.25 s per body. Max depth 7.
- [ ] Patch build on `WorkerThreadPool` (arrays on worker, `ArrayMesh` commit on main thread), ≤4 in flight per body; LRU cache 256 patches, never evict depth ≤2.
- [ ] Skirts: edge ring dropped 2% of patch span below the surface. No T-junction stitching — skirts only.
- [ ] Vertices relative to patch center; patch node positioned by center (float32 discipline per design doc).
- [ ] **Skim collision**: when ship's true distance to surface < 500 m — build `ConcavePolygonShape3D` for resident patches within 300 m of the ship (on the worker), disable the body's sphere collider, enable ship CCD (`continuous_cd = true`). Reverse all three above 600 m (hysteresis). The sphere/patch swap is mandatory in BOTH directions — sphere walls you out of valleys, missing patches make peaks intangible.
- [ ] `tests/planet_test.gd`: seam agreement (shared-edge vertices of same-depth neighbours within epsilon), determinism (same patch id ⇒ bit-identical arrays), approach monotonicity + return-to-baseline (streaming leak), budget caps never exceeded during a scripted proxy→spawn approach, scripted low pass at 60 m altitude / 80 m/s over 20 km of terrain — no tunnel-through, no invisible-sphere contact.
- [ ] **PR2 gate**: all suites green; screenshot set: continuous approach series (5 frames, no visible pop), low-skim frame with terrain filling the lower third.

### PR3 — Detail sites + NYC pilot
- [ ] `scripts/world/detail_site.gd` per the design doc schema (`lat_deg/lon_deg/footprint_m/height_inset/scene/night_emissive/nav_note`).
- [ ] Site streamer in `PlanetSurface`: in at 3 km, out at 4 km (hysteresis); scene oriented to the sphere tangent at (lat,lon), rotating with spin; inset height blended into overlapping patches with smoothstep falloff over the footprint.
- [ ] Authored maps: Earth/Moon/Mars height+albedo (public domain: NASA Blue Marble, LRO LOLA, MOLA), 2–4k equirect PNG. Preferred home: asset-server raw drop `CASCADE_Planets` (needs owner/server write access); fallback if the server is not writable from the dev box: commit under `assets/planets/` (a few MB, un-ignored) and note the migration. Do not block the milestone on server access.
- [ ] NYC pilot `scenes/sites/nyc.tscn`: add `POLYGON_SciFi_City` + `POLYGON_City` to `DEFAULT_PACKS` (now, not before), Manhattan grid from `SM_Bld_Background_*` at miniature scale (towers 25–40 m), rivers/harbor from the height inset, emissive street-grid night texture. Placed at 40.7 N, −74.0 E on the REAL Earth map — the recognizable-coastline premise needs the authored map, so that item precedes this one.
- [ ] **PR3 gate**: all suites green + site stream-in/out test; the money shot — NYC at night from 2 km, terminator in frame. Owner review.

### PR4 (stretch — owner call): atmosphere rim shell, clouds, geomorphing, more sites (Canaveral, Baikonur, Shanghai, Tycho, Olympus Mons).

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

## Milestone 3 — Debris capture + contracts (DO NOT START)

Gated on M1 + M2 verification and owner sign-off on movement feel. Not yet broken down. Headline scope from plan.md Phase 2/3: physics-active debris, Grapple Arm `Tool` Resource + RotationMatch minigame, tether joint, CargoBay stow, first contract via `ContractManager`.
