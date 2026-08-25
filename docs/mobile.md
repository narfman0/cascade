# Cascade — Mobile builds

Android APK builds, the toolchain that produces them, and the renderer finding
that decides how the game looks on a phone. Web is assessed at the bottom.

## 1. The renderer decision (read this before changing anything)

**Android runs `gl_compatibility`, deliberately.** Godot refuses to export
`forward_plus` to Android at all ("designed for Desktop devices"), which leaves
Forward Mobile or Compatibility — and **Forward Mobile is the broken one for
Cascade**:

`assets/shaders/atmosphere_common.gdshaderinc` clamps its in-scatter march
against the depth buffer (`hint_depth_texture`) so each ray stops at whatever
geometry it hits. Forward Mobile cannot read that buffer, so every ray
traverses the **full 50 m atmosphere shell** instead of stopping at terrain —
and Earth's relief is ~40 m, filling 80% of the shell. The result is roughly
double the in-scatter everywhere: the planet vanishes under pale blue haze.

Compatibility reads depth correctly and renders close to Forward+ (slightly
oversaturated, no Forward+ tonemap/glow parity).

Verify any of this without a phone:

```bash
CASCADE_PROBE=forward_plus  xvfb-run -a godot --rendering-method forward_plus     res://tests/capture_renderer_probe.tscn
CASCADE_PROBE=mobile        xvfb-run -a godot --rendering-method mobile           res://tests/capture_renderer_probe.tscn
CASCADE_PROBE=compat        xvfb-run -a godot --rendering-method gl_compatibility res://tests/capture_renderer_probe.tscn
```

Three shots of the same framing land in `user://shots/probe_*.png`. This is the
only self-verification available for mobile rendering — everything else needs
the device.

## 2. Toolchain (one-time, all user-local, no sudo)

| Piece | Where | Notes |
|---|---|---|
| Export templates | `~/.var/app/org.godotengine.Godot/data/godot/export_templates/4.7.1.stable/` | From `Godot_v4.7.1-stable_export_templates.tpz`; must match the engine version exactly |
| Android SDK | `~/Android/Sdk` | `cmdline-tools/latest`, `platform-tools`, `build-tools;34.0.0`, `platforms;android-34` |
| JDK 17 | `~/.local/jdk17` | Temurin. The flatpak also bundles one at `/usr/lib/sdk/openjdk17/jvm/openjdk-17`, which is what the editor setting points at |
| Debug keystore | `~/.var/app/org.godotengine.Godot/data/godot/keystores/debug.keystore` | alias `androiddebugkey`, pass `android` |

The flatpak Godot has `filesystems=host`, so it sees all of the above with no
extra permissions. Editor settings already carry the paths
(`export/android/android_sdk_path`, `java_sdk_path`, `debug_keystore`).

No NDK and no Gradle are needed: `gradle_build/use_gradle_build=false` uses the
prebuilt template APK.

## 3. Building

```bash
godot --headless --import                              # ETC2/ASTC variants
godot --headless --export-debug "Android" build/cascade.apk
```

Preset lives in `export_presets.cfg` (committed — it is a build input, not a
secret). arm64-v8a only, minSdk 24, package `com.blastedstudios.cascade`.
Output is ~111 MB: 76 MB of that is `libgodot_android.so`, the rest is the
project's 117 MB of assets after compression.

Install with `adb install -r build/cascade.apk` (platform-tools is in the SDK),
or copy the APK to the device and open it.

## 4. Project settings this required

- `rendering/textures/vram_compression/import_etc2_astc=true` — mandatory for
  Android export, and wanted anyway (the 4096×2048 Earth albedo is 32 MB of
  VRAM uncompressed).
- `rendering/renderer/rendering_method.mobile="gl_compatibility"` — see §1.
- `display/window/stretch/mode="canvas_items"` + `aspect="expand"` — the HUD is
  authored at 14 px against 1600×900; unscaled it is unreadable on a phone.
- `display/window/handheld/orientation=1` (landscape) — the flight HUD is wide.
- `ship_controller` no longer grabs the mouse under `OS.has_feature("mobile")`.

None of these changed desktop behaviour: all thirteen suites stayed green.

## 4b. The second finding: instance uniforms do not survive GLES

The first APK booted, ran fast — and textured Earth as **per-patch
starbursts**: each quadtree patch smeared the albedo radially out of its own
centre, while the planet's silhouette stayed perfectly round.

Geometry intact + texturing wrong pointed at one line:

```glsl
v_sdir = normalize(VERTEX + patch_center);   // patch_center: INSTANCE uniform
```

Patch vertices were stored patch-relative, and the shader re-added the patch
centre from an `instance uniform`. On a real GLES driver that instance uniform
arrives as **zero**, so `v_sdir` became `normalize(VERTEX)` — a direction that
swings wildly across a patch whose coordinates are centred on zero, sweeping
the whole equirect map. llvmpipe delivers instance uniforms correctly, which is
why the desktop Compatibility probe looked clean.

**Fix: vertices are now BODY-local and the instance uniform is gone.** The
patch node already sat at `node.center` (`mi.position = node.center`), so the
value was redundant with the node transform all along. `v_sdir` is simply
`normalize(VERTEX)`. Float precision is a non-issue: Jupiter's 8000 m radius
leaves ~1 mm against metre-scale vertex spacing.

`morph_t` is still an instance uniform, and that is safe by construction: if a
driver drops it, it reads its declared default of `1.0` — no morphing, an
honest LOD pop, never broken geometry.

Two defensive changes came along: the custom vertex arrays are
`ARRAY_CUSTOM_RGBA_FLOAT` rather than the 3-component variant (which is not
dependably delivered by GLES), and the vertex shader skips the morph outright
if the parent normal is not unit length. Neither is provably necessary; both
are cheap insurance on a platform that cannot be debugged interactively from
here.

Watch for this class of bug: **anything per-instance is suspect on GLES.**

## 5. Known state and what is missing

**The APK boots and renders; it cannot be flown.** Every control is mouse-look
plus keyboard, so a phone build is currently a viewer: the ship spawns
station-keeping in Earth orbit, the camera works, the HUD updates, and the
debug-build perf overlay (top right — FPS, worst frame, adapter, resolution)
reports what the device actually does. That number is the whole point of the
first build. **Track TC** covers real touch controls.

Untested on device and expected to need work: frame rate over an atmospheric
planet (a per-pixel raymarch plus streaming terrain LOD is the heavy part),
thermal behaviour, and touch-target sizing.

## 6. Web (assessed, not built)

Same Compatibility renderer as Android, so the atmosphere should look the same
— but:

- Threads need `SharedArrayBuffer`, i.e. COOP/COEP headers. Without them
  `WorkerThreadPool` (12 call sites, all terrain patch building) falls back to
  single-threaded and streaming stalls. itch.io supports this; GitHub Pages
  needs the `coi-serviceworker` shim.
- 117 MB of assets download before first play, versus bundled in an APK.
- Mobile-browser performance is below native.

Android is the better target for the same effort; web is worth revisiting only
if zero-install sharing matters more than performance.
