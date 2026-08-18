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


def save_rgb(img, path):
    img = img.convert("RGB").resize((WIDTH, HEIGHT), Image.LANCZOS)
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
    save_rgb(Image.open(fetch("bluemarble")), os.path.join(OUT, "earth_albedo.png"))

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


def cook_nyc():
    """Real terrain for the NYC diorama, from public-domain terrain tiles.

    The window is ~29 km of real New York squeezed into the site's 400 m
    footprint -- the diorama stylization from docs/planet-renderer.md. What
    survives the squeeze is the shape that matters: Manhattan, the Hudson and
    East rivers, the Upper Bay, Brooklyn and the Jersey shore.
    """
    print("NYC inset")
    half_lat = NYC_SPAN_DEG * 0.5
    half_lon = half_lat / math.cos(math.radians(NYC_LAT))
    x0, y0 = _tile_xy(NYC_LAT + half_lat, NYC_LON - half_lon, TILE_Z)
    x1, y1 = _tile_xy(NYC_LAT - half_lat, NYC_LON + half_lon, TILE_Z)
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

    # Sample the mosaic per output pixel. The window is small enough that the
    # Mercator/equirect difference inside it is far below one texel.
    n = NYC_INSET
    lats = NYC_LAT + half_lat - (np.arange(n) + 0.5) / n * (2 * half_lat)
    lons = NYC_LON - half_lon + (np.arange(n) + 0.5) / n * (2 * half_lon)
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

    # Terrarium carries the tidal Hudson/East River at ~0 m, exactly the datum,
    # so a strict e > 0 test leaves the rivers ragged. Call anything under a
    # metre water, then run one 3x3 majority pass to knock out the single-pixel
    # speckle that a 56 m/px DEM leaves along a marshy shoreline.
    water = out < 1.0
    votes = np.zeros_like(water, dtype=np.int16)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            votes += np.roll(np.roll(water, dy, axis=0), dx, axis=1).astype(np.int16)
    water = votes >= 5
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["earth", "moon", "mars", "nyc"])
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    jobs = {"earth": cook_earth, "moon": cook_moon, "mars": cook_mars, "nyc": cook_nyc}
    for name, fn in jobs.items():
        if args.only in (None, name):
            fn()
    print("done -> %s" % OUT)


if __name__ == "__main__":
    main()
