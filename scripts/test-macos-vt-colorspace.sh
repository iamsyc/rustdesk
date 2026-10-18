#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 VCPKG_TRIPLET_DIRECTORY ARCH" >&2
  exit 2
fi
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
triplet_dir="$(cd "$1" && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/rustdesk-vt-colorspace.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
xcrun clang -O2 -arch "$2" -mmacosx-version-min=15.8 \
  -I "$triplet_dir/include" "$repo_dir/scripts/probe-macos-vt-colorspace.c" \
  "$triplet_dir/lib/libavutil.a" -framework VideoToolbox -framework CoreVideo \
  -framework CoreGraphics -framework CoreMedia -framework CoreFoundation \
  -o "$probe_dir/probe"
"$probe_dir/probe" --require-reuse
