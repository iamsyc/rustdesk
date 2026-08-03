# RustDesk 1.4.9 macOS Event Tap recovery

This build vendors RustDesk's pinned `rdev` dependency at commit
`871bf1c856d6a30af2f56ab8848396a025140855` and changes only the macOS keyboard
grab path.

## Failure

The controlling Mac uses a session-level `CGEventTap` for keyboard capture.
macOS can disable an event tap after a timeout or a user-input request. The
upstream callback did not handle either notification, so the disabled tap
remained unusable until the RustDesk process recreated it.

## Fix

The patched callback:

1. Keeps the active Event Tap handle in an atomic pointer.
2. Detects `TapDisabledByTimeout` and `TapDisabledByUserInput`.
3. Calls `CGEventTapEnable(tap, true)` immediately.
4. Emits a warning containing the disable reason.
5. Clears and disables the saved handle when the grab loop exits.

RustDesk already uses this recovery pattern for its privacy-mode Event Tap in
`src/platform/macos.mm`.

## Build

Run the **Build macOS Event Tap fix** workflow from GitHub Actions. It builds an
Intel `x86_64` application with the same Rust, Flutter and vcpkg versions pinned
by RustDesk 1.4.9, applies an ad-hoc signature, creates a DMG and uploads:

* `RustDesk-EventTapFix-1.4.9-x86_64.dmg`
* `SHA256SUMS.txt`

The build is intentionally not notarized. It is intended only for installation
on the owner's Mac.

## Install and roll back

Run:

```bash
./scripts/install-eventtapfix-macos.sh /path/to/RustDesk-EventTapFix-1.4.9-x86_64.dmg
```

The script verifies the checksum, architecture, embedded recovery log marker
and code signature. It then moves the existing `/Applications/RustDesk.app` to
a timestamped backup before installing the patched application. It resets the
two relevant macOS privacy permissions, which must be granted again.

To roll back, quit RustDesk, move the patched application elsewhere, and rename
the timestamped backup to `/Applications/RustDesk.app`.

## Runtime validation

Keep `Input source 1` selected. Connect to the target Mac and repeat each action
several times:

1. Capture through WeChat.
2. Capture through another screenshot tool.
3. Open and dismiss Spotlight.
4. Switch applications and Spaces.
5. Enter and leave full screen.
6. Type in several ordinary remote application fields after every action.

Search the local RustDesk log for:

```text
macOS keyboard event tap was disabled
```

If the message appears and typing continues, the recovery path executed.
