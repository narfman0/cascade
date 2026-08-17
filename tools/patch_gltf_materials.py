#!/usr/bin/env python3
"""
Post-process cooked glTF files under assets/meshes/ so Godot imports them at
the right scale with the right materials. Ported from godot-rts and trimmed to
the fixes the *space* packs actually need (see "Deliberately not ported").

Run: python3 tools/patch_gltf_materials.py
Called automatically at the end of fetch_assets.sh.
Idempotent: skips files already correct. Deletes stale .gltf.import sidecars
for any file it modifies so Godot re-imports it.

What it fixes
-------------
1. Stray 0.01 root-node scale on metre-unit cooks. Every Synty cook on the
   asset server carries `scale: [0.01, 0.01, 0.01]` on its root node plus a
   +90° X rotation (Z-up -> Y-up). For the POLYGON_* static meshes that is
   correct: their vertices really are in centimetres. But two families ship
   metre-unit vertices *and* the 0.01, so they land at 1/100 size — an
   invisible speck:
     * every skeletal (SK_*) cook, in any pack (the SK_Chr_BR_EVA_Suit_01
       T-pose measures 2.9 x 1.7 x 0.5 raw -> a 1.7 cm astronaut);
     * every mesh in the SIMPLE_* packs (SM_Veh_Satellite_01 raw 2.24 ->
       2.2 cm; SM_Veh_SpaceStation_01 raw 89.8 -> 0.9 m).
   Policy is therefore pack-scoped (PACK_UNITS) with a max-coordinate
   threshold fallback for packs not listed. Note this differs from godot-rts,
   whose single global threshold of 50 raw units gets both
   SM_Veh_Sweepo_01 (45 raw, genuinely centimetres) and
   SM_Veh_SpaceStation_01 (89.8 raw, genuinely metres) wrong.

2. Wrong texture atlas on POLYGON_Scifi_Space cooks. ~80% of that pack's
   glTFs point their single material at PolygonSciFiSpace_Signs_Texture_01_A
   .png — the 1024x1024 *signage* atlas (black field, white door labels and
   pictograms) — instead of the 2048x2048 PolygonSciFiSpace_Texture_01_A.png
   hull/panel atlas the UVs were authored against. Left alone, hulls, crates,
   debris and ships all import near-black with stray glyphs on them.
   Measured, not guessed: sampling each mesh's own TEXCOORD_0 against both
   images, 23/23 fetched space meshes average 92% pure-black samples on the
   signage atlas and 0% on the hull atlas (SM_Veh_Part_Body_03: 100% vs 0%;
   SM_Hud_Reticle_01: 100% black on signage, HUD cyan on hull). The remap is
   therefore unconditional for that pack. Only ..._Signs_Texture_01_A.png is
   remapped; ..._Signs_Texture_01_B.png (the real sign lettering sheet, used
   correctly by SM_Sign_*/SM_SignBorder_*) and ..._Texture_03_A.png are
   untouched.

3. Out-of-bounds baseColorTexture index -> clamped to the images array length.
   Defensive; Godot falls back to an error material otherwise.

4. Stray emissiveFactor with no emissiveTexture -> removed. Synty "custom
   shader" materials translate to a Principled BSDF with full-white emission,
   which washes the prop out to pure white regardless of its base texture.

5. metallicFactor >= 0.3 -> 0, and KHR_materials_specular stripped. Cascade has
   no reflection probes and a single hard sun, so a metallic Synty material
   renders near-black. Synty stylised assets are never actually metallic.

Deliberately not ported from godot-rts
--------------------------------------
* alphaMode BLEND -> MASK, and "opaque material whose base texture has an
  alpha channel -> MASK". Both exist to stop foliage cards depth-sorting badly
  under an isometric camera. Cascade has no foliage, and the space packs *do*
  legitimately want real blending for cockpit glass (SM_Chr_Attach_EVA_Cover_
  Clear_01, SM_Chr_Attach_Junker_Helmet_Glass_01), HUD holograms (SM_Hud_*) and
  engine flame cards (SM_Flame_Mesh_*). Alpha-testing those would harden the
  glass into opaque plates. A 60-file sample of the space packs found only
  3 MASK materials and 0 BLEND materials, so the rule had nothing to do anyway.
* strip_lods.gd (the EditorScenePostImport step). Synty's foliage packs ship
  stacked _LOD1/_LOD2 sibling mesh nodes inside one glTF; the space packs do
  not. 0 of 40 randomly sampled glTFs across POLYGON_Scifi_Space,
  POLYGON_SciFiWorlds, SIMPLE_Space and SIMPLE_Space_Interiors contain a
  _LODn node, and no filename in any of them mentions LOD. Adding the import
  script would be a project-wide no-op. Re-add it (copy
  ../godot-rts/scripts/import/strip_lods.gd, then set
  [importer_defaults] scene={"import_script/path": ...} in project.godot) if a
  future pack turns out to ship them.
"""
import json
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).parent.parent / "assets" / "meshes"

