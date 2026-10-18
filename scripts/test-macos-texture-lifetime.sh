#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 ]]; then
  echo "Usage: $0 ENGINE_SOURCE_DIR FRAMEWORK_BINARY" >&2
  exit 2
fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/rustdesk-texture-probe.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
xcrun clang++ -std=c++17 -fobjc-arc -O2 \
  -I "$1" "$script_dir/probe-macos-texture-lifetime.mm" \
  -framework Foundation -framework CoreVideo -framework Metal \
  -o "$probe_dir/probe"
"$probe_dir/probe" "$2"
