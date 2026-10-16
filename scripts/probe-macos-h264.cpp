// Exercise the production wrapper with real VideoToolbox hardware.
#include <cassert>
#include <cstdio>
#include <string>
#include <vector>

namespace gol {
void error(const std::string &s) { fprintf(stderr, "%s\n", s.c_str()); }
void warn(const std::string &) {}
void info(const std::string &) {}
void debug(const std::string &) {}
void trace(const std::string &) {}
}
#include "../third_party/hwcodec/cpp/ffmpeg_ram/ffmpeg_ram_encode.cpp"

struct Output { int packets = 0; int keys = 0; };
static void receive(const uint8_t *, int size, int64_t, int key, const void *obj) {
  assert(size > 0);
  auto &out = *static_cast<Output *>(const_cast<void *>(obj));
  out.packets++;
  out.keys += key != 0;
}

int main() {
  for (const auto name : {"h264_videotoolbox", "hevc_videotoolbox"}) {
    for (const int width : {1920, 2880}) {
      for (const auto fmt : {AV_PIX_FMT_YUV420P, AV_PIX_FMT_NV12}) {
        int stride[8] = {}, offset[8] = {}, length = 0;
        auto *enc = ffmpeg_ram_new_encoder(name, "", width, width * 5 / 8,
            fmt, 64, 30, 0, RC_CBR, Quality_Default, 4000, -1, 1, -1,
            stride, offset, &length, receive);
        assert(enc != nullptr);
        std::vector<uint8_t> input(length, 128);
        Output out;
        int pending = 0;
        for (int i = 0; i < 60; ++i) {
          const int before = out.packets;
          const int ret = ffmpeg_ram_encode(enc, input.data(), length, &out, i * 33);
          // EAGAIN is pending output, not an encoding failure.
          assert(ret == 0);
          pending += before == out.packets;
        }
        assert(out.packets > 0 && out.keys > 0);
        // Invalid input must still fail rather than become pending output.
        assert(ffmpeg_ram_encode(enc, input.data(), 0, &out, 2000) < 0);
        printf("PASS %s %dx%d format=%d packets=%d pending=%d keys=%d\n",
               name, width, width * 5 / 8, fmt, out.packets, pending, out.keys);
        ffmpeg_ram_free_encoder(enc);
      }
    }
  }
}