# Per-pack vertex units. "cm" -> the 0.01 root scale is correct, leave it.
# "m" -> vertices are already metres, the 0.01 is a cook artifact, strip it.
# Character cooks are always metres regardless of pack (see CHAR_MARKERS).
PACK_UNITS = {
    "POLYGON_Scifi_Space_SourceFiles_v2": "cm",
    "POLYGON_SciFiWorlds_SourceFiles_v4": "cm",
    "POLYGON_SciFi_City_SourceFiles_v5": "cm",
    "POLYGON_SciFi_Outpost_Map_SourceFiles_v1": "cm",
    "POLYGON_Particle_FX_SourceFiles_v2": "cm",
    "SIMPLE_Space_Source_Files": "m",
    "SIMPLE_Space_Interiors_SourceFiles": "m",
    "SIMPLE_Space_Characters_SourceFiles": "m",
    "SIMPLE_Sky_SourceFiles": "m",
}

# Skeletal cooks are metre-unit in every pack, unlike their SM_ static twins.
# Verified pairs: SM_Veh_Barge_01 raw extent 1822 (cm) vs SK_Veh_Barge_01 max
# coord 10.08 (m); SK_Chr_BR_EVA_Suit_01 T-pose 2.88 x 1.73 (m).
SKELETAL_PREFIX = "SK_"
SKELETAL_DIRS = ("Characters", "Unreal_Characters")

# Fallback for packs missing from PACK_UNITS: a max absolute vertex coordinate
# below this cannot be a centimetre-unit Synty asset (smallest cm-cook prop
# measured on the server is SM_Veh_Sweepo_01 at ~45 raw units; the largest
# metre-cook character is ~2.9), so the 0.01 is stray.
CM_COOK_THRESHOLD = 20.0

# POLYGON_Scifi_Space: signage atlas -> hull/panel atlas. See docstring #2.
# Only ..._Signs_Texture_01_A.png is remapped. ..._Signs_Texture_01_B.png (used
# by SM_Sign_* / SM_SignBorder_*) and ..._Texture_03_A.png (used by many
# SM_Bld_* interior pieces) are correct as cooked and left alone.
SIGNS_ATLAS = "PolygonSciFiSpace_Signs_Texture_01_A.png"
MAIN_ATLAS = "PolygonSciFiSpace_Texture_01_A.png"


def _pack_of(path: pathlib.Path) -> str:
    rel = path.relative_to(ROOT).parts
    return rel[0] if rel else ""


def _is_skeletal(path: pathlib.Path) -> bool:
    if path.name.startswith(SKELETAL_PREFIX):
        return True
    return any(part in SKELETAL_DIRS for part in path.relative_to(ROOT).parts)


