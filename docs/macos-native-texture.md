# macOS native NV12 client

The macOS client requires macOS 15.8. The controlled Mac mini continues to send
H.264 through VideoToolbox. This change does not lower resolution, quality or FPS.

The renderer publishes the decoder's retained CVPixelBuffer directly for NV12
with a BT.601 matrix and centered, left, top or top-left chroma siting. Flutter
samples its two Metal planes and performs YUV conversion, source ICC conversion
to sRGB and scaling in the final draw. This removes the intermediate BGRA surface
and the separate Core Image GPU task. Other input formats retain the existing
Core Image path.

The pinned Flutter 3.24.5 engine patch retains the Core Video backing until Skia's
GPU release callback. It also uses the actual 4:2:0 plane dimensions and propagates
the source ICC profile and chroma siting. The Skia patch supports cosited sampling.
The Dart patch reads the actual macOS product version: its old Darwin-major
calculation reported every macOS 15 minor release as 15.0 and rejected a 15.8 build.

Build the engine with an installed macOS SDK supported by the pinned compiler:

```sh
scripts/build-macos-native-texture-engine.sh ENGINE_WORKSPACE MACOS_SDK all x86_64
```

The script pins the engine, depot tools and engine dependencies. It applies the
three patches in `.github/patches`, targets the selected architecture and macOS 15.8, builds the
framework, runs the texture regression tests and verifies both NV12 planes remain
readable by Metal after the provider is released. Pass `arm64` for Apple Silicon;
the default is the host architecture. The framework is under `src/out/host_release`
for Intel or `src/out/host_release_arm64` for Apple Silicon. Use the macOS 15.4 SDK
from Xcode 16.3 with the pinned engine compiler. Tests require a host running at
least macOS 15.8.

Normal macOS builds require the patched framework and finalize the application
before returning a packageable bundle:

```sh
export RUSTDESK_SIGNING_IDENTITY=YOUR_CERTIFICATE_SHA1
export RUSTDESK_FLUTTER_ENGINE=ENGINE_WORKSPACE/src/out/host_release/FlutterMacOS.framework
./build.py --flutter --hwcodec --unix-file-copy-paste
scripts/test-macos-texture-copy.sh FLUTTER_FRAMEWORK_DIRECTORY
```

Use the same certificate identity for subsequent local builds. The finalizer
requires it and delegates signing to `scripts/sign-macos-local.py`. Ad-hoc signing
changes its designated requirement with the app hash and invalidates existing
privacy permissions. CI explicitly sets `RUSTDESK_ADHOC_SIGN=1`
for development artifacts without a private certificate; it is mutually exclusive
with the persistent signing identity. Both macOS workflows build/cache the pinned
framework and pass it to the same finalizer. For an existing staged bundle, run
`python3 scripts/finalize-macos-client.py RustDesk.app "$RUSTDESK_FLUTTER_ENGINE"`.
CI archives the Xcode 16.3 SDK on a macOS 15 runner, then compiles the framework
and application on macOS 26 runners. The compiler needs the pinned SDK while
its generated build tools also require a host meeting the macOS 15.8 minimum.
To replace only the Rust backend,
prepare a copy of the installed bundle, replace the library, then run:

```sh
python3 scripts/sign-macos-local.py RustDesk.app
codesign --verify --deep --strict RustDesk.app
codesign -d -r- RustDesk.app
```

The designated requirement must remain unchanged across updates. Keep the
private signing key on the build Mac and transfer the complete signed bundle to
the client without signing it again. Stop the existing app before replacing the
installed bundle. The initial switch from ad-hoc signing may require one privacy
permission refresh. Validate later updates through the normal LaunchAgent and
client launch paths, including live screen capture and keyboard delivery.

`native_pixelbuffer_ready.ready_us` measures publication readiness. On the direct
NV12 path this is CPU handoff time, not GPU completion or end-to-end latency.
`RUSTDESK_GPU_TRACE=1` enables separate Metal command timing and sampled Core Image
kernel timing for controlled experiments; it should be unset during normal use.

