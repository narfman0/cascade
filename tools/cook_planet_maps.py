#!/usr/bin/env python3
"""
Cook the committed coarse global planet maps in assets/planets/ from public
scientific rasters (PR3, docs/planet-renderer.md "Height sources").

Run:  python3 tools/cook_planet_maps.py [--only earth|moon|mars|nyc]

This is a one-shot cook, not part of the runtime or of fetch_assets.sh. The
outputs are committed; the multi-hundred-megabyte inputs are not. Re-run it only
if a source is updated or an encoding constant below changes.

Sources (all public domain / open, no registration)
---------------------------------------------------
  Earth height   NOAA NCEI ETOPO 2022, 60 arc-second, surface elevation
                 (bedrock+ice surface incl. bathymetry), netCDF float32
                 https://www.ngdc.noaa.gov/thredds/fileServer/global/ETOPO2022/
                   60s/60s_surface_elev_netcdf/ETOPO_2022_v1_60s_N90W180_surface.nc
  Earth albedo   NASA Visible Earth, Blue Marble Next Generation with
                 Topography and Bathymetry (Dec 2004), 5400x2700
                 .../imagerecords/73000/73909/world.topo.bathy.200412.3x5400x2700.jpg
  Earth night    NASA Earth Observatory Black Marble 2016, 0.1 deg, 3600x1800
                 .../imagerecords/144000/144898/BlackMarble_2016_01deg_geo.tif
  Moon  height   NASA SVS CGI Moon Kit (id 4720), LOLA LDEM 16 px/deg,
                 float32 kilometres, 5760x2880 -- vis/a000000/a004700/a004720/ldem_16.tif
  Moon  albedo   NASA SVS CGI Moon Kit, LROC WAC colour w/ poles, 2048x1024
                 -- vis/a000000/a004700/a004720/lroc_color_poles_2k.tif
  Mars  height   PDS MGS MOLA MEGDR 16 px/deg, MSB int16 metres, 5760x2880
                 https://pds-geosciences.wustl.edu/mgs/mgs-m-mola-5-megdr-l3-v1/
                   mgsl_300x/meg016/megt90n000eb.img
  Mars  albedo   USGS Astrogeology Viking colourised global mosaic, 925 m/px
                 https://planetarymaps.usgs.gov/mosaic/Mars_Viking_ClrMosaic_global_925m.tif
  NYC inset      AWS Open Data "Terrain Tiles" (terrarium encoding; SRTM/NED
                 composite, public domain) https://s3.amazonaws.com/elevation-tiles-prod/

Output conventions (these are what the engine assumes -- docs/assets.md 7)
--------------------------------------------------------------------------
  * 2048x1024 equirectangular, column 0 = longitude -180 deg, row 0 = +90 deg
    latitude. That is exactly the game's lookup: lon = atan2(dir.z, dir.x),
    lat = asin(dir.y), u = 0.5 + lon/TAU, v = 0.5 - lat/PI
    (BodySurface.HeightSampler._sample_equirect and planet_surface.gdshader).
  * Height maps carry 16 bits SPLIT ACROSS TWO 8-BIT CHANNELS -- red is the
    high byte, green the low byte, blue unused:
        p = (R*256 + G) / 65535        (BodySurface._decode_height)
    Godot's PNG importer does not preserve a true 16-bit greyscale PNG, and a
    single 8-bit channel would quantise Earth's +-40 m of relief into 0.31 m
    terraces -- coarser than the depth-7 vertex spacing the geometry can express.
    Two channels give ~1 mm. These maps are read with `get_image()` and never
    assigned to a material, so the importer's detect-3d VRAM compression (which
    would corrupt the split) never fires; tests/planet_test.gd asserts the
    decoded map still agrees with the raster.
  * p in [0,1] means normalized height n = 2p - 1 in [-1,1], the same range
    BodySurface's procedural noise produces, so `amplitude` and `sea_level`
    keep their meanings.
  * n is a SIGNED POWER of true elevation, not a linear ramp:
        n = sign(e) * (|e| / ref_side) ** GAMMA
    with separate positive/negative reference elevations per body. GAMMA < 1
    lifts low ground so relief reads at Cascade's compressed scale -- the
    stylization the design doc commits to ("relief is exaggerated"). The zero
    crossing is exact, so for Earth n = 0 is mean sea level and BodySurface's
    `sea_level` can simply be 0.0: the coastline is the datum, not a tuned
    constant.
"""

