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
godot --headless --import       # ETC2/ASTC variants (after texture changes)
tools/build_apk.sh              # export + SELinux restorecon (see below)
```

Preset lives in `export_presets.cfg` (committed — it is a build input, not a
secret). arm64-v8a only, minSdk 24, package `com.blastedstudios.cascade`.
Output is ~111 MB: 76 MB of that is `libgodot_android.so`, the rest is the
project's 117 MB of assets after compression.

Install with `adb install -r build/cascade.apk` (platform-tools is in the SDK),
or fetch it over the LAN from the nginx vhost the owner runs on port 8080:

```
http://192.168.1.10:8080/cascade.apk
```

**SELinux note (Fedora, Enforcing):** files written into `build/` land as
`user_tmp_t`, which nginx may not read — the symptom is a 403 with
`open() ... (13: Permission denied)` in `/var/log/nginx/error.log`, and it is
NOT a file-permission problem (the traversal path is already `o+x`). The
directory is labelled once:

```bash
sudo chcon -R -t httpd_sys_content_t ~/workspace/cascade/build
```

The subtle part, learned the hard way: **new files inherit the directory's
type, but Godot's export RENAMES a temp file into place, and a rename keeps
the source's label** (`user_tmp_t`) — so a "verified" inheritance probe using
`touch` passed while the very next rebuilt APK 403'd. The fcontext policy is
registered:

```bash
sudo semanage fcontext -a -t httpd_sys_content_t "/home/narfman0/workspace/cascade/build(/.*)?"
```

…but policy applies at creation/restorecon, not at rename — so every rebuild
still needs `restorecon -R build/`. `tools/build_apk.sh` does both steps.

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

## 6. Touch controls — the design (Track TC)

### The rule that keeps it cheap

**Synthesize, never rewrite.** One `TouchInput` CanvasLayer parses raw
`InputEventScreenTouch/Drag` and feeds the two channels every controller
already listens to:

1. `Input.action_press(action, strength)` / `action_release` for the mapped
   actions — and because `action_press` takes a strength, the virtual stick
   gives **analog thrust on mobile for free** (the ship and suit already read
   `get_action_strength`; the desktop keyboard is the thing that was binary).
2. A public `add_look_delta(delta: Vector2)` on the ship and EVA controllers,
   which the existing `InputEventMouseMotion` handlers are refactored to call —
   one accumulator, two feeders. Torque, EVA look, and the walk's camera-boom
   pitch all arrive exactly as if a mouse had moved.

Flight, EVA, walking, docking, landing, autoland, hazard and autopilot code
never learn a phone exists. Every existing gate keeps covering the physics;
the touch suite only has to prove the synthesis layer itself.

Instantiated only under `OS.has_feature("mobile")` or `CASCADE_TOUCH=1` (the
desktop override that lets the layout be screenshotted and gate-tested here).

### Layout (landscape, thumbs at the edges)

```
+----------------------------------------------------------------------+
| VEL/ATT/FUEL/FA/REF        [warnings/banners]        APPROACH/SURFACE|
|                                                            [ROLL L/R]|
|                                                                      |
|                        (right half = LOOK DRAG:                      |
|                         pitch/yaw torque in flight,                  |
|      look + camera boom on foot)                                     |
|   [ ▲ ]                                                              |
| ( STICK )                                       context bar          |
|   [ ▼ ]     [FA] [CAM] [NAV]   [EVA|BOARD|UNDOCK|LATCH|AUTOLAND|...] |
+----------------------------------------------------------------------+
```

- **Left virtual stick** (bottom-left quarter, appears where the thumb lands,
  ~140 px radius, 0.15 deadzone): X → `thrust_left/right`, Y →
  `thrust_forward/back`. Same axes as WASD, analog.
- **▲/▼ buttons** flanking the stick: `thrust_up` / `thrust_down` (the sixth
  axis gets dedicated buttons — a second stick axis pair is untrainable).
  While WALKING, ▲ relabels **JUMP** (tap = jump, hold = jetpack — the
  desktop SPACE semantics verbatim, because it IS thrust_up) and ▼ hides.
  While LANDED, ▲ relabels **LIFT OFF — hold** (again: it is just
  thrust_up, and the landing computer's hold-to-release already listens).
- **Right half = look surface**: any drag not starting on a button feeds
  `add_look_delta` scaled by DPI. No visible widget — the whole area is the
  mouse. Two simultaneous drags are not needed anywhere.
- **ROLL ⟲/⟳** small paired buttons, top-right of the look zone; flight modes
  only (`roll_left/right`).
- **System row** (bottom-centre-left): `FA` (state-tinted — it changes how
  every axis feels, so it is always one tap away), `CAM`, `NAV`.
- **Context bar** (bottom-centre-right): shows ONLY actions whose predicate is
  live, reusing the exact conditions the HUD prompts already compute —
  `EVA` (flying, suit aboard) · `BOARD` (bay overlap or walking at bay) ·
  `UNDOCK` (docked) · `LATCH/RELEASE` (LatchComputer ready/latched) ·
  `AUTOLAND` (`AutolandComputer.can_engage()`) · `ABORT` (autoland/autopilot
  active). Never a button that would do nothing.
- All widgets: the calm HUD language — thin 1 px outlines, low-alpha fills,
  no chrome. Buttons ≥ 48 px touch targets, laid out from the safe area.

### Per-mode summary

| Mode | Stick | ▲/▼ | Drag | Extras |
|---|---|---|---|---|
| Ship flight | strafe / fwd-back | up / down | pitch+yaw | roll, FA, NAV, context |
| Docked / landed | hidden | LIFT OFF (landed) | hidden | UNDOCK / EVA |
| EVA free flight | strafe / fwd-back | up / down | pitch+yaw | LATCH, BOARD |
| EVA clamped to rock | hidden | — | hidden | RELEASE (shove = G) |
| Walking (LD6) | run | JUMP / — | look + boom pitch | BOARD at bay |
| Nav console open | hidden | hidden | list scroll | tap row, ENGAGE, CLOSE |

### Nav console touch pass

The console is keyboard-driven labels today. Mobile additions: rows become
48 px tap targets (tap = select), momentum scroll for the list, an **ENGAGE**
button where the "ENTER engage" footer text sits, and CLOSE top-right. The
keyboard path is untouched.

### What deliberately does NOT exist

- No pinch-zoom, no gyro look, no multi-finger gestures — nothing invisible.
  Every control is a visible affordance or the one obvious drag.
- No auto-fire/toggle for the main engine: thrust is held, like the key.
- No layout editor. One layout, tuned by owner feedback.

### Gates

`tests/touch_test.gd`, headless with `CASCADE_TOUCH=1`:
- synthetic stick drag → the right actions at the right strengths (analog);
  release → all zero; deadzone honored.
- synthetic look drag → `fx_torque_local` responds with the correct signs
  (the fx_test trick reused); on foot → yaw turns, boom pitch moves.
- JUMP tap on the Moon → the anim/landing jump gates' apex unchanged.
- context bar: docked shows UNDOCK not EVA; inside a shell shows AUTOLAND;
  autoland active shows ABORT; nothing dead ever visible.
- stick input aborts the autopilot (the discoverable rule survives synthesis).
- desktop with the layer absent: zero nodes added, all suites green.

Plus `CASCADE_TOUCH=1` layout screenshots per mode for owner review — the
feel pass itself needs the phone.

## 7. Web (assessed, not built)

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