Regression surface: the Swift native-frame publisher, macOS Flutter external
texture ownership and YUV sampling, the Ganesh cosited YUV shader, and Dart's macOS
version query. Existing raw BGRA uploads and the existing asynchronous Core Image
path remain covered by the texture probe. Shared Rust video behavior and the
server encoder are unchanged by this NV12 optimization; the Rust completion log
now uses the neutral `ready_us` name to distinguish it from GPU time.

| Existing file or engine file | Necessary behavior change |
|---|---|
| `third_party/flutter_texture_rgba_renderer/macos/Classes/TextRgba.swift` | Publish eligible NV12 without a separate conversion; preserve existing BGRA and CI entry points. |
| `src/flutter/macos_pixelbuffer.rs` | Rename completion timing to readiness, since native publication completes before GPU drawing. |
| `FlutterExternalTexture.mm` | Retain both Core Video planes and their backing; propagate source ICC and chroma location. |
| `embedder.h` | Carry frame ownership, ICC bytes and chroma siting through the Metal texture descriptor. |
| `embedder_external_texture_metal.mm` | Transfer frame ownership to Skia and consume the source metadata. |
| `FlutterDarwinExternalTextureMetal.h` and `.mm` | Wrap actual 4:2:0 planes and fuse source-to-sRGB conversion into drawing. |
| Skia `SkYUVAInfo.h` and `GrYUVtoRGBEffect.cpp` | Support the source's left/cosited chroma samples accurately. Centered sampling stays on its existing path. |
| Skia `GrMtlCommandBuffer.mm` | Add opt-in actual GPU timestamps; no completion hook when tracing is disabled. |
| Dart `runtime/platform/utils_macos.cc` | Read the actual minor version so a macOS 15.8 deployment can start on 15.8.1. |
| `build.py` and both macOS workflows | Require the patched framework and finalize every macOS Flutter bundle before packaging. |
| `scripts/finalize-macos-client.py` | Require the native texture engine and matching Intel or Apple Silicon slices/minimum 15.8 before packaging. |

The three engine/Skia/Dart patches carry these edits against their pinned source
trees; engine tests are added in `FlutterEmbedderExternalTextureTest.mm`.

## Decoder color-space cache

The FFmpeg overlay applies `0013-cache-macos-decoder-colorspace.patch`. On macOS,
VideoToolbox decoded frames reuse the color space synthesized from the same ICC
profile, primaries, transfer function, YCbCr matrix and gamma. The single cache
entry belongs to the existing AVHWFramesContext and is released with it. Its key
is an immutable deep copy, so in-place mutation of ICC data is detected. An
os_unfair_lock covers lookup and replacement; callers receive a retained result.
CPU frame uploads continue to use their existing color-space synthesis.

Build FFmpeg through the overlay before rebuilding the hwcodec crate and client.
The hwcodec static library bundles FFmpeg objects, so relinking only the final
RustDesk library does not pick up replaced FFmpeg archives. Test with:

```sh
scripts/test-macos-vt-colorspace.sh VCPKG_TRIPLET_DIRECTORY x86_64
```

The probe compares rendered color samples against the original Core Video
factory for repeated metadata, changed primaries/matrix/transfer/gamma, ICC
profiles and mutable ICC bytes. It also requires object reuse for identical
metadata. Original FFmpeg passes the color checks but fails the reuse assertion.
The existing `macos_h264` integration test checks H.264/HEVC native decoded pixels
and buffer ownership after decoder teardown.

Additional regression surface for this cache:

| Existing file or FFmpeg file | Necessary behavior change |
|---|---|
| `res/vcpkg/ffmpeg/portfile.cmake` | Apply the decoder cache patch when building the existing FFmpeg overlay. |
| FFmpeg `libavutil/hwcontext_videotoolbox.c` | Reuse the synthesized color space only for native macOS decoded frames, within their existing frame-context lifetime. |
| FFmpeg `libavcodec/videotoolbox.c` | Attach the existing frame-context reference before color metadata synthesis so the cache has its owner. |