import argparse
import io
import math
import os
import sys
import urllib.request

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "assets", "planets")
RAW = os.environ.get("CASCADE_PLANET_RAW", "/tmp/cascade_planet_raw")

WIDTH, HEIGHT = 2048, 1024

# Exponent applied to |elevation| before encoding. 1.0 would be a linear ramp;
# 0.6 lifts the low ground that dominates every real body so it reads as relief
# at a 2,000 m Earth radius. See the module docstring.
GAMMA = 0.6

SOURCES = {
    "etopo": ("https://www.ngdc.noaa.gov/thredds/fileServer/global/ETOPO2022/60s/"
              "60s_surface_elev_netcdf/ETOPO_2022_v1_60s_N90W180_surface.nc"),
    "bluemarble": ("https://eoimages.gsfc.nasa.gov/images/imagerecords/73000/73909/"
                   "world.topo.bathy.200412.3x5400x2700.jpg"),
    "blackmarble": ("https://eoimages.gsfc.nasa.gov/images/imagerecords/144000/144898/"
                    "BlackMarble_2016_01deg_geo.tif"),
    "ldem": "https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/ldem_16.tif",
    "lroc": "https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/lroc_color_poles_2k.tif",
    "mola": ("https://pds-geosciences.wustl.edu/mgs/mgs-m-mola-5-megdr-l3-v1/"
             "mgsl_300x/meg016/megt90n000eb.img"),
    "viking": "https://planetarymaps.usgs.gov/mosaic/Mars_Viking_ClrMosaic_global_925m.tif",
    "clouds": ("https://eoimages.gsfc.nasa.gov/images/imagerecords/57000/57747/"
               "cloud_combined_2048.jpg"),
    "bsc5": "http://tdc-www.harvard.edu/catalogs/bsc5.dat.gz",
}


def fetch(name):
    """Download a source raster into RAW once. Returns the local path."""
    url = SOURCES[name]
    os.makedirs(RAW, exist_ok=True)
    path = os.path.join(RAW, name + os.path.splitext(url)[1])
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return path
    print("  fetching %s -> %s" % (url, path))
    urllib.request.urlretrieve(url, path)
    return path


# --- encoding -----------------------------------------------------------------

def encode_height(elev_m, pos_ref, neg_ref):
    """Metres of true elevation -> normalized height n in [-1, 1]."""
    up = np.clip(elev_m, 0.0, None) / float(pos_ref)
    down = np.clip(-elev_m, 0.0, None) / float(neg_ref)
    n = np.power(np.clip(up, 0.0, 1.0), GAMMA) - np.power(np.clip(down, 0.0, 1.0), GAMMA)
    return np.clip(n, -1.0, 1.0)


def save_height(n, path):
    """16 bits of height in the red/green channels of an RGB8 PNG."""
    v = np.round(np.clip((n + 1.0) * 0.5, 0.0, 1.0) * 65535.0).astype(np.uint32)
    rgb = np.zeros(v.shape + (3,), dtype=np.uint8)
    rgb[:, :, 0] = (v >> 8).astype(np.uint8)
    rgb[:, :, 1] = (v & 0xFF).astype(np.uint8)
    img = Image.fromarray(rgb, mode="RGB")
    img.save(path, optimize=True)
    print("  wrote %s (%dx%d, 16-bit split R:G)" % (path, img.width, img.height))


def resize_f32(a, w=WIDTH, h=HEIGHT):
    """Area-average a float field down to the target grid."""
    return np.asarray(
        Image.fromarray(a.astype(np.float32), mode="F").resize((w, h), Image.BOX),
        dtype=np.float32,
    )


def save_rgb(img, path, w=WIDTH, h=HEIGHT):
    img = img.convert("RGB").resize((w, h), Image.LANCZOS)
    img.save(path, optimize=True)
    print("  wrote %s (%dx%d, RGB8)" % (path, img.width, img.height))


# --- bodies -------------------------------------------------------------------

