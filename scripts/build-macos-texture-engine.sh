#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 ENGINE_WORKSPACE [prepare|compile|test|all]" >&2
  exit 2
fi
phase="${2:-all}"
case "$phase" in prepare|compile|test|all) ;; *) exit 2 ;; esac
engine_revision=a18df97ca57a249df5d8d68cd0820600223ce262
depot_revision=071d5b9d91e06cb2a9c9ce926d6ee666df185b49
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
mkdir -p "$1"
engine_workspace="$(cd "$1" && pwd)"
engine_source="$engine_workspace/src/flutter"
export PATH="$engine_workspace/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0 DEPOT_TOOLS_METRICS=0

if [[ "$phase" == prepare || "$phase" == all ]]; then
if [[ ! -d "$engine_workspace/depot_tools/.git" ]]; then
  git init -q "$engine_workspace/depot_tools"
  git -C "$engine_workspace/depot_tools" remote add origin \
    https://chromium.googlesource.com/chromium/tools/depot_tools.git
  git -C "$engine_workspace/depot_tools" fetch --depth=1 origin "$depot_revision"
  git -C "$engine_workspace/depot_tools" checkout --detach FETCH_HEAD
fi
test "$(git -C "$engine_workspace/depot_tools" rev-parse HEAD)" = "$depot_revision"

cat > "$engine_workspace/.gclient" <<'GCLIENT'
solutions = [{
  "name": "src/flutter",
  "url": "https://github.com/flutter/engine.git",
  "managed": False,
  "custom_deps": {
    # The Flutter mirror rejects shallow fetches of this historical commit.
    "src/flutter/third_party/tinygltf":
      "https://github.com/syoyo/tinygltf.git@9bb5806df4055ac973b970ba5b3e27ce27d98148",
  },
  "custom_vars": {
    "download_android_deps": False,
    "download_windows_deps": False,
    "download_linux_deps": False,
    "download_fuchsia_deps": False,
    "download_emsdk": False,
    "download_esbuild": False,
    "setup_githooks": False,
  },
}]
target_os = ["mac"]
GCLIENT
cd "$engine_workspace"
gclient sync --no-history --shallow --jobs=4 --revision "src/flutter@$engine_revision"
test "$(git -C "$engine_source" rev-parse HEAD)" = "$engine_revision"
fi

if [[ "$phase" == compile || "$phase" == all ]]; then
ninja_binary=/usr/local/bin/ninja
if [[ ! -x "$ninja_binary" ]]; then
  echo "Install standalone Ninja at /usr/local/bin/ninja" >&2
  exit 1
fi
patch_file="$repo_dir/.github/patches/flutter-engine-3.24.5-macos-texture-lifetime.diff"
if git -C "$engine_source" apply --check "$patch_file"; then
  git -C "$engine_source" apply "$patch_file"
elif ! git -C "$engine_source" apply --reverse --check "$patch_file"; then
  echo "Texture patch does not match the pinned engine" >&2
  exit 1
fi

cd "$engine_workspace/src"
python3 flutter/tools/gn --runtime-mode=release --no-lto --enable-unittests
python3 - out/host_release/compile_commands.json <<'PYTHON'
import json
import pathlib
import shlex
import subprocess
import sys

wanted = {"FlutterDarwinExternalTextureMetal.mm", "FlutterExternalTexture.mm",
          "embedder_external_texture_metal.mm", "FlutterEmbedderExternalTextureTest.mm"}
checked = set()
for entry in json.loads(pathlib.Path(sys.argv[1]).read_text()):
    name = pathlib.Path(entry["file"]).name
    if name in wanted and name not in checked:
        print("Preflight syntax:", name, flush=True)
        args = entry.get("arguments") or shlex.split(entry["command"])
        for flag in ("-o", "-MF"):
            if flag in args:
                index = args.index(flag)
                del args[index:index + 2]
        if "-MMD" in args:
            args.remove("-MMD")
        args.append("-fsyntax-only")
        subprocess.run(args, cwd=entry["directory"], check=True)
        checked.add(name)
if checked != wanted:
    raise SystemExit("Missing preflight entries: " + str(wanted - checked))
PYTHON
"$ninja_binary" -C out/host_release -j "${ENGINE_BUILD_JOBS:-3}" \
  flutter_framework flutter_desktop_darwin_unittests
fi

if [[ "$phase" == test || "$phase" == all ]]; then
cd "$engine_workspace/src"
out/host_release/flutter_desktop_darwin_unittests \
  --gtest_filter='FlutterEmbedderExternalTextureTest.RejectingFrameReleasesResources:FlutterEmbedderExternalTextureTest.FrameResourcesSurvivePendingGPUDraw' \
  --gtest_output="xml:$engine_workspace/texture-tests.xml"

set +e
bash "$script_dir/test-macos-texture-lifetime.sh" "$engine_source" \
  "$engine_workspace/src/out/host_release/FlutterMacOS.framework/Versions/A/FlutterMacOS" \
  > "$engine_workspace/metal-probe.json"
probe_status=$?
set -e
cat "$engine_workspace/metal-probe.json"
if [[ "$probe_status" != 0 && "$probe_status" != 77 ]]; then
  exit "$probe_status"
fi
fi
