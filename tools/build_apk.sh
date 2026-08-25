#!/usr/bin/env bash
# Build the Android APK and keep it servable by the owner's nginx (port 8080).
#
# The restorecon is load-bearing, not ceremony: Godot exports to a temp file
# and RENAMES it into build/, and a rename keeps the source's SELinux label
# (user_tmp_t) — the fcontext policy on build/ applies only at creation or
# restorecon. Learned when a "verified" inheritance probe (touch, which
# CREATES) said rebuilds were fine and the very next rebuilt APK 403'd.
set -euo pipefail
cd "$(dirname "$0")/.."
godot --headless --export-debug "Android" build/cascade.apk
sudo -n restorecon -R build/ 2>/dev/null \
  || echo "note: restorecon needs passwordless sudo; run: sudo restorecon -R build/"
ls -Z build/cascade.apk
