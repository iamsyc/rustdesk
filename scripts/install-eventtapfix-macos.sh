#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/RustDesk-EventTapFix-1.4.9-x86_64.dmg" >&2
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
BACKUP_APP="/Applications/RustDesk-official-backup-$(date +%Y%m%d-%H%M%S).app"
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
  echo "Warning: SHA256SUMS.txt is missing; continuing with signature and binary checks." >&2
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
codesign --verify --deep --strict --verbose=2 "${SOURCE_APP}"

echo "Verified patched x86_64 RustDesk application."
echo "The current application will be moved to:"
echo "  ${BACKUP_APP}"
read -r -p "Install the patched build now? [y/N] " reply
if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
  echo "Installation cancelled."
  exit 0
fi

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

if ! ditto "${SOURCE_APP}" "${TARGET_APP}"; then
  if [[ -d "${BACKUP_APP}" && ! -e "${TARGET_APP}" ]]; then
    mv "${BACKUP_APP}" "${TARGET_APP}"
  fi
  echo "Installation failed; the original application was restored." >&2
  exit 74
fi

xattr -dr com.apple.quarantine "${TARGET_APP}" 2>/dev/null || true
tccutil reset ListenEvent com.carriez.rustdesk >/dev/null 2>&1 || true
tccutil reset Accessibility com.carriez.rustdesk >/dev/null 2>&1 || true

echo "Installed patched RustDesk."
echo "Original application backup:"
echo "  ${BACKUP_APP}"
echo "macOS input permissions were reset. Re-enable Input Monitoring and Accessibility when prompted."
open "${TARGET_APP}"
