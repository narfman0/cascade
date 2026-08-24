# Cascade — Architecture

## Scene Structure

```
GameWorld (Node3D)                    # game_world.gd — bootstraps origin, then bodies, then ship
├── SolarSystem (Node3D)              # solar_system.gd — generates all bodies + the system light
│   ├── Sun / Earth / Moon / ...      # CelestialBody, created at runtime from SolarSystemData
│   └── SunLight (DirectionalLight3D)
├── Environment (Node3D)
│   └── WorldEnvironment              # starfield sky, earthshine ambient, tonemap
├── Ship (RigidBody3D)
│   ├── Hull (imported mesh)
│   ├── Autopilot (Node)              # autopilot.gd — destination transfers
│   ├── Thrusters (Node3D)            # thruster force application points
│   ├── CargoBay (Area3D)             # boarding trigger volume
│   ├── ExitPoint (Marker3D)          # EVA hatch, clear of the hull collision
│   ├── NavLight* (MeshInstance3D)
│   └── CameraRig (Node3D)            # top-level; third-person + cockpit
├── DebrisField (Node3D)              # orbital_anchor.gd — pinned to a body's frame
│   ├── Debris_001 (StaticBody3D)     # RigidBody3D from M3 on
│   └── ...
└── HUD (CanvasLayer)
    ├── Panel (velocity, attitude, fuel, FA, reference frame)
    ├── AutopilotLabel                # destination, distance, ETA, warp factor
    ├── InteractPrompt                # what F does right now
    ├── NavConsole (Control)          # nav_console.gd, built at runtime
    ├── ToolMinigame (Control)        # shown during tool use (M3)
    └── ContractTracker               # (M3)

The EVA suit is NOT in this tree while the player is aboard — it is held by
ship_controller.character. See "never nest a RigidBody3D" below.
```

## Ship Interior Scene

The ship interior is a separate scene loaded when the player is between missions (docked or in transit). It replaces the GameWorld scene or loads as a sub-scene depending on implementation preference — keep it isolated.

```
ShipInterior (Node3D)
├── Geometry (Node3D)                  # walkable meshes, walls, floor, ceiling
├── GravityVolume (Area3D)             # low gravity override for interior; no zero-g
├── CrewNPCs (Node3D)
│   ├── CrewMember_A (CharacterBody3D)
│   │   ├── Mesh (MeshInstance3D)
│   │   └── DialogueTrigger (Area3D)  # player proximity → interaction prompt
│   ├── CrewMember_B (CharacterBody3D)
│   └── CrewMember_C (CharacterBody3D)  # optional third crew slot
├── InteractiveObjects (Node3D)
│   ├── ContractBoardTerminal (StaticBody3D)   # opens ContractManager UI
│   ├── ToolBench (StaticBody3D)               # upgrade/maintain tools
│   ├── RepairStation_A (StaticBody3D)         # triggers ship repair minigame
│   ├── RepairStation_B (StaticBody3D)
│   └── RepairStation_C (StaticBody3D)
└── HUD_Interior (CanvasLayer)
    └── InteractionPrompt (Label)
```

**Gravity:** Interior uses a low-gravity `Area3D` (not zero-g). Player moves with magnetic boots — standard CharacterBody3D movement, no floating. Keeps navigation readable without full EVA physics.

**Crew NPC behavior:** Crew idle in their areas, comment contextually when approached. Dialogue is driven by `CrewDialogue` resources (see below). Crew do not block the player — interaction is always player-initiated via proximity trigger.

**Scene transitions:** On "undock" from the interior, save crew state and load GameWorld. On contract completion and return, load ShipInterior and trigger relevant crew reaction lines.

---

## Physics Approach

