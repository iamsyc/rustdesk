#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 3 ]]; then
  echo "Usage: $0 BASELINE_DMG PATCHED_FRAMEWORK OUTPUT_DIR" >&2
  exit 2
fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
baseline_dmg="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
framework_dir="$(cd "$2" && pwd)"
mkdir -p "$3"
output_dir="$(cd "$3" && pwd)"
package_dir="$(mktemp -d "${TMPDIR:-/tmp}/rustdesk-texture-package.XXXXXX")"
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then
    hdiutil detach "$package_dir/mount" >/dev/null || true
  fi
  rm -rf "$package_dir"
}
trap cleanup EXIT
mkdir -p "$package_dir/mount" "$package_dir/payload"
test "$(shasum -a 256 "$baseline_dmg" | cut -d ' ' -f 1)" = \
  6c7e6d5b201c5ccbbcd1d2cd501465fddcfeb347bb171dda3e2ae9ae3b6499e5
hdiutil attach -readonly -nobrowse -mountpoint "$package_dir/mount" "$baseline_dmg" >/dev/null
mounted=true
app="$package_dir/payload/RustDesk.app"
ditto "$package_dir/mount/RustDesk.app" "$app"
hdiutil detach "$package_dir/mount" >/dev/null
mounted=false
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = 1.5.0
test "$(lipo -archs "$framework_dir/Versions/A/FlutterMacOS")" = x86_64

# Only the engine framework is replaced; the existing Dart snapshot and native
# RustDesk decoder/input binaries are the exact baseline's files.
rm -rf "$app/Contents/Frameworks/FlutterMacOS.framework"
ditto "$framework_dir" "$app/Contents/Frameworks/FlutterMacOS.framework"
codesign --force --deep --sign - \
  --entitlements "$repo_dir/flutter/macos/Runner/Release.entitlements" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
ln -s /Applications "$package_dir/payload/Applications"
experiment_name=RustDesk-TextureLifetimeExperiment-1.5.0-x86_64.dmg
hdiutil create -volname RustDeskTextureLifetime -srcfolder "$package_dir/payload" \
  -format UDZO -ov "$output_dir/$experiment_name"
cp "$baseline_dmg" "$output_dir/RustDesk-TextureBaseline-1.5.0-x86_64.dmg"
cp "$repo_dir/TEXTURE_LIFETIME_EXPERIMENT.md" "$output_dir/README.md"
python3 - "$repo_dir" "$framework_dir" "$output_dir" <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys

repo, framework, output = map(pathlib.Path, sys.argv[1:])
def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
manifest = {
    "application_version": "1.5.0",
    "architecture": "x86_64",
    "engine_revision": "a18df97ca57a249df5d8d68cd0820600223ce262",
    "baseline_source_commit": "59f1a6ba23dc8028a675b94e25838fdbc96c7abe",
    "baseline_github_run": 37577650499,
    "engine_build_github_run": int(os.environ.get("ENGINE_BUILD_GITHUB_RUN", "0")) or None,
    "patch_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
    "engine_patch_sha256": sha256(repo / ".github/patches/flutter-engine-3.24.5-macos-texture-lifetime.diff"),
    "patched_framework_sha256": sha256(framework / "Versions/A/FlutterMacOS"),
    "signing": "ad-hoc",
    "remote_flicker_validation": "pending fixed-codec A/B on the affected client",
}
(output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
cd "$output_dir"
shasum -a 256 ./*.dmg manifest.json README.md > SHA256SUMS.txt
