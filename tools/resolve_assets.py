#!/usr/bin/env python3
"""
Used-only asset resolver: scan the project for res:// references into
assets/meshes/, fetch each referenced glTF from the asset server, then follow
its .bin and texture URIs until the dependency closure is satisfied.

Invoked by fetch_assets.sh (twice — once before tools/patch_gltf_materials.py
and once after, because the patcher's atlas remap can introduce a reference to
a texture that was not part of the original closure). Idempotent: files already
on disk are never re-downloaded.

Env: ASSET_SERVER (default http://srv.blastedstudios.com:49200), DEST
(default assets/meshes). Run from the project root.
"""
import glob
import json
import os
import re
import sys
import urllib.parse
import urllib.request

SERVER = os.environ.get("ASSET_SERVER", "http://srv.blastedstudios.com:49200")
DEST = os.environ.get("DEST", "assets/meshes")
LOCAL_PREFIX = DEST + "/"       # local  path:  assets/meshes/<rest>
SERVER_PREFIX = "assets/"       # server path:  assets/<rest>

# Directories scanned for references. .tscn ExtResource lines, .gd
# preload/load calls and .tres Resource properties all name meshes as plain
# quoted res:// strings, so one literal pattern covers the majority.
SCAN_DIRS = ("scenes", "scripts", "resources")


def local_to_server(fs: str) -> str:
    return SERVER_PREFIX + fs[len(LOCAL_PREFIX):]


def find_references() -> set[str]:
    referenced: set[str] = set()

    # 1) literal res://assets/meshes/....(gltf|glb|png) anywhere in the project.
    #    Allow spaces — Synty cooked dirs like "Source Files/FBX" contain them;
    #    paths are always quoted so the quote bounds the match. .glb is matched
    #    so a hand-authored reference still resolves, but nothing in Cascade
    #    should reference one (the .glb cooks are untextured — see
    #    docs/assets.md).
    for base in SCAN_DIRS:
        for f in glob.glob(base + "/**/*", recursive=True):
            if not os.path.isfile(f):
                continue
            txt = open(f, encoding="utf-8", errors="ignore").read()
            for m in re.findall(r'res://assets/meshes/[^"\'\n]+?\.(?:gltf|glb|png)', txt):
                referenced.add(m.replace("res://", "", 1))

    # 2) dir-const + bare-filename pattern: any .gd that defines a
    #    res://assets/meshes/... directory string gets its quoted *.gltf/*.glb
    #    basenames resolved against every such directory in the file. This is
    #    how a debris-prop table ("one const for the pack dir, then a list of
    #    names") stays readable. Accepts `:=`, `=` and `const X =` forms —
    #    godot-rts only matched `:=`, which silently missed untyped consts.
    for f in glob.glob("scripts/**/*.gd", recursive=True):
        txt = open(f, encoding="utf-8", errors="ignore").read()
        dirs = re.findall(r'=\s*"res://assets/meshes/([^"]+/)"', txt)
        if not dirs:
            continue
        for name in re.findall(r'"([A-Za-z0-9_.\-]+\.(?:gltf|glb))"', txt):
            for d in dirs:
                referenced.add("assets/meshes/" + d + name)

    return referenced


def http_get(server_path: str, out_fs: str) -> None:
    os.makedirs(os.path.dirname(out_fs), exist_ok=True)
    url = f"{SERVER}/{urllib.parse.quote(server_path)}"
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    with open(out_fs, "wb") as fh:
        fh.write(data)


def main() -> None:
    closure: set[str] = set()
    seen: set[str] = set()

    def ensure(fs: str) -> None:
        if fs in seen:
            return
        seen.add(fs)
        closure.add(fs)
        if not os.path.isfile(fs):
            try:
                http_get(local_to_server(fs), fs)
                print(f"  fetched {fs[len(LOCAL_PREFIX):]}")
            except Exception as e:
                print(f"  MISS {fs[len(LOCAL_PREFIX):]}  ({e})", file=sys.stderr)
                return
        if fs.endswith(".gltf"):
            try:
                d = json.load(open(fs))
            except Exception:
                return
            base = os.path.dirname(fs)
            for section in ("buffers", "images"):
                for item in d.get(section, []):
                    uri = item.get("uri")
                    if uri and not uri.startswith("data:"):
                        ensure(os.path.normpath(
                            os.path.join(base, urllib.parse.unquote(uri))))

    for r in sorted(find_references()):
        ensure(r)

    have = sum(1 for p in closure if os.path.isfile(p))
    size = sum(os.path.getsize(p) for p in closure if os.path.isfile(p))
    print(f"Reference closure: {have}/{len(closure)} files present, "
          f"{size / 1024 / 1024:.1f} MB.")


if __name__ == "__main__":
    main()
