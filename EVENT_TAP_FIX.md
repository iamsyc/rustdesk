# RustDesk 1.5.0 macOS Event Tap recovery

This build vendors RustDesk's pinned `rdev` dependency at commit
`a361d86a8b0245f3618a9efb375c149530a6b599` and retains the macOS keyboard
grab and native-window focus fixes from the owner's 1.4.9 build.

The official 1.5.0 tag is merged, including its matching rdev changes. Native
Event Tap capture stays armed across Flutter focus-loss notifications, and each
key is gated by the active AppKit remote-desktop window. Fullscreen/Space and
tab-transfer recovery remain in the Flutter layer. Per-key diagnostics use trace
logging so ordinary sessions do not write a line for every key event.

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

Run the **Build macOS Event Tap and focus fix** workflow from GitHub Actions. It builds an
Intel `x86_64` application with the same Rust, Flutter and vcpkg versions pinned
by RustDesk 1.5.0, applies an ad-hoc signature, creates a DMG and uploads:

* `RustDesk-EventTapFocusFix-1.5.0-x86_64.dmg`
* `SHA256SUMS.txt`

The build is intentionally not notarized. It is intended only for installation
on the owner's Mac.

## Install and roll back

Run:

```bash
./scripts/install-eventtapfix-macos.sh /path/to/RustDesk-EventTapFocusFix-1.5.0-x86_64.dmg
```

The script verifies the checksum, architecture, embedded recovery log marker
and code signature. It then moves the existing `/Applications/RustDesk.app` to
a timestamped backup before installing the patched application. It preserves existing
settings and privacy permissions. Check macOS permissions after launch; an
ad-hoc signed replacement may require a new grant.

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
