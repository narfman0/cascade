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

2. Wrong texture assignment on the cooked glTFs, fixed from the pack's own
   MaterialList. Every Synty pack ships MaterialList_<Pack>.txt at its source
   root: the mesh -> material -> texture mapping exported from the Unity project
   the UVs were authored in. tools/fetch_material_lists.py pulls it from the
   server's /raw/ tree (the cooker does not carry it across).

   The cooks disagree with it badly. In POLYGON_Scifi_Space roughly 80% of
   glTFs name PolygonSciFiSpace_Signs_Texture_01_A.png — a 1024x1024 signage
   sheet, black field with white door pictograms — for hull geometry whose UVs
   target the 2048x2048 PolygonSciFiSpace_Texture_01_A.png panel atlas. Left
   alone, hulls, crates, debris and ships all import near-black with stray
   glyphs on them.

   An earlier version of this script remapped that atlas unconditionally for the
   pack. The MaterialList shows why that was wrong: 47 meshes (SM_Sign_* /
   SM_SignBorder_*) genuinely do use a signage sheet, and the one they use is
   ..._Signs_Texture_01_B.png — so the cooks have the wrong *variant* even where
   they have the right family (the pack ships _01_A through _01_F). Driving the
   assignment from the list is right by construction and needs no per-pack
   policy: 828 space meshes across 5 distinct textures, 1978 SciFiWorlds meshes
   across 37, all resolved from data.

   Slots reading "Uses custom shader" or "No Albedo Texture" are left untouched.

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
import re
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

# Texture assignment comes from each pack's MaterialList_*.txt (fetched by
# tools/fetch_material_lists.py), which is the mapping exported from the original
# Unity project. See docstring #2.
#
# Slot values that name no usable albedo texture — leave these materials alone.
MATLIST_SKIP = {
    "Uses custom shader",
    "No Albedo Texture",
    "None",
}

# Cache of pack name -> {mesh name: [texture stem per material slot]}.
_MATLIST_CACHE: dict[str, dict[str, list[str]]] = {}
_MATLIST_MISSING: set[str] = set()