- **Global gravity:** `ProjectSettings.physics/3d/default_gravity = 0`. Nothing falls unless explicitly told to.
- **Planetary gravity wells:** `Area3D` nodes around bodies (Earth, Moon, etc.). On `body_entered` / per-frame `_physics_process`, apply gravitational acceleration to any RigidBody3D inside. Used for background debris drift and orbital mechanics flavor — player physics stay raw.
- **Player and grabbed debris:** Full `RigidBody3D` physics. No gravity override unless player is inside a gravity well Area3D and has "orbital mode" toggled.
- **Orbital-path background objects:** Not full physics sims. Use `Path3D` + `PathFollow3D` for background satellites and debris that don't need to interact. Only pulled into full physics when the player approaches (proximity-based activation radius).

## Flight Assist Maneuver System

Approach burns, docking, and orbital insertion are guided maneuvers — the ship computer calculates the optimal burn, the player executes it.

**Flow:**

1. Player initiates a maneuver (approach vector, docking sequence, or orbital insertion).
2. Ship computer issues a directive: "Burn 8.4 s at 047° relative." HUD shows a guided overlay:
   - Angle indicator: current ship heading vs. target angle
   - Burn timer: countdown window (e.g., ±0.8 s tolerance)
   - Throttle bar
3. Player aligns heading and holds burn within the window.
4. **On success (within tolerance):** Clean maneuver. Minimal fuel spent. No follow-up needed.
5. **On miss:** Ship overcorrects. A secondary compensation prompt appears — smaller window, tighter angle. Repeat until stable or player switches to manual override.
6. **Manual override:** Always available. Exits the guided system; player handles the burn in raw 6DOF. Useful for experienced players or when the computer's recommendation is suboptimal.

**Implementation:** This is a `ManeuverMinigame` Control scene, same architecture as tool minigames — instantiated into HUD, emits `succeeded` / `failed` / `override_requested`. The minigame parameters (target angle, burn duration, tolerance window) are passed as a `Dictionary` when instantiated.

**Applies to:** Approach to debris field entry, docking with a station or relay platform, orbital insertion burns when transitioning zones.

---

## Flight Model

- **6DOF thrusters:** In `_physics_process`, read input axes (WASD for forward/back/strafe, QE for roll, mouse or controller for pitch/yaw). Apply `apply_central_force()` and `apply_torque()` to Ship RigidBody3D.
- **Flight assist (FA on):** When no input on an axis, apply counter-force proportional to velocity on that axis, clamped to a max assist force. Effectively damps translation and rotation toward zero.
- **Flight assist (FA off):** Raw Newtonian. Velocity persists until thrusted against.
- **Thruster fuel:** Optional in Phase 1; tracked as a float on the Ship node. EVA fuel is a separate `Resource` on Character.

## EVA Model

- **While aboard:** the suit is stowed — frozen, collision disabled, and *out of the scene tree*, held by `ship_controller.character`. It is not parented under the ship; see the RigidBody3D nesting constraint below.
- **On exit:** the suit is added to GameWorld at the ship's `ExitPoint` (positioned clear of the hull's collision shape, so there is no depenetration pop) as an independent RigidBody3D. Velocity is inherited as `ship.linear_velocity + ship.angular_velocity × r` — the ω × r term means leaving a rotating ship flings you tangentially, correctly.
- Same 6DOF thruster model, lower force values, fuel tracked in `EVAThrusterFuel` resource. Flight assist holds station against the local reference frame, as with the ship.
- **On return:** the suit must overlap the CargoBay Area3D. Boarding freezes it, disables collision, and stows it out of the tree again — in that order, so no contact frame is generated against the hull.
- Low fuel warning at 20%; auto-return prompt at 5%.

## Input Modes and Interaction

Controls stay simple by using **modes, not more keys**. Exactly one input mode is active at a time, held in `GameState.input_mode`; each controller (ship, EVA, interior, minigame) processes input only when its mode is active.

| Mode | Movement keys mean | Entered via |
|---|---|---|
| `SHIP_FLIGHT` | 6DOF thrust (WASDQE + mouse torque) | default; `interact` from EVA in CargoBay |
| `EVA` | same 6DOF, suit-scale thrust | `interact` at hatch while aboard |
| `INTERIOR` | WASD walk, magnetic boots (Phase 5) | `interact` to leave a seat/console |
| `FOCUSED` | movement suspended; active minigame/console owns input | `interact` at a console; minigame end or `interact` exits |

