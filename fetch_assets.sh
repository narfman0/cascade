#!/usr/bin/env bash
# Sync cooked Synty meshes/textures from the asset server into assets/meshes/.
# The asset server is the source of truth; fetched files are .gitignore'd.
# Ported from godot-rts (which got it from wayfarer) and retargeted to the
# space packs Cascade draws from. See docs/assets.md for the curated manifest.
#
# Two modes:
#   ./fetch_assets.sh                     # DEFAULT: fetch only what the
#                                         #   project references, plus each
#                                         #   glTF's .bin + textures.
#   ./fetch_assets.sh --pack scifi_space  # whole-pack fetch (for browsing a
#                                         #   pack you're about to author with).
#                                         #   No args after --pack = the
#                                         #   DEFAULT_PACKS set below.
#
# Cascade-specific deviations from the godot-rts original (all deliberate):
#   * .glb is NOT fetched. The space-pack .glb cooks have their `images` array
#     stripped, so every material loses its baseColorTexture and the prop
#     imports flat grey. The .gltf + .bin + shared Textures/*.png triple is the
#     only textured form. (Verified on SM_Veh_Part_Body_03.glb: 0 images,
#     0 textures, material "SciFi11" with no baseColorTexture.)
#   * Characters/Unreal_Characters/ duplicates are skipped — same skeletal mesh
#     as Characters/, but cooked pointing at the *Signs* atlas.
set -euo pipefail

cd "$(dirname "$0")"

SERVER="${ASSET_SERVER:-http://srv.blastedstudios.com:49200}"
DEST="assets/meshes"

# The space set. POLYGON_Scifi_Space is the spine; SciFiWorlds supplies the
# scrap/satellite/antenna vocabulary; SIMPLE_Space supplies real-world
# satellites, solar panels and planets (different, flatter art style — mix
# knowingly). Particle_FX is thruster/spark support.
# Deliberately absent: `_skies` and SIMPLE_Sky. Both are terrestrial daylight
# panoramas (blue sky over a brown ground plane) — there is no starfield on the
# server. Build the orbital sky in-engine. See docs/assets.md §4.4.
# POLYGON only — the art family is decided (docs/assets.md section 5). The
# SIMPLE_Space* packs are deliberately absent: their flat, near-untextured look
# does not sit in the same shot as POLYGON's panel detail.
# POLYGON_SciFi_City / POLYGON_City joined at PR3 for the New York detail site
# (docs/planet-renderer.md). SciFi_City is the one that matters: its
# SM_Bld_Background_* meshes are purpose-built skyline filler — single-material,
# a few hundred triangles, no interiors — which is exactly what a 400 m diorama
# of Manhattan wants. POLYGON_City is the near-ground variety set, unused so far.
DEFAULT_PACKS=(
	POLYGON_Scifi_Space
	POLYGON_SciFiWorlds
	POLYGON_SciFi_Outpost_Map
	POLYGON_Particle_FX
	POLYGON_SciFi_City
	POLYGON_City
)

# ── whole-pack mode ───────────────────────────────────────────────────────────
if [[ "${1:-}" == "--pack" || "${1:-}" == "--all" ]]; then
	shift
	if [[ $# -gt 0 ]]; then PACKS=("$@"); else PACKS=("${DEFAULT_PACKS[@]}"); fi
	index=$(curl -fsS --max-time 120 "$SERVER/index.json")
	for pack in "${PACKS[@]}"; do
		echo "== $pack"
		echo "$index" | PACK="$pack" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
pack = os.environ['PACK'].lower()
for p in d['cooked']['packs']:
    if pack in p['name'].lower():
        for f in p['files']:
            path = f['path']
            # .glb cooks are untextured here — see header comment.
            if not path.endswith(('.gltf', '.bin', '.png')):
                continue
            if '/Unreal_Characters/' in path:
                continue
            print(path)
" | while IFS= read -r path; do
			out="$DEST/${path#assets/}"
			[[ -f "$out" ]] && continue
			mkdir -p "$(dirname "$out")"
			# Pack paths contain spaces ("Source Files") — encode for the URL.
			enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$path")
			curl -fsS --max-time 120 -o "$out" "$SERVER/$enc"
			echo "  fetched ${path#assets/}"
		done
	done
	python3 tools/fetch_material_lists.py || true
	python3 tools/patch_gltf_materials.py || true
	python3 tools/fetch_missing_textures.py || true
	echo "Done. Run: godot --headless --import"
	exit 0
fi

# ── used-only mode (default): resolve the reference closure and fetch it ───────
# tools/resolve_assets.py scans scenes/ scripts/ resources/ for res:// paths
# into assets/meshes/ and pulls each glTF's .bin + textures. It runs twice:
# the patcher's atlas remap (see tools/patch_gltf_materials.py) can introduce a
# reference to a texture that was not in the first closure.
export ASSET_SERVER="$SERVER" DEST="$DEST"
python3 tools/resolve_assets.py
# Texture assignment is taken from each pack's MaterialList (see docs/assets.md
# section 3), so it has to be on disk before the patcher runs.
python3 tools/fetch_material_lists.py
python3 tools/patch_gltf_materials.py
# The patcher can name a texture the original cook never referenced, so it was
# never in the closure. resolve_assets covers referenced assets; this covers
# whole-pack browsing sets too.
python3 tools/resolve_assets.py
python3 tools/fetch_missing_textures.py
echo "Done. Run: godot --headless --import"
