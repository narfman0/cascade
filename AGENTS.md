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
  scenes/         # Godot scene files (.tscn)
  scripts/        # GDScript source (.gd)
  resources/      # Godot Resource files (.tres, .res)
  assets/         # Art, audio, shaders
```

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

An agent starting fresh should: read `architecture.md` first, then `plan.md` to find the active phase, then `tasks.md` for the current task. Do not invent systems not described in architecture.md — propose additions here first.

## Coding Agent Guidance

1. Read `docs/architecture.md` before adding any new system.
2. Read `docs/plan.md` to understand the current phase scope.
3. Do not add combat systems, weapons, damage models, or faction conflict. This is a peaceful game.
4. Debris is not an enemy. Tools are not weapons.
5. When in doubt about scope, check `docs/tasks.md` for the current task list.
6. Crew dialogue uses `CrewDialogue` Resource — leave `lines` arrays as placeholders; do not invent authored dialogue content.