**Nav console (M).** Opens the destination list in `FOCUSED` mode: arrow keys select, Enter engages the autopilot, M or Esc closes. Travel is the one system that earns a console before the walkable interior exists, because there the player's decision is "where to" rather than "how".

**Universal interact key (F).** One context-sensitive action drives every transition and interaction: go EVA, board ship, use a console, talk to crew. The HUD `InteractionPrompt` label always states what F will do right now ("F — Board", "F — Grapple Console"); it is hidden when F has no target. Never bind a mode-specific action to F.

**Tool operation is station-based.** Ship-mounted tools are operated from consoles, not from the pilot seat: fly to the debris, park (flight assist holds station), `interact` at the tool's console, run the minigame. There is no tool hotbar or in-flight tool switching — one station per tool. In Phase 3 consoles are *seats* the player switches into directly (no walkable interior yet); Phase 5's walkable interior replaces the seat-switch with physically walking to the console. The EVA suit carries at most **one** handheld tool (Phase 2: grapple arm) with a single "use tool" key that opens its minigame — no selection UI on EVA.

**Crew and stations (Phase 5+, recorded for direction):** the player never switches control to another crewmember. Crew can be *asked* (over comms/dialogue) to man a station; whether and how well they do is relationship-driven. Crew remain characters, not vehicles.

## Tool System

### Tool Resource

```gdscript
class_name Tool extends Resource

enum MinigameType {
    ROTATION_MATCH,    # Grapple arm — align to debris spin
    TRAJECTORY_ARC,    # Net launcher — lead moving target
    SEQUENCE_CAPTURE,  # Tether — timing sequence
    VECTOR_ALIGN,      # Deorbit kit — burn vector
    CURSOR_HOLD,       # Laser nudge — dwell time
    PIPE_SEAL,         # Ship repair — seal a leaking pipe (pressure valve timing)
    SENSOR_CALIBRATE,  # Ship repair — recalibrate sensors (signal-match sweep)
    HULL_PATCH,        # Ship repair — patch hull breach (material alignment + bond hold)
}

@export var minigame_type: MinigameType
@export var range_meters: float
@export var minigame_params: Dictionary   # type-specific config
```

### Crew Dialogue Resource

```gdscript
class_name CrewDialogue extends Resource

enum DialogueTrigger {
    IDLE,                  # ambient lines, no trigger required
    CONTRACT_ACCEPTED,     # player just took a job
    CONTRACT_COMPLETED,    # returned from a successful job
    CONTRACT_FAILED,       # returned from a failed job
    KESSLER_EVENT_START,   # cascade event began
    KESSLER_EVENT_END,
    SHIP_REPAIR_NEEDED,    # a repair station is in a degraded state
    RELATIONSHIP_BEAT,     # authored subplot moment (manually triggered by GameState)
}

@export var crew_id: StringName         # matches CrewMember node name
@export var trigger: DialogueTrigger
@export var condition: Dictionary       # optional: e.g. { "min_relationship": 2 }
@export var lines: Array[String]        # TODO: replace with authored content
@export var next_dialogue: CrewDialogue # optional: chains to a follow-up
```

Dialogue resources live in `resources/crew/`. Each crewmember has a subdirectory. Placeholder arrays of empty strings are acceptable during development — authors fill them in.

---

### Tool Activation Flow

Ship-mounted tools (console/station-based — see "Input Modes and Interaction"):

1. Pilot parks within tool range of the target debris (flight assist holds station).
2. `interact` at the tool's console → input mode `FOCUSED`, console camera/view, HUD shows minigame overlay for `minigame_type`. Target acquisition (raycast or sphere overlap within `range_meters`) happens from the console.
3. On minigame success → tool effect applied (PhysicsJoint for grapple, impulse for nudge, etc.).
4. On minigame failure → tool goes on cooldown, debris may react (increased spin, etc.).
5. `interact` exits the console back to the previous mode at any time.

