# AGENTS.md — Cascade

## What This Project Is

Cascade is a peaceful space debris cleanup simulation built in Godot 4. The player pilots a ship and performs EVA operations to capture and deorbit debris in near-future Earth orbit. There is no combat. There will never be combat.

## Workspace Layout

```
cascade/
  docs/           # Source of truth for design and architecture
    architecture.md
    narrative.md
    plan.md
    tasks.md
    assets.md     # Asset server, fetch pipeline, curated Synty manifest
  scenes/         # Godot scene files (.tscn)
  scripts/        # GDScript source (.gd)
  resources/      # Godot Resource files (.tres, .res)
  assets/         # Art, audio, shaders
    meshes/       # gitignored — fetched from the asset server
  tools/          # fetch/patch helpers (resolve_assets.py, patch_gltf_materials.py)
  fetch_assets.sh # sync cooked Synty meshes from the asset server
```

## Asset Pipeline

3D art comes from Synty packs on the asset server
(`http://srv.blastedstudios.com:49200`), which is the source of truth;
`assets/meshes/` is gitignored.

```bash
./fetch_assets.sh                     # used-only: fetch what the project references
./fetch_assets.sh --pack scifi_space  # whole-pack: browse before authoring
godot --headless --import
```

Read `docs/assets.md` before touching art. It has the curated manifest (player
ship candidates, debris props, EVA suit, planets, stations, thruster FX) with
exact server paths and measured metre dimensions, plus the Synty cook caveats
that will otherwise waste your afternoon: never use the `.glb` cooks (they are
untextured), the stray `0.01` root scale on skeletal and `SIMPLE_*` meshes, and
the wrong-texture-atlas bug in `POLYGON_Scifi_Space`.

## Key Conventions

- **GDScript** for all gameplay logic. Clear, readable, signal-driven.
- **GDExtension** only if a physics-critical path proves too slow in GDScript — document the reason.
- `docs/architecture.md` is the source of truth for scene structure, physics approach, and system design. Check it before adding or restructuring systems.
- Signals over direct references between systems. Keep scenes self-contained where possible.
- Tools are `Resource` subclasses — they define minigame type and parameters, not logic. Logic lives in the minigame scene.

## Tone and Reference

**Primary reference: Planetes** (manga by Makoto Yukimura, 1999–2004; anime 2003, Sunrise). Near-future debris collectors, hard sci-fi, unglamorous work, grounded crew drama. Read `docs/narrative.md` for a full summary of why this is the reference and what to take from it.

Do not make the game feel epic or heroic. The work is meaningful because it is necessary and done well, not because the stakes are dramatic. The crew are people, not archetypes.

## Picking Up Development

These docs are sufficient to resume development from any point:

- `docs/plan.md` — phased development roadmap, current phase scope
- `docs/architecture.md` — scene structure, physics, all system designs; authoritative source of truth
- `docs/narrative.md` — tone, setting, crew concept, full story arc
- `docs/tasks.md` — current task list

An agent starting fresh should: read `architecture.md` first, then `tasks.md` — its ordering directive names the active track (currently Track SD, then Track PR; design docs: architecture.md "Stations and Docking" and `docs/planet-renderer.md`), and its "Standing traps" list is mandatory reading before writing code. `plan.md` gives the long-arc phases. Do not invent systems not described in architecture.md — propose additions here first.

## Travel and Scale (read before touching movement or world code)

- There are two coordinate spaces: **true space** (system-absolute, 64-bit `[x,y,z]` arrays) and **render space** (`Node3D` transforms, kept near zero by `OriginShift`). Know which one you are in. `architecture.md` → "Scale and Precision".
- Celestial bodies are **analytic**: position and velocity are functions of `SimClock.sim_time`, never integrated. Do not add frame-accumulated motion to anything on rails — it breaks time compression.
- **Never nest a `RigidBody3D` under another `RigidBody3D`.** Godot does not support it and both transforms corrupt. The EVA suit is stowed out of the tree while aboard.
- The physics server owns a live `RigidBody3D`'s transform and reverts script writes. Steer only while frozen.
- Run `godot --headless res://tests/travel_test.tscn` after changing flight, the solar system, the autopilot, or the floating origin. It verifies spawn state, orbits, and a transfer to every destination inside the five-minute promise.

## Coding Agent Guidance

1. Read `docs/architecture.md` before adding any new system.
2. Read `docs/plan.md` to understand the current phase scope.
3. Do not add combat systems, weapons, damage models, or faction conflict. This is a peaceful game.
4. Debris is not an enemy. Tools are not weapons.
5. When in doubt about scope, check `docs/tasks.md` for the current task list.
6. Crew dialogue uses `CrewDialogue` Resource — leave `lines` arrays as placeholders; do not invent authored dialogue content.