_MATLIST_MESH = re.compile(r"^Mesh Name:\s*(.+?)\s*$")
_MATLIST_SLOT = re.compile(r"^Slot:\s*(.+?)\s*\((.+?)\)\s*$")


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
    intentional child scaling survives.

    NEVER strip it from a SKINNED cook. The character cooks keep their
    skeleton joints and inverse bind matrices in centimetres even when the
    mesh vertices are metres, and glTF skinning runs in the skeleton's space
    — the 0.01 root is what brings the skinned result back to metres.
    Stripping it explodes the limbs ~100x the moment the skeleton drives the
    mesh (the giant-EVA-suit bug), while every REST-space check still reads
    1.73 m, because a skinned mesh's AABB cannot see skinning. Verified
    empirically on SK_Chr_BR_EVA_Suit_01: root restored -> correct 1.73 m
    posed figure; root stripped -> exploded."""
    if g.get("skins"):
        return False
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


def _load_material_list(pack: str) -> dict[str, list[str]]:
    """Parse a pack's MaterialList into {mesh name: [texture stem per slot]}.

    Slot order in the list is Unity's material-slot order, which is the same
    order as a glTF mesh's primitives — so slot N belongs to primitive N.
    """
    if pack in _MATLIST_CACHE:
        return _MATLIST_CACHE[pack]

    mapping: dict[str, list[str]] = {}
    candidates = sorted((ROOT / pack).glob("*/MaterialList*.txt"))
    if not candidates:
        if pack not in _MATLIST_MISSING:
            _MATLIST_MISSING.add(pack)
            print(
                f"  ! no MaterialList for {pack} — textures left as cooked."
                " Run tools/fetch_material_lists.py"
            )
        _MATLIST_CACHE[pack] = mapping
        return mapping

    mesh = None
    for line in candidates[0].read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        m = _MATLIST_MESH.match(stripped)
        if m:
            mesh = m.group(1)
            mapping.setdefault(mesh, [])
            continue
        m = _MATLIST_SLOT.match(stripped)
        if m and mesh is not None:
            mapping[mesh].append(m.group(2))

    _MATLIST_CACHE[pack] = mapping
    return mapping


def _mesh_name_candidates(path: pathlib.Path, g: dict) -> dict[int, list[str]]:
    """Names to try against the MaterialList, per mesh index.

    The cooker runs meshes through Blender, which renames them "Mesh",
    "Mesh.001" and so on — the original asset name survives only on the node
    that references the mesh. Single-mesh files fall back to the filename, which
    is the asset name.
    """
    candidates: dict[int, list[str]] = {}
    for node in g.get("nodes", []):
        mesh_index = node.get("mesh")
        name = node.get("name")
        if mesh_index is None or not name:
            continue
        candidates.setdefault(mesh_index, []).append(name)
    for i in range(len(g.get("meshes", []))):
        candidates.setdefault(i, []).append(path.stem)
    return candidates


def _texture_uri(path: pathlib.Path, pack: str, stem: str) -> str | None:
    """Relative URI from a glTF to a texture stem, if the file exists."""
    tex_dirs = sorted((ROOT / pack).glob("*/Textures"))
    # A MaterialList names only the texture stem, and packs file textures in
    # subdirectories (Misc/, Alts/, Emissive/, FX/, Signs/) that the cooker does
    # not copy to the top level — so search the whole pack, not just Textures/.
    for tex_dir in tex_dirs:
        for candidate in sorted(tex_dir.rglob(f"{stem}.png")):
            return os.path.relpath(candidate, path.parent).replace(os.sep, "/")
    # Not fetched yet: still emit the conventional path so resolve_assets.py
    # picks it up on its second pass.
    if tex_dirs:
        return os.path.relpath(tex_dirs[0] / f"{stem}.png", path.parent).replace(
            os.sep, "/"
        )
    return None


def _image_for_uri(g: dict, uri: str) -> int:
    """Index of the image with this URI, appending one if absent."""
    images = g.setdefault("images", [])
    for i, img in enumerate(images):
        if img.get("uri") == uri:
            return i
    images.append({"uri": uri})
    return len(images) - 1


def _texture_for_image(g: dict, image_index: int) -> int:
    """Index of a texture pointing at this image, appending one if absent."""
    textures = g.setdefault("textures", [])
    for i, tex in enumerate(textures):
        if tex.get("source") == image_index:
            return i
    entry: dict = {"source": image_index}
    # Reuse an existing sampler so filtering/wrapping stays consistent.
    for tex in textures:
        if "sampler" in tex:
            entry["sampler"] = tex["sampler"]
            break
    textures.append(entry)
    return len(textures) - 1


def _fix_atlas(path: pathlib.Path, g: dict) -> bool:
    """Point every material at the texture its MaterialList entry names.

    The cooked glTFs are unreliable here: in POLYGON_Scifi_Space roughly 80% of
    them name a signage atlas for hull geometry, and even the genuine sign props
    get the wrong colour variant (..._01_A instead of the ..._01_B the list
    specifies). Rather than guess with a per-pack rule, take the mapping from the
    pack's own MaterialList — it is exported from the project the UVs were
    authored in, so it is right by construction and needs no per-pack policy.
    """
    pack = _pack_of(path)
    mapping = _load_material_list(pack)
    if not mapping:
        return False

    names = _mesh_name_candidates(path, g)
    changed = False
    for mesh_index, mesh in enumerate(g.get("meshes", [])):
        slots = None
        for candidate in names.get(mesh_index, []):
            slots = mapping.get(candidate)
            if slots:
                break
        if not slots:
            continue
        for slot_index, prim in enumerate(mesh.get("primitives", [])):
            if slot_index >= len(slots):
                break
            stem = slots[slot_index]
            if stem in MATLIST_SKIP:
                continue
            mat_index = prim.get("material")
            if mat_index is None or mat_index >= len(g.get("materials", [])):
                continue
            uri = _texture_uri(path, pack, stem)
            if uri is None:
                continue

            pbr = g["materials"][mat_index].setdefault("pbrMetallicRoughness", {})
            bct = pbr.get("baseColorTexture")
            tex_index = _texture_for_image(g, _image_for_uri(g, uri))
            if bct is None:
                pbr["baseColorTexture"] = {"index": tex_index}
                changed = True
            elif bct.get("index") != tex_index:
                bct["index"] = tex_index
                changed = True

    if changed:
        _drop_orphan_images(g)
    return changed


def _drop_orphan_images(g: dict) -> None:
    """Remove images/textures nothing references any more, reindexing what is
    left. Keeps the cooks from accumulating dead atlas references each run,
    which would make the patcher non-idempotent."""
    used_tex = set()
    for mat in g.get("materials", []):
        for block in (mat, mat.get("pbrMetallicRoughness", {})):
            for key in ("baseColorTexture", "emissiveTexture", "normalTexture",
                        "occlusionTexture", "metallicRoughnessTexture"):
                ref = block.get(key) if isinstance(block, dict) else None
                if isinstance(ref, dict) and "index" in ref:
                    used_tex.add(ref["index"])

    textures = g.get("textures", [])
    keep_tex = [i for i in range(len(textures)) if i in used_tex]
    if len(keep_tex) == len(textures):
        return
    tex_remap = {old: new for new, old in enumerate(keep_tex)}
    g["textures"] = [textures[i] for i in keep_tex]

    used_img = {textures[i].get("source") for i in keep_tex}
    images = g.get("images", [])
    keep_img = [i for i in range(len(images)) if i in used_img]
    img_remap = {old: new for new, old in enumerate(keep_img)}
    g["images"] = [images[i] for i in keep_img]
    for tex in g["textures"]:
        if "source" in tex and tex["source"] in img_remap:
            tex["source"] = img_remap[tex["source"]]

    for mat in g.get("materials", []):
        for block in (mat, mat.get("pbrMetallicRoughness", {})):
            if not isinstance(block, dict):
                continue
            for key in ("baseColorTexture", "emissiveTexture", "normalTexture",
                        "occlusionTexture", "metallicRoughnessTexture"):
                ref = block.get(key)
                if isinstance(ref, dict) and ref.get("index") in tex_remap:
                    ref["index"] = tex_remap[ref["index"]]


def _fix_materials(g: dict) -> bool:
    """docstrings #3, #4, #5."""
    max_idx = max(len(g.get("textures", [])) - 1, 0)
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