EVA handheld tool (single slot, no selection UI):

1. Player aims at debris within tool range.
2. "Use tool" key → minigame overlay; success/failure as above.

### Minigame Implementations

Each minigame is a standalone `Control` scene instantiated into the HUD's `ToolMinigame` slot. They emit `succeeded` and `failed` signals. Minigame logic is self-contained; it does not reference debris nodes directly — the tool node mediates.

## Scale and Precision

- **Compressed solar system:** Distances are not to scale. LEO is close, the outer system is far. Orbital periods are dramatized — hours, not years, so bodies visibly move within a session. Defined in `scripts/world/solar_system_data.gd`; the whole system fits inside a ~2,200 km sphere.
- **Two coordinate spaces.** Vector3 is float32, which has about a quarter-metre of precision two million metres out — fine for cruising, useless for EVA. So:
  - **true space** — system-absolute, Sun at origin, held as `[x, y, z]` arrays of 64-bit floats. Celestial bodies, the autopilot, and the nav console work here.
  - **render space** — what `Node3D` transforms hold, always kept within `OriginShift.SHIFT_THRESHOLD_METERS` of zero.
- **Floating origin:** `OriginShift` tracks the true-space position of the render origin in 64-bit and shifts every node in the `origin_shiftable` group when the tracked node drifts past the threshold. It emits `origin_shifted(offset)`. A shift is an instantaneous translation of the frame, not motion of it, so velocities are untouched and the frame stays inertial.
  - Nodes holding a real render-space position **join** `origin_shiftable` (ship, EVA suit).
  - Nodes that recompute their position from true space every frame **must not** join, or they get shifted twice (`SolarSystem`, `OrbitalAnchor`).

## Solar System

`SolarSystem` (`scripts/world/solar_system.gd`) generates every body from `SolarSystemData` — planets and moons differ only in numbers, so hand-placing them as scene nodes would be a worse copy of the same table. Each `CelestialBody` holds a `BodyDef` resource.

- **Positions are analytic, never integrated:** a body's position and velocity are closed-form functions of `SimClock.sim_time`. This is what lets the autopilot ask where a body *will be* at arrival, and what lets time compression skip ahead with no drift.
- **Far-field rendering:** a body past `CelestialBody.MAX_RENDER_DISTANCE` is drawn along its true direction at a clamped distance, scaled by the same ratio. `tan(θ) = r/d` is unchanged when r and d scale together, so apparent angular size is exact — only depth is a lie, and nothing the player can do reveals it.
- **One light for the system:** a single `DirectionalLight3D` owned by `SolarSystem`, re-aimed each frame from the Sun's true position toward the render origin. The terminator is then correct on every body from anywhere in the system.
- **Reference frames:** `reference_body()` returns the deepest body whose influence sphere contains a point; `reference_velocity()` returns that body's orbital velocity. Flight assist nulls velocity *relative to that frame*, so parking beside a moving moon actually parks. Influence never exceeds a fraction of a body's own orbit radius — otherwise the Moon's frame would swallow low Earth orbit.
- **Orbital anchors:** `OrbitalAnchor` pins authored content (a debris field) to a body's frame, recomputing from true space each frame. Debris in low Earth orbit must travel with Earth or it is kilometres behind within a minute.
- **Sky:** procedural starfield shader (`assets/shaders/starfield.gdshader`). Written rather than textured because the asset server has no orbital sky — see docs/assets.md.
- **Surfaces:** bodies are currently flat-shaded spheres. The progressive planet renderer (relief on every body, authored detail sites like NYC, city lights on the dark side) is designed in `docs/planet-renderer.md` — read that before touching `CelestialBody` visuals; it constrains how the proxy clamp and any future LOD interact.

## Travel and the Autopilot

