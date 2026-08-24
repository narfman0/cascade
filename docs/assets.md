# Cascade — Art Assets

Cascade's 3D art comes from Synty POLYGON / SIMPLE packs served pre-cooked by a
local asset server. **The server is the source of truth.** Nothing under
`assets/meshes/` is committed (see `.gitignore`); you re-fetch it.

- Server: `http://srv.blastedstudios.com:49200`
- Index: `GET /index.json` — a 62 MB JSON listing 151 packs. Parse it with
  `python3`, never `cat` it. Shape:
  `{"cooked": {"packs": [{"name": ..., "files": [{"path", "size", "mtime"}]}]}}`.
  Every `path` starts with `assets/`, and `assets/<rest>` on the server maps to
  `assets/meshes/<rest>` locally.
- Override the host with `ASSET_SERVER=... ./fetch_assets.sh`.

---

## 1. Running the pipeline

```bash
./fetch_assets.sh                       # used-only: fetch what the project references
./fetch_assets.sh --pack scifi_space    # whole-pack: browse before authoring
./fetch_assets.sh --pack                # whole-pack for every DEFAULT_PACKS entry
./fetch_assets.sh --no-import           # ...and skip the import step
```

Every mode ends by running `godot --headless --import` to bake the `.import`
sidecars, because an unimported `.gltf` fails silently: the mesh renders as
nothing, with no error. `--no-import` skips it (useful when chaining several
fetches). The binary is looked up as `GODOT`, then `godot`, `godot4`, `godot-4`;
if none is found the fetch still succeeds and prints the command to run.

### Used-only mode (the default)

`tools/resolve_assets.py` scans `scenes/`, `scripts/` and `resources/` for
references into `assets/meshes/`, downloads each referenced glTF, then follows
its `buffers` (`.bin`) and `images` (`.png`) URIs until the closure is
satisfied. Two reference styles are recognised:

1. **Literal path**, anywhere in any file under those three dirs:
   `"res://assets/meshes/<pack>/.../SM_Foo.gltf"`. This covers `.tscn`
   `ExtResource` lines, `preload()`/`load()` in `.gd`, and `.tres` properties.
   Spaces in the path are fine (some cooked dirs are literally
   `Source Files/FBX`); the surrounding quote bounds the match.
2. **Directory const + bare basenames** in a single `.gd`: a string
   `"res://assets/meshes/<pack>/.../"` assigned anywhere in the file, plus
   quoted `"SM_Foo.gltf"` basenames elsewhere in the same file. Good for a
   debris-prop table.

Caveats, both worth knowing before you debug a phantom `MISS`:

- Style 2 takes the **cross product** of every directory string × every
  basename in that file. A `.gd` holding two directory consts and twenty
  basenames asks the server for forty paths and reports `MISS` for the twenty
  that do not exist. Keep one directory const per file, or use full literal
  paths.
- With nothing referenced yet, used-only mode correctly prints
  `Reference closure: 0/0 files present, 0.0 MB.` and does nothing. That is not
  a failure — use `--pack` until real references exist.

The script runs the resolver, then `tools/patch_gltf_materials.py`, then the
resolver **again**: the patcher's atlas remap (§3) can introduce a reference to
a texture that was not in the first closure.

### `--pack` mode

Substring-matches pack names in `index.json` (case-insensitive) and pulls every
`.gltf` / `.bin` / `.png` in the matching packs. `--all` is a synonym. Whole
packs are big — `POLYGON_Scifi_Space` alone is 2056 files — so use it to browse
a pack, not as the normal path. It skips `.glb` and `Characters/Unreal_Characters/`
for the reasons in §3.

`DEFAULT_PACKS` in `fetch_assets.sh` is the Cascade space set:
`POLYGON_Scifi_Space`, `POLYGON_SciFiWorlds`, `SIMPLE_Space_Source_Files`,
`SIMPLE_Space_Interiors`, `SIMPLE_Space_Characters`, `POLYGON_Particle_FX`.
`_skies` and `SIMPLE_Sky` are deliberately absent — see §4.4.

---

## 2. Pack paths (exact, they are inconsistent)

The cooked directory names differ in capitalisation between packs. Copy them,
don't retype them.

| Short name used below | Server prefix |
|---|---|
| `SPACE` | `assets/POLYGON_Scifi_Space_SourceFiles_v2/SourceFiles/FBX/` |
| `SPACE_FX` | `assets/POLYGON_Scifi_Space_SourceFiles_v2/SourceFiles/FBX/FX_Meshes/` |
| `SPACE_CHR` | `assets/POLYGON_Scifi_Space_SourceFiles_v2/SourceFiles/Characters/` |
| `SPACE_TEX` | `assets/POLYGON_Scifi_Space_SourceFiles_v2/SourceFiles/Textures/` |
| `WORLDS` | `assets/POLYGON_SciFiWorlds_SourceFiles_v4/Sourcefiles/FBX/` (lower-case `f`) |
| `WORLDS_TEX` | `assets/POLYGON_SciFiWorlds_SourceFiles_v4/Sourcefiles/Textures/` |
| `SIMPLE` | `assets/SIMPLE_Space_Source_Files/SourceFiles/Fbx/` (`Fbx`, not `FBX`) |
| `SIMPLE_INT` | `assets/SIMPLE_Space_Interiors_SourceFiles/SourceFiles/Fbx/` |
| `SIMPLE_CHR` | `assets/SIMPLE_Space_Characters_SourceFiles/SourceFiles/FBX/` |
| `PFX` | `assets/POLYGON_Particle_FX_SourceFiles_v2/Source Files/FBX/` (spaces!) |
| `SKIES` | `assets/_skies/` |
| `CITY` | `assets/POLYGON_SciFi_City_SourceFiles_v5/Source_Files/FBX/` (`Source_Files`, with an underscore) |

Packs surveyed and **rejected**: `POLYGON_SciFi_Outpost_Map_SourceFiles_v1` (a
terrestrial map kit — grass clumps, fences, floodlights). The only things in it
Cascade could want — `SM_Prop_SatDish_01..03`, `SM_Prop_Vent_01..04` — exist in
better form in the packs above.

