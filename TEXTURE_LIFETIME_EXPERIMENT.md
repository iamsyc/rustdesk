# macOS texture lifetime experiment

This experiment tests whether extending Core Video frame ownership through
Skia's Metal texture release callback eliminates the brief remote-view flicker
observed on the Intel macOS RustDesk 1.5.0 client with texture rendering enabled.
The actual remote flicker remains unverified until the affected client is tested.

## Packages

- `RustDesk-TextureBaseline-1.5.0-x86_64.dmg` is the unchanged EventTap/focus-fix
  baseline from GitHub Actions run `37577650499`, commit
  `59f1a6ba23dc8028a675b94e25838fdbc96c7abe`.
- `RustDesk-TextureLifetimeExperiment-1.5.0-x86_64.dmg` replaces only that app's
  `FlutterMacOS.framework`, compiled from the same Flutter 3.24.5 engine commit
  `a18df97ca57a249df5d8d68cd0820600223ce262` plus the included patch.
- Both apps retain the same Dart snapshot, RustDesk native libraries, renderer
  plugin, codecs, and EventTap/focus fixes. The experiment is ad-hoc signed,
  without notarization, like the baseline.
- `SHA256SUMS.txt` and `manifest.json` identify the files, original build,
patch commit, patch hash, and rebuilt framework hash.

The engine build fetches `tinygltf` from its upstream GitHub repository at the
same DEPS commit `9bb5806df4055ac973b970ba5b3e27ce27d98148`; the old Flutter
mirror returns HTTP 400 for that commit. This changes only the download source.

## Mechanism and scope

The original BGRA path releases the `CVMetalTextureRef` immediately after
obtaining `id<MTLTexture>`. The patch keeps both the Core Video texture and
pixel buffer alive until Skia releases its borrowed backend texture.
An optional size-checked ownership callback is appended to
`FlutterMetalExternalTexture` because the macOS pixel-buffer producer and
the Skia consumer sit on opposite sides of the embedder payload. Existing
callers, old struct prefixes, and wrapper method signatures are retained.

Regression surface inside the pinned engine:

- `FlutterExternalTexture.mm`: the macOS BGRA producer hands off frame resources.
- `embedder.h`: adds optional ownership fields at the end of the Metal payload.
- `embedder_external_texture_metal.mm`: forwards provided ownership to Skia and
  releases rejected frames. Payloads without the callback use the old path.
- `FlutterDarwinExternalTextureMetal.h/.mm`: adds parallel Skia wrapper methods
  with release callbacks for the two supported formats. Existing methods remain.
- `FlutterEmbedderExternalTextureTest.mm`: two tests cover rejected-frame release
  and keeping a frame alive while a GPU draw is pending.

The macOS YUVA producer and the iOS texture producer are unchanged. This patch
targets RustDesk's macOS BGRA renderer and the Flutter 3.24.5 Skia backend.

## Verification

The engine's existing unit-test executable runs two new ownership tests.
`scripts/test-macos-texture-lifetime.sh ENGINE_SOURCE_DIR FRAMEWORK_BINARY`
loads the real engine and copies a solid BGRA frame through Metal after dropping
the provider/holder. It verifies all 256 pixels and releases ownership after
GPU completion. The original framework reports `missing_frame_release_callback`.
A host without a Metal device reports exit code 77 explicitly; that result does
not count as successful GPU validation.

## Fixed-codec comparison on the affected client

1. Save work in the remote session and quit RustDesk before switching packages.
2. Preserve the current installed app. Test one package at a time using the same
   app location, remote machine, window size, scaling, and texture-render setting.
3. Keep texture rendering enabled in both packages. Explicitly select the same
   codec and hardware-decoding setting and verify the negotiated decoder in the
   session log. Changing texture rendering resets the decoder/capabilities, so
   toggling it alone is not a controlled comparison.
4. Replay the activity that usually produces the brief flicker for a comparable
   duration on both packages. Record flicker count, codec, decoder, and duration.
5. Check resizing, fullscreen transitions, reconnecting, and normal input. If the
   experiment regresses, quit it and restore the baseline app.

The probe validates resource lifetime and GPU pixels. Compilation or those tests
alone cannot establish that the user's intermittent remote-view flicker is fixed.

Sources: [Flutter issue 157379](https://github.com/flutter/flutter/issues/157379),
[pinned macOS producer](https://github.com/flutter/engine/blob/a18df97ca57a249df5d8d68cd0820600223ce262/shell/platform/darwin/macos/framework/Source/FlutterExternalTexture.mm),
[pinned Skia release contract](https://github.com/google/skia/blob/93461bed7394e3c554125b0c50b00fb81eea42c6/include/gpu/ganesh/SkImageGanesh.h).
