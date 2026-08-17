#!/usr/bin/env python3
"""
Fetch any texture a glTF on disk references but that is not present locally.

Needed because the patcher reassigns textures from each pack's MaterialList
(see tools/patch_gltf_materials.py), and the corrected texture is often one the
original cook never mentioned — so it was never in the fetch closure. For assets
the project actually references, resolve_assets.py's second pass picks those up.
For a whole-pack browsing set it does not, because those files are not reachable
from scenes/ or scripts/, and Godot then logs an import error per dangling image.

Run: python3 tools/fetch_missing_textures.py
Called by fetch_assets.sh after the patcher.
"""

import json
import os
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request

SERVER = os.environ.get("ASSET_SERVER", "http://srv.blastedstudios.com:49200")
DEST = pathlib.Path(os.environ.get("DEST", "assets/meshes"))
SERVER_PREFIX = "assets"
TIMEOUT = 120


def referenced_textures() -> set[pathlib.Path]:
    """Every image path referenced by any glTF under DEST, resolved."""
    wanted: set[pathlib.Path] = set()
    for gltf in DEST.rglob("*.gltf"):
        try:
            doc = json.loads(gltf.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        for image in doc.get("images", []):
            uri = image.get("uri")
            if not uri or uri.startswith("data:"):
                continue
            wanted.add((gltf.parent / urllib.parse.unquote(uri)).resolve())
    return wanted


def _raw_fallback(rel: pathlib.PurePath) -> bytes | None:
    """Find a texture in the server's raw tree when the cooked path 404s.

    The cooker copies only top-level textures, but packs file plenty of them in
    subdirectories (Misc/, Alts/, Emissive/, FX/, Signs/) — and a MaterialList
    names the stem alone, so those are exactly the ones it points at.
    """
    parts = list(rel.parts)
    if "Textures" not in parts:
        return None
    tex_root = parts[: parts.index("Textures") + 1]
    base = f"{SERVER}/raw/" + urllib.parse.quote("/".join(tex_root)) + "/"
    try:
        with urllib.request.urlopen(base, timeout=TIMEOUT) as response:
            listing = response.read().decode("utf-8", "replace")
    except (urllib.error.URLError, urllib.error.HTTPError):
        return None
    import re as _re

    subdirs = [d for d in _re.findall(r'href="([^"]+/)"', listing) if d != "../"]
    for subdir in subdirs:
        url = base + urllib.parse.quote(subdir.strip("/")) + "/" + urllib.parse.quote(rel.name)
        try:
            with urllib.request.urlopen(url, timeout=TIMEOUT) as response:
                return response.read()
        except (urllib.error.URLError, urllib.error.HTTPError):
            continue
    return None


def main() -> None:
    if not DEST.exists():
        print(f"{DEST} not found — nothing to do")
        return

    dest_root = DEST.resolve()
    missing = sorted(p for p in referenced_textures() if not p.exists())
    if not missing:
        print("0 missing textures.")
        return

    fetched = 0
    for path in missing:
        try:
            rel = path.relative_to(dest_root)
        except ValueError:
            print(f"  ! outside {DEST}, skipped: {path}")
            continue
        url = f"{SERVER}/{SERVER_PREFIX}/{urllib.parse.quote(str(rel))}"
        try:
            with urllib.request.urlopen(url, timeout=TIMEOUT) as response:
                data = response.read()
        except (urllib.error.URLError, urllib.error.HTTPError) as e:
            data = _raw_fallback(rel)
            if data is None:
                print(f"  ! {rel}: {e}")
                continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        print(f"  fetched {rel}")
        fetched += 1

    print(f"{fetched}/{len(missing)} missing texture(s) fetched.")


if __name__ == "__main__":
    sys.exit(main())
