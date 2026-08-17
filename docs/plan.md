# Cascade — Development Plan

## Phase 1: Core Flight Loop

**Goal:** A ship you actually want to fly.

- 6DOF Newtonian flight model using RigidBody3D with thruster forces (WASDQE)
- Zero-gravity environment; no ambient gravity on player or ship
- Flight assist toggle — when on, applies counter-thrust to damp velocity toward zero
- Basic HUD: velocity vector, orientation indicator, fuel remaining
- Placeholder environment: Earth sphere in background, a handful of static debris meshes
- Camera: third-person follow with optional cockpit mode

**Done when:** Flying around the scene feels good. Flight assist off is challenging but controllable. Flight assist on lets you hover and translate precisely.

---

## Phase 2: EVA + First Tool

**Goal:** Leave the ship, grab something, bring it back.

- Exit/enter ship action; character becomes independent RigidBody3D on EVA
- EVA thruster model (same 6DOF, lower thrust, fuel Resource tracked on character)
- Fuel depletion and low-fuel warning; return-to-ship prompt
- First tool: **Grapple Arm** — RotationMatch minigame (align targeting reticle to debris spin axis, hold to lock)
- Successfully grappled debris follows character/ship on a tether physics joint
- Debris can be stowed in ship cargo hold (simple trigger volume)
- Basic contract: capture one marked debris piece

**Done when:** Player can undock, EVA to debris, grapple it, drag it back, stow it, and complete a contract.

---

## Phase 3: Full Tool Set + Debris Fields

**Goal:** A complete cleanup toolkit and real debris environments.

- **Net Launcher** — TrajectoryArc minigame: lead a moving target, arc adjusts with debris velocity
- **Tether** — SequenceCapture minigame: match a timing sequence to spool the tether before debris tumbles free
- **Deorbit Kit** — VectorAlign minigame: align a burn vector indicator to the deorbit window, confirm burn
- **Laser Nudge** — CursorHold minigame: hold crosshair on debris surface for required dwell time
- Procedural debris fields: varying density, spin rates, sizes, materials
- Contract system v1: objective types (capture N pieces, deorbit field, retrieve specific item), timer, payout
- Tool consoles: ship-mounted tools operated from seat-based stations (`interact` to enter/exit; no walkable interior yet — see architecture.md "Input Modes and Interaction"); no tool hotbar or in-flight switching. Tool resource definitions in `resources/tools/`

**Done when:** All five tools work, feel distinct, and at least two contract types are completable.

---

## Phase 4: Economy + Solar System Scope

**Goal:** A full session loop with stakes and progression.

- Contract board: multiple contracts available, accept/decline, reputation per zone
- Dynamic Kessler cascade events: chain-reaction debris burst in a zone, emergency contracts, difficulty spike
- Multiple orbital zones: LEO (dense, fast, chaotic), MEO (sparser, slower), GEO (vast, lonely, high-value)
- Ship upgrades: thruster efficiency, cargo capacity, EVA fuel tank, tool slots
- Economy: credits, upgrade shop, operational costs (fuel, repairs)
- Floating-origin precision handling for MEO/GEO distances
- Ambient audio and environmental storytelling (radio chatter, debris backstory on scan)

**Done when:** A 30-minute session has a clear arc — take contracts, work a zone, survive a Kessler event, upgrade, repeat.

---

## Phase 5: Ship Interior + Crew System

**Goal:** The ship feels like a home. The crew feels like people.

- Walkable ship interior scene ("Toy Box") in low gravity / magnetic boots
- 2–3 crew NPCs with distinct personalities, idle dialogue, and reactions to contract outcomes
- Crew interaction system: dialogue trees, relationship tracking, per-crew subplot hooks (placeholders for authored content)
- Interactive objects: contract board terminal, tool maintenance bench, ship repair stations
- Ship repair minigames: fix a leaking pipe, recalibrate sensors, patch hull breaches — same minigame framework as tools
- Flight assist maneuver system: guided HUD overlay for approach, docking, and orbital insertion burns — "burn X seconds at Y angle," player executes timing and angle, with overcorrect/compensate consequences on miss
- Crew comments on accepted contracts, react to completed or failed jobs

**Done when:** The interval between two contracts feels populated — player has a reason to walk around, talk to crew, and maintain the ship before undocking.

---

## Phase 6: Cascade Endgame Arc

**Goal:** Everything the player has learned is required. The stakes are finally real.

Story structure builds on Acts 1–2 established in narrative.md:

- **Act 1 (Phases 1–3):** Routine contracts, small debris, building skill. Crew settles in. The work feels sustainable.
- **Act 2 (Phases 4–5):** Debris fields grow denser, Kessler events increase in frequency and severity. Crew tensions surface. Contracts get harder and stranger. Something is accelerating.
- **Climax (Phase 6):** A major collision triggers a full Kessler cascade threatening to make orbital lanes permanently unusable. Player must apply every tool, every skill, and every crew relationship to stop it from becoming self-sustaining.

Implementation:
- Scripted cascade trigger event (not purely procedural) tied to a contract chain
- Escalating multi-zone emergency: debris spreading across LEO→MEO, time pressure, stacking objectives
- Crew moments at the climax — each crewmember contributes based on their subplot resolution
- Multiple endings based on cascade containment success and crew state
- Cool-down epilogue: player can finish remaining contracts in a recovered orbital environment

**Done when:** Playtesting confirms the climax feels earned, not arbitrary — that skills and crew relationships matter to the outcome.