Flight assist with a destination. The player opens the nav console, picks a body, and `Autopilot` (`scripts/autopilot.gd`) flies a brachistochrone transfer: accelerate toward the target, flip at the midpoint, decelerate into a standoff park matched to the body's orbital velocity.

- **Bounded trip time is a guarantee, not a hope.** `_plan_warp` picks a time-compression factor to land the trip on `target_real_seconds` (45 s default) and never exceed `max_real_seconds` (300 s). Trips already shorter than `min_warp_sim_seconds` run uncompressed, so a hop to a nearby moon is flown in real time.
- **The transfer is analytic, not physical.** The ship is frozen and its true-space position integrated in 64-bit, then written to render space each frame. A live physics burn under 20× compression would take 300-metre physics steps: every collision check would tunnel and integration error would compound.
- **Guidance is closed-loop.** Destinations move while you travel, so each step re-aims at where the body is *now* and brakes against the distance left (`sqrt(2*a*d)` is the speed whose full-braking distance is exactly `d`). Arrival falls out of tracking that; no rendezvous polynomial is solved. The engage-time plan only picks the warp factor and the ETA.
- **The flip is emergent.** The hull is pointed along the thrust vector, and the thrust vector reverses at the midpoint.
- **The cruise drive is not the manual main engine.** 20 m/s² would make precision debris work unflyable by hand, so the computer gets a high-impulse drive it alone throttles and the pilot keeps the 4 m/s² main.
- **Any stick input cancels it.** Discoverable, and it means a player never hunts for a disengage key.

## Stations and Docking (built — Track SD1/SD2 complete)

Dockable orbital stations, and eventually other ships. Design constraints and
decisions (all now implemented; first station is "Meridian Relay",
`scenes/stations/meridian_relay.tscn`, Earth orbit at 9 km):

**Stations ride the same analytic rails as moons.** An `OrbitalStation` is a
scene (POLYGON station modules — see docs/assets.md §4.5) attached to a
`StationDef` carrying the same orbital elements as `BodyDef` (parent body,
orbit radius/period/phase/inclination). Position and velocity are closed-form
functions of `SimClock.sim_time`, so stations work under time compression and
the autopilot can intercept them exactly like a moon. The orbit math moves from
`CelestialBody` into a shared helper both classes call.

**Autopilot destinations become an interface.** `Autopilot` and `NavConsole`
currently take `CelestialBody`. Both generalize to any object exposing
`position_at(t)`, `velocity_at(t)`, `arrival_standoff()`, and a display name —
which is exactly the set the transfer math already uses. Stations then appear in
the nav console with live ETAs for free, standoff ~200 m.

**Reference frames include stations.** A station gets a small influence radius
(~2 km); `reference_body()` resolves it as deeper than its parent planet, so
flight assist holds station relative to the station while you approach — the
docking prerequisite, and it falls out of the existing deepest-wins rule.

**Docking is a state, not a joint.** Soft-capture conditions: within the dock
volume of a `DockingPort` (Area3D on the station, axis marker for alignment),
relative velocity under ~1.5 m/s, approach axis within ~20° of the port axis.
On capture the ship is frozen kinematic and parented to the port (ships are
RigidBody3D but the *station* is on rails, not a physics body — so this is
node-under-Node3D parenting, and the never-nest-RigidBody rule below is not
violated; if ship-to-ship docking lands later, the docked ship freezes and the
host stays live, same pattern as the stowed EVA suit). Undock reverses it with
a small push-off impulse. Docked is an input-mode-adjacent state: flight
controls stand down, `interact` context becomes the station (contract board,
repairs — Phase 4/5 content hangs here).