def cook_earth():
    import netCDF4

    print("Earth")
    ds = netCDF4.Dataset(fetch("etopo"))
    lat = ds.variables["lat"][:]
    z = ds.variables["z"]
    # ETOPO ships south-up (lat ascending) on a -180..180 longitude grid, which
    # is our column convention already; only the row order needs flipping.
    elev = np.asarray(z[:, :], dtype=np.float32)
    if lat[0] < lat[-1]:
        elev = elev[::-1, :]
    ds.close()
    print("  ETOPO %s  min %.0f m  max %.0f m" % (elev.shape, elev.min(), elev.max()))

    small = resize_f32(elev)
    # Area-averaging a DEM across a coastline pulls shoreline cells below zero
    # and erodes islands. Rebuild the land/sea decision from the full-resolution
    # majority instead, then bias the averaged elevation to agree with it: the
    # coastline is what this whole milestone is gated on.
    land_hi = (elev > 0.0).astype(np.float32)
    land_frac = resize_f32(land_hi)
    land = land_frac >= 0.5
    small = np.where(land, np.maximum(small, 1.0), np.minimum(small, -1.0))
    weighted = np.cos(np.linspace(np.pi / 2, -np.pi / 2, HEIGHT))[:, None]
    frac = float((land * weighted).sum() / (weighted.sum() * WIDTH))
    print("  land fraction after downsample: %.3f (real Earth 0.292)" % frac)

    save_height(encode_height(small, 8500.0, 10500.0),
                os.path.join(OUT, "earth_height.png"))
    # Same writer as cook_earth_tiles so reruns cannot regress the 4096 size
    # or drop the sea-mask alpha (Track SL7).
    save_earth_albedo(land_hi)

    # Night lights. The published Black Marble is a *composite*: warm yellow-white
    # lights painted over a blue-purple land base. Its luminance is therefore not
    # a lights mask — every continent carries a plateau around 52/255, and using
    # it directly sets all the land glowing, which is exactly what it looked like.
    # Separate on hue instead: the base is blue (B > R), the lights are warm, so
    # R - 0.6B keeps the cities (including the saturated white cores, which a
    # plain R - B would zero out) and drops the base to nothing.
    bm = np.asarray(Image.open(fetch("blackmarble")).convert("RGB").resize(
        (WIDTH, HEIGHT), Image.LANCZOS), dtype=np.float32)
    warm = np.clip(bm[:, :, 0] - 0.6 * bm[:, :, 2], 0.0, 255.0)
    hi = float(np.percentile(warm, 99.9))
    lights = np.clip(warm / max(hi, 1.0), 0.0, 1.0) ** 0.85
    # Offshore rigs and shipping lanes are real, but at this resolution they read
    # as noise on the ocean; keep a trace rather than all of it.
    lights = np.where(land, lights, lights * 0.15)
    path = os.path.join(OUT, "earth_night.png")
    Image.fromarray(np.round(lights * 255.0).astype(np.uint8), mode="L").save(path)
    print("  wrote %s (%dx%d, L8)" % (path, WIDTH, HEIGHT))


def cook_moon():
    print("Moon")
    # SVS ships the CGI Moon Kit maps centred on 0 deg longitude, i.e. column 0
    # is -180 -- the same convention as the game. Verified from the data: the
    # hemisphere around column 0 is the high, bright, maria-free far side.
    ldem = np.asarray(Image.open(fetch("ldem")), dtype=np.float32) * 1000.0  # km -> m
    print("  LDEM %s  min %.0f m  max %.0f m" % (ldem.shape, ldem.min(), ldem.max()))
    small = resize_f32(ldem)
    save_height(encode_height(small, 10700.0, 9100.0),
                os.path.join(OUT, "moon_height.png"))
    save_rgb(Image.open(fetch("lroc")), os.path.join(OUT, "moon_albedo.png"))


