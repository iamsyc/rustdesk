#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_DIR="$(mktemp -d)"
trap 'rm -rf "$PROBE_DIR"' EXIT
# The dependency uses the old FFmpeg profile names; values are unchanged.
clang++ -std=c++17 -DFF_PROFILE_H264_HIGH=100 -DFF_PROFILE_HEVC_MAIN=1 \
  "$ROOT/scripts/probe-macos-h264.cpp" \
  "$ROOT/third_party/hwcodec/cpp/common/util.cpp" \
  -I"$ROOT/third_party/hwcodec/cpp/common" \
  $(pkg-config --cflags --libs libavcodec libavutil) \
  -o "$PROBE_DIR/probe"
"$PROBE_DIR/probe"