*Implementation caveat learned the hard way:* freezing is **not** enough for a
docked ship under a rail-driven parent. The physics server writes a frozen
kinematic body's global transform back to the node every physics step, one
frame behind the moving parent, so the ship's local offset under the port
drifts without bound. On capture the ship's body is therefore removed from the
physics space entirely (`PhysicsServer3D.body_set_space(rid, RID())`, after
the reparent) — the tree alone owns the transform, exactly like the stowed
suit leaves the tree. Re-entering the world on undock re-adds the body to the
space. The ship's CargoBay Area3D is a separate physics object and keeps
working for EVA boarding while docked. `DockingComputer` (node on the Ship,
like Autopilot) owns the whole sequence and also keeps the frozen hull's
`linear_velocity` tracking the station so EVA exit inherits the right frame.

**Manual first, assisted second.** Docking is flown by hand with flight assist
in station frame — that is the skill loop, and the tone. The guided-burn
`ManeuverMinigame` (see "Flight Assist Maneuver System" above) can be layered on
later as the "computer-assisted approach" option; it is not a prerequisite.

**Other ships** (NPC vessels as dock targets) are explicitly stretch: same
`DockingPort` component, but they need the ship-to-ship freeze pattern plus NPC
traffic to exist at all. Design accommodates; nothing is built for it yet.

### Constraint: never nest a RigidBody3D under another RigidBody3D

Godot does not support it. Both bodies live independently in the physics space, so the server keeps writing the child's global transform while the node tree re-derives its local transform from the moving parent. The two fight, the child's local position diverges without bound, and it drags the parent's reported transform with it.

This is why the EVA suit is **removed from the scene tree** while the player is aboard (held by `ship_controller.character`) rather than parented under the ship as an earlier draft of this document prescribed. `freeze` is not sufficient — a frozen body is still in the space. Group membership follows the tree, so a stowed suit is correctly skipped by floating-origin shifts.

Related: the physics server owns a live `RigidBody3D`'s transform and reverts writes from script. Setting the ship's transform or basis only works while it is frozen, which is why the autopilot freezes before steering.

## Landing (Track LD — BUILT; gates in tests/anchor_test.gd and tests/landing_test.gd)

Two tiers, because the physics regimes are genuinely different: at debris and
asteroid masses gravity is negligible and "landing" is contact-and-latch; at
planet scale it is a gravity well and a spinning surface. Everything below
reuses a pattern this project has already paid for.

### Tier 1 — rocks: contact + anchor

**Asteroids/heavy debris are a new class, `SpaceRock`:** RigidBody3D at prop
scale (2–50 m, 0.5–20 t), procedural rock mesh with convex collision, tumbling.
The first free-physics bodies in the world besides the ship and the suit.

**Sleep on rails, wake to physics.** A dynamic body cannot ride an
`OrbitalAnchor` (the write-back fight), but a rock left dynamic in LEO drifts
off its field as Earth's frame velocity rotates. So rocks sleep as
kinematic-follow props under their field anchor, and wake into free physics —
with the anchor frame's velocity handed off, the EVA-exit pattern — when the
player closes within a wake radius (~500 m). Fields manage respawn/cull;
a woken rock far from any player interest goes back to sleep by re-anchoring.

**Anchoring is a joint, not a reparent.** Latching (ship magnetic clamps, suit
boot clamps) creates a locked `Generic6DOFJoint3D` between the two bodies.
Both stay independent bodies in the physics space, so the never-nest rule is
not violated, and a jointed suit rides a tumbling rock's rotation for free.
Latch conditions mirror soft-capture: contact plus relative velocity under
~0.5 m/s. Unlatch on input; the joint also breaks past a force limit, so
towing a rock heavier than your clamps is a gameplay fact, not a clip.
Because the ship (12 t) and rocks (0.5–20 t) couple through the joint,
thrusting while latched tows the pair — which is exactly the M3 deorbit
loop: latch debris, drag it to disposal, release.

**EVA on a rock:** clamped suit = jointed suit; controls stay MMU (torque
only while clamped — translation thrust above the break limit is how you
push off). Walking is a non-goal at every tier.

### Tier 2 — planets: a gravity shell and a landed state

