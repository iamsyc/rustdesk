# macOS texture upload changes

Vendored runtime sources from rustdesk-org/flutter_texture_rgba_renderer commit
42797e0f03141dc2b585f76c64a13974508058b4, previously pinned in flutter/pubspec.yaml.
License and other supported platform implementations are retained.

The macOS renderer copies BGRA rows with Accelerate vImageCopyBuffer and protects
only the published CVPixelBuffer reference with a separate lock. Pixel allocation,
upload, and retirement no longer hold the raster thread's read lock. Published
buffers remain immutable and copyPixelBuffer returns a retained reference.

The minimum supported macOS version is 15.8. Native regression and profiling entry:

    scripts/test-macos-texture-copy.sh FLUTTER_FRAMEWORK_DIRECTORY

The probe validates retained-frame data, different source/destination row strides,
and resolution changes. Its optional --benchmark mode measures upload duration and
concurrent raster-read waiting on a physical Mac. Timing is diagnostic output, not
a scheduler-dependent pass/fail threshold.

For H.264/H.265 VideoToolbox sessions with Flutter texture rendering enabled,
RustDesk now retains the decoder's native CVPixelBuffer. It avoids the FFmpeg
hardware-to-RAM transfer, the Rust YUV-plane copies, and CPU RGB conversion.
Core Image converts the retained frame to BGRA on Metal, then publishes the
completed surface to the existing Flutter texture. A per-texture CVPixelBufferPool
recycles BGRA IOSurfaces after all owners release them, avoiding repeated large
allocations and Metal texture retirement. Resolution changes replace the pool;
closing a texture releases it. CPU/software-decoder paths
continue using the original RGB conversion.

Each texture allows at most one asynchronous GPU conversion in flight. New input
while that task is busy replaces a single pending frame. Once the task finishes,
the latest pending frame is converted even if the desktop stops updating. A GPU
completion retains its input/output until work finishes, and generation checks
prevent publishing an old result after CPU rendering or texture close. A newer
native/CPU frame and texture close also cancel pending conversion. Close
invalidates the texture and clears its registry reference before unregistration.
The native completion callback logs GPU readiness or superseded work at trace
level; enqueue counts must not be reported as GPU-presented FPS. The texture probe
covers a burst ending in a resized white frame, cancellation by newer native/CPU
publication, and closure with pending work.

The native decoder test compares H.264/H.265 frame planes with the original
decoder and keeps a frame alive after decoder destruction. The Swift probe also
checks Metal color channels, video range, alpha, orientation, retained surfaces,
and close during pending work. `--benchmark-gpu` measures time through completion.

RustDesk also continues decoding reference frames in order while avoiding macOS
texture uploads when more than one newer frame is already queued. A single queued
frame still permits presentation, avoiding excessive frame suppression during
ordinary packet bursts. Compressed H.264/H.265 reference packets are still decoded.

The Intel client also requires the existing Flutter 3.24.5 Metal texture lifetime
patch from the fork's `codex/macos-texture-lifetime-1.5.0` branch. The installed
MacBook engine already contains that patch. Replacing it with the stock Flutter
engine reproduced frequent flickering; preserving it removed the regression in
the user's real session. This upload change does not replace that engine fix.
After building Flutter, finalize with that patched framework before packaging:

    python3 scripts/finalize-macos-client.py RustDesk.app FlutterMacOS.framework

The finalizer rejects a stock engine, verifies matching architecture and the app's
macOS 15.8 minimum, installs the supplied framework, and verifies bundle signing.
The selector check identifies the required patch; it does not prove GPU behavior.
