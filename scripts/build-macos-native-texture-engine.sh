#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "Usage: $0 ENGINE_WORKSPACE MACOS_SDK [prepare|compile|test|all] [x86_64|arm64]" >&2
  exit 2
fi
sdk_dir="$(cd "$2" && pwd)"
phase="${3:-all}"
case "$phase" in prepare|compile|test|all) ;; *) exit 2 ;; esac
arch="${4:-$(uname -m)}"
case "$arch" in
  x86_64) mac_cpu=x64; output=out/host_release ;;
  arm64) mac_cpu=arm64; output=out/host_release_arm64 ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 2 ;;
esac
engine_revision=a18df97ca57a249df5d8d68cd0820600223ce262
depot_revision=071d5b9d91e06cb2a9c9ce926d6ee666df185b49
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
ninja_binary="$(command -v ninja || true)"
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
"$engine_workspace/depot_tools/ensure_bootstrap"

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
if [[ ! -x "$ninja_binary" ]]; then
  echo "Install Ninja and put it on PATH" >&2
  exit 1
fi
patch_file="$repo_dir/.github/patches/flutter-engine-3.24.5-native-nv12.diff"
if git -C "$engine_source" apply --check "$patch_file"; then
  git -C "$engine_source" apply "$patch_file"
elif ! git -C "$engine_source" apply --reverse --check "$patch_file"; then
  echo "Texture patch does not match the pinned engine" >&2
  exit 1
fi

skia_source="$engine_source/third_party/skia"
skia_patch="$repo_dir/.github/patches/flutter-skia-3.24.5-native-nv12.diff"
if git -C "$skia_source" apply --check "$skia_patch"; then
  git -C "$skia_source" apply "$skia_patch"
elif ! git -C "$skia_source" apply --reverse --check "$skia_patch"; then
  echo "NV12 chroma-siting patch does not match pinned Skia" >&2
  exit 1
fi

dart_source="$engine_source/third_party/dart"
dart_patch="$repo_dir/.github/patches/flutter-dart-3.24.5-macos-product-version.diff"
if git -C "$dart_source" apply --check "$dart_patch"; then
  git -C "$dart_source" apply "$dart_patch"
elif ! git -C "$dart_source" apply --reverse --check "$dart_patch"; then
  echo "macOS version patch does not match pinned Dart" >&2
  exit 1
fi

cd "$engine_workspace/src"
host_arg=""
if [[ "$(uname -m)" == arm64 ]]; then host_arg=--force-mac-arm64; fi
python3 flutter/tools/gn --runtime-mode=release --no-lto --enable-unittests --mac-cpu="$mac_cpu" \
  ${host_arg:+"$host_arg"} \
  --gn-args 'mac_deployment_target="15.8"' \
  --gn-args "mac_sdk_path=\"$sdk_dir\""
"$ninja_binary" -C "$output" -j "${ENGINE_BUILD_JOBS:-3}" \
  flutter_framework flutter_desktop_darwin_unittests shell_unittests
fi

if [[ "$phase" == test || "$phase" == all ]]; then
cd "$engine_workspace/src"
"$output/shell_unittests" \
  --gtest_filter='ShellTest.CachedTextureFramesDoNotWaitForVsync:ShellTest.Animator*:ShellTest.VSyncTargetTime' \
  --gtest_output="xml:$engine_workspace/texture-pacing-tests.xml"

"$output/flutter_desktop_darwin_unittests" \
  --gtest_filter='FlutterEmbedderExternalTextureTest.RejectingFrameReleasesResources:FlutterEmbedderExternalTextureTest.FrameResourcesSurvivePendingGPUDraw:FlutterEmbedderExternalTextureTest.NativeNv12PreservesSourceTransferFunction:FlutterEmbedderExternalTextureTest.NativeNv12PreservesLeftChromaSiting:FlutterEmbedderExternalTextureTest.NativeGammaPaletteIsContinuous' \
  --gtest_output="xml:$engine_workspace/texture-tests.xml"

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/rustdesk-nv12-probe.XXXXXX")"
xcrun clang++ -std=c++17 -fobjc-arc -O2 -arch "$arch" -mmacosx-version-min=15.8 \
  -I "$engine_source" "$script_dir/probe-macos-nv12-lifetime.mm" \
  -framework Foundation -framework CoreVideo -framework Metal \
  -o "$probe_dir/probe"
"$probe_dir/probe" "$engine_workspace/src/$output/FlutterMacOS.framework/FlutterMacOS" \
  > "$engine_workspace/nv12-metal-probe.json"
rm -rf "$probe_dir"
cat "$engine_workspace/nv12-metal-probe.json"
fi