The public FFmpeg API is unchanged. The cache does not alter the server encoder,
pixel conversion, texture lifetime, GPU shader or non-macOS color-space path.
`decode_us` includes synchronous VideoToolbox wait and FFmpeg postprocessing;
compare it as elapsed stage time rather than CPU execution time.

The FFmpeg overlay explicitly sets the macOS 15.8 compiler/linker minimum. After
changing overlay patches, rebuild the affected triplet before relinking hwcodec;
an old installed archive can pass the color checks while failing the reuse check.

## Cached texture frame pacing

The macOS engine draws cached layer trees as soon as an external texture is
ready. `Animator::AwaitVSync` uses this path only after a scene has rendered and
no layer-tree regeneration is pending. When a UI frame is already pending,
`Animator::RequestFrame(false)` redraws the last layer trees without consuming or
releasing the pending UI frame's semaphore. The UI rebuild keeps its existing
vsync callback. This prevents the one-second quality-monitor refresh from
delaying an unrelated video texture update. This avoids adding a display interval to an already-paced
remote video source; the decoded frame rate is unchanged.

`CachedTextureFramesDoNotWaitForVsync` exercises two successive texture updates
without a vsync tick, then starts a normal UI rebuild. A texture update while
that rebuild is pending must redraw immediately; the later vsync must still
complete the UI rebuild. The fake renderer consumes its pipeline so both UI
frames can run. It
fails on the unmodified animator and passes with the patch. The engine build
script builds and runs this test alongside the existing animator and texture
ownership tests.

Set `RUSTDESK_FRAME_TRACE=1` together with `RUSTDESK_GPU_TRACE=1` for opt-in
per-frame tracing. The Swift publisher attaches a local texture/generation tag
to the native buffer. The engine passes the tag through Metal texture labels;
Skia logs the command and render target it binds to. GPU completion logs carry
the command identifier, and the macOS surface manager logs the target surface's
presentation request and Core Animation commit. These are software submission
boundaries; they do not measure physical display scanout. Normal launches leave
both tracing variables unset.

Additional regression surface: `shell/common/animator.cc` changes only the
macOS cached-tree redraw cadence. Its unit test is in `animator_unittests.cc`.
`FlutterExternalTexture.mm`, `FlutterSurfaceManager.mm`,
`GrMtlCommandBuffer.mm`, `GrMtlPipelineState.mm` and the Swift publisher add
opt-in trace points without changing pixel data or ownership. The Rust client
and receive-loop logs add packet PTS and native-buffer identity at trace level.
The FFmpeg decoder and server encoder are unchanged by this pacing adjustment.

## Native YUV source gamma specialization

The measured Core Video source profile has the pure transfer curve
`x^1.9609375`. On macOS, opaque YUV draws using this exact profile, an sRGB
converted image, ordinary sampling and a non-identity YUV matrix use a dedicated
Skia runtime effect. It evaluates the exact source power, gamut matrix and signed
sRGB encoding with fixed curve parameters. It stays in the final draw and adds
no intermediate frame. The runtime effect's source participates in Skia's shader
cache key. Other color profiles, cubic sampling and alpha-bearing images retain
their existing conversion path.

`NativeGammaPaletteIsContinuous` renders 65,536 color pixels for the measured
curve and its next representable exponent. The latter exercises the general
conversion path. The test requires no more than one 8-bit code of difference,
so specializing the curve must not introduce a visible color discontinuity.
The existing native transfer-function test also compares grayscale output to
Core Graphics color matching. Both passed on the Intel client.

This optimization changes only macOS `SkImage_GaneshYUVA::asFragmentProcessor`
and its local runtime-effect helper. No FFmpeg, transport, Swift publisher,
public API, decoder lifecycle or framebuffer format changes are involved.
The implementation lives in the pinned Skia patch; the palette regression test
lives in the pinned engine patch. Its measured benefit is GPU command duration;
input-to-display latency has not been measured.