def cook_mars():
    print("Mars")
    # MOLA MEGDR: MSB int16 metres relative to the areoid, 16 px/deg, and its
    # first column is longitude 0 (the label's CENTER_LONGITUDE is 180). Roll it
    # half a turn so column 0 becomes -180 like every other map here.
    raw = np.fromfile(fetch("mola"), dtype=">i2").astype(np.float32)
    mola = raw.reshape(2880, 5760)
    mola = np.roll(mola, mola.shape[1] // 2, axis=1)
    print("  MOLA %s  min %.0f m  max %.0f m" % (mola.shape, mola.min(), mola.max()))
    small = resize_f32(mola)
    save_height(encode_height(small, 21300.0, 8200.0),
                os.path.join(OUT, "mars_height.png"))
    # The USGS mosaic is a projected equirect whose tie point is -180 deg, so no
    # roll here -- only the odd trailing column of a 23059-wide image to ignore.
    save_rgb(Image.open(fetch("viking")), os.path.join(OUT, "mars_albedo.png"))


def cook_earth_clouds():
    """Real cloud climatology: the NASA Blue Marble cloud composite, kept as an
    8-bit cloud-fraction weight the cloud shader multiplies its noise by. This
    is what puts the ITCZ and the storm tracks where they belong and keeps the
    deserts clear — the continents stay identifiable exactly where a real
    photo of Earth would show them."""
    print("Earth clouds")
    img = Image.open(fetch("clouds")).convert("L").resize(
        (WIDTH, HEIGHT), Image.LANCZOS)
    a = np.asarray(img, dtype=np.float32) / 255.0
    path = os.path.join(OUT, "earth_clouds.png")
    Image.fromarray(np.round(np.clip(a, 0.0, 1.0) * 255.0).astype(np.uint8),
                    mode="L").save(path, optimize=True)
    print("  wrote %s (%dx%d, L8 cloud fraction)" % (path, WIDTH, HEIGHT))


# --- Earth height tile pyramid (fidelity tier, owner-approved 2026-08-23) ------
#
# Equirect tiles over the same lon/lat mapping as the global map: level L is a
# 2^(L+1) x 2^L grid of 1024^2 tiles, so L1 is an effective 4096 global and L2
# an effective 8192, L3 an effective 16384 — all genuinely resolved by the
# 21600x10800 ETOPO source.
# Same 16-bit split encoding and the same global reference elevations as
# earth_height.png, so a tile and the global map agree wherever both exist and
# the sampler can hard-switch between layers without a step.
#
# L2 tiles that are essentially all ocean are NOT cooked: the global map already
# carries the low-frequency bathymetry, the sampler falls back per-lookup, and
# skipping them keeps the committed set small. L1 is complete.

TILE = 1024
# L3 (Track TF): an effective 16384 equirect — 0.77 m/texel in-game, 2.4 km
# real — still genuinely resolved by the 21600-wide ETOPO source (0.0167°/px
# vs L3's 0.022°/px). Matches the mesh's old max_depth-7 vertex spacing.
TILE_LEVELS = (1, 2, 3)
LAND_MIN_FRAC = 0.02


def cook_earth_tiles():
    import netCDF4

    print("Earth height tiles")
    ds = netCDF4.Dataset(fetch("etopo"))
    lat = ds.variables["lat"][:]
    elev = np.asarray(ds.variables["z"][:, :], dtype=np.float32)
    if lat[0] < lat[-1]:
        elev = elev[::-1, :]
    ds.close()
    grid_h, grid_w = elev.shape
    tdir = os.path.join(OUT, "tiles")
    os.makedirs(tdir, exist_ok=True)
    land_hi = (elev > 0.0).astype(np.float32)
    cooked = 0
    skipped = 0
    for level in TILE_LEVELS:
        cols, rows = 2 ** (level + 1), 2 ** level
        for ty in range(rows):
            for tx in range(cols):
                y0, y1 = grid_h * ty // rows, grid_h * (ty + 1) // rows
                x0, x1 = grid_w * tx // cols, grid_w * (tx + 1) // cols
                sub = elev[y0:y1, x0:x1]
                subland = land_hi[y0:y1, x0:x1]
                if level > TILE_LEVELS[0] and float(subland.mean()) < LAND_MIN_FRAC:
                    skipped += 1
                    continue
                small = resize_f32(sub, TILE, TILE)
                # Same coastline rule as the global cook: the land/sea decision
                # comes from the full-resolution majority, not the average.
                land = resize_f32(subland, TILE, TILE) >= 0.5
                small = np.where(land, np.maximum(small, 1.0),
                                 np.minimum(small, -1.0))
                save_height(
                    encode_height(small, 8500.0, 10500.0),
                    os.path.join(tdir, "earth_h_L%d_%d_%d.png" % (level, tx, ty)))
                cooked += 1
    print("  %d tiles cooked, %d all-ocean L2 tiles skipped" % (cooked, skipped))
    save_earth_albedo(land_hi)


def save_earth_albedo(land_hi):
    """Earth's albedo at 4096x2048 (owner call, 2026-08-23) with the SEA MASK
    in the alpha channel (Track SL7): alpha 255 = land, 0 = sea, from the same
    full-resolution ETOPO majority rule as every coastline in the project. The
    surface shader turns sea texels glossy so the sun draws its glint disc."""
    rgb = Image.open(fetch("bluemarble")).convert("RGB").resize(
        (4096, 2048), Image.LANCZOS)
    land = resize_f32(land_hi, 4096, 2048) >= 0.5
    alpha = Image.fromarray(np.where(land, 255, 0).astype(np.uint8), mode="L")
    rgba = rgb.convert("RGBA")
    rgba.putalpha(alpha)
    path = os.path.join(OUT, "earth_albedo.png")
    rgba.save(path, optimize=True)
    print("  wrote %s (%dx%d, RGBA8, alpha = land mask)" % (path, 4096, 2048))


# --- The real sky (Track SL6) ---------------------------------------------------

STARMAP_W, STARMAP_H = 4096, 2048
EARTH_AXIAL_TILT = 0.41          # matches SolarSystemData._spin(earth, ..., 0.41)
MAG_COMPRESSION = 0.6            # perceptual: linear magnitudes bury the faint sky


def _bv_to_rgb(bv):
    """B-V colour index -> linear-ish RGB, via the standard temperature
    approximation and a compact blackbody fit. Good to the eye, which is the
    bar a sky map has to clear."""
    bv = max(-0.4, min(2.0, bv))
    t = 4600.0 * (1.0 / (0.92 * bv + 1.7) + 1.0 / (0.92 * bv + 0.62))
    t = max(2000.0, min(40000.0, t)) / 100.0
    if t <= 66.0:
        r = 1.0
        g = min(1.0, max(0.0, (99.47 * math.log(t) - 161.12) / 255.0))
    else:
        r = min(1.0, max(0.0, 329.7 * ((t - 60.0) ** -0.1332) / 255.0))
        g = min(1.0, max(0.0, 288.12 * ((t - 60.0) ** -0.0755) / 255.0))
    if t >= 66.0:
        b = 1.0
    elif t <= 19.0:
        b = 0.0
    else:
        b = min(1.0, max(0.0, (138.52 * math.log(t - 10.0) - 305.04) / 255.0))
    return np.array([r, g, b], dtype=np.float32)


def _equatorial_to_world(ra_rad, dec_rad):
    """RA/Dec (J2000) -> game world direction: +Y is the celestial pole and
    RA 0 is +X, then the whole sphere leans by Earth's axial tilt about X —
    so the celestial pole sits over Earth's spin axis and the ecliptic lies
    in the orbital plane.

    The z term is NEGATED on purpose: the naive (x, sin dec, cos dec sin ra)
    swaps two axes of the right-handed equatorial frame, which is an improper
    transform (det -1) — it bakes a MIRROR-IMAGE sky, every constellation
    backwards and the sphere winding against Earth's spin. The proper
    rotation real(x,y,z) -> game(x, z, -y) keeps chirality; the gate test
    measures the baked map's handedness so this cannot regress."""
    x = math.cos(dec_rad) * math.cos(ra_rad)
    y = math.sin(dec_rad)
    z = -math.cos(dec_rad) * math.sin(ra_rad)
    ct, st = math.cos(EARTH_AXIAL_TILT), math.sin(EARTH_AXIAL_TILT)
    return x, y * ct - z * st, y * st + z * ct


def cook_stars():
    """The real night sky: the Yale Bright Star Catalog (~9,100 stars to
    mag 6.5, public domain) splatted into an equirect panorama, coloured by
    B-V temperature, magnitudes perceptually compressed so the faint sky
    survives 8 bits; plus a Milky Way band as smoothed unresolved starlight
    along the galactic plane. The real sky for the same reason as the real
    coastline: Orion should be findable."""
    import gzip

    print("Star map")
    img = np.zeros((STARMAP_H, STARMAP_W, 3), dtype=np.float32)
    count = 0
    with gzip.open(fetch("bsc5"), "rt", encoding="latin-1") as f:
        for line in f:
            try:
                ra = (float(line[75:77]) + float(line[77:79]) / 60.0
                      + float(line[79:83]) / 3600.0) * 15.0
                dec = (float(line[84:86]) + float(line[86:88]) / 60.0
                       + float(line[88:90]) / 3600.0)
                if line[83] == "-":
                    dec = -dec
                vmag = float(line[102:107])
                bv_txt = line[109:114].strip()
                bv = float(bv_txt) if bv_txt else 0.5
            except (ValueError, IndexError):
                continue
            x, y, z = _equatorial_to_world(math.radians(ra), math.radians(dec))
            u = 0.5 + math.atan2(z, x) / (2.0 * math.pi)
            v = 0.5 - math.asin(max(-1.0, min(1.0, y))) / math.pi
            px, py = u * STARMAP_W, v * STARMAP_H
            inten = 2.512 ** (-vmag * MAG_COMPRESSION) / 2.3
            rgb = _bv_to_rgb(bv) * inten
            sigma = 1.0 + 0.9 * min(inten, 1.2)
            reach = int(3.0 * sigma) + 1
            cy, cx = int(py), int(px)
            for dy in range(-reach, reach + 1):
                yy = cy + dy
                if yy < 0 or yy >= STARMAP_H:
                    continue
                for dx in range(-reach, reach + 1):
                    xx = (cx + dx) % STARMAP_W
                    d2 = (cx + dx - px) ** 2 + (cy + dy - py) ** 2
                    img[yy, xx] += rgb * math.exp(-d2 / (2.0 * sigma * sigma))
            count += 1
    print("  %d stars splatted" % count)

    # Milky Way: unresolved starlight as a gaussian band about the galactic
    # plane, patchy via smoothed noise. Galactic north pole (J2000):
    # RA 192.859, Dec +27.128 — pushed through the same world transform.
    pole = np.array(_equatorial_to_world(
        math.radians(192.859), math.radians(27.128)), dtype=np.float32)
    vv, uu = np.mgrid[0:STARMAP_H, 0:STARMAP_W].astype(np.float32)
    lon = (uu + 0.5) / STARMAP_W * 2.0 * np.pi - np.pi
    lat = np.pi / 2.0 - (vv + 0.5) / STARMAP_H * np.pi
    dirs = np.stack([np.cos(lat) * np.cos(lon), np.sin(lat),
                     np.cos(lat) * np.sin(lon)], axis=-1)
    b = np.arcsin(np.clip(dirs @ pole, -1.0, 1.0))
    rng = np.random.default_rng(5309)
    patch = np.asarray(Image.fromarray(
        rng.random((64, 128)).astype(np.float32), mode="F")
        .resize((STARMAP_W, STARMAP_H), Image.BICUBIC), dtype=np.float32)
    band = np.exp(-(b / math.radians(9.0)) ** 2) * (0.5 + 0.7 * patch)
    img += band[..., None] * np.array([0.055, 0.052, 0.05], dtype=np.float32)

    out = np.clip(img / max(img.max(), 1e-6), 0.0, 1.0)
    out = np.round(np.power(out, 1.0 / 1.6) * 255.0).astype(np.uint8)
    sky_dir = os.path.join(ROOT, "assets", "sky")
    os.makedirs(sky_dir, exist_ok=True)
    path = os.path.join(sky_dir, "starmap.png")
    Image.fromarray(out, mode="RGB").save(path, optimize=True)
    print("  wrote %s (%dx%d, RGB8)" % (path, STARMAP_W, STARMAP_H))


# --- NYC detail site ----------------------------------------------------------

NYC_LAT, NYC_LON = 40.75, -73.98
NYC_SPAN_DEG = 0.26          # latitude extent of the window: ~29 km
NYC_INSET = 512
TILE_Z = 12


def _tile_xy(lat, lon, z):
    n = 2 ** z
    x = (lon + 180.0) / 360.0 * n
    s = math.sin(math.radians(lat))
    y = (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * n
    return x, y


def _terrarium_window(center_lat, center_lon, span_deg, n):
    """Sample an n x n elevation window (metres) from the public-domain AWS
    terrarium tiles, centred on (lat, lon), span_deg of latitude across. The
    window is small enough that the Mercator/equirect difference inside it is
    far below one texel."""
    half_lat = span_deg * 0.5
    half_lon = half_lat / math.cos(math.radians(center_lat))
    x0, y0 = _tile_xy(center_lat + half_lat, center_lon - half_lon, TILE_Z)
    x1, y1 = _tile_xy(center_lat - half_lat, center_lon + half_lon, TILE_Z)
    tx0, ty0, tx1, ty1 = int(x0), int(y0), int(x1), int(y1)
    print("  terrarium z%d tiles x %d..%d y %d..%d" % (TILE_Z, tx0, tx1, ty0, ty1))

    tiles = {}
    for tx in range(tx0, tx1 + 1):
        for ty in range(ty0, ty1 + 1):
            path = os.path.join(RAW, "terrarium_%d_%d_%d.png" % (TILE_Z, tx, ty))
            if not os.path.exists(path):
                url = ("https://s3.amazonaws.com/elevation-tiles-prod/terrarium/"
                       "%d/%d/%d.png" % (TILE_Z, tx, ty))
                os.makedirs(RAW, exist_ok=True)
                with urllib.request.urlopen(url, timeout=60) as r:
                    open(path, "wb").write(r.read())
            a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32)
            # terrarium: elevation_m = R*256 + G + B/256 - 32768
            tiles[(tx, ty)] = a[:, :, 0] * 256.0 + a[:, :, 1] + a[:, :, 2] / 256.0 - 32768.0

    lats = center_lat + half_lat - (np.arange(n) + 0.5) / n * (2 * half_lat)
    lons = center_lon - half_lon + (np.arange(n) + 0.5) / n * (2 * half_lon)
    out = np.zeros((n, n), dtype=np.float32)
    for j, la in enumerate(lats):
        fx, fy = _tile_xy(la, lons[0], TILE_Z)
        step = (_tile_xy(la, lons[-1], TILE_Z)[0] - fx) / max(n - 1, 1)
        xs = fx + np.arange(n) * step
        ty = int(fy)
        py = min(int((fy - ty) * 256), 255)
        for i, xv in enumerate(xs):
            tx = int(xv)
            tile = tiles.get((tx, ty))
            if tile is None:
                continue
            out[j, i] = tile[py, min(int((xv - tx) * 256), 255)]
    return out


def _tidal_water_mask(out):
    """Anything under a metre is water, then one 3x3 majority pass to knock out
    the single-pixel speckle a 56 m/px DEM leaves along a marshy shoreline —
    the rule that made the Hudson read as a river, reused for every coastal
    site window."""
    water = out < 1.0
    votes = np.zeros_like(water, dtype=np.int16)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            votes += np.roll(np.roll(water, dy, axis=0), dx, axis=1).astype(np.int16)
    return votes >= 5


def cook_nyc():
    """Real terrain for the NYC diorama, from public-domain terrain tiles.

    The window is ~29 km of real New York squeezed into the site's 400 m
    footprint -- the diorama stylization from docs/planet-renderer.md. What
    survives the squeeze is the shape that matters: Manhattan, the Hudson and
    East rivers, the Upper Bay, Brooklyn and the Jersey shore.
    """
    print("NYC inset")
    n = NYC_INSET
    out = _terrarium_window(NYC_LAT, NYC_LON, NYC_SPAN_DEG, n)
    water = _tidal_water_mask(out)
    half_lat = NYC_SPAN_DEG * 0.5
    print("  window %.0f m across, min %.0f m max %.0f m, %.1f%% land"
          % (2 * half_lat * 111320.0, out.min(), out.max(),
             100.0 * float((~water).mean())))

    # The diorama squeezes 29 km of New York into a 400 m footprint, so its
    # vertical scale is stylized to match rather than inherited from the global
    # map: Manhattan stands ~5 m proud of a flat harbour instead of the 1.3 m
    # the global reference elevations would give it. The blend weight goes to
    # zero at the footprint edge, so the two encodings never meet in a step.
    elev = np.where(water, np.minimum(out, -30.0), np.maximum(out, 1.0))
    save_height(encode_height(elev, 700.0, 1500.0),
                os.path.join(OUT, "nyc_height_inset.png"))

    # Night lights for the diorama: authored art, not data (no public night
    # raster resolves a 29 km window). A street grid on Manhattan's ~29 deg
    # bearing, brightest downtown/midtown, fading out over the water.
    land = ~water
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    cx, cy = n * 0.5, n * 0.5
    theta = math.radians(29.0)
    u = (xx - cx) * math.cos(theta) + (yy - cy) * math.sin(theta)
    v = -(xx - cx) * math.sin(theta) + (yy - cy) * math.cos(theta)
    avenues = np.exp(-((u % 9.0 - 4.5) ** 2) / 1.6)
    streets = np.exp(-((v % 4.0 - 2.0) ** 2) / 0.7)
    grid = np.clip(avenues * 0.85 + streets * 0.5, 0.0, 1.0)
    # Density envelope: a bright core over midtown/downtown falling away into the
    # outer boroughs, plus a slow mottle so the suburbs are not a flat wash.
    radial = np.exp(-((xx - cx) ** 2 + (yy - cy) ** 2) / (2 * (n * 0.22) ** 2))
    rng = np.random.default_rng(7402)
    mottle = np.asarray(Image.fromarray(rng.random((16, 16)).astype(np.float32), mode="F")
                        .resize((n, n), Image.BICUBIC), dtype=np.float32)
    density = np.clip(0.10 + 0.95 * radial + 0.30 * (mottle - 0.5), 0.0, 1.0)
    glow = np.clip((0.35 + 0.65 * grid) * density, 0.0, 1.0)
    glow = np.where(land, glow, 0.0)
    # Fade to nothing at the footprint edge. The plate is a finite quad laid over
    # an infinite planet; without this its border reads as a hard rectangle of
    # light sitting on the terrain.
    edge = np.minimum(np.minimum(xx, n - 1 - xx), np.minimum(yy, n - 1 - yy))
    glow *= np.clip(edge / (n * 0.12), 0.0, 1.0)
    path = os.path.join(OUT, "nyc_night.png")
    Image.fromarray(np.round(glow * 255.0).astype(np.uint8), mode="L").save(path)
    print("  wrote %s (%dx%d, L8, authored)" % (path, n, n))


# --- Cape Canaveral detail site (PR5 site list, owner-picked 2026-08-23) -------

CANAVERAL_LAT, CANAVERAL_LON = 28.55, -80.62
CANAVERAL_SPAN_DEG = 0.26     # ~29 km: VAB and LC-39 north, CCSFS pads east,
                              # Port Canaveral south, Banana/Indian rivers between

## Real places inside the window, as (lat, lon, brightness) for the night
## plate and as anchors the site scene reads to place its landmarks.
CANAVERAL_LIGHTS = [
    (28.608, -80.604, 0.55),   # LC-39A
    (28.627, -80.621, 0.50),   # LC-39B
    (28.586, -80.651, 0.85),   # VAB / industrial area
    (28.615, -80.694, 0.35),   # Shuttle Landing Facility
    (28.488, -80.577, 0.60),   # CCSFS pad row
    (28.410, -80.605, 0.95),   # Port Canaveral / Cocoa Beach
]


def cook_canaveral():
    """Real terrain for the Cape Canaveral diorama: the same 29-km-window
    treatment as NYC. What survives the squeeze is exactly what identifies the
    place from orbit -- the cape's hook, the barrier islands, and the Banana
    and Indian rivers between them and the mainland."""
    print("Canaveral inset")
    n = NYC_INSET
    out = _terrarium_window(CANAVERAL_LAT, CANAVERAL_LON, CANAVERAL_SPAN_DEG, n)
    water = _tidal_water_mask(out)
    print("  window min %.0f m max %.0f m, %.1f%% land"
          % (out.min(), out.max(), 100.0 * float((~water).mean())))

    # Florida is FLAT -- the whole window lives under ~20 m -- so the local
    # positive reference is small or the cape reads as a water-level smear.
    elev = np.where(water, np.minimum(out, -30.0), np.maximum(out, 1.0))
    save_height(encode_height(elev, 60.0, 800.0),
                os.path.join(OUT, "canaveral_height_inset.png"))

    # Night plate: authored, like NYC's (no public raster resolves the window).
    # Gaussian glows at the real installations plus a faint mottle over land --
    # a launch coast at night, not a metropolis.
    land = ~water
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    half_lat = CANAVERAL_SPAN_DEG * 0.5
    half_lon = half_lat / math.cos(math.radians(CANAVERAL_LAT))
    glow = np.zeros((n, n), dtype=np.float32)
    for la, lo, e in CANAVERAL_LIGHTS:
        px = (lo - (CANAVERAL_LON - half_lon)) / (2 * half_lon) * n
        py = ((CANAVERAL_LAT + half_lat) - la) / (2 * half_lat) * n
        glow += e * np.exp(-((xx - px) ** 2 + (yy - py) ** 2) / (2 * 9.0 ** 2))
    rng = np.random.default_rng(3928)
    mottle = np.asarray(Image.fromarray(rng.random((16, 16)).astype(np.float32),
                                        mode="F").resize((n, n), Image.BICUBIC),
                        dtype=np.float32)
    glow = np.clip(glow + 0.06 * mottle, 0.0, 1.0)
    glow = np.where(land, glow, glow * 0.1)   # a little harbour light on water
    edge = np.minimum(np.minimum(xx, n - 1 - xx), np.minimum(yy, n - 1 - yy))
    glow *= np.clip(edge / (n * 0.12), 0.0, 1.0)
    path = os.path.join(OUT, "canaveral_night.png")
    Image.fromarray(np.round(glow * 255.0).astype(np.uint8), mode="L").save(path)
    print("  wrote %s (%dx%d, L8, authored)" % (path, n, n))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=[
        "earth", "moon", "mars", "nyc", "clouds", "tiles", "canaveral", "stars"])
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    jobs = {"earth": cook_earth, "moon": cook_moon, "mars": cook_mars,
            "nyc": cook_nyc, "clouds": cook_earth_clouds,
            "tiles": cook_earth_tiles, "canaveral": cook_canaveral,
            "stars": cook_stars}
    for name, fn in jobs.items():
        if args.only in (None, name):
            fn()
    print("done -> %s" % OUT)


if __name__ == "__main__":
    main()
