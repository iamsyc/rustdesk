#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

#include <dlfcn.h>
#include <cstdio>
#include "shell/platform/embedder/embedder.h"

@protocol TextureContext
- (instancetype)initWithDefaultMTLDevice;
@property(nonatomic, readonly) id<MTLDevice> device;
@end

@protocol TextureHolder
- (instancetype)initWithFlutterTexture:(id)texture darwinMetalContext:(id)context;
- (BOOL)populateTexture:(FlutterMetalExternalTexture*)texture;
@end

@interface SolidRedFrame : NSObject
- (CVPixelBufferRef)copyPixelBuffer;
@end

@implementation SolidRedFrame {
  CVPixelBufferRef _buffer;
}
- (instancetype)init {
  if ((self = [super init])) {
    NSDictionary* options = @{(NSString*)kCVPixelBufferMetalCompatibilityKey : @YES};
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                                         (__bridge CFDictionaryRef)options, &_buffer);
    if (status != kCVReturnSuccess) {
      return nil;
    }
    CVPixelBufferLockBaseAddress(_buffer, 0);
    auto* bytes = static_cast<unsigned char*>(CVPixelBufferGetBaseAddress(_buffer));
    size_t stride = CVPixelBufferGetBytesPerRow(_buffer);
    for (size_t y = 0; y < 16; ++y) {
      for (size_t x = 0; x < 16; ++x) {
        bytes[y * stride + x * 4] = 0;
        bytes[y * stride + x * 4 + 1] = 0;
        bytes[y * stride + x * 4 + 2] = 255;
        bytes[y * stride + x * 4 + 3] = 255;
      }
    }
    CVPixelBufferUnlockBaseAddress(_buffer, 0);
  }
  return self;
}
- (CVPixelBufferRef)copyPixelBuffer {
  return CVPixelBufferRetain(_buffer);
}
- (void)dealloc {
  if (_buffer) {
    CVPixelBufferRelease(_buffer);
  }
}
@end

static int Failure(const char* reason, int code = 2) {
  printf("{\"ok\":false,\"reason\":\"%s\"}\n", reason);
  return code;
}

int main(int argc, char** argv) {
  @autoreleasepool {
    if (argc != 2) {
      return Failure("expected_framework_binary_argument");
    }
    if (!dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)) {
      fprintf(stderr, "%s\n", dlerror());
      return Failure("framework_load_failed");
    }
    Class contextClass = NSClassFromString(@"FlutterDarwinContextMetalSkia");
    Class holderClass = NSClassFromString(@"FlutterExternalTexture");
    if (!contextClass || !holderClass) {
      return Failure("engine_classes_unavailable");
    }
    if (!MTLCreateSystemDefaultDevice()) {
      return Failure("metal_device_unavailable", 77);
    }
    id<TextureContext> context = [(id<TextureContext>)[contextClass alloc] initWithDefaultMTLDevice];
    SolidRedFrame* provider = [[SolidRedFrame alloc] init];
    if (!provider || !context.device) {
      return Failure("frame_or_context_creation_failed");
    }
    id<TextureHolder> holder = [(id<TextureHolder>)[holderClass alloc]
        initWithFlutterTexture:provider darwinMetalContext:context];
    FlutterMetalExternalTexture frame = {};
    frame.struct_size = sizeof(frame);
    if (![holder populateTexture:&frame]) {
      return Failure("frame_population_failed");
    }
    if (!frame.destruction_callback) {
      return Failure("missing_frame_release_callback", 1);
    }
    if (!frame.user_data || frame.num_textures != 1 || !frame.textures) {
      frame.destruction_callback(frame.user_data);
      return Failure("invalid_frame_ownership_payload");
    }
    id<MTLTexture> source = (__bridge id<MTLTexture>)frame.textures[0];
    holder = nil;
    provider = nil;
    // Discrete GPUs need a managed readback buffer synchronized to the CPU.
    constexpr size_t readbackStride = 256;
    MTLResourceOptions readbackOptions = context.device.hasUnifiedMemory
                                            ? MTLResourceStorageModeShared
                                            : MTLResourceStorageModeManaged;
    id<MTLBuffer> destination = [context.device newBufferWithLength:readbackStride * 16
                                                          options:readbackOptions];
    id<MTLCommandQueue> queue = [context.device newCommandQueue];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    if (!source || !destination || !command) {
      frame.destruction_callback(frame.user_data);
      return Failure("metal_command_creation_failed");
    }
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    if (!blit) {
      frame.destruction_callback(frame.user_data);
      return Failure("metal_blit_creation_failed");
    }
    [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
              sourceSize:MTLSizeMake(16, 16, 1) toBuffer:destination destinationOffset:0
        destinationBytesPerRow:readbackStride destinationBytesPerImage:readbackStride * 16];
    if (destination.storageMode == MTLStorageModeManaged) {
      [blit synchronizeResource:destination];
    }
    [blit endEncoding];
    [command commit];
    [command waitUntilCompleted];
    bool completed = command.status == MTLCommandBufferStatusCompleted;
    auto* pixels = static_cast<const unsigned char*>(destination.contents);
    frame.destruction_callback(frame.user_data);
    if (!completed) {
      return Failure("gpu_command_failed");
    }
    if (!pixels) {
      return Failure("readback_mapping_failed");
    }
    for (size_t y = 0; y < 16; ++y) {
      for (size_t x = 0; x < 16; ++x) {
        size_t i = y * readbackStride + x * 4;
        if (pixels[i] != 0 || pixels[i + 1] != 0 || pixels[i + 2] != 255 || pixels[i + 3] != 255) {
          fprintf(stderr, "GPU=%s format=%lu source_storage=%lu pixel[%zu,%zu]=%u,%u,%u,%u\n",
                  context.device.name.UTF8String, (unsigned long)source.pixelFormat,
                  (unsigned long)source.storageMode, x, y, pixels[i], pixels[i + 1],
                  pixels[i + 2], pixels[i + 3]);
          return Failure("gpu_pixel_mismatch");
        }
      }
    }
    printf("{\"ok\":true,\"gpu_pixels\":256,\"released_after_gpu_completion\":true}\n");
    return 0;
  }
}