## VideoToolbox asynchronous submission

The FFmpeg overlay applies `0014-enable-macos-asynchronous-decode.patch`.
On macOS it passes `kVTDecodeFrame_EnableAsynchronousDecompression` to the
existing decoder call. The existing `VTDecompressionSessionWaitForAsynchronousFrames`
remains before sample release and frame postprocessing, so the consumer still
receives a completed frame. There is one submitted packet per existing decode
operation; no callback queue, extra frame buffering or decoder API change is
introduced. Other Apple platforms keep their existing flags.

The native H.264/HEVC integration test validates pixels against owned planes and
retains a native frame past decoder destruction. The test and live-session
comparison must be run with rebuilt FFmpeg archives bundled into hwcodec.
The source change is confined to FFmpeg `libavcodec/videotoolbox.c` and its
overlay patch registration. Submit-call time and submit-plus-wait time must be
reported separately; a faster return alone does not establish lower latency.


## Metal-compatible decoder output surfaces

The macOS FFmpeg overlay applies `0015-use-macos-metal-decoder-surfaces.patch`.
It replaces the decoder output's IOSurface OpenGL texture compatibility request
with `kCVPixelBufferMetalCompatibilityKey`. Width, height, IOSurface ownership,
NV12 range and the decoder's existing completion wait remain unchanged. iOS keeps
its existing OpenGL ES request.

On the Intel client, the prior OpenGL constraint caused a separate
`com.apple.coremedia.asyncpixeltransfer` worker to invoke
`VTPixelTransferSessionTransferImage` and wait for an Intel GPU fence. That worker
and call disappeared in the Metal-only diagnostic comparison. Native H.264 and
HEVC pixels still match the owned-plane decoder result, and retained native
frames remain usable after decoder destruction. Compare the rebuilt backend
against the previous backend with the same engine and workload before claiming
an overall latency benefit. Input-to-display latency remains unmeasured.

Client frame trace records now include `monotonic=Some(seconds)` from
`CLOCK_UPTIME_RAW`, matching Core Animation/Metal timestamps. Wall-clock log
prefixes can move relative to uptime during a sample; do not subtract a single
wall-clock anchor from those prefixes to calculate cross-stage latency. With
normal logging, the trace expressions are disabled. This changes diagnostics
only, without changing frame dispatch, queue policy or decoding.

Additional regression surface: `libavcodec/videotoolbox.c` changes the macOS
output-surface requirement; the overlay registration makes it reproducible.
`src/client/macos.rs`, `src/client.rs` and `src/client/io_loop.rs` add a shared
macOS trace clock. No public API, capture setting, render shader or texture
lifetime is changed by this follow-up.


## Low-interference tail measurements

Per-frame diagnostics synchronously written to a file can block the rendering
thread for about 20 ms on the tested client. Bypassing a stdio lock alone does
not exclude the underlying write syscall. Controlled tail measurements buffer
the whitelisted Rust/Metal timing records in preallocated memory and flush only
after the sample window, checking the buffer drop count. The external probe is
not part of the shipped app. Normal launches leave all trace and injection flags
unset. Client I/O trace markers include message dispatch boundaries and framed
TCP buffer length; received-frame markers include keyframes. These diagnostics
do not change queue policy or socket options.

Report transport receive gaps separately from decode-to-GPU time. TCP bursts
can create a decode queue even when each individual decode is fast. ACK-policy
experiments require their own repeated comparison and must not be inferred from
a single clean connection.


## Hidden quality-monitor updates

`QualityMonitorModel` continues to cache incoming metrics while its panel is
hidden, but only notifies its listeners when visible. Toggling visibility still
notifies and displays the latest cached metrics. This removes the once-per-second
Flutter frame that an invisible quality-panel consumer previously scheduled.
The toolbar reads the cached codec on demand and does not depend on these
notifications. Visible quality panels keep their existing live updates.

Regression surface: the shared Dart quality-monitor model and its existing test
file. No transport, decoder, native texture or GPU shader changes are involved.