`POLYGON_SciFi_City_SourceFiles_v5` was rejected at the same survey ("cyberpunk
street furniture") and **re-admitted at PR3** for exactly one thing: its
`SM_Bld_Background_*` skyline filler, which is the right shape for the New York
detail site (§4.7). Nothing else in the pack is used. `POLYGON_City_SourceFiles_v5`
joined `DEFAULT_PACKS` alongside it as the near-ground variety set and is so far
unused.

---

## 3. Synty cook caveats (read this before debugging a broken import)

Everything here is handled automatically by `tools/patch_gltf_materials.py`,
which `fetch_assets.sh` runs for you. It is idempotent and deletes the stale
`.gltf.import` sidecar for anything it edits.

### Never use the `.glb` cooks

Many packs ship both `SM_Foo.glb` and `SM_Foo.gltf` + `SM_Foo.bin`. **The `.glb`
cooks have their `images` and `textures` arrays stripped** — the material
survives, the texture reference does not, and the prop imports flat grey.
Verified on `SM_Veh_Part_Body_03.glb`: 0 images, 0 textures, material
`SciFi11` with no `baseColorTexture`. Use the `.gltf` + `.bin` + shared
`Textures/*.png` triple. `fetch_assets.sh` refuses to download `.glb` at all.

### Unit scale: every cook carries a `scale: [0.01, 0.01, 0.01]` root

Plus a +90° X rotation (Synty authors Z-up; glTF is Y-up), so **world extents
are `(rawX, rawZ, rawY) × root scale`**. Whether the 0.01 is correct depends on
the cook generation:

**Skinned cooks are the exception to the exception (2026-08-23):** a cook
with `skins` (the rigged characters) must KEEP its 0.01 root even though its
mesh vertices are metres — the skeleton joints and inverse bind matrices are
centimetres, glTF skinning runs in the skeleton's space, and the root scale is
what brings the skinned result back to metres. Stripping it explodes the limbs
~100x in render while every rest-space AABB still reads 1.73 m (a skinned
mesh's `get_aabb()` cannot see skinning — do not trust it). The patcher now
refuses to touch any glTF with `skins`.

| Family | Vertices | The 0.01 is | Result if left alone |
|---|---|---|---|
| `POLYGON_*` static `SM_*` | centimetres | correct | fine |
| any skeletal `SK_*` cook, any pack | metres | a bug | 1/100 size |
| everything in `SIMPLE_*` packs | metres | a bug | 1/100 size |

The patcher decides per pack (`PACK_UNITS`) and per prefix (`SK_`), with a
max-coordinate threshold of 20 raw units as a fallback for unlisted packs.
**Do not port godot-rts's single global threshold of 50** — it gets
`SM_Veh_Sweepo_01` (45 raw units, genuinely centimetres → would become a 45 m
floor-sweeping robot) and `SM_Veh_SpaceStation_01` (89.8 raw units, genuinely
metres → would stay a 0.9 m station) wrong in opposite directions.

Verified pair for the `SK_` rule: `SM_Veh_Barge_01` has a raw extent of 1822
units (centimetres) while its skeletal twin `SK_Veh_Barge_01` maxes at 10.08
(metres).

### Texture assignment comes from the pack's MaterialList, not the cook

**Every Synty pack ships `MaterialList_<Pack>.txt` at its source root.** It is
the mesh → material → texture mapping exported from the Unity project the UVs
were authored in — the authoritative answer to "which atlas does this mesh use":

```
Prefab Name: SM_Veh_Part_Body_03
    Mesh Name: SM_Veh_Part_Body_03
        Slot: PolygonScifiSpace_Material_01_A (PolygonSciFiSpace_Texture_01_A)
```

It exists only in the server's **raw** tree (the cooker converts meshes and
copies textures but does not carry documentation across), so
`tools/fetch_material_lists.py` pulls it from `/raw/<pack>/<SourceFiles>/`.
`fetch_assets.sh` runs it automatically before the patcher.

**Why this matters: the cooks are unreliable and inconsistent.** Sampled fresh
from the server with no patching:

| Mesh | Cook references | MaterialList says |
|---|---|---|
| `SM_Veh_Part_Engine_01` | `Signs_Texture_01_A.png` | `Texture_01_A` |
| `SM_Bld_Wall_01` | `Texture_03_A.png` | `Texture_01_A` |
| `SM_Prop_Crate_01` | `Texture_01_A.png` | `Texture_01_A` (correct) |
| `SM_SignBorder_Nuclear_01` | `Signs_Texture_01_B.png` | `Signs_Texture_01_B` (correct) |

`Signs_Texture_01_A` is a 1024² signage sheet — black field, white door
pictograms — so hull geometry pointed at it imports near-black with stray glyphs.
Roughly 80% of the pack's meshes were affected in the original survey's sample.

**An earlier version of the patcher remapped that atlas unconditionally for the
pack, and that was wrong.** The MaterialList shows 47 meshes (`SM_Sign_*`,
`SM_SignBorder_*`) genuinely do use a signage sheet — and the one they use is
`Signs_Texture_01_B`, so the cooks have the wrong *variant* even where they have
the right family (the pack ships `_01_A` through `_01_F`). A blanket rule
destroys those props. Driving assignment from the list is right by construction
and needs no per-pack policy: 828 space meshes across 5 distinct textures, 1978
`SciFiWorlds` meshes across 37, all resolved from data.

Two gotchas the implementation handles, worth knowing if you touch it:

- **Mesh names in the cooks are Blender's**, not the asset's — `Mesh`,
  `Mesh.001`. The original name survives only on the *node* referencing the mesh,
  so lookups resolve from node names, falling back to the filename.
- Slots reading `Uses custom shader` or `No Albedo Texture` are left untouched.

A systemic fix belongs in the cooker rather than in every consumer — filed as a
deferred task in `workspace/asset-server/TODO.md`, with this implementation
named as the reference. Until that lands, every project consuming these packs
needs its own copy of this repair.

### Material fixes (defensive, all cheap)

Out-of-range `baseColorTexture.index` is clamped; a stray `emissiveFactor` with
no `emissiveTexture` is deleted (Synty "custom shader" materials otherwise
translate to full-white emission and wash the prop out); `metallicFactor >= 0.3`
is zeroed and `KHR_materials_specular` stripped (Cascade has no reflection
probes, so a metallic Synty material renders near-black). A 60-file sample of
the space packs found none of these in practice — they cost nothing and cover
the pack-update case.

### What was deliberately **not** ported from godot-rts

- **`alphaMode BLEND → MASK`** and the "opaque material whose base texture has
  an alpha channel → MASK" rule. Both exist to stop foliage cards
  depth-sorting badly under an isometric camera. Cascade has no foliage, and the
  space packs genuinely want blending: cockpit glass
  (`SM_Chr_Attach_EVA_Cover_Clear_01`, `SM_Chr_Attach_Junker_Helmet_Glass_01`),
  HUD holograms (`SM_Hud_*`), engine flame cards (`SM_Flame_Mesh_*`).
  Alpha-testing those would harden glass into opaque plates. The 60-file sample
  found 3 `MASK` materials and 0 `BLEND` materials anyway.
- **`scripts/import/strip_lods.gd`** (the project-wide `EditorScenePostImport`
  that drops Synty's stacked `_LOD1+` sibling mesh nodes). The space packs do
  not ship them: 0 of 40 randomly sampled glTFs across
  `POLYGON_Scifi_Space`, `POLYGON_SciFiWorlds`, `SIMPLE_Space` and
  `SIMPLE_Space_Interiors` contain a `_LODn` node, and no filename in any of
  them mentions LOD. Adding the import script would be a project-wide no-op,
  and it would also add a `[importer_defaults]` block to `project.godot` that
  every future asset silently inherits. If a later pack does ship stacked LODs:
  copy `../godot-rts/scripts/import/strip_lods.gd` to
  `scripts/import/strip_lods.gd` and add
  `[importer_defaults] scene={"import_script/path": "res://scripts/import/strip_lods.gd"}`
  to `project.godot`.

---

## 4. Curated manifest

All sizes are **measured**, not estimated: each mesh was fetched, patched,
imported by Godot 4.7.1, instantiated, and its merged `MeshInstance3D` AABB
read. Format is `X × Y × Z` metres in Godot world axes (Y up), at native scale
after patching. Prefix the `Path` column with the table in §2.

### 4.1 Player ship — ranked candidates

Cascade's ship is a worn working tug ("Toy Box") with a **4 × 2 × 8 m**
collision box. No warships: `SM_Ship_Fighter_*`, `_Bomber_*`, `_Stealth_*`,
`_Cruiser_*`, `_Colossal_*` and every `SM_Prop_Turret_*` / `SM_Prop_Missile_*`
in the space pack are excluded on principle.

| Rank | Mesh | Path | Measured | Notes |
|---|---|---|---|---|
| **1** | `SM_Veh_Part_Body_03` | `SPACE/SM_Veh_Part_Body_03.gltf` | 4.59 × 3.01 × 7.24 | Boxy blue/white pressurised hull module: framed side window, panel greebles, no wings, no guns. **Fits the collision box at native scale** — only the 3.0 m height overshoots 2 m, so either widen the box to 4 × 3 × 8 or apply a uniform 0.85 scale. Uses the same atlas as every debris prop you will place, so ship and junk match. Extensible with the pack's `SM_Veh_Part_Cockpit_01..05`, `_Engine_01..09`, `_Misc_01..023`, `_Wing_01..016`, `_LandingGear_*`. |
| **2** | `SM_Veh_Barge_01` | `WORLDS/SM_Veh_Barge_01.gltf` | 10.60 × 4.67 × 18.22 | The best "worn working tug" silhouette on the server: finished open flatbed with railed cargo deck and a small forward cab, chunky yellow/rust industrial paint. The open deck is literally a `CargoBay`. Needs a uniform **0.44** scale → 4.66 × 2.05 × 8.02, essentially exactly 4 × 2 × 8. Costs: desert-scavenger palette and a different atlas from the space props, and it is authored as a surface barge with no visible thruster nozzles — bolt on `SIMPLE/SM_Veh_Thruster_0x` or `SPACE/SM_Veh_Part_Engine_0x`. |
| **3** | `SM_Veh_Scav_Lifter_02` | `WORLDS/SM_Veh_Scav_Lifter_02.gltf` | 5.71 × 9.19 × 16.35 | Cab-plus-crane-arm industrial lifter; the most explicitly "machinery for moving heavy things" of the three, and the arm doubles as a visible grapple. At 0.5 scale it is 2.86 × 4.60 × 8.18 — right length, twice the target height, so its proportions fight the box more than the other two. `SM_Veh_Scav_Lifter_01` is the larger sibling (8.14 × 10.6 × 25.6 raw). |

Also considered and rejected as the player ship, but useful elsewhere:

| Mesh | Path | Measured | Use instead as |
|---|---|---|---|
| `SM_Veh_Drone_Repair_01` | `SPACE/SM_Veh_Drone_Repair_01.gltf` | 4.33 × 1.64 × 2.00 | uncrewed companion / bay drone |
| `SM_Veh_Sweepo_01` | `SPACE/SM_Veh_Sweepo_01.gltf` | 0.45 × 0.64 × 0.78 | Synty's little sweeper droid — a free ship's-cat character (its "SWEEPO" decal is on the hull atlas) |
| `SM_Veh_EscapePod_Large_01` | `SPACE/SM_Veh_EscapePod_Large_01.gltf` | 3.18 × 2.82 × 3.96 | boxy pod / bolt-on ship module |
| `SM_Veh_Part_Body_01` / `_02` | `SPACE/SM_Veh_Part_Body_0{1,2}.gltf` | 7.96 × 2.72 × 8.76 / 1.93 × 1.19 × 4.36 | wide flat hull, small single-seat pod |
| `SM_Ship_Block_01..04` | `WORLDS/SM_Ship_Block_0N.gltf` | 13–52 m | mid-size derelicts to salvage |
| `SM_Veh_Shuttle_01` | `SIMPLE/SM_Veh_Shuttle_01.gltf` | 12.94 × 9.01 × 19.37 | recognisable Shuttle orbiter (SIMPLE art style) |

### 4.2 Debris props

Orbital junk. Everything here is at a hand-grabbable-to-small-truck scale, so
it works as `RigidBody3D` debris without rescaling.

| Purpose | Path | Measured | Notes |
|---|---|---|---|
| Dead satellite (bus + dish + boom) | `WORLDS/SM_Prop_Satellite_01.gltf` | 12.06 × 6.96 × 7.49 | Largest of the set; a proper derelict satellite |
| Dead satellite (tall comsat) | `WORLDS/SM_Prop_Satellite_02.gltf` | 2.63 × 6.05 × 2.62 | Good tumbler |
| Dead satellite (squat dish) | `WORLDS/SM_Prop_Satellite_03.gltf` | 4.93 × 3.13 × 4.93 | |
| Dead satellite (big dish array) | `WORLDS/SM_Prop_Satellite_04.gltf` | 15.18 × 8.10 × 15.49 | Big enough to be a contract objective |
| Dead satellite (mast type) | `WORLDS/SM_Prop_Satellite_05.gltf` | 2.59 × 6.11 × 2.38 | |
| Dead satellite (small mast) | `WORLDS/SM_Prop_Satellite_06.gltf` | 2.25 × 4.33 × 2.33 | |
| Dead satellite (tripod probe) | `WORLDS/SM_Prop_Satellite_07.gltf` | 2.81 × 1.70 × 2.81 | |
| Satellite bus module (boxy) | `WORLDS/SM_Prop_Satellite_08.gltf` | 2.45 × 1.25 × 1.17 | Reads as a hull fragment too |
| Satellite, real-world boxy bus | `SIMPLE/SM_Veh_Satellite_01.gltf` | 2.24 × 2.59 × 2.88 | SIMPLE style; see note in §5 |
| Satellite, real-world solar-wing | `SIMPLE/SM_Veh_Satellite_02.gltf` | 1.03 × 3.57 × 3.14 | |
| Satellite, Hubble-alike tube | `SIMPLE/SM_Veh_Satellite_04.gltf` | 1.44 × 1.77 × 5.52 | |
| Satellite, X-panel comsat | `SIMPLE/SM_Veh_Satellite_05.gltf` | 5.89 × 2.46 × 5.89 | |
| Solar array, big frame | `WORLDS/SM_Prop_SolarPanel_01.gltf` | 11.50 × 2.92 × 9.96 | The signature "torn-off solar wing" |
| Solar array, on frame | `WORLDS/SM_Prop_SolarPanel_02.gltf` | 7.31 × 3.71 × 8.40 | |
| Solar array, trolley-mounted | `WORLDS/SM_Prop_SolarPanel_03.gltf` | 6.22 × 1.91 × 4.05 | |
| Solar array, segmented/flexible | `WORLDS/SM_Prop_SolarPanel_04.gltf` | 1.91 × 6.21 × 3.70 | Good folded-array look |
| Solar array, thin blade | `SIMPLE/SM_Prop_SolarPanel_02.gltf` | 11.22 × 0.20 × 2.49 | Nearly 2D — great tumbling silhouette |
| Solar tile, hex | `SPACE/SM_Prop_Solar_Hex_01.gltf` | 1.42 × 0.45 × 1.23 | Small, scatter in numbers |
| Antenna mast, thin whip | `SPACE/SM_Prop_Antenna_01.gltf` | 0.35 × 4.69 × 0.24 | |
| Antenna mast, dressed | `WORLDS/SM_Prop_Antenna_01.gltf` | 0.96 × 5.41 × 0.47 | Note: **same basename, different pack** |
| Antenna, dish on boom | `WORLDS/SM_Prop_Antenna_05.gltf` | 2.96 × 8.68 × 3.42 | Biggest of `_01..09` |
| Antenna, cross-arm | `WORLDS/SM_Prop_Antenna_08.gltf` | 6.00 × 2.89 × 0.58 | |
| Radar/dish panel, small | `SPACE/SM_Prop_Radar_Panel_01.gltf` | 0.81 × 0.19 × 0.82 | `_02` is the bigger variant |
| Dish, large | `SIMPLE/SM_Bld_RadarDish_01.gltf` | 22.33 × 23.87 × 19.52 | Set-piece scale |
| Hull fragment, curved plate | `SPACE/SM_Env_Debris_Shell_01..08.gltf` | 0.65 × 0.83 × 0.28 … 4.32 × 6.10 × 3.24 | Eight variants, small→large; the core "orbital junk" vocabulary |
| Hull fragment, truss/frame | `SPACE/SM_Env_Debris_Structure_01..03.gltf` | 1.61 × 5.53 × 1.62 … 1.94 × 8.18 × 2.10 | Bent structural members |
| Pipe bundle | `SPACE/SM_Env_Debris_Pipe_01.gltf` | 1.52 × 1.61 × 6.21 | |
| Broken pipe section | `SPACE/SM_Prop_Detail_Pipe_Broken_01.gltf` | — | Not fetched in this survey; same family |
| Pipe, long straight | `SIMPLE/SM_Prop_Pipes_01.gltf` | 0.97 × 0.87 × 10.00 | 10 m — a proper girder-scale hazard |
| Girder / strut frame | `SPACE/SM_Prop_Detail_Struts_01.gltf` | 4.61 × 3.77 × 1.22 | `_02` is a variant |
| Pressure vessel / drum | `WORLDS/SM_Prop_Scav_Scrap_01..04.gltf` | 6.17 × 5.43 × 6.18 … 7.83 × 11.73 × 7.90 | Cylindrical tanks; the best mid-size debris in the survey |
| Crumpled sheet metal | `WORLDS/SM_Prop_Scav_Scrap_05..08.gltf` | 4.15 × 1.74 × 4.15 … 13.14 × 2.96 × 5.67 | Torn hull plate |
| Broken mast / spar | `WORLDS/SM_Prop_Scav_Scrap_09.gltf` | 8.12 × 7.14 × 2.06 | |
| Crate, salvage | `SPACE/SM_Prop_Crate_01.gltf` | 0.73 × 0.61 × 0.67 | `_02`, `_Wide_01` are variants; `WORLDS/SM_Prop_Crate_01..15` is a much bigger set |
| Oxygen tank | `SPACE/SM_Prop_Oxygen_Tank.gltf` | 0.34 × 1.04 × 0.34 | `_Large`, `_Small` variants |
| Fuel tank | `SIMPLE/SM_Fueltank_01.gltf` | 4.82 × 6.36 × 10.43 | |
| Battery / avionics box | `SPACE/SM_Prop_Battery_01.gltf`, `_02` | — | Small greeble-scale salvage |
| Air vent / duct | `SPACE/SM_Prop_AirVent_Large_01.gltf` | — | |
| Loose wiring bundle | `SPACE/SM_Prop_Wires_01.gltf`, `_02` | — | Reads as trailing harness |
| Satellite cradle / stand | `SPACE/SM_Prop_Satellite_Stand_01.gltf` | 3.01 × 2.10 × 1.73 | Also a hangar/dock prop |
| Drone hulk, small | `WORLDS/SM_Prop_Drone_01..04.gltf` | 0.56 × 0.77 × 0.70 … 1.69 × 1.07 × 1.34 | Grabbable in one pass |
| Marker beacon | `SPACE/SM_Veh_Beacon_01.gltf` | 9.19 × 17.76 × 9.19 | Lit spar; contract-zone marker |
| Marker beacon, simple | `SIMPLE/SM_Prop_Beacon_01.gltf` | 4.04 × 6.66 × 4.04 | |
| Tether / cable span | `SIMPLE/SM_Prop_Tether_01..03.gltf` | 14.45 × 4.23 × 0.46 | Catenary wire spans |
| Tether wire (ship) | `WORLDS/SM_Prop_Tether_Wire_Ship_01.gltf` | 0.06 × 4.46 × 0.05 | Hairline; scale to taste |

**Rejected:** `WORLDS/SM_Env_Ground_Junk_01..05` (60 × 5 × 37 m rainbow-coloured
terrestrial rubbish mats — they read as landfill, not orbital debris) and the
`SPACE_FX/SM_Pebble_Debris_0N` / `SPACE/SM_Env_Rubble_*` / `SM_Env_Asteroid_*` /
`SM_Env_Astroid_*` families (rock, not manufactured junk — keep them for
asteroid work, not for Cascade's debris field).

### 4.3 EVA astronaut / pressure suit

| Purpose | Path | Measured | Notes |
|---|---|---|---|
| **EVA suit, rigged** | `SPACE_CHR/SK_Chr_BR_EVA_Suit_01.gltf` | 2.88 × 0.49 × 1.73 (rest-pose mesh AABB; **1.73 m standing height**) | The pick. Imports as `Root/Skeleton3D` (48 bones) + one `MeshInstance3D` + an `AnimationPlayer` with 1 clip, material correctly bound to `PolygonSciFiSpace_Texture_01_A.png`. The AABB is the T-pose in skeleton rest space, hence the 2.88 m "width" (arm span) and 0.49 m "height" — the figure is 1.73 m tall once posed. Do **not** use the `Unreal_Characters/` copy (signage atlas, no animation). |
| EVA helmet, opaque cover | `SPACE/SM_Chr_Attach_EVA_Cover_01.gltf` | — | Attachment; `_Clear_01` is the transparent visor (leave its `BLEND` alone) |
| EVA head, blank / scaled | `SPACE/SM_Chr_Attach_EVA_{Male,Female}_Head_{Blank,Scaled}_01.gltf` | — | Head swaps inside the helmet |
| Generic space helmet | `SPACE/SM_Chr_Attach_SpaceHelmet_01.gltf` | 0.37 × 0.46 × 0.42 | |
| Salvager crew (unhelmeted) | `SPACE_CHR/SK_Chr_Junker_{Male,Female}_01.gltf` | — | Best Planetes-crew read of the pack's characters; also `SK_Chr_Crew_*`, `SK_Chr_CrewCaptain_*`, `SK_Chr_Medic_Male_01` |
| Crew, SIMPLE style | `SIMPLE_CHR/Characters.gltf` | 3.37 × 1.22 × 2.97 | **One glTF containing all 8 characters** as sibling meshes on a shared skeleton — split it by hand if you use it. Also has no texture image at all (7 untextured `lambert*` materials). Prefer the POLYGON characters. |
| Junker helmet + glass | `SPACE/SM_Chr_Attach_Junker_{Helmet_01,Helmet_Glass_01,Headset_01}.gltf` | — | |

### 4.4 Planets, moons and sky

| Purpose | Path | Measured | Notes |
|---|---|---|---|
| **Earth (+ small moon)** | `SIMPLE/SM_Env_Scale_Earth_01.gltf` | 9.68 × 10.27 × 10.42 | The only blue-and-green Earth on the server. Flat-shaded low-poly; scale to taste |
| Sun | `SIMPLE/SM_Env_Scale_Sun.gltf` | 100.32 × 101.77 × 100.32 | |
| Mercury / Venus / Mars | `SIMPLE/SM_Env_Scale_{Mercury,Venus,Mars}_01.gltf` | 6.05 / 9.17 / 5.17 dia. | |
| Jupiter / Saturn / Uranus / Neptune / Pluto | `SIMPLE/SM_Env_Scale_{Jupiter,Saturn,Uranus,Neptune,Pluto}_01.gltf` | 28.13 / 45.78 (rings) / 14.04 / 13.92 / 2.99 dia. | Saturn's mesh includes its ring. A complete matched solar-system set — relevant to `scripts/world/solar_system.gd` |
| Generic planet / moon, rocky | `SPACE/SM_Env_Planet_01..11.gltf` | 419–476 m dia. | Grey cratered moon-like spheres. None are Earth-like |
| Generic planet, banded | `SPACE/SM_Env_Planet_12..14.gltf` | 493 / 486 / 698 m dia. | Blue/orange banding — the most "planet" of the set |
| Planet ring | `SPACE/SM_Env_PlanetRings_01.gltf` | 0.21 × 0.00 × 0.21 | **Authored tiny and flat** — a ring card meant to be scaled up to whatever planet you pair it with |
| Sky, day | `SKIES/sky_day_01.png` | 2048 × 1024 PNG | Loose panorama, no mesh. Two files total in the `_skies` pack |
| Sky, gloom | `SKIES/sky_gloom_01.png` | 2048 × 1024 PNG | **Not usable for Cascade.** Both files are flat 2:1 equirectangular gradients of blue sky over a brown ground plane with a hard horizon line — terrestrial daylight panoramas, verified by inspection. There is no starfield anywhere on the asset server. Build the orbital sky in-engine (`ProceduralSkyMaterial` with a black ground/sky and a star shader, or a custom `ShaderMaterial` on the `SkyboxEnvironment`), or bring your own equirectangular star map |
| Sky dome mesh | `assets/SIMPLE_Sky_SourceFiles/SourceFiles/FBX/SkyDome.gltf` | — | Plus `Cloud_01..06`; atmospheric, not orbital |

### 4.5 Space station / relay platform (for docking work)

| Purpose | Path | Measured | Notes |
|---|---|---|---|
| Ring station, huge | `SPACE/SM_Ship_Station_01.gltf` | 565.82 × 146.83 × 563.36 | 2 MB `.bin`; the hero station |
| Ring station, flat | `SPACE/SM_Ship_Station_02.gltf` | 498.02 × 41.30 × 502.83 | |
| Ring station, medium | `SPACE/SM_Ship_Station_03.gltf` | 268.37 × 43.30 × 275.55 | |
| Drum station | `SPACE/SM_Ship_Station_04.gltf` | 257.59 × 148.54 × 257.59 | |
| **Tower / spine station** | `SPACE/SM_Ship_Station_05.gltf` | 129.21 × 291.97 × 143.88 | Best "relay platform you dock at" read; smallest useful hero station |
| Tower station, small | `SPACE/SM_Ship_Station_06.gltf` | 60.35 × 101.06 × 52.27 | Good first docking target |
| ISS-alike | `SIMPLE/SM_Veh_SpaceStation_01.gltf` | 89.82 × 28.87 × 63.58 | Truss + solar wings; the most Planetes-plausible station |
| Hangar / dock interior | `SPACE/SM_Bld_Hangar_01.gltf`, `SM_Bld_HangarPlatform_01.gltf`, `SM_Bld_HangarExteriorShip_01..02.gltf` | — | For an interior dock scene |
| Landing platform | `SPACE/SM_Bld_Landing_Platform_01.gltf` | — | |
| Airlock / pressure tube | `SPACE/SM_Prop_SpaceWalk_Tube_01.gltf`, `SM_Prop_SpaceWalk_End_01.gltf` | 4.76 × 3.96 × 5.00 / 3.73 × 3.73 × 1.28 | Modular EVA gangway |
| Escape-pod hatch | `SPACE/SM_Prop_EscapePod_Hatch_{Large,Small}_01.gltf`, `SM_Bld_Wall_EscPod_Hatch_01.gltf` | — | |
| Big derelict / wreck | `WORLDS/SM_Bld_Scav_Wreckage_01..03.gltf` | 114 × 113 × 305 … 196 × 174 × 486 | Crashed capital-ship hulls. Enormous — a whole level's worth of set dressing |
| Derelict dish array | `WORLDS/SM_Bld_Scav_Dish_01.gltf` | 83.29 × 62.23 × 83.02 | |
| Comms mast, tall | `WORLDS/SM_Bld_Core_Antenna_Greeble_01.gltf`, `_02` | 7.37 × 65 × 7.37 | 65 m red/orange masts |
| Ship interior modules | `SPACE/SM_Bld_Bridge_*.gltf`, `SM_Bld_Floor_*`, `SM_Bld_Wall_*`, `SM_Bld_Corridor_*`, `SM_Bld_Crew_*` | — | Full modular interior kit for the Phase 5 walkable `ShipInterior` |
| Interior consoles / seats / lockers | `SIMPLE_INT/SM_Prop_Console_01..08.gltf`, `SM_Prop_Seat_01..03`, `SM_Prop_SwivelChair_01..04`, `SM_Prop_Lockers_01..05`, `SM_Prop_Hatch_01..03`, `SM_Prop_Panel_01..07` | — | For `ContractBoardTerminal`, `ToolBench`, `RepairStation_*` |

### 4.6 Thruster and engine FX

| Purpose | Path | Measured | Notes |
|---|---|---|---|
| **Flame card mesh** | `SPACE_FX/SM_Flame_Mesh_New.gltf` | 0.16 × 0.24 × 0.16 | Authored tiny — scale up per thruster. `SM_Flame_Mesh_Square.gltf` is the square variant |
| Flame gradient texture | `SPACE_TEX/Gradient_Boost.png` | 120 KB | The boost/flame ramp |
| Emissive mask | `SPACE_TEX/PolygonSciFiSpace_Emissive_01.png` | 198 KB | Pair with the hull atlas for lit windows and engine glow |
| Thruster nozzle, bell | `SIMPLE/SM_Veh_Thruster_01.gltf` | 1.04 × 1.02 × 1.19 | Physical geometry, not FX |
| Thruster nozzle, small | `SIMPLE/SM_Veh_Thruster_02.gltf` | 0.59 × 0.51 × 0.51 | RCS-scale |
| Thruster, long stage | `SIMPLE/SM_Veh_Thruster_03.gltf` | 1.37 × 11.02 × 1.19 | |
| Engine block (industrial) | `SPACE/SM_Prop_Engine_Construction_01.gltf` | 1.52 × 1.73 × 2.55 (raw-derived) | Bolt-on engine module |
| Engine nacelles (kit) | `SPACE/SM_Veh_Part_Engine_01..09.gltf` | 1.37 × 1.50 × 4.73 … 5.74 × 3.76 × 13.04 (raw-derived) | Matches the `SM_Veh_Part_Body_*` kit |
| Particle: cone | `PFX/FX_Cone_01.gltf`, `FX_Cone_02.gltf` | — | Exhaust plume cones |
| Particle: soft puff | `PFX/FX_Sphere_Puff_01.gltf` | — | Vent / RCS puff |
| Particle: spark | `PFX/FX_Spark_01.gltf` | — | Cutting-tool sparks |
| Particle: smoke | `PFX/SM_Particle_Smoke_01.gltf` | — | |
| Particle: shockwave ring | `PFX/FX_Ring_01.gltf` | — | |
| Particle: debris shards | `PFX/FX_Shard_Rock_01..04.gltf` | — | Small fragments for a cut/break |
| Particle atlas | `assets/POLYGON_Particle_FX_SourceFiles_v2/Source Files/Textures/PolygonParticles_Texture_01_A.png` | — | The only texture in the FX pack |

### 4.7 New York detail site (PR3)

`scripts/sites/nyc_site.gd` builds the Manhattan diorama in code from these, at
**native scale** — Synty authored them 18–42 m tall, which lands inside the
25–40 m miniature range `docs/planet-renderer.md` asks for with no rescaling.
Heights below are world Y after the cook's `(rawX, rawZ, rawY) x 0.01`.

| Purpose | Path | Height | Notes |
|---|---|---|---|
| Towers | `CITY/SM_Bld_Background_{Lrg_02,Lrg_03,Med_09}.gltf` | 42.0 / 42.5 / 30.4 m | The midtown/downtown core |
| Blocks | `CITY/SM_Bld_Background_{Lrg_01,Med_01,Med_03,Med_04,Med_05,Med_06}.gltf` | 23.1–25.5 m | |
| Low-rise | `CITY/SM_Bld_Background_{Med_02,Med_07,Med_08,Small_01,Small_02,Small_03}.gltf` | 4.9–23.1 m | Outer boroughs |

**No textures needed.** The pack's MaterialList reports every one of these as
`PolygonSciFi_Buildings_Background (No Albedo Texture)` — they are meant to be
coloured by the scene, and `nyc_site.gd` applies one shared `StandardMaterial3D`
(dark by day, faintly emissive across dusk) to all of them. That is also why
`fetch_assets.sh` pulls no textures for this pack.

Placement is not authored either: the script samples the site's own
`nyc_height_inset.png` and puts buildings only where that raster says land, so
the skyline sits on the real coastline and the Hudson, East River and Upper Bay
stay dark. Fixed RNG seed — the diorama is identical every session.

---

**No combat FX.** The FX pack also contains `FX_Ammo_01`, `FX_Bullet_Trail*`,
`FX_Grenade_0N`, `SM_GoreChunk_0N`, and the space pack has
`SPACE_FX/SM_Laser_Trail_01`,
`SM_MissleBody`, `SM_Prop_Missile_01..07`, `SM_Prop_Mine_01`, `SM_Wep_*`. None
of these belong in Cascade.

---

## 5. Art family: POLYGON (decided)

**Decision (project owner, 2026-08-17): use POLYGON.** `POLYGON_Scifi_Space` is
the primary pack; `POLYGON_SciFiWorlds` is the secondary for scrap, barges and
industrial props. Do not mix SIMPLE assets into scenes.

Consequences worth knowing:

- The SIMPLE packs are where the recognisable real-world vocabulary lives
  (actual satellites, the Shuttle, the ISS, a matched planet set). Giving that
  up means Cascade's debris reads as generic sci-fi hardware rather than
  identifiable hardware. If a specific contract ever needs a recognisable
  object, treat it as a modelling task, not a pack swap.
- Planets stay **procedural** (`CelestialBody` builds its own sphere), which
  sidesteps the question entirely for the largest objects on screen. SIMPLE's
  Earth mesh is not used.
- The sky is a procedural shader — there is no orbital sky on the server at all
  (see below).

The original survey's reasoning is kept below, since it explains what the
decision costs.

### Background: the two families do not match

- **POLYGON** (`POLYGON_Scifi_Space`, `POLYGON_SciFiWorlds`) — dense texture
  atlases, panel-line detail, saturated blue/white or yellow/rust palettes,
  hundreds to low thousands of triangles per prop.
- **SIMPLE** (`SIMPLE_Space*`) — flat vertex-coloured look off a tiny 20 KB
  atlas, very few triangles, no panel detail.

- **POLYGON** (`POLYGON_Scifi_Space`, `POLYGON_SciFiWorlds`) — dense texture
  atlases, panel-line detail, saturated blue/white or yellow/rust palettes,
  hundreds to low thousands of triangles per prop.
- **SIMPLE** (`SIMPLE_Space*`) — flat vertex-coloured look off a tiny 20 KB
  atlas, very few triangles, no panel detail.

SIMPLE is where the *real-world* vocabulary lives (recognisable satellites,
the Shuttle, the ISS, a matched solar-system planet set, Earth), which is
exactly what a Planetes-flavoured game wants. POLYGON is where the hull
fragments, scrap and stations live. Mixing them in one shot will read as an
error unless you commit to it. Two workable strategies:

1. **POLYGON foreground, SIMPLE background.** Debris the player touches comes
   from POLYGON; planets, the sky, and distant stations come from SIMPLE where
   the flat shading is invisible at range.
2. **All SIMPLE.** Cheaper, more toy-like, and the real-satellite silhouettes
   carry the Planetes read on their own — but the debris vocabulary is thinner.

Pick one and record it here before authoring a level.

---

## 6. Local state after the initial survey

`assets/meshes/` currently holds ~31 MB (136 glTFs) — the survey set behind
this manifest, already patched and imported with zero import errors under Godot
4.7.1. It is gitignored and unreferenced by any scene, so a plain
`./fetch_assets.sh` will report a 0-file closure and leave it alone. Delete the
directory and re-run `--pack` any time you want a clean slate.

---

## 7. Planet maps (`assets/planets/`) — committed, not fetched

These are the only binary art in the repo. Everything else comes from the asset
server; a handful of static scientific rasters is not the same problem, and
committing them removes the server write dependency and the whole fetch/cook
path for data that will never change. ~19 MB total.

Cooked by `tools/cook_planet_maps.py` (one-shot, not part of `fetch_assets.sh`).
It downloads the sources into `/tmp/cascade_planet_raw` — about 1.4 GB, not
committed — and writes the nine PNGs below. Re-run it only if a source is
updated or an encoding constant changes.

### 7.1 What is real, and what is not

Every global map is real public-domain data. Everything is stated here so nobody
has to guess later which is which.

| File | Source | Real? |
|---|---|---|
| `earth_height.png` | NOAA NCEI **ETOPO 2022**, 60 arc-second surface elevation (topography + bathymetry), netCDF float32 21600×10800 | real |
| `earth_albedo.png` | NASA Visible Earth **Blue Marble Next Generation** with topography and bathymetry, Dec 2004, 5400×2700 | real |
| `earth_night.png` | NASA Earth Observatory **Black Marble 2016**, 0.1°, 3600×1800 | real |
| `moon_height.png` | NASA SVS **CGI Moon Kit** (id 4720) — LRO **LOLA** LDEM at 16 px/deg, float32 km | real |
| `moon_albedo.png` | NASA SVS CGI Moon Kit — **LROC WAC** colour mosaic with poles, already 2048×1024 | real |
| `mars_height.png` | PDS **MGS MOLA MEGDR** 16 px/deg, MSB int16 metres | real |
| `mars_albedo.png` | USGS Astrogeology **Viking** colourised global mosaic, 925 m/px | real |
| `nyc_height_inset.png` | AWS Open Data **Terrain Tiles** (terrarium encoding; SRTM/NED composite), z12 mosaic over a 29 km window at 40.75 N 73.98 W | real |
| `nyc_night.png` | **Authored art.** A street grid on Manhattan's ~29° bearing, masked by the land/water mask of the inset above. No public night raster resolves a 29 km window | **synthetic** |
| `earth_clouds.png` | NASA Visible Earth **Blue Marble Clouds** composite (id 57747), kept as an L8 cloud-fraction weight | real |
| `tiles/earth_h_L{1,2}_x_y.png` | **ETOPO 2022** again, at full source resolution: the height tile pyramid (§7.3) | real |
| `canaveral_height_inset.png` | AWS Open Data **Terrain Tiles**, 29 km window at 28.55 N 80.62 W — the cape, the barrier islands, the Banana/Indian rivers | real |
| `canaveral_night.png` | **Authored art**: gaussian glows at the real installations (LC-39A/B, VAB, SLF, the CCSFS row, Port Canaveral) over faint land mottle | **synthetic** |

Exact URLs are in the `SOURCES` table at the top of the cook script.

No other body has an authored map: the eleven remaining ones are procedural, and
that is the designed fallback, not a gap (`BodySurface` samples the map only
when one is set).

### 7.2 Encoding — read this before touching a height map

- **2048×1024 equirectangular**, column 0 = longitude −180°, row 0 = +90°
  latitude. That is the game's own lookup: `lon = atan2(dir.z, dir.x)`,
  `lat = asin(dir.y)`, `u = 0.5 + lon/TAU`, `v = 0.5 - lat/PI`, shared by
  `BodySurface.HeightSampler._sample_equirect` and
  `assets/shaders/planet_surface.gdshader`. MOLA ships starting at longitude 0
  and is rolled half a turn by the cook; the SVS Moon maps and the USGS Viking
  mosaic already start at −180.
- **2048×1024 was the global-map ceiling** (owner decision, 2026-08-17) until
  the fidelity tier (owner call, 2026-08-23) raised Earth specifically:
  `earth_albedo.png` is now **4096×2048** (real detail from the 5400-wide Blue
  Marble source), and Earth height gains the tile pyramid in §7.3. Every other
  body keeps the 2048 ceiling, which remains correct at their view distances.
- **Height carries 16 bits split across two 8-bit channels**: red is the high
  byte, green the low byte, `p = (R*256 + G) / 65535`. Godot's PNG importer does
  not preserve a true 16-bit greyscale PNG, and a single 8-bit channel would
  quantise Earth's ±40 m of relief into 0.31 m terraces — coarser than the
  0.77 m vertex spacing the geometry can express. Two channels give ~1 mm.
- Height maps are read with `get_image()` and **never assigned to a material**,
  so the importer's detect-3d VRAM compression — which would shred the split
  encoding — never fires. `tests/planet_test.gd` re-derives Earth's land
  fraction from the decoded map (0.293 against a real 0.292) and spot-checks the
  Pacific, the Atlantic, the Sahara, the Himalaya and New York, so a broken
  decode or a flipped orientation fails the suite rather than shipping.
- `p` maps to the engine's normalized height `n = 2p - 1 ∈ [-1,1]`, the same
  range the procedural noise produces, so `amplitude` and `sea_level` keep their
  meanings. `n` is a **signed power** of true elevation,
  `n = sign(e) · (|e| / ref_side)^0.6`, with separate positive/negative
  reference elevations per body. The exponent is the design doc's "relief is
  exaggerated" made concrete; the zero crossing is exact, which is what lets
  Earth's `sea_level` simply be `0.0` — the coastline is the datum now, not a
  tuned constant.
- The NYC inset uses the same encoding with **local** reference elevations
  (700 m up, 1500 m down) rather than the global ones. Its 29 km of real terrain
  is squeezed into a 400 m footprint, so its vertical scale is stylized to match;
  the blend weight reaches zero at the footprint edge, so the two encodings never
  meet in a step.
- `earth_clouds.png` is the odd one out: a plain **L8 cloud fraction**, not a
  height map. It IS assigned to a material (the cloud shader samples it), so
  the importer may VRAM-compress it — that is fine for a weight mask and must
  never be taken as licence to assign the height maps.

### 7.3 Earth height tile pyramid (fidelity tier, owner call 2026-08-23)

`assets/planets/tiles/earth_h_L{level}_{x}_{y}.png` — equirect tiles over the
same lon/lat mapping as the global map. Level L is a 2^(L+1) × 2^L grid of
1024² tiles: **L1 is an effective 4096 global and is complete; L2 is an
effective 8192 and is land-only** (all-ocean tiles are not cooked — the global
map already carries low-frequency bathymetry). Same split-16-bit encoding and
the **same global reference elevations**, so a tile and the global map agree
wherever both exist and `BodySurface.HeightSampler` can hard-switch layers
per lookup (finest resident tile wins, global map is the floor) without a
value step.

Residency (2026-08-23): **L1 loads eagerly** in `prepare()` — the complete,
seamless floor — and **L2 streams by observer proximity** (14°/28°
enter/exit hysteresis, driven from `PlanetSurface._update_tile_streaming`).
Residency changes go through a replace-not-mutate dictionary swap, which
in-flight worker samplers snapshot by reference; cached deep patches over a
changed tile are purged and rebuilt by the refine loop. Steady state holds
~1–4 L2 tiles (~12 MB) instead of the whole set.
