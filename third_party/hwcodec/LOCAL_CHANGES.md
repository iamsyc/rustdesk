# Local VideoToolbox changes

Vendored from https://github.com/rustdesk-org/hwcodec at
`778df1f99597722473b29443bac22ae6c23946fe`, the revision previously pinned in
RustDesk's Cargo.lock. Upstream source and metadata are retained.

Changes:

* Restore the native H.264 hardware capability probe and register H.264
  VideoToolbox when it reports hardware support.
* Allow the macOS capability probe up to one second of input before requiring
  its first keyframe. The input frame count is limited to one second at the
  configured frame rate.
* Return success with no packets when VideoToolbox accepts input but FFmpeg
  reports EAGAIN. Continue returning errors for rejected input and other errors.
* Exercise real hardware through `tests/macos_h264.rs` and the root
  `scripts/test-macos-h264.sh` probe. The latter can use a system FFmpeg;
  the Rust integration test uses the dependency's normal build and linked FFmpeg.
  It also decodes the H.264 packets through VideoToolbox and checks frame sizes.

The application requires macOS 15.8 or newer. Rust, Runner, and CocoaPods
deployment targets use this minimum.

RustDesk propagates this no-output result as a typed pending condition, without
counting it as an encoder failure. Real hardware errors remain errors. A refresh
can wait at most one second for an asynchronous encoder's first output.

No H.264 latency or image-quality improvement is claimed until a full application
build and remote session have been tested. Preserve the existing applications
while comparing the experimental build.

The hosted CI compiles the hardware test but does not assume VideoToolbox
hardware is exposed by its virtual machine. Run the resulting test executable
on the physical Mac before installing the experimental application.
