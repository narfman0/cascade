# Cascade — Task Board

_This file is populated by agents. Do not edit manually._

**Ordering directive (from project owner):** Model 3D flight accurately. Get travel and lighting solid first (M1), then EVA (M2). Debris pickup, tools, and contracts come only after movement is verified — do not start M3 work until the M1 and M2 verification gates below have passed.

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

## Milestone 3 — Debris capture + contracts (DO NOT START)

Gated on M1 + M2 verification and owner sign-off on movement feel. Not yet broken down. Headline scope from plan.md Phase 2/3: physics-active debris, Grapple Arm `Tool` Resource + RotationMatch minigame, tether joint, CargoBay stow, first contract via `ContractManager`.
