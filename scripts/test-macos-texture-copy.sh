#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 FLUTTER_FRAMEWORK_DIRECTORY [TEXT_RGBA_SWIFT]" >&2
  exit 2
fi
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
framework_dir="$(cd "$1" && pwd)"
source_file="${2:-$repo_dir/third_party/flutter_texture_rgba_renderer/macos/Classes/TextRgba.swift}"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/rustdesk-texture-copy.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
swiftc -O -target "$(uname -m)-apple-macos15.8" -F "$framework_dir" \
  "$source_file" "$repo_dir/scripts/probe-macos-texture-copy.swift" \
  -o "$probe_dir/probe" -Xlinker -rpath -Xlinker "$framework_dir"
"$probe_dir/probe"