**Gravity is a surface shell, NOT a global field.** The system's rails are
dramatized: Meridian Relay's rail speed at 9 km bears no relation to circular
orbital speed for any honest g(r), so a global field would make every parked
ship, station approach, and debris field fall out of the sky. Instead each
solid body gets a shell from its surface up to `1.5 R`: inverse-square inside,
smoothly faded to zero across the top of the shell. Autopilot arrival
standoffs sit outside every shell, so transfers, parks, stations, fields, and
all existing suites are untouched by construction. `SolarSystem.gravity_at
(true_pos)` is the single query; the ship and suit apply it as a force in
`_physics_process`, and the autopilot's 64-bit integrator adds the same term
(closed-loop guidance then handles it, but it never matters if standoffs stay
outside). The autopilot refuses to engage from inside a shell — take off
first, manually.

**Surface gravity is dramatized ×0.25, like every other number here.** Real
g₀ against the 4 m/s² main engine gives Earth a thrust-to-weight of 0.4 —
unlandable. At ×0.25 (Earth 2.45, Mars 0.93, Moon 0.40 m/s²) the ship lands
on Earth at TWR 1.6 (lunar-module feel) and the suit (2.0 m/s² of thrust)
still cannot hover on Earth but flies freely on the Moon — EVA capability
becomes a per-body fact. Gas giants get no shell and no landing; the nav
console says why.

**Belly landing jets.** The vertical RCS (15 kN) is weaker than the hull's
weight on Earth (29 kN), so inside a gravity shell the ship's vertical axis
gets the main-engine budget — that is where TWR 1.6 comes from, and it lights
only where there is a surface to land on, leaving deep-space RCS feel alone.
Flight assist adds a gravity feed-forward term inside shells (holding station
means thrusting against the pull, not reacting to the sag), and the per-axis
clamp keeps it honest: attitude matters, and a craft whose thrust cannot beat
local gravity still falls.

**Skim-collider swap guard.** A LOD change swaps in a different triangulation
of the same relief; a trimesh materializing inside a hull a few metres off
the deck gets that hull solver-ejected at tens of m/s (measured 68 m/s).
While a hull is within the relief band of the ground, the collider set in
its footprint is frozen — no adds, no frees — and far patches keep swapping
freely. Landing also disarms its own capture on lift-off until the ground
has been clear for a beat, and pushes off at 2.5 m/s (both the docking
computer's patterns), because a live hull left resting on per-frame-
teleporting colliders is eventually thrown.

**Landed is a state, not a contact.** Touchdown capture mirrors docking
soft-capture: contact with the skim colliders, surface-relative speed under
~2 m/s, ship's up within ~25° of local up — otherwise you bounce. On capture
the ship freezes, leaves the physics space (`body_set_space(RID())`), leaves
`origin_shiftable`, and records its pose in surface-local coordinates; each
frame it is placed by the same transform chain that carries detail sites
(`site_transform` precedent), so a landed ship co-rotates with the spinning
surface and survives origin shifts by construction. Takeoff reverses it with
the surface point's velocity (body frame + spin ω×r) handed off — the
EVA-exit pattern a third time.

**Scale honesty bounds the ground game.** Earth's radius is 2,000 m and the
albedo is 6 m/texel; landing v1 is: descend through the atmosphere (aerial
perspective and reddened light already exist), touch down, look around, take
off. The two detail sites are the only "places". No walking, no ground
content — that is a later, owner-approved scope, not an implication of this
track.

## No ECS

At Cascade's scale, Godot's node tree is sufficient. Do not introduce an ECS framework. Keep systems as Autoloads or manager nodes with clear responsibilities. Prefer composition (nodes-as-components) over inheritance chains.

## Autoloads

| Name | Responsibility |
|---|---|
| `SimClock` | Simulation time and time compression (warp). Everything on rails derives position from `sim_time` |
| `GameState` | Current phase, active contract, session stats |
| `ContractManager` | Contract pool, acceptance, completion callbacks |
| `OriginShift` | Floating-origin tracking and shift events |
| `AudioManager` | Ambient audio, positional SFX helpers |
