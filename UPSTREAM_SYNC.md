# Maintained macOS fork: RustDesk 1.5.1

This integration merges the official `1.5.1` release commit
`23e5bb471a040d62f0a6ad52591fb30784265b73` into the maintained fork at
`455df3c63c1c66fc6ce5d171cefd56de8c3e11a9`.

The older `codex/macos-texture-lifetime-1.5.1` experiment starts from
`3010bcef` and omits the subsequent maintained-fork changes. It is retained
separately and is not the base of this integration.

## Native video and input contracts

- Keep the vendored hwcodec H.264 hardware probe, typed pending-output result,
  native VideoToolbox frames, and retained CVPixelBuffer ownership.
- Keep the vendored NV12/Metal renderer, latest pending-frame publication,
  color-description caching, and Flutter texture-lifetime patches.
- Keep mouse-hover backlog coalescing, ordered keyboard/click delivery, and
  selective macOS keyboard pacing.
- Retain the one-second encoder warm-up deadline when combining the upstream
  first-packet tracking with pending output. Pending input is fed input, and
  does not count as an encoding failure.
- Keep idle H.264 VideoToolbox sessions from repeatedly encoding old frames.
  Other upstream static-frame refinement paths remain available.
- Limit H.264 VideoToolbox to one reference frame so its default 1920x1200
  stream can open the tested Intel hardware decoder. Keep hardware decode
  assertions for both 1920x1200 and 2880x1800; no software fallback is added.

## Dependency integration

`third_party/hwcodec` now follows the official release's `ec38ebaf2454269d4c5668a57e3813c6e5541be7`
base. Its upstream changes, including the software-transfer resolution-change
fix, are combined with the existing local macOS changes.

The vendored rdev base follows `0904f23ce496e255461a98848b85c11fa5a62eab`.
The updated diagnostic sources are included and the local Event Tap recovery
remains intact. Root Cargo patches continue selecting both vendored crates.
`hbb_common` follows the release's `fae47e024dd83cef6aaecde0aa7d11731df11649`.

FFmpeg remains at 7.1.1. Its upstream QSV and MP4 fixes and the existing macOS
color-cache, asynchronous-decode, and Metal-surface patches are all applied.

## Build and signing

macOS 15.8 is the minimum for both Intel and ARM. The native engine preparation
and finalization steps remain mandatory. The existing native engine patch
already includes the earlier texture-lifetime experiment; the historical
1.5.0 comparison workflow is not needed for this build.

Local packages require `RUSTDESK_SIGNING_IDENTITY` and the existing persistent
identity. Ad-hoc signing remains restricted to explicitly selected development
artifacts. Updating source does not replace either installed application.

Generate Flutter bridge files through the pinned CI entry points, as described
in AGENTS.md. The standalone hwcodec test uses the stable toolchain already
installed for the standalone rdev test; the application build keeps the
upstream's locked macOS toolchain and dependency graph.

Relevant validation commands include:

```sh
cargo test --locked --lib --features hwcodec
MACOSX_DEPLOYMENT_TARGET=15.8 cargo +stable test --manifest-path third_party/hwcodec/Cargo.toml --test macos_h264
bash scripts/test-macos-texture-copy.sh /path/to/framework-directory
```

The Intel hardware test executable must also be run on a physical Intel Mac.
Full Flutter applications need the generated bridge, patched engine, complete
vcpkg patch set, architecture checks, fixed-signature finalization, and real
remote-session acceptance before installation.
