#!/usr/bin/env python3
"""
Fetch each pack's MaterialList_*.txt from the asset server's raw tree.

Every Synty pack ships a MaterialList at its source root — a plain-text dump of
the authoritative mesh -> material -> texture mapping straight out of the
original Unity project:

    Prefab Name: SM_Veh_Part_Body_03
        Mesh Name: SM_Veh_Part_Body_03
            Slot: PolygonScifiSpace_Material_01_A (PolygonSciFiSpace_Texture_01_A)

This is the ground truth the cooked glTFs get wrong (see
tools/patch_gltf_materials.py). It lives only in the *raw* tree, because the
cooker converts meshes and copies textures but does not carry documentation
across — so it is fetched from /raw/ rather than /assets/.

Run: python3 tools/fetch_material_lists.py
Called by fetch_assets.sh before the patcher.
"""

import os
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

SERVER = os.environ.get("ASSET_SERVER", "http://srv.blastedstudios.com:49200")
DEST = pathlib.Path(os.environ.get("DEST", "assets/meshes"))
TIMEOUT = 60


def _get(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
        return r.read()


def _listing(url: str) -> list[str]:
    """Entries from an nginx autoindex page."""
    try:
        html = _get(url).decode("utf-8", "replace")
    except (urllib.error.URLError, urllib.error.HTTPError) as e:
        print(f"  ! cannot list {url}: {e}")
        return []
    return [
        urllib.parse.unquote(h)
        for h in re.findall(r'href="([^"]+)"', html)
        if h not in ("../", "/")
    ]


def fetch_for_pack(pack: str) -> int:
    """Fetch every MaterialList under a pack's source dir. Returns count."""
    base = f"{SERVER}/raw/{urllib.parse.quote(pack)}/"
    found = 0
    # The source directory's capitalisation is inconsistent across packs
    # ("SourceFiles" vs "Sourcefiles" vs "Source Files"), so discover it.
    for entry in _listing(base):
        if not entry.endswith("/"):
            continue
        src_url = base + urllib.parse.quote(entry)
        for name in _listing(src_url):
            if not re.match(r"MaterialList.*\.txt$", name, re.IGNORECASE):
                continue
            out = DEST / pack / entry.rstrip("/") / name
            if out.exists():
                found += 1
                continue
            out.parent.mkdir(parents=True, exist_ok=True)
            try:
                out.write_bytes(_get(src_url + urllib.parse.quote(name)))
            except (urllib.error.URLError, urllib.error.HTTPError) as e:
                print(f"  ! {pack}/{name}: {e}")
                continue
            print(f"  fetched {pack}/{entry}{name}")
            found += 1
    return found


def main() -> None:
    if not DEST.exists():
        print(f"{DEST} not found — nothing to do")
        return
    packs = sorted(p.name for p in DEST.iterdir() if p.is_dir())
    if not packs:
        print("no packs fetched yet — nothing to do")
        return
    total = 0
    for pack in packs:
        total += fetch_for_pack(pack)
    print(f"{total} material list(s) available.")


if __name__ == "__main__":
    sys.exit(main())
