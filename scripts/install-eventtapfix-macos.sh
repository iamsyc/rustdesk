#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/RustDesk-EventTapFocusFix-1.5.0-x86_64.dmg" >&2
  exit 64
fi

DMG_PATH="$1"
if [[ ! -f "${DMG_PATH}" ]]; then
  echo "DMG not found: ${DMG_PATH}" >&2
  exit 66
fi

DMG_DIR="$(cd "$(dirname "${DMG_PATH}")" && pwd)"
DMG_PATH="${DMG_DIR}/$(basename "${DMG_PATH}")"
CHECKSUM_FILE="${DMG_DIR}/SHA256SUMS.txt"
MOUNT_POINT="$(mktemp -d /tmp/rustdesk-eventtapfix.XXXXXX)"
SOURCE_APP="${MOUNT_POINT}/RustDesk.app"
TARGET_APP="/Applications/RustDesk.app"
BACKUP_APP="/Applications/RustDesk-backup-$(date +%Y%m%d-%H%M%S).app"
STAGED_APP="/Applications/.RustDesk-staged-$(date +%Y%m%d-%H%M%S).app"
MOUNTED=0

cleanup() {
  if [[ "${MOUNTED}" -eq 1 ]]; then
    hdiutil detach "${MOUNT_POINT}" -quiet || true
  fi
  rmdir "${MOUNT_POINT}" 2>/dev/null || true
}
trap cleanup EXIT

if [[ -f "${CHECKSUM_FILE}" ]]; then
  (
    cd "${DMG_DIR}"
    shasum -a 256 -c "$(basename "${CHECKSUM_FILE}")"
  )
else
  echo "SHA256SUMS.txt is required." >&2
  exit 65
fi

hdiutil attach -nobrowse -readonly -mountpoint "${MOUNT_POINT}" "${DMG_PATH}" >/dev/null
MOUNTED=1

if [[ ! -d "${SOURCE_APP}" ]]; then
  echo "RustDesk.app is missing from the DMG." >&2
  exit 65
fi

SOURCE_BIN="${SOURCE_APP}/Contents/Frameworks/liblibrustdesk.dylib"
ARCHS="$(lipo -archs "${SOURCE_BIN}")"
[[ " ${ARCHS} " == *" x86_64 "* ]]
grep -aFq "macOS keyboard event tap was disabled" "${SOURCE_BIN}"
grep -aFq "native Event Tap remains armed" "${SOURCE_BIN}"
grep -aFq "ignoring unsupported macOS input source" "${SOURCE_BIN}"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${SOURCE_APP}/Contents/Info.plist")" == "1.5.0" ]]
codesign --verify --deep --strict --verbose=2 "${SOURCE_APP}"

echo "Verified patched x86_64 RustDesk application."
echo "The current application will be moved to:"
echo "  ${BACKUP_APP}"
read -r -p "Install the patched build now? [y/N] " reply
if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
  echo "Installation cancelled."
  exit 0
fi

if [[ -e "${STAGED_APP}" ]]; then
  echo "Staging target already exists: ${STAGED_APP}" >&2
  exit 73
fi
ditto "${SOURCE_APP}" "${STAGED_APP}"
codesign --verify --deep --strict --verbose=2 "${STAGED_APP}"

osascript -e 'tell application "RustDesk" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
  if ! pgrep -x RustDesk >/dev/null; then
    break
  fi
  sleep 0.25
done
if pgrep -x RustDesk >/dev/null; then
  echo "RustDesk is still running. Quit it completely and run this installer again." >&2
  exit 70
fi

if [[ -e "${BACKUP_APP}" ]]; then
  echo "Backup target already exists: ${BACKUP_APP}" >&2
  exit 73
fi

if [[ -d "${TARGET_APP}" ]]; then
  mv "${TARGET_APP}" "${BACKUP_APP}"
fi

if ! mv "${STAGED_APP}" "${TARGET_APP}"; then
  if [[ -d "${BACKUP_APP}" && ! -e "${TARGET_APP}" ]]; then
    mv "${BACKUP_APP}" "${TARGET_APP}"
  fi
  echo "Installation failed; previous application retained or restored." >&2
  exit 74
fi

xattr -dr com.apple.quarantine "${TARGET_APP}" 2>/dev/null || true

echo "Installed patched RustDesk."
echo "Original application backup:"
echo "  ${BACKUP_APP}"
echo "Existing settings and privacy permissions were preserved. Check macOS prompts after launch."
open "${TARGET_APP}"
