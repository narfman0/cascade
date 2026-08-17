# Cascade

**A meditative space debris cleanup sim.**

Codename: Cascade
Engine: Godot 4
Status: Early prototype

You pilot a small independent cleanup vessel in near-future Earth orbit. The work is slow, precise, and quietly satisfying. Kessler cascade events keep the contracts coming.

## Docs

- [docs/plan.md](docs/plan.md) — Development phases
- [docs/architecture.md](docs/architecture.md) — Godot 4 scene and physics design
- [docs/narrative.md](docs/narrative.md) — Tone, setting, world
- [docs/tasks.md](docs/tasks.md) — Task board (populated by agents)

## Core Mechanics

- **6DOF ship flight** — Newtonian physics, WASDQE thruster controls, optional flight assist
- **EVA movement** — Exit the ship in a pressure suit; limited thruster fuel
- **Tool minigames** — Grapple arm, net launcher, tether, deorbit kit, laser nudge
- **Contracts** — Cleanup objectives in procedural debris fields; dynamic Kessler events
