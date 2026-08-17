# Cascade — Architecture

## Scene Structure

```
GameWorld (Node3D)
├── Environment (Node3D)
│   ├── EarthBody (StaticBody3D + MeshInstance3D)
│   ├── GravityWell (Area3D)          # planetary gravity for background objects
│   └── SkyboxEnvironment (WorldEnvironment)
├── Ship (RigidBody3D)
│   ├── Mesh (MeshInstance3D)
│   ├── Thrusters (Node3D)            # thruster force application points
│   ├── CargoBay (Area3D)             # stow trigger volume
│   ├── Camera (Camera3D)
│   └── Character (RigidBody3D)       # parented here when aboard; freed on EVA
│       ├── Mesh (MeshInstance3D)
│       ├── EVAThrusterFuel (Resource)
│       └── ToolSlot (Node3D)         # active tool attach point
├── DebrisField (Node3D)
│   ├── Debris_001 (RigidBody3D)
│   ├── Debris_002 (RigidBody3D)
│   └── ...
└── HUD (CanvasLayer)
    ├── VelocityIndicator
    ├── FuelGauge
    ├── ToolMinigame (Control)        # shown during tool use
    └── ContractTracker
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

- On exit action: Character node is removed from Ship's scene tree and added to GameWorld as an independent RigidBody3D. Initial velocity is inherited from Ship.
- Same 6DOF thruster model, lower force values, fuel tracked in `EVAThrusterFuel` resource.
- On return: Character must be within CargoBay Area3D. Enter ship action re-parents Character to Ship.
- Low fuel warning at 20%; auto-return prompt at 5%.

## Input Modes and Interaction

Controls stay simple by using **modes, not more keys**. Exactly one input mode is active at a time, held in `GameState.input_mode`; each controller (ship, EVA, interior, minigame) processes input only when its mode is active.

| Mode | Movement keys mean | Entered via |
|---|---|---|
| `SHIP_FLIGHT` | 6DOF thrust (WASDQE + mouse torque) | default; `interact` from EVA in CargoBay |
| `EVA` | same 6DOF, suit-scale thrust | `interact` at hatch while aboard |
| `INTERIOR` | WASD walk, magnetic boots (Phase 5) | `interact` to leave a seat/console |
| `FOCUSED` | movement suspended; active minigame/console owns input | `interact` at a console; minigame end or `interact` exits |

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

- **Compressed solar system:** Distances are not to scale. LEO is close, MEO is middling, GEO is far. Orbital periods are dramatized. This is acceptable for gameplay.
- **Floating origin:** When the Ship exceeds a threshold distance from the world origin (e.g., 10,000 units), shift all node positions back toward origin and offset the origin tracker. Prevents floating-point precision loss at distance. Implement as a singleton `OriginShift` that emits `origin_shifted(offset: Vector3)`.

## No ECS

At Cascade's scale, Godot's node tree is sufficient. Do not introduce an ECS framework. Keep systems as Autoloads or manager nodes with clear responsibilities. Prefer composition (nodes-as-components) over inheritance chains.

## Autoloads

| Name | Responsibility |
|---|---|
| `GameState` | Current phase, active contract, session stats |
| `ContractManager` | Contract pool, acceptance, completion callbacks |
| `OriginShift` | Floating-origin tracking and shift events |
| `AudioManager` | Ambient audio, positional SFX helpers |