def _max_abs_coord(g: dict) -> float:
    """Largest absolute POSITION coordinate, from accessor min/max — no .bin
    parsing needed."""
    extent = 0.0
    for mesh in g.get("meshes", []):
        for prim in mesh.get("primitives", []):
            pos_idx = prim.get("attributes", {}).get("POSITION")
            if pos_idx is None:
                continue
            acc = g["accessors"][pos_idx]
            for v in (acc.get("min") or []) + (acc.get("max") or []):
                extent = max(extent, abs(v))
    return extent


def _vertices_are_metres(path: pathlib.Path, g: dict) -> bool:
    if _is_skeletal(path):
        return True
    units = PACK_UNITS.get(_pack_of(path))
    if units == "m":
        return True
    if units == "cm":
        return False
    extent = _max_abs_coord(g)
    return extent != 0.0 and extent < CM_COOK_THRESHOLD


def _fix_stray_unit_scale(path: pathlib.Path, g: dict) -> bool:
    """Strip the 0.01 root-node scale when the vertices are already in
    metres (docstring #1). Only root nodes named by a scene are touched, so
    intentional child scaling survives."""
    if not _vertices_are_metres(path, g):
        return False
    changed = False
    for scene in g.get("scenes", []):
        for node_idx in scene.get("nodes", []):
            node = g["nodes"][node_idx]
            scale = node.get("scale")
            if scale and all(abs(s - 0.01) < 1e-4 for s in scale):
                del node["scale"]
                changed = True
    return changed


def _fix_atlas(path: pathlib.Path, g: dict) -> bool:
    """Repoint POLYGON_Scifi_Space cooks off the signage atlas (docstring #2)."""
    if _pack_of(path) != "POLYGON_Scifi_Space_SourceFiles_v2":
        return False
    changed = False
    for img in g.get("images", []):
        uri = img.get("uri", "")
        if uri.endswith(SIGNS_ATLAS):
            img["uri"] = uri[: -len(SIGNS_ATLAS)] + MAIN_ATLAS
            changed = True
    return changed


def _fix_materials(g: dict) -> bool:
    """docstrings #3, #4, #5."""
    max_idx = max(len(g.get("images", [])) - 1, 0)
    changed = False
    for mat in g.get("materials", []):
        pbr = mat.get("pbrMetallicRoughness", {})
        bct = pbr.get("baseColorTexture")

        if bct is not None and bct.get("index", 0) > max_idx:
            bct["index"] = max_idx
            changed = True

        if "emissiveFactor" in mat and "emissiveTexture" not in mat:
            del mat["emissiveFactor"]
            changed = True

        if bct is not None and pbr.get("metallicFactor", 0) >= 0.3:
            pbr["metallicFactor"] = 0
            changed = True

        if "KHR_materials_specular" in mat.get("extensions", {}):
            del mat["extensions"]["KHR_materials_specular"]
            if not mat["extensions"]:
                del mat["extensions"]
            changed = True
    return changed


def patch_file(path: pathlib.Path) -> list[str]:
    with open(path) as f:
        g = json.load(f)

    fixes = []
    if _fix_stray_unit_scale(path, g):
        fixes.append("unit-scale")
    if _fix_atlas(path, g):
        fixes.append("atlas")
    if _fix_materials(g):
        fixes.append("materials")

    if not fixes:
        return []

    with open(path, "w") as f:
        json.dump(g, f, separators=(",", ":"))

    sidecar = path.with_suffix(path.suffix + ".import")
    if sidecar.exists():
        sidecar.unlink()

    return fixes


def main():
    if not ROOT.exists():
        print(f"assets/meshes/ not found at {ROOT} — run fetch_assets.sh first")
        sys.exit(0)

    patched = 0
    for gltf in sorted(ROOT.rglob("*.gltf")):
        fixes = patch_file(gltf)
        if fixes:
            print(f"patched  {gltf.relative_to(ROOT)}  [{', '.join(fixes)}]")
            patched += 1

    print(f"{patched} file(s) patched.")


if __name__ == "__main__":
    main()
